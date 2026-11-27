import 'dart:convert';

import 'package:galley_core/galley_core.dart';
import 'package:http/http.dart' as http;

/// What the canvas reads and writes: a galley's rounds, its marks, and a mark raised or an event
/// recorded on one. `galley serve` is the one behind it today (DESIGN D13), and the server of
/// ROADMAP step 6 is the next. The canvas sees only this, so it does not change when the
/// backend does.
abstract interface class GalleyApi {
  /// The finished rounds, oldest first.
  Future<List<int>> rounds();

  /// Round [n]: its index, every record and every tree.
  Future<StoredRound> round(int n);

  /// Where the file at [path] of round [n], such as a frame's PNG, is fetched from.
  Uri file(int n, String path);

  /// Every mark, where it was last placed, whatever its status.
  Future<List<PlacedMark>> marks();

  /// Raises a mark on the widget at [node] in [frame] of the latest round, pinned at [at], a
  /// point in the frame's logical pixels inside that widget.
  Future<Mark> raise({
    required FrameKey frame,
    required IndexPath node,
    required ({double x, double y}) at,
    required String note,
    required String by,
  });

  /// Records [event] on the mark [id], and returns the mark as it is now. The backend stamps
  /// the time, so [event] has no `at`.
  Future<Mark> record(String id, JsonMap event);
}

/// A mark where it was last placed: in [round], or in none when no round has placed it yet.
final class PlacedMark {
  /// [carried] in [round].
  const PlacedMark(this.round, this.carried);

  /// Reads one item of `GET /api/marks`, the form `galley pull --json` prints.
  factory PlacedMark.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    final round = r.optionalInteger('round');
    return PlacedMark(
      round,
      Carried(
        r.read('mark', Mark.fromJson),
        r.read('where', Placement.fromJson),
        r.read('anchor', Anchor.fromJson),
      ),
    );
  }

  /// The round it was last placed in, or null.
  final int? round;

  /// The mark, its placement there, and its anchor.
  final Carried carried;

  /// The mark.
  Mark get mark => carried.mark;
}

/// The backend said no: [status] and its reason, in the backend's words.
final class GalleyRefusal implements Exception {
  /// A refusal.
  const GalleyRefusal(this.status, this.message);

  /// The HTTP status: 400 malformed, 404 not found, 409 not allowed now, 422 impossible, 500 a
  /// galley that does not hold together.
  final int status;

  /// Why, as the backend said it.
  final String message;

  @override
  String toString() => message;
}

/// [GalleyApi] over HTTP, against `galley serve` at [base] (the page's own origin when served).
final class HttpGalleyApi implements GalleyApi {
  /// The API at [base], through [client].
  HttpGalleyApi(this._client, this.base);

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
  Future<List<PlacedMark>> marks() async {
    final r = JsonReader(await _get(_api(['marks'])), 'marks');
    return r.readList('items', PlacedMark.fromJson);
  }

  @override
  Future<Mark> raise({
    required FrameKey frame,
    required IndexPath node,
    required ({double x, double y}) at,
    required String note,
    required String by,
  }) async {
    final reply = await _post(_api(['marks']), {
      'frame': '$frame',
      'node': node,
      'at': [at.x, at.y],
      'note': note,
      'by': by,
    });
    return JsonReader(reply, 'raised').read('mark', Mark.fromJson);
  }

  @override
  Future<Mark> record(String id, JsonMap event) async {
    final reply = await _post(_api(['marks', id, 'events']), event);
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

  /// The reply's JSON, or a [GalleyRefusal] in the backend's words when it is not a success.
  ///
  /// A reply that is not JSON is a refusal too, naming the URL. It is what a proxy, or a
  /// `galley serve` too old to have the route, answers, and showing it beats a blank canvas.
  static Object? _decode(http.Response response, Uri url) {
    Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw GalleyRefusal(response.statusCode, '$url answered ${response.statusCode}, not JSON');
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return json;
    final error = json is Map<String, Object?> ? json['error'] : null;
    throw GalleyRefusal(
      response.statusCode,
      error is String ? error : '$url answered ${response.statusCode}',
    );
  }
}

/// A round's files over HTTP, for [StoredRound.read]: a 404 is a file that is not there.
final class _HttpRoundFiles implements RoundFiles {
  _HttpRoundFiles(this._api, this._round);

  final HttpGalleyApi _api;
  final int _round;

  @override
  Future<Object?> json(String path) async {
    try {
      return await _api._get(_api.file(_round, path));
    } on GalleyRefusal catch (e) {
      if (e.status == 404) throw RoundFileMissing(path);
      rethrow;
    }
  }
}
