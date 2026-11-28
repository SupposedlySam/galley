@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:galley_cli/galley_cli.dart';
import 'package:galley_cli/src/rest.dart';
import 'package:galley_cli/src/server_source.dart';
import 'package:test/test.dart';

import 'support/pocketbase.dart' show cache, codeAfter;

// `galley bundle` (DESIGN D18): a Galley server written out for a machine elsewhere. The
// bundle for this machine is run here, through its own `run`, as a host would run it; the
// bundle for Linux is checked to be Linux's, since nothing here can run it.

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('galley_bundle_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String canvas() {
    final web = Directory('${tmp.path}/web')..createSync();
    File('${web.path}/index.html').writeAsStringSync('<html>canvas</html>');
    return web.path;
  }

  Future<(int, String, String)> bundle(
    List<String> args, {
    Future<Uint8List> Function(Uri url)? fetch,
  }) async {
    final (out, err) = (StringBuffer(), StringBuffer());
    final code = await runGalley(
      ['bundle', ...args],
      GalleyContext(
        out: out,
        err: err,
        environment: {'GALLEY_CACHE': cache.root},
        fetch: fetch ?? httpFetch,
        now: () => DateTime.utc(2026, 11, 27, 12),
      ),
    );
    return (code, '$out', '$err');
  }

  final here = PinnedPocketBase.forAbi()!.platform;

  test('for this machine, runs by its own `run`: the canvas, sign-in, and judged writes', () async {
    final to = '${tmp.path}/server';
    final (code, out, err) = await bundle([to, '--platform', here, '--web', canvas()]);
    expect((code, err), (0, ''));
    expect(out, contains('Writing a Galley server for $here to $to'));

    final port = await () async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final p = s.port;
      await s.close();
      return p;
    }();
    final data = '${tmp.path}/data';
    final otp = Directory('${tmp.path}/otp')..createSync();
    // Started from another directory: `run` finds its files beside itself.
    final server = await Process.start(
      '$to/run',
      [],
      workingDirectory: tmp.path,
      environment: {
        'GALLEY_DATA': data,
        'GALLEY_HTTP': '127.0.0.1:$port',
        'GALLEY_OWNERS': 'op@example.com',
        'GALLEY_OTP_LOG': otp.path,
      },
    );
    final said = StringBuffer();
    server.stdout.transform(utf8.decoder).listen(said.write);
    server.stderr.transform(utf8.decoder).listen(said.write);
    addTearDown(() async {
      server.kill();
      await server.exitCode;
    });
    final url = Uri.parse('http://127.0.0.1:$port');
    Answer? health;
    for (var i = 0; i < 100 && health?.status != 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      try {
        health = await send(url, 'GET', '/api/health', tries: 1);
      } on Object {
        // Not listening yet.
      }
    }
    expect(health?.status, 200, reason: '$said');

    final client = HttpClient();
    addTearDown(client.close);
    final root = await (await client.getUrl(url)).close();
    expect(await utf8.decodeStream(root), '<html>canvas</html>');

    late Answer requested;
    final otpCode = await codeAfter(otp.path, 'op@example.com', () async {
      requested = await send(
        url,
        'POST',
        '/api/collections/users/request-otp',
        body: {'email': 'op@example.com'},
      );
    });
    expect(otpCode, isNotNull, reason: '$said');
    final signed = await send(
      url,
      'POST',
      '/api/collections/users/auth-with-otp',
      body: {'otpId': (requested.body as Map)['otpId'], 'password': otpCode},
    );
    expect(signed.status, 200, reason: '${signed.body}');
    final (token, user) = (
      (signed.body as Map)['token'] as String,
      ((signed.body as Map)['record'] as Map)['id'] as String,
    );

    // A galley and its owner's membership: the membership is judged by the validator, so a
    // bundle whose validator did not run would refuse it ("this server has no validator").
    Future<Answer> makeGalley(String id, String alias) => send(
      url,
      'POST',
      '/api/batch',
      token: token,
      body: {
        'requests': [
          {
            'method': 'POST',
            'url': '/api/collections/galleys/records',
            'body': {'id': id, 'name': 'App', 'owner': user},
          },
          {
            'method': 'POST',
            'url': '/api/collections/members/records',
            'body': {'galley': id, 'user': user, 'role': 'owner', 'alias': alias},
          },
        ],
      },
    );
    // Ids of PocketBase's form: 15 of [a-z0-9].
    final made = await makeGalley('bundledgallery1', 'Owner');
    expect(made.status, 200, reason: '${made.body}');
    // A refusal only the validator makes: an alias galley_core will not read.
    final refused = await makeGalley('bundledgallery2', ' ');
    expect(refused.status, 400, reason: '${refused.body}');
    expect('${refused.body}', isNot(contains('no validator')));
  });

  test('for Linux: Linux executables, the schema, the canvas, and how it was made', () async {
    final to = '${tmp.path}/linux';
    final (code, out, err) = await bundle([to, '--web', canvas()]);
    expect((code, err), (0, ''));
    expect(out, contains('cd $to && fly deploy --ha=false --remote-only'));

    List<String> entries(String dir) => [
      for (final e in Directory(dir).listSync(recursive: true))
        if (e is File) e.path.substring(dir.length + 1),
    ]..sort();
    final schema = GalleySource.resolve().pocketbase;
    expect(
      entries(to),
      [
        'Dockerfile',
        'bundle.json',
        'galley_validate',
        'pocketbase',
        'public/index.html',
        'run',
        for (final f in entries(schema)) 'schema/$f',
      ]..sort(),
    );
    for (final f in entries(schema)) {
      expect(File('$to/schema/$f').readAsStringSync(), File('$schema/$f').readAsStringSync());
    }

    // An ELF file (0x7f "ELF"), 64-bit (class 2), little-endian, for x86-64 (machine 0x3e).
    for (final exe in ['pocketbase', 'galley_validate']) {
      final head = File('$to/$exe').openSync()..setPositionSync(0);
      final bytes = head.readSync(20);
      head.closeSync();
      expect(
        [...bytes.sublist(0, 6), bytes[18], bytes[19]],
        [0x7f, 0x45, 0x4c, 0x46, 2, 1, 0x3e, 0],
        reason: '$exe is not an x86-64 ELF executable',
      );
    }
    for (final exe in ['pocketbase', 'galley_validate', 'run']) {
      expect(File('$to/$exe').statSync().mode & 0x49, 0x49, reason: '$exe is not executable');
    }
    expect(jsonDecode(File('$to/bundle.json').readAsStringSync()), {
      'platform': 'linux_amd64',
      'pocketbase': pocketBaseVersion,
      'canvas': 'a build',
      'made': '2026-11-27T12:00:00.000Z',
    });
    final docker = File('$to/Dockerfile').readAsStringSync();
    expect(docker, contains('CMD ["/galley/run"]'));
    // Its base is pinned by digest: one FROM, naming the image by its sha256.
    expect(
      [
        for (final l in docker.split('\n'))
          if (l.startsWith('FROM ')) l,
      ],
      [matches(RegExp(r'^FROM debian:bookworm-slim@sha256:[0-9a-f]{64}$'))],
    );
  });

  group('refuses', () {
    test('a directory that is not empty, and writes nothing into it', () async {
      final to = Directory('${tmp.path}/full')..createSync();
      File('${to.path}/kept').writeAsStringSync('mine');
      final (code, _, err) = await bundle([to.path, '--platform', here, '--web', canvas()]);
      expect(code, isNot(0));
      expect(err, contains('${to.path} is not empty'));
      expect([for (final e in to.listSync()) e.path], ['${to.path}/kept']);
    });

    test('a platform it cannot build for', () async {
      final (code, _, err) = await bundle(['${tmp.path}/w', '--platform', 'windows_amd64']);
      expect(code, isNot(0));
      expect(err, contains('not windows_amd64'));
      expect(Directory('${tmp.path}/w').existsSync(), isFalse);
    });

    test('with no canvas, since its reviewers would open nothing', () async {
      final (code, _, err) = await bundle([
        '${tmp.path}/nc',
        '--platform',
        here,
      ], fetch: (url) async => throw const SocketException('offline'));
      expect(code, isNot(0));
      expect(err, contains('no canvas to serve'));
      expect(Directory('${tmp.path}/nc').existsSync(), isFalse);
    });
  });
}
