import 'dart:convert';

import 'package:galley_core/galley_core.dart';
import 'package:http/http.dart' as http;

/// A [Galley] over HTTP, against `galley serve` at [base] (the page's own origin when served).
/// The canvas sees only [Galley], so it does not change when the backend does.
final class ServedGalley implements Galley {
  /// The API at [base], through [client].
  ServedGalley(this._client, this.base);

  final http.Client _client;

  /// Where `/api` is.
  final Uri base;

  @override
  Future<List<int>> rounds() async {
    final r = JsonReader(await _get(_api(['galley'])), 'galley');
    return r.integers('rounds');
  }

  @override
  Future<StoredRound> round(int n) => StoredRound.read(_HttpRoundFiles(this, n));

  @override
  Uri file(int n, String path) => _api(['rounds', '$n', ...path.split('/')]);

  @override
  Future<GalleyMarks> marks() async => GalleyMarks.fromJson(await _get(_api(['marks'])), 'marks');

  @override
  Future<({Mark mark, WidgetNode node, int round})> raise({
    required FrameKey frame,
    required PinTarget target,
    required String note,
    required String by,
  }) async {
    final reply = await _post(_api(['marks']), {
      'frame': '$frame',
      ...target.toJson(),
      'note': note,
      'by': by,
    });
    final r = JsonReader(reply, 'raised');
    return (
      mark: r.read('mark', Mark.fromJson),
      node: r.read('node', WidgetNode.fromJson),
      round: r.integer('round'),
    );
  }

  @override
  Future<Mark> record(String id, MarkEvent Function(DateTime at) event) async {
    // `galley serve` gives the time, so the event goes without one (D13).
    final json = event(DateTime.now().toUtc()).toJson()..remove('at');
    final reply = await _post(_api(['marks', id, 'events']), json);
    return JsonReader(reply, 'recorded').read('mark', Mark.fromJson);
  }

  /// A path under `/api`, each segment encoded: a frame's file name holds `=` and `;`.
  /// `/api/<segments>` on [base]'s server. Built from [base]'s parts, not with [Uri.replace]:
  /// there a null query keeps the page's own (`?by=<name>`), which would then ride on every
  /// call.
  Uri _api(List<String> segments) => Uri(
    scheme: base.scheme,
    userInfo: base.userInfo,
    host: base.host,
    port: base.port,
    pathSegments: ['api', ...segments],
  );

  Future<Object?> _get(Uri url) async => _decode(await _client.get(url), url);

  Future<Object?> _post(Uri url, JsonMap body) async => _decode(
    await _client.post(
      url,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ),
    url,
  );

  /// The reply's JSON, or a [Refused] in the backend's words when it is not a success.
  ///
  /// A reply that is not JSON is a refusal too, naming the URL. It is what a proxy, or a
  /// `galley serve` too old to have the route, answers, and showing it beats a blank canvas.
  static Object? _decode(http.Response response, Uri url) {
    Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw Refused.ofStatus(response.statusCode, '$url answered ${response.statusCode}, not JSON');
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return json;
    final error = json is Map<String, Object?> ? json['error'] : null;
    throw Refused.ofStatus(
      response.statusCode,
      error is String ? error : '$url answered ${response.statusCode}',
    );
  }
}

/// A round's files over HTTP, for [StoredRound.read]: a 404 is a file that is not there.
final class _HttpRoundFiles implements RoundFiles {
  _HttpRoundFiles(this._api, this._round);

  final ServedGalley _api;
  final int _round;

  @override
  Future<Object?> json(String path) async {
    try {
      return await _api._get(_api.file(_round, path));
    } on Refused catch (e) {
      if (e.kind == RefusalKind.missing) throw RoundFileMissing(path);
      rethrow;
    }
  }
}
