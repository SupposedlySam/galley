import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:galley_cli/galley_cli.dart';
import 'package:test/test.dart';

import 'support/round.dart';
import 'support/tar.dart';

void main() {
  group('CanvasCache', () {
    late Directory root;
    final archive = gz(tarOf(canvasFiles));
    final pin = PinnedCanvas(version: '9.9.9', sha256: '${sha256.convert(archive)}');
    late List<Uri> fetched;
    Future<Uint8List> serves(Uri url) async {
      fetched.add(url);
      return archive;
    }

    setUp(() {
      root = Directory.systemTemp.createTempSync('galley_cache_');
      addTearDown(() => root.deleteSync(recursive: true));
      fetched = [];
    });

    /// Everything under the cache, so a test sees what was kept, and what was not.
    List<String> kept() =>
        [for (final e in root.listSync(recursive: true)) e.path.substring(root.path.length + 1)]
          ..sort();

    test('fetches the pinned build once, unpacks it whole, then starts with no network', () async {
      final cache = CanvasCache(root.path, fetch: serves);

      final first = await cache.canvas(pin);
      expect((first as CanvasAt).directory, cache.directoryOf(pin));
      expect(fetched, [pin.url]);
      expect(File('${first.directory}/canvaskit/canvaskit.wasm').readAsStringSync(), 'wasm');
      final dir = 'canvas/galley_web-9.9.9-${pin.sha256.substring(0, 16)}';
      expect(kept(), [
        'canvas',
        dir,
        '$dir/canvaskit',
        '$dir/canvaskit/canvaskit.wasm',
        '$dir/index.html',
      ]);

      final offline = CanvasCache(root.path, fetch: (_) => throw StateError('no network'));
      expect((await offline.canvas(pin) as CanvasAt).directory, first.directory);
    });

    test('refuses an archive that is not the pinned one, and keeps nothing', () async {
      final other = gz(tarOf([file('index.html', 'tampered')]));
      final cache = CanvasCache(root.path, fetch: (_) async => other);

      final got = await cache.canvas(pin);

      expect(
        (got as NoCanvas).why,
        '${pin.url} is not the pinned build: its SHA-256 is ${sha256.convert(other)}, not '
        '${pin.sha256}. Nothing was kept',
      );
      expect(kept(), isEmpty);
    });

    test(
      'says why when the build cannot be fetched, or does not unpack, and keeps nothing',
      () async {
        final down = await CanvasCache(
          root.path,
          fetch: (url) => throw HttpException('answered 404', uri: url),
        ).canvas(pin);
        expect((down as NoCanvas).why, startsWith('could not fetch ${pin.url}: '));
        expect(down.why, contains('answered 404'));

        for (final (bad, why) in [
          (
            gz(tarOf([file('readme', 'x')])),
            '${'galley_web-9.9.9.tar.gz'} has no index.html at its root',
          ),
          (
            gz(tarOf([...canvasFiles, link('evil', '/')])),
            'galley_web-9.9.9.tar.gz does not unpack: evil is a "2" entry: '
                'only files and directories are unpacked',
          ),
        ]) {
          final p = PinnedCanvas(version: '9.9.9', sha256: '${sha256.convert(bad)}');
          final got = await CanvasCache(root.path, fetch: (_) async => bad).canvas(p);
          expect((got as NoCanvas).why, why);
        }
        expect(kept(), isEmpty, reason: 'no build, and no partial one');
      },
    );

    test('an unpack that fails partway through writing leaves no partial build', () async {
      // `a` is written as a file, so `a/b` cannot be: the failure comes after files were
      // written, which no refusal above reaches (they all come before the first write).
      final bad = gz(tarOf([...canvasFiles, file('a', 'x'), file('a/b', 'y')]));
      final p = PinnedCanvas(version: '9.9.9', sha256: '${sha256.convert(bad)}');

      final got = await CanvasCache(root.path, fetch: (_) async => bad).canvas(p);

      expect((got as NoCanvas).why, startsWith('could not unpack galley_web-9.9.9.tar.gz into '));
      expect(kept(), ['canvas'], reason: 'only the cache directory, none of what was written');
    });

    test('a partial unpack left by a crash is never taken for the build', () async {
      final cache = CanvasCache(root.path, fetch: serves);
      final partial = Directory('${cache.directoryOf(pin)}.partial-1-1')
        ..createSync(recursive: true);
      File('${partial.path}/index.html').writeAsStringSync('half');

      final got = await cache.canvas(pin) as CanvasAt;

      expect(fetched, [pin.url]);
      expect(File('${got.directory}/index.html').readAsStringSync(), '<html>canvas</html>');
    });
  });

  group('galley serve', () {
    late Directory app, cache;
    final archive = gz(tarOf(canvasFiles));
    final pin = PinnedCanvas(version: '9.9.9', sha256: '${sha256.convert(archive)}');

    setUp(() {
      app = Directory.systemTemp.createTempSync('galley_serve_canvas_');
      cache = Directory('${app.path}/cache');
      addTearDown(() => app.deleteSync(recursive: true));
      writeRound(GalleyDirectory('${app.path}/.galley'));
    });

    /// Runs `serve` until [then] is done with its address, and returns what it printed.
    Future<(String, String)> serving(
      Fetch fetch,
      Future<void> Function(Uri url) then, {
      Map<String, String>? environment,
    }) async {
      final out = StringBuffer(), err = StringBuffer();
      final stop = Completer<void>();
      final running = runGalley(
        ['--app', app.path, 'serve', '--port', '0'],
        GalleyContext(
          out: out,
          err: err,
          untilStopped: () => stop.future,
          environment: environment ?? {'GALLEY_CACHE': cache.path},
          fetch: fetch,
          canvas: pin,
        ),
      );
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return !'$out'.contains('Serving');
      }).timeout(const Duration(seconds: 10));
      final url = Uri.parse(RegExp(r'at (http\S+)').firstMatch('$out')!.group(1)!);
      await then(url);
      stop.complete();
      expect(await running, 0);
      return ('$out', '$err');
    }

    Future<(int, String)> get(Uri url) async {
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(url)).close();
        return (response.statusCode, await utf8.decodeStream(response));
      } finally {
        client.close();
      }
    }

    test('serves the pinned canvas, fetched on the first start only', () async {
      var fetches = 0;
      Future<Uint8List> fetch(Uri _) async {
        fetches++;
        return archive;
      }

      for (final start in [1, 2]) {
        final (out, err) = await serving(fetch, (url) async {
          expect(await get(url), (200, '<html>canvas</html>'), reason: 'start $start');
        });
        expect(err, isEmpty, reason: 'start $start');
        expect(out.contains('Fetching the canvas'), start == 1, reason: 'start $start');
      }
      expect(fetches, 1);
    });

    test('without a canvas still serves the API, and says why at start and at /', () async {
      for (final (fetch, env, why) in [
        (
          (Uri url) => throw HttpException('answered 404', uri: url),
          {'GALLEY_CACHE': cache.path},
          'could not fetch ${pin.url}',
        ),
        ((Uri _) async => archive, <String, String>{}, 'there is nowhere to cache it'),
      ]) {
        final (_, err) = await serving(fetch, (url) async {
          final (code, body) = await get(url);
          expect(code, 404);
          expect(jsonDecode(body), {'error': startsWith('no canvas here: $why')});
          expect((await get(url.resolve('/api/galley'))).$1, 200);
        }, environment: env);
        expect(err, allOf(contains('no canvas at'), contains(why), contains('--web <dir>')));
      }
    });
  });
}
