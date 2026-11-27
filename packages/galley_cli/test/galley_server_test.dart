import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:galley_cli/galley_cli.dart';
import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

import 'support/round.dart';

void main() {
  late Directory dir;
  late GalleyDirectory g;
  late GalleyServer server;
  late String commit;
  final clock = DateTime.utc(2026, 11, 26, 9, 30);
  var ids = 0;

  String git(List<String> args) {
    final r = Process.runSync('git', [
      '-c', 'user.name=galley', '-c', 'user.email=galley@example.invalid',
      '-c', 'commit.gpgsign=false', ...args, //
    ], workingDirectory: dir.path);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return '${r.stdout}'.trim();
  }

  Future<GalleyServer> serve({String? web}) => GalleyServer.start(
    LocalGalley(g, repository: dir.path, now: () => clock, newId: () => 'm${++ids}'),
    canvas: web == null ? const NoCanvas('it was not given one') : CanvasAt(web),
  );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('galley_server_');
    git(['init', '-q']);
    File('${dir.path}/a.txt').writeAsStringSync('a\n');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'one']);
    commit = git(['rev-parse', 'HEAD']);
    g = GalleyDirectory('${dir.path}/.galley');
    ids = 0;
    writeRound(g);
    server = await serve();
  });
  tearDown(() async {
    await server.close();
    dir.deleteSync(recursive: true);
  });

  final client = HttpClient();
  tearDownAll(client.close);

  /// [method] [path] with an optional JSON [body], answered as (status, content type, bytes).
  Future<(int, String?, List<int>)> call(
    String method,
    String path, {
    Object? body,
    String type = 'application/json',
    GalleyServer? on,
  }) async {
    final request = await client.openUrl(method, (on ?? server).url.resolve(path));
    if (body != null) {
      request.headers.contentType = ContentType.parse(type);
      request.write(body is String ? body : jsonEncode(body));
    }
    final response = await request.close();
    final bytes = [for (final chunk in await response.toList()) ...chunk];
    return (response.statusCode, response.headers.contentType?.mimeType, bytes);
  }

  Future<(int, Object?)> json(String method, String path, {Object? body, String? type}) async {
    final (code, _, bytes) = await call(method, path, body: body, type: type ?? 'application/json');
    return (code, jsonDecode(utf8.decode(bytes)));
  }

  /// The request exactly as written, so a path an HTTP client would normalize (`..`) reaches
  /// the server as sent. Returns the status code.
  Future<int> raw(String target, {String? host, InternetAddress? to}) async {
    final socket = await Socket.connect(to ?? InternetAddress.loopbackIPv4, server.url.port);
    socket.write(
      'GET $target HTTP/1.1\r\nHost: ${host ?? 'localhost:${server.url.port}'}\r\n'
      'Connection: close\r\n\r\n',
    );
    final reply = utf8.decode([for (final c in await socket.toList()) ...c], allowMalformed: true);
    socket.destroy();
    return int.parse(reply.split(' ')[1]);
  }

  test('the galley, and a round\'s files as they were written', () async {
    // Records compare with ==, so a list or a matcher inside one never matches: one expect
    // per value.
    final (galleyCode, galley) = await json('GET', '/api/galley');
    expect(galleyCode, 200);
    expect(galley, {
      'rounds': [1],
      'latest_round': 1,
    });
    final (code, type, bytes) = await call('GET', '/api/rounds/1/frames/drawn.png');
    expect((code, type), (200, 'image/png'));
    expect(bytes, png);
    final (indexCode, index) = await json('GET', '/api/rounds/1/index.json');
    expect(indexCode, 200);
    expect((index! as JsonMap)['frames'], ['records/drawn.json', 'records/blank.json']);
  });

  test('a round that did not finish, or a file not in it, is not found', () async {
    File('${g.roundPath(2)}/records/x.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    expect((await call('GET', '/api/rounds/2/records/x.json')).$1, 404, reason: 'no index.json');
    expect((await call('GET', '/api/rounds/one/index.json')).$1, 404);
    expect((await call('GET', '/api/rounds/1/frames/none.png')).$1, 404);
    expect((await call('GET', '/api/rounds/1')).$1, 404, reason: 'a round is not a file');
  });

  test('nothing outside a round is served, however the path is spelled', () async {
    File('${dir.path}/secret.txt').writeAsStringSync('secret');
    Link('${g.roundPath(1)}/out.txt').createSync('${dir.path}/secret.txt');
    // Positive control: the raw request reaches a file that is there.
    expect(await raw('/api/rounds/1/index.json'), 200);
    for (final target in [
      '/api/rounds/1/../../../secret.txt',
      '/api/rounds/1/%2e%2e/%2e%2e/%2e%2e/secret.txt',
      '/api/rounds/1/..%2F..%2F..%2Fsecret.txt',
      '/api/rounds/1/frames/..%5C..%5Csecret.txt',
      '/api/rounds/1/out.txt',
    ]) {
      expect(await raw(target), 404, reason: target);
    }
  });

  test('a request naming another host is refused: DNS rebinding', () async {
    expect(await raw('/api/galley', host: '127.0.0.1:${server.url.port}'), 200);
    expect(await raw('/api/galley', host: 'evil.example:${server.url.port}'), 403);
    expect(await raw('/api/galley', host: 'localhost:1'), 403, reason: 'another port');
    expect(await raw('/api/galley', host: 'localhost.evil.example'), 403);
    expect(await raw('/api/galley', host: '[::2]:${server.url.port}'), 403);
  });

  test('it answers on IPv6 loopback too, at the same port', () async {
    final v6 = InternetAddress.loopbackIPv6;
    expect(await raw('/api/galley', to: v6, host: '[::1]:${server.url.port}'), 200);
    expect(await raw('/api/galley', to: v6), 200, reason: 'Host: localhost, reached on ::1');
    expect(await raw('/api/galley', to: v6, host: 'evil.example:${server.url.port}'), 403);
  });

  test('a mark raised here is saved, placed, and listed with its image as a URL', () async {
    final (code, body) = await json(
      'POST',
      '/api/marks',
      body: {
        'frame': {'screen': 'drawn'},
        'at': [100, 50],
        'note': 'too tight',
        'by': 'r',
      },
    );
    expect(code, 201, reason: '$body');
    final raised = body! as JsonMap;
    expect(((raised['node']! as JsonMap)['type'], raised['round']), ('Card', 1));
    expect(raised['status'], 'open');
    expect((raised['mark']! as JsonMap)['pin'], {'dx': 0.5, 'dy': 0.5});
    expect(g.mark('m1')!.note, 'too tight');
    expect(g.placements(1)!.of('m1'), isNotNull);

    // The key string a mark's JSON carries is taken back as it is.
    expect((raised['mark']! as JsonMap)['frame'], 'screen=drawn');
    final (secondCode, second) = await json(
      'POST',
      '/api/marks',
      body: {
        'frame': 'screen=blank',
        'node': [0],
        'note': 'n',
        'by': 'r',
      },
    );
    expect(secondCode, 201, reason: '$second');
    expect(g.mark('m2')!.frame, FrameKey({'screen': 'blank'}));

    // A widget and a point in it: the reviewer clicked the card's corner and picked the App.
    final (thirdCode, third) = await json(
      'POST',
      '/api/marks',
      body: {
        'frame': 'screen=drawn',
        'node': <int>[],
        'at': [100, 50],
        'note': 'the whole page',
        'by': 'r',
      },
    );
    expect(thirdCode, 201, reason: '$third');
    expect(
      (g.mark('m3')!.anchor.type, g.mark('m3')!.pin.dx, g.mark('m3')!.pin.dy),
      ('App', 0.25, 0.0625),
    );
    final (listCode, list) = await json('GET', '/api/marks');
    expect(listCode, 200);
    final items = ((list! as JsonMap)['items']! as List).cast<JsonMap>();
    expect(
      [for (final i in items) (i['id'], i['image'])],
      [
        ('m1', '/api/rounds/1/frames/drawn.png'),
        ('m2', null),
        ('m3', '/api/rounds/1/frames/drawn.png'),
      ],
    );
    expect((await call('GET', items[0]['image']! as String)).$3, png);
  });

  test('a mark that cannot be raised is refused, and nothing is saved', () async {
    final good = {
      'frame': {'screen': 'drawn'},
      'node': [0],
      'note': 'x',
      'by': 'r',
    };
    for (final (body, code, error) in [
      ({...good, 'note': ' '}, 422, 'a mark says what is wrong'),
      ({...good, 'by': ''}, 422, 'a mark says who raised it'),
      (
        {
          ...good,
          'frame': {'screen': 'gone'},
        },
        422,
        'has no frame',
      ),
      (
        {
          ...good,
          'node': [5],
        },
        422,
        'no widget',
      ),
      (
        {
          ...good,
          'at': [300, 50],
        },
        422,
        'is outside Card',
      ),
      ({...good}..remove('node'), 400, 'give "node"'),
      (
        {
          ...good,
          'at': {'dx': 0.5, 'dy': 0.5},
        },
        400,
        'not a pin\'s {"dx", "dy"}',
      ),
      (
        {
          ...good,
          'at': {'dx': 0.5, 'dy': 0.5},
        }..remove('node'),
        400,
        'not a pin\'s {"dx", "dy"}',
      ),
      ({...good}..remove('note'), 400, 'note'),
      (
        {
          ...good,
          'frame': {'screen': 1},
        },
        400,
        'not a string',
      ),
      ({...good, 'frame': 'screen'}, 400, 'not axis=value'),
      ({...good, 'frame': 7}, 400, 'not a key or an object'),
    ]) {
      final (got, reply) = await json('POST', '/api/marks', body: body);
      expect(got, code, reason: '$body');
      expect((reply! as JsonMap)['error'], contains(error), reason: '$body');
    }
    expect((await json('POST', '/api/marks', body: good, type: 'text/plain')).$1, 415);
    expect((await json('POST', '/api/marks', body: '{"frame":')).$1, 400);
    expect((await json('POST', '/api/marks', body: '[1]')).$1, 400);
    final huge = {...good, 'note': 'x' * (GalleyServer.maxBody + 1)};
    expect((await json('POST', '/api/marks', body: huge)).$1, 413);
    expect(g.marks(), isEmpty);
    expect(ids, 0, reason: 'no id was taken by a refusal');
    // Positive control: the same body, well formed, is raised.
    expect((await json('POST', '/api/marks', body: good)).$1, 201);
  });

  test('events are recorded at the server\'s time, a fix names its full commit', () async {
    await json(
      'POST',
      '/api/marks',
      body: {
        'frame': {'screen': 'drawn'},
        'node': [0],
        'note': 'x',
        'by': 'r',
      },
    );
    Future<(int, Object?)> event(JsonMap e) => json('POST', '/api/marks/m1/events', body: e);

    var (code, body) = await event({'event': 'verified', 'by': 'r'});
    expect(
      (code, (body! as JsonMap)['error']),
      (409, 'mark m1 is open, and cannot be verified now'),
    );
    (code, body) = await event({
      'event': 'answered',
      'by': 'c',
      'answer': {'kind': 'fixed', 'commit': 'abcdef1'},
    });
    expect(code, 422);
    expect((body! as JsonMap)['error'], contains('is not a commit'));

    (code, body) = await event({
      'event': 'answered',
      'by': 'c',
      'at': '1999-01-01T00:00:00.000Z',
      'answer': {'kind': 'fixed', 'commit': commit.substring(0, 7)},
    });
    expect(code, 200, reason: '$body');
    final answered = g.mark('m1')!.history.single as Answered;
    expect((answered.answer.commit, answered.at), (commit, clock));

    (code, body) = await event({'event': 'reopened', 'by': 'r', 'note': ''});
    expect(code, 400, reason: 'a reopen says why');
    (code, body) = await event({'event': 'reopened', 'by': 'r', 'note': 'the left edge'});
    expect((code, (body! as JsonMap)['status']), (200, 'reopened'));
    expect(g.mark('m1')!.history.map((e) => e.runtimeType), [Answered, Reopened]);

    expect(
      (await json('POST', '/api/marks/m9/events', body: {'event': 'verified', 'by': 'r'})).$1,
      404,
      reason: 'no such mark',
    );
    expect((await event({'event': 'deleted', 'by': 'r'})).$1, 400);
  });

  test('a mark is withdrawn by whoever raised it, and is still listed', () async {
    await json(
      'POST',
      '/api/marks',
      body: {
        'frame': 'screen=drawn',
        'node': [0],
        'note': 'x',
        'by': 'r',
      },
    );
    Future<(int, Object?)> withdraw(String by) => json(
      'POST',
      '/api/marks/m1/events',
      body: {'event': 'withdrawn', 'by': by, 'note': 'a duplicate'},
    );
    var (code, body) = await withdraw('c');
    expect(
      (code, (body! as JsonMap)['error']),
      (409, 'mark m1 was raised by r, and only they can withdraw it'),
    );
    (code, body) = await withdraw('r');
    expect((code, (body! as JsonMap)['status']), (200, 'withdrawn'));
    final (_, marks) = await json('GET', '/api/marks');
    final items = ((marks! as JsonMap)['items']! as List).cast<JsonMap>();
    expect([for (final i in items) (i['id'], i['status'])], [('m1', 'withdrawn')]);
  });

  group('a galley whose own files do not read', () {
    // What the adopting app did: delete a mark's file by hand, leaving a round's placements
    // still naming it.
    Future<void> damage() async {
      await json(
        'POST',
        '/api/marks',
        body: {
          'frame': 'screen=drawn',
          'node': [0],
          'note': 'x',
          'by': 'r',
        },
      );
      File('${g.path}/marks/m1.json').deleteSync();
    }

    test('is 500 naming the file, not 400 blaming the request', () async {
      await damage();
      final (code, body) = await json(
        'POST',
        '/api/marks',
        body: {
          'frame': 'screen=drawn',
          'node': [0],
          'note': 'y',
          'by': 'r',
        },
      );
      expect(code, 500);
      expect(
        (body! as JsonMap)['error'],
        allOf(
          contains('does not hold together'),
          contains('rounds/1/placements.json'),
          contains('no mark "m1"'),
          contains('marks/m1.json is not there'),
        ),
      );
      expect((await json('GET', '/api/marks')).$1, 500);
      expect(g.marks(), isEmpty, reason: 'nothing more was written');
    });

    test('is refused at start, naming the file', () async {
      await damage();
      await expectLater(
        serve(),
        throwsA(
          isA<Refused>()
              .having((r) => r.kind, 'kind', RefusalKind.damaged)
              .having((r) => r.message, 'message', contains('rounds/1/placements.json')),
        ),
      );
      final err = StringBuffer();
      expect(
        await runGalley([
          '--app',
          dir.path,
          'serve',
          '--port',
          '0',
        ], GalleyContext(out: StringBuffer(), err: err, environment: const {})),
        1,
      );
      expect('$err', allOf(contains('rounds/1/placements.json'), contains('marks/m1.json')));
    });

    test('a round record that does not read, or is not there, is 500 too, naming it', () async {
      final record = File('${g.roundPath(1)}/records/drawn.json');
      Future<(int, Object?)> post() => json(
        'POST',
        '/api/marks',
        body: {
          'frame': 'screen=drawn',
          'node': [0],
          'note': 'y',
          'by': 'r',
        },
      );
      record.writeAsStringSync('{');
      var (code, body) = await post();
      expect(code, 500);
      expect(
        (body! as JsonMap)['error'],
        'round 1: ${record.path}: not JSON (Unexpected end of input)',
      );
      record.deleteSync();
      (code, body) = await post();
      expect(code, 500);
      expect(
        (body! as JsonMap)['error'],
        'round 1 in ${g.path}/rounds/1: records/drawn.json is listed and not there',
      );
    });
  });

  test('a wrong method is 405, a wrong path 404', () async {
    expect((await json('DELETE', '/api/marks')).$1, 405);
    expect((await json('GET', '/api/marks/m1/events')).$1, 405);
    expect((await json('POST', '/api/galley', body: {})).$1, 405);
    expect((await json('GET', '/api/nothing')).$1, 404);
    // Apart, not as one record: a record compares its map by identity.
    final (code, body) = await json('GET', '/');
    expect(code, 404);
    expect(body, {'error': 'no canvas here: it was not given one'});
  });

  test('the canvas is served from web, and nothing outside it', () async {
    final web = Directory('${dir.path}/web')..createSync();
    File('${web.path}/index.html').writeAsStringSync('<html>canvas</html>');
    File('${web.path}/main.dart.js').writeAsStringSync('main()');
    File('${dir.path}/secret.txt').writeAsStringSync('secret');
    final canvas = await serve(web: web.path);
    addTearDown(canvas.close);
    final (code, type, bytes) = await call('GET', '/', on: canvas);
    expect((code, type, utf8.decode(bytes)), (200, 'text/html', '<html>canvas</html>'));
    expect((await call('GET', '/main.dart.js', on: canvas)).$2, 'text/javascript');
    expect((await call('POST', '/', on: canvas, body: {})).$1, 405);
    expect((await call('GET', '/%2e%2e/secret.txt', on: canvas)).$1, 404);
    expect(
      (await call('GET', '/api/galley', on: canvas)).$1,
      200,
      reason: 'the api is still there',
    );
  });

  test('galley serve listens until it is stopped, and refuses what it cannot serve', () async {
    final out = StringBuffer(), err = StringBuffer();
    final stop = Completer<void>();
    GalleyContext context() =>
        GalleyContext(out: out, err: err, untilStopped: () => stop.future, environment: const {});
    final running = runGalley(['--app', dir.path, 'serve', '--port', '0'], context());
    await Future.doWhile(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return !'$out'.contains('Serving');
    }).timeout(const Duration(seconds: 5));
    final url = Uri.parse(RegExp(r'http://\S+').firstMatch('$out')![0]!);
    final request = await client.getUrl(url.resolve('/api/galley'));
    expect((await request.close()).statusCode, 200);
    stop.complete();
    expect(await running, 0);

    expect(
      await runGalley(['--app', dir.path, 'serve', '--port', '${server.url.port}'], context()),
      1,
      reason: 'the port is taken',
    );
    expect('$err', contains('could not listen on port ${server.url.port}'));
    expect(await runGalley(['--app', dir.path, 'serve', '--web', dir.path], context()), 1);
    expect('$err', contains('has no index.html'));
    expect(await runGalley(['--app', dir.path, 'serve', '--port', 'x'], context()), 64);
  });
}
