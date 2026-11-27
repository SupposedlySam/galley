import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:galley_cli/galley_cli.dart';
import 'package:test/test.dart';

import 'support/zip.dart';

void main() {
  group('cacheDirectory', () {
    test('is GALLEY_CACHE as given, else galley under the platform user cache', () {
      expect(
        [
          for (final (env, os) in [
            ({'GALLEY_CACHE': '/c', 'HOME': '/h'}, 'macos'),
            ({'GALLEY_CACHE': '', 'HOME': '/h'}, 'macos'),
            ({'HOME': '/h'}, 'linux'),
            ({'XDG_CACHE_HOME': '/x', 'HOME': '/h'}, 'linux'),
            ({'LOCALAPPDATA': r'C:\L', 'HOME': '/h'}, 'windows'),
            (<String, String>{}, 'macos'),
            ({'HOME': '/h'}, 'windows'),
          ])
            cacheDirectory(env, os: os),
        ],
        [
          '/c',
          '/h/Library/Caches/galley',
          '/h/.cache/galley',
          '/x/galley',
          r'C:\L/galley',
          null,
          null,
        ],
      );
    });
  });

  group('httpFetch', () {
    late HttpServer server;
    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        switch (r.uri.path) {
          case '/asset':
            r.response.add(List.filled(2000, 7));
          case '/moved':
            r.response
              ..statusCode = 302
              ..headers.set('location', '/asset');
          default:
            r.response.statusCode = 404;
        }
        await r.response.close();
      });
      addTearDown(() => server.close(force: true));
    });
    Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

    test('gets the body, through a redirect as a release asset has', () async {
      expect(await httpFetch(at('/asset')), List.filled(2000, 7));
      expect(await httpFetch(at('/moved')), List.filled(2000, 7));
    });

    test('refuses anything but a 200, and a body past its limit', () async {
      await expectLater(
        httpFetch(at('/gone')),
        throwsA(isA<HttpException>().having((e) => e.message, 'message', 'answered 404')),
      );
      await expectLater(
        httpFetch(at('/asset'), max: 1000),
        throwsA(isA<HttpException>().having((e) => e.message, 'message', 'larger than 1000 bytes')),
      );
    });
  });

  group('ArchiveCache, for a zip', () {
    late Directory root;
    setUp(() {
      root = Directory.systemTemp.createTempSync('galley_archive_cache_');
      addTearDown(() => root.deleteSync(recursive: true));
    });

    test('unpacks it whole, with the program runnable by its owner only', () async {
      final archive = zipOf([
        zfile('pocketbase', '#!/bin/sh\necho ran\n', mode: 0x81ff), // 0o100777: kept as 700
        zfile('LICENSE.md', 'MIT', mode: 0x81b6), // 0o100666: not made runnable
      ]);
      final pin = _Pin(archive);
      final got = await ArchiveCache(root.path, fetch: (_) async => archive).unpacked(pin);

      final dir = (got as UnpackedAt).directory;
      expect(dir, '${root.path}/test/thing_1.0_any-${pin.sha256.substring(0, 16)}');
      final ran = await Process.run('$dir/pocketbase', const []);
      expect(ran.stdout, 'ran\n');
      expect(File('$dir/pocketbase').statSync().modeString(), 'rwx------');
      expect(File('$dir/LICENSE.md').statSync().mode & 0x49, 0, reason: 'nobody runs it');
    }, skip: Platform.isWindows ? 'no execute bit' : null);

    test('without its marker at the root is refused, and nothing is kept', () async {
      final archive = zipOf([zfile('bin/pocketbase', 'x')]);
      final got = await ArchiveCache(
        root.path,
        fetch: (_) async => archive,
      ).unpacked(_Pin(archive));
      expect((got as NotUnpacked).why, 'thing_1.0_any.zip has no pocketbase at its root');
      expect(root.listSync(), isEmpty);
    });
  });

  group('PinnedPocketBase', () {
    test('is pinned for every platform PocketBase is released for, by its own name', () {
      final pins = {for (final abi in Abi.values) abi: ?PinnedPocketBase.forAbi(abi)};
      expect(
        {for (final MapEntry(:key, :value) in pins.entries) '$key': value.platform},
        {
          'macos_x64': 'darwin_amd64',
          'macos_arm64': 'darwin_arm64',
          'linux_x64': 'linux_amd64',
          'linux_arm64': 'linux_arm64',
          'windows_x64': 'windows_amd64',
          'windows_arm64': 'windows_arm64',
        },
      );
      for (final pin in pins.values) {
        expect(pin.version, pocketBaseVersion);
        expect(pin.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(
          '${pin.url}',
          'https://github.com/pocketbase/pocketbase/releases/download/'
              'v$pocketBaseVersion/pocketbase_${pocketBaseVersion}_${pin.platform}.zip',
        );
        expect(pin.marker, pin.platform.startsWith('windows') ? 'pocketbase.exe' : 'pocketbase');
      }
      expect({for (final p in pins.values) p.sha256}, hasLength(6), reason: 'one hash each');
      expect(PinnedPocketBase.forAbi(Abi.linuxRiscv64), isNull);
      expect(PinnedPocketBase.forAbi(), isNotNull, reason: 'this machine is one of them');
    });
  });
}

/// A zip pinned by its own hash.
final class _Pin implements PinnedArchive {
  _Pin(Uint8List archive) : sha256 = '${crypto.sha256.convert(archive)}';

  @override
  final String sha256;
  @override
  String get kind => 'test';
  @override
  String get asset => 'thing_1.0_any.zip';
  @override
  Uri get url => Uri.parse('https://example.invalid/$asset');
  @override
  String get marker => 'pocketbase';
}
