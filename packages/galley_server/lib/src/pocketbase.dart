import 'dart:convert';
import 'dart:typed_data';

import 'package:galley_core/galley_core.dart';
import 'package:http/http.dart' as http;

/// How long to wait before the [attempt]th try of a request PocketBase answered 429.
typedef Backoff = Duration Function(int attempt);

/// PocketBase's REST API at [base], through package:http, so the CLI and the canvas (on the
/// web) speak it the same way (docs/DESIGN.md D15).
///
/// Every refusal is a [Refused] in PocketBase's own words, with the kind its status names.
final class PocketBase {
  /// The server at [base], through [client]. [backoff] says how long to wait out a 429.
  PocketBase(this._client, this.base, {Backoff? backoff}) : _backoff = backoff ?? _waitMore;

  final http.Client _client;
  final Backoff _backoff;

  /// The server's root: `/api` is under it.
  final Uri base;

  /// The most tries a request gets while PocketBase answers 429.
  static const tries = 8;

  /// The most records one page asks for: PocketBase's own cap (apis/record_crud.go, v0.40.6).
  static const pageSize = 500;

  /// The first wait is half a second, and each one after is half a second longer: the
  /// limiter's shortest window is one second, and the sign-in window three.
  static Duration _waitMore(int attempt) => Duration(milliseconds: 500 * attempt);

  /// `/api/<segments>` with [query]. Each segment is encoded, so a record id or file name is
  /// never read as a path.
  Uri api(List<String> segments, [Map<String, String>? query]) => base.replace(
    pathSegments: [...base.pathSegments.where((s) => s.isNotEmpty), 'api', ...segments],
    queryParameters: query == null || query.isEmpty ? null : query,
  );

  /// Sends [method] to [url] with [body] as JSON and [token] as its `Authorization`, and
  /// returns the reply's JSON (null for an empty reply).
  ///
  /// A 429 is waited out and sent again, up to [tries] in all. Galley turns PocketBase's rate
  /// limiter on, and it counts by address: every reviewer behind one router shares a limit.
  /// Rejected: turning the limiter off, or up. It is what keeps a sign-in code from being
  /// guessed.
  Future<Object?> send(String method, Uri url, {Object? body, String? token}) => _retrying(url, () {
    final request = http.Request(method, url);
    if (token != null) request.headers['Authorization'] = token;
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    return request;
  });

  /// Creates a record of [collection] with [fields] and the file [bytes] in [field], named
  /// [filename], as a multipart request: the one way PocketBase takes a file.
  Future<JsonMap> upload(
    String collection, {
    required Map<String, String> fields,
    required String field,
    required String filename,
    required Uint8List bytes,
    required String token,
  }) async {
    final url = api(['collections', collection, 'records']);
    final reply = await _retrying(url, () {
      final request = http.MultipartRequest('POST', url)
        ..headers['Authorization'] = token
        ..fields.addAll(fields)
        ..files.add(http.MultipartFile.fromBytes(field, bytes, filename: filename));
      return request;
    });
    return _object(reply, url);
  }

  /// Every record of [collection] that [token]'s user may list, matching [filter], in [sort]
  /// order, read a page at a time.
  ///
  /// Each page skips the total (`skipTotal`), which PocketBase would otherwise count with a
  /// second query per page; the last page is the first one shorter than [pageSize].
  Future<List<JsonMap>> list(
    String collection, {
    String? filter,
    String sort = 'created,id',
    required String token,
  }) async {
    final all = <JsonMap>[];
    for (var page = 1; ; page++) {
      final url = api(
        ['collections', collection, 'records'],
        {
          'page': '$page',
          'perPage': '$pageSize',
          'skipTotal': 'true',
          'sort': sort,
          'filter': ?filter,
        },
      );
      final r = JsonReader(await send('GET', url, token: token), '$url');
      final items = r.list('items');
      all.addAll([for (final i in items) _object(i, url)]);
      if (items.length < pageSize) return all;
    }
  }

  /// The bytes at [url], as [token]'s user may read them.
  Future<Uint8List> bytes(Uri url) async {
    final response = await _sent(url, () => http.Request('GET', url));
    if (response.statusCode == 200) return response.bodyBytes;
    throw _refusal(response, url);
  }

  Future<Object?> _retrying(Uri url, http.BaseRequest Function() request) async {
    final response = await _sent(url, request);
    final ok = response.statusCode >= 200 && response.statusCode < 300;
    if (!ok) throw _refusal(response, url);
    if (response.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw Refused.environment('$url answered ${response.statusCode}, and not with JSON');
    }
  }

  /// [request]'s answer, sent again while it is 429, up to [tries] in all. A request is built
  /// anew for each try: package:http sends a request once.
  Future<http.Response> _sent(Uri url, http.BaseRequest Function() request) async {
    for (var attempt = 1; ; attempt++) {
      final http.Response response;
      try {
        response = await http.Response.fromStream(await _client.send(request()));
      } on http.ClientException catch (e) {
        throw Refused.environment('could not reach $base: ${e.message}');
      }
      if (response.statusCode != 429 || attempt >= tries) return response;
      await Future<void>.delayed(_backoff(attempt));
    }
  }

  /// A failed answer as a [Refused], in PocketBase's message when it gave one.
  ///
  /// A 401 is a sign-in that has run out, and says what to do. PocketBase sentenizes what a
  /// hook throws ("Round 2 is not next: the next round is 1."), and that is passed on as it is.
  /// A field's own error (`data.<field>.message`) is added, since the top-level message for a
  /// failed rule or a failed field is the same "Failed to create record.".
  Refused _refusal(http.Response response, Uri url) {
    final status = response.statusCode;
    if (status == 401) {
      return Refused.environment('$base: the sign-in has run out or was refused; sign in again');
    }
    Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      json = null;
    }
    final message = switch (json) {
      {'message': final String m} when m.isNotEmpty => m,
      _ => '$url answered $status',
    };
    final fields = switch (json) {
      {'data': final Map<String, Object?> data} => [
        for (final MapEntry(:key, :value) in data.entries)
          if (value case {'message': final String m}) '$key: $m',
      ],
      _ => const <String>[],
    };
    return Refused.ofStatus(status, fields.isEmpty ? message : '$message (${fields.join('; ')})');
  }

  static JsonMap _object(Object? json, Uri url) => switch (json) {
    final JsonMap m => m,
    _ => throw Refused.environment('$url answered with something that is not a record'),
  };
}
