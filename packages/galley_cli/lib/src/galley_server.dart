import 'dart:convert';
import 'dart:io';

import 'package:galley_core/galley_core.dart';

import 'local_galley.dart';

/// A local galley over HTTP, for the canvas: its rounds as files, its marks as work items, and
/// a mark raised or an event recorded through the same [LocalGalley] the commands use.
///
/// ```
/// GET  /api/galley                  {"rounds": [1, 2], "latest_round": 2}
/// GET  /api/marks                   {"latest_round": 2, "items": [...]}, every mark, `image`
///                                   as a URL under /api/rounds
/// GET  /api/rounds/<n>/<path>       a file of finished round n: index.json, records/, trees/,
///                                   frames/
/// POST /api/marks                   {"frame": {...}, "node": [0, 1] | "at": [x, y], "note",
///                                   "by"} -> 201 {"mark", "status", "node", "round"}
/// POST /api/marks/<id>/events       a MarkEvent's JSON without "at" -> 200 {"mark", "status"}
/// GET  /<path>                      the canvas's files from `web`, when it is given
/// ```
///
/// A refusal is 409 with {"error"}, a malformed request 400, anything not found 404.
///
/// It is for one machine. It binds loopback only, and refuses a request whose Host is not
/// loopback at its port: a page on another site that rebinds its name to 127.0.0.1 reaches the
/// socket, but sends its own name as the Host (DNS rebinding). A POST must be
/// `application/json`, which a page on another origin cannot send without a CORS preflight, and
/// this server answers no preflight. Rejected: a token in the URL. It protects against the same
/// two attacks and ends up in shell history and screenshots. Who is acting is whoever the
/// request says (`by`), as it is for the commands: whoever can reach this socket can already
/// write the galley's files.
final class GalleyServer {
  GalleyServer._(this._server, this._local, this._web);

  /// Serves [local] on loopback at [port] (0 picks a free one), and the canvas from [web].
  static Future<GalleyServer> start(LocalGalley local, {int port = 0, String? web}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final s = GalleyServer._(server, local, web);
    server.listen(s._handle);
    return s;
  }

  final HttpServer _server;
  final LocalGalley _local;
  final String? _web;

  /// The largest request body read. A mark is a note and a pin; a megabyte is far past one.
  static const maxBody = 1 << 20;

  /// Where it is.
  Uri get url => Uri.parse('http://localhost:${_server.port}/');

  /// Stops serving. A request in progress is finished.
  Future<void> close() => _server.close();

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Cache-Control', 'no-store');
    try {
      if (!_isLoopbackHost(request)) throw const _Status(403, 'not a loopback host');
      final segments = request.uri.pathSegments;
      if (segments.firstOrNull == 'api') {
        await _api(request, segments.sublist(1));
      } else {
        await _static(request, segments);
      }
    } on _Status catch (e) {
      _json(response, e.code, {'error': e.message});
    } on Refused catch (e) {
      _json(response, 409, {'error': e.message});
    } on StateError catch (e) {
      _json(response, 409, {'error': e.message});
    } on FormatException catch (e) {
      _json(response, 400, {'error': e.message});
    } on ArgumentError catch (e) {
      _json(response, 400, {'error': '${e.name}: ${e.message}'});
    }
    await response.close();
  }

  bool _isLoopbackHost(HttpRequest request) {
    final host = request.headers.host;
    return (host == 'localhost' || host == '127.0.0.1') && request.headers.port == _server.port;
  }

  Future<void> _api(HttpRequest request, List<String> path) async {
    final get = request.method == 'GET', post = request.method == 'POST';
    switch (path) {
      case ['galley'] when get:
        final rounds = _local.directory.rounds();
        _json(request.response, 200, {'rounds': rounds, 'latest_round': rounds.lastOrNull});
      case ['marks'] when get:
        _json(request.response, 200, {
          'latest_round': _local.directory.rounds().lastOrNull,
          'items': await _local.workItems(all: true, imageAt: _roundUrl),
        });
      case ['marks'] when post:
        final json = await _object(request);
        final body = JsonReader(json, 'request');
        final target = switch ((json['node'], json['at'])) {
          (List<Object?>(), null) => AtNode(body.integers('node')),
          (null, [final num x, final num y]) => AtPoint(x.toDouble(), y.toDouble()),
          _ => throw const FormatException('request: give one of "node": [0, 1] and "at": [x, y]'),
        };
        final raised = await _local.raise(
          frame: FrameKey(_strings(json['frame'], 'request.frame')),
          target: target,
          note: body.string('note'),
          by: body.string('by'),
        );
        _json(request.response, 201, {
          'mark': raised.mark.toJson(),
          'status': raised.mark.status.name,
          'node': raised.node.toJson(),
          'round': raised.round,
        });
      case ['marks', final id, 'events'] when post:
        final event = await _object(request);
        final mark = _local.record(id, (at) => MarkEvent.fromJson(_stamped(event, at), 'request'));
        _json(request.response, 200, {'mark': mark.toJson(), 'status': mark.status.name});
      case ['rounds', final n, ...final file] when get:
        final round = int.tryParse(n);
        if (round == null || !_local.directory.rounds().contains(round)) {
          throw _Status(404, 'no finished round $n');
        }
        await _file(request.response, _local.directory.roundPath(round), file);
      case ['galley'] || ['marks'] || ['marks', _, 'events'] || ['rounds', ...]:
        throw _Status(405, '${request.method} is not allowed here');
      default:
        throw _Status(404, 'no ${request.uri.path}');
    }
  }

  /// [event] with the server's [at], and a fix's commit in full. The time is the server's, not
  /// the client's: a history ordered by clocks the reviewers set is not an order.
  JsonMap _stamped(JsonMap event, DateTime at) {
    final answer = event['answer'];
    return {
      ...event,
      'at': at.toIso8601String(),
      if (event['event'] == 'answered' && answer is JsonMap && answer['kind'] == 'fixed')
        'answer': {
          ...answer,
          'commit': _local.fullCommit(JsonReader(answer, 'answer').string('commit')),
        },
    };
  }

  String _roundUrl(int round, String image) =>
      Uri(pathSegments: ['', 'api', 'rounds', '$round', ...image.split('/')]).toString();

  Future<void> _static(HttpRequest request, List<String> path) async {
    final web = _web;
    if (web == null) throw const _Status(404, 'no canvas here: serve was started without --web');
    if (request.method != 'GET') throw _Status(405, '${request.method} is not allowed here');
    await _file(request.response, web, path.isEmpty || path.last.isEmpty ? ['index.html'] : path);
  }

  /// Sends [path] under [root], which it must not leave.
  ///
  /// One rule: the file, with every `..` and symlink resolved, must be under the resolved
  /// root. That catches `..`, `%2e%2e`, an encoded `/` or `\` decoded into a segment, and a
  /// symlink out. Rejected: also refusing such segments one by one. Mutation showed no request
  /// that the segment check refuses and this rule lets through, so it proved nothing.
  static Future<void> _file(HttpResponse response, String root, List<String> path) async {
    final file = File('$root/${path.join('/')}');
    // A directory is not a File, so an empty path, or a round's own directory, is not found.
    if (!file.existsSync()) throw const _Status(404, 'no such file');
    final base = Directory(root).resolveSymbolicLinksSync();
    if (!file.resolveSymbolicLinksSync().startsWith('$base${Platform.pathSeparator}')) {
      throw const _Status(404, 'no such file');
    }
    response
      ..statusCode = 200
      ..headers.contentType = _types[path.last.split('.').last] ?? ContentType.binary;
    await response.addStream(file.openRead());
  }

  static final _types = {
    'json': ContentType.json,
    'png': ContentType('image', 'png'),
    'html': ContentType.html,
    'js': ContentType('text', 'javascript', charset: 'utf-8'),
    'mjs': ContentType('text', 'javascript', charset: 'utf-8'),
    'css': ContentType('text', 'css', charset: 'utf-8'),
    'wasm': ContentType('application', 'wasm'),
    'svg': ContentType('image', 'svg+xml'),
    'ttf': ContentType('font', 'ttf'),
    'otf': ContentType('font', 'otf'),
    'ico': ContentType('image', 'x-icon'),
  };

  static Future<JsonMap> _object(HttpRequest request) async => switch (await _body(request)) {
    final JsonMap m => m,
    _ => throw const FormatException('request: not a JSON object'),
  };

  static Future<Object?> _body(HttpRequest request) async {
    if (request.headers.contentType?.mimeType != 'application/json') {
      throw const _Status(415, 'a POST is application/json');
    }
    // Past the limit the rest is read and dropped, not kept: replying before the client has
    // sent it all resets the connection, and the client sees no 413, only a broken pipe.
    final bytes = <int>[];
    var size = 0;
    await for (final chunk in request) {
      size += chunk.length;
      if (size <= maxBody) bytes.addAll(chunk);
    }
    if (size > maxBody) throw const _Status(413, 'the request is too large');
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw FormatException('request: not JSON (${e.message})');
    }
  }

  static Map<String, String> _strings(Object? json, String context) => switch (json) {
    final Map<String, Object?> m => {
      for (final MapEntry(:key, :value) in m.entries)
        key: value is String ? value : throw FormatException('$context.$key: not a string'),
    },
    _ => throw FormatException('$context: not an object of axis to value'),
  };

  static void _json(HttpResponse response, int code, Object? body) {
    response
      ..statusCode = code
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
  }
}

/// An HTTP status, and why.
final class _Status implements Exception {
  const _Status(this.code, this.message);
  final int code;
  final String message;
}
