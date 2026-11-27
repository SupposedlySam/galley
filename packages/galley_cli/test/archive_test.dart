import 'dart:io';
import 'dart:typed_data';

import 'package:galley_cli/galley_cli.dart';
import 'package:test/test.dart';

import 'support/tar.dart';
import 'support/zip.dart';

void main() {
  group('readTarGz', () {
    test('reads files and directories, inside the directory, without the leading ./', () {
      expect(read(gz(tarOf(canvasFiles))), {
        'index.html': '<html>canvas</html>',
        'canvaskit/': null,
        'canvaskit/canvaskit.wasm': 'wasm',
      });
    });

    test('reads a long name from the ustar prefix, and from a pax header by its bytes', () {
      final deep = '${List.filled(12, 'segment').join('/')}/file.js'; // 104 bytes
      final named = 'é/${'n' * 120}.js'; // pax: a record length counted in bytes, not chars
      expect(read(gz(tarOf([file(deep, 'a'), pax(named), file('short', 'b')]))), {
        deep: 'a',
        named: 'b',
      });
    });

    test('refuses every entry that is not a file or a directory, naming it', () {
      for (final (entry, type) in [
        (link('index.html', '/etc/passwd'), '2'),
        (link('index.html', 'other', type: '1'), '1'),
        (link('fifo', '', type: '6'), '6'),
        (link('dev', '', type: '3'), '3'),
      ]) {
        expect(
          () => readTarGz(gz(tarOf([...canvasFiles, entry]))),
          refusedWith('${entry.name} is a "$type" entry: only files and directories are unpacked'),
          reason: type,
        );
      }
    });

    test('refuses a path that would leave its directory', () {
      for (final name in [
        '../escape',
        'a/../../escape',
        '/etc/passwd',
        r'a\..\escape',
        'C:/escape',
      ]) {
        expect(
          () => readTarGz(gz(tarOf([file(name, 'x')]))),
          refusedWith('$name would be unpacked outside its directory'),
          reason: name,
        );
      }
      expect(
        () => readTarGz(gz(tarOf([pax('../escape'), file('innocent', 'x')]))),
        refusedWith('../escape would be unpacked outside its directory'),
        reason: "a pax header's path is checked like any other",
      );
    });

    test('refuses an archive that is damaged, not tar, or not gzip', () {
      final good = tarOf(canvasFiles);
      expect(
        () => readTarGz(gz(tarOf(canvasFiles, corrupt: (h) => h[0] ^= 1))),
        refusedWith('the header at byte 0 does not match its checksum'),
      );
      expect(
        () => readTarGz(gz(Uint8List.sublistView(good, 0, 512 * 2 + 10))),
        refusedWith('it ends inside an entry'),
      );
      expect(
        () => readTarGz(gz(Uint8List.sublistView(good, 0, 512 * 3 + 100))),
        refusedWith('it ends inside a header'),
      );
      expect(() => readTarGz(good), refusedWith(startsWith('not gzip')));
    });
  });

  group('readTarGz on what tar makes', () {
    // The release archive is made by this machine's `tar` (docs/RELEASING.md), so what that
    // writes is the population that matters, not only what the test writer above writes.
    late Directory build;
    setUp(() {
      build = Directory.systemTemp.createTempSync('galley_tar_');
      addTearDown(() => build.deleteSync(recursive: true));
      Directory('${build.path}/web/assets/${'deep' * 30}').createSync(recursive: true);
      File('${build.path}/web/index.html').writeAsStringSync('<html>canvas</html>');
      File('${build.path}/web/assets/${'deep' * 30}/font.otf').writeAsStringSync('font');
    });

    for (final format in ['ustar', 'pax']) {
      test('in $format', () async {
        final out = '${build.path}/web.tar.gz';
        final made = await Process.run(
          'tar',
          ['--format', format, '-czf', out, '-C', '${build.path}/web', '.'],
          environment: {'COPYFILE_DISABLE': '1'},
        );
        expect(made.exitCode, 0, reason: '${made.stderr}');
        final files = read(File(out).readAsBytesSync());
        expect(
          {for (final MapEntry(:key, :value) in files.entries) key: ?value},
          {'index.html': '<html>canvas</html>', 'assets/${'deep' * 30}/font.otf': 'font'},
        );
      }, skip: Platform.isWindows ? 'the release is made on macOS or Linux' : null);
    }
  });

  group('readTarGz keeps', () {
    test('the owner execute bit, as tar writes it', () async {
      final build = Directory.systemTemp.createTempSync('galley_tar_mode_');
      addTearDown(() => build.deleteSync(recursive: true));
      File('${build.path}/run').writeAsStringSync('#!/bin/sh\n');
      File('${build.path}/data').writeAsStringSync('x');
      expect((await Process.run('chmod', ['755', '${build.path}/run'])).exitCode, 0);
      final out = '${build.path}.tar.gz';
      addTearDown(() => File(out).deleteSync());
      final made = await Process.run(
        'tar',
        ['-czf', out, '-C', build.path, 'run', 'data'],
        environment: {'COPYFILE_DISABLE': '1'},
      );
      expect(made.exitCode, 0, reason: '${made.stderr}');
      expect(
        {for (final e in readTarGz(File(out).readAsBytesSync())) e.path: e.executable},
        {'run': true, 'data': false},
      );
    }, skip: Platform.isWindows ? 'no chmod' : null);
  });

  group('readZip', () {
    test('reads stored and deflated files and directories, and which may be run', () {
      final entries = readZip(
        zipOf([
          zdir('bin/'),
          zfile('bin/tool', 'run me', mode: 0x81ed), // 0o100755
          zfile('README.md', 'stored', method: 0),
          zfile('LICENSE.md', 'deflated ' * 50),
          // Made where there is no Unix mode: a file by its name, with no execute bit,
          // whatever its attributes hold (here, what on Unix would be a link's 0o120777).
          zfile('dos.exe', 'x', mode: 0xa1ff, unix: false),
        ], comment: 'a comment, after the end record'),
      );
      expect(readable(entries), {
        'bin/': null,
        'bin/tool': 'run me',
        'README.md': 'stored',
        'LICENSE.md': 'deflated ' * 50,
        'dos.exe': 'x',
      });
      expect(
        {for (final e in entries) e.path: e.executable},
        {'bin': false, 'bin/tool': true, 'README.md': false, 'LICENSE.md': false, 'dos.exe': false},
      );
    });

    test('refuses a symbolic link, or any entry not a file or a directory, naming it', () {
      expect(
        () => readZip(zipOf([zfile('pocketbase', 'x'), zlink('evil', '/etc')])),
        refusedWith('evil is a "0o120000" entry: only files and directories are unpacked'),
      );
      expect(
        () => readZip(zipOf([zfile('fifo', '', mode: 0x11a4)])), // 0o010644
        refusedWith('fifo is a "0o10000" entry: only files and directories are unpacked'),
      );
      expect(
        () => readZip(zipOf([zfile('a-file/', '', mode: 0x81a4)])),
        refusedWith(startsWith('a-file/ is a "0o100000" entry')),
        reason: 'a name that says directory, with a mode that says file',
      );
    });

    test('refuses a path that would leave its directory', () {
      for (final name in ['../escape', 'a/../../escape', '/etc/passwd', r'a\..\escape', 'C:/x']) {
        expect(
          () => readZip(zipOf([zfile(name, 'x')])),
          refusedWith('$name would be unpacked outside its directory'),
          reason: name,
        );
      }
    });

    test('refuses what it does not read: encrypted, another method, zip64, in parts', () {
      final plain = zfile('f', 'x');
      expect(
        () => readZip(
          zipOf([(name: 'f', data: plain.data, method: 8, mode: plain.mode, unix: true, flags: 1)]),
        ),
        refusedWith('f is encrypted'),
      );
      expect(
        () => readZip(zipOf([zfile('f', 'x', method: 12)])),
        refusedWith('f is compressed by method 12, not stored or deflated'),
      );
      expect(
        () => readZip(zipOf([plain], sizes: (packed: 0xffffffff, unpacked: 1))),
        refusedWith('f is a zip64 entry, which is not unpacked'),
      );
      final parts = zipOf([plain]);
      ByteData.sublistView(parts).setUint16(parts.length - 22 + 4, 1, Endian.little);
      expect(() => readZip(parts), refusedWith('a zip in parts is not unpacked'));
    });

    test('refuses an archive that is damaged or not a zip', () {
      expect(
        () => readZip(gz(tarOf(canvasFiles))),
        refusedWith('not a zip: it has no end of central directory'),
      );
      expect(
        () => readZip(zipOf([zfile('f', 'x')], central: (c) => c.setUint32(0, 0, Endian.little))),
        refusedWith('central directory entry 1 does not read'),
      );
      expect(
        () => readZip(zipOf([zfile('f', 'x')], central: (c) => c.setUint32(42, 9, Endian.little))),
        refusedWith('f: its local header does not read'),
      );
      expect(
        () => readZip(zipOf([zfile('f', 'abc', method: 0)], sizes: (packed: 3, unpacked: 4))),
        refusedWith('f is 3 bytes, and its entry says 4'),
      );
      expect(
        () => readZip(zipOf([zfile('f', 'abc', method: 0)], sizes: (packed: 9000, unpacked: 3))),
        refusedWith('f ends outside the archive'),
      );
      final garbled = zipOf([zfile('f', 'deflate me ' * 20)]);
      garbled.fillRange(31, 35, 0xff); // the deflated data's first bytes
      expect(() => readZip(garbled), refusedWith(startsWith('f does not inflate')));
    });
  });

  group('readZip on what zip makes', () {
    // PocketBase's release zips are made by Go's archive/zip; this machine's `zip` is the
    // other writer at hand, and makes the entries that must be refused, a symbolic link above
    // all, which a test writer could get subtly unlike the real thing.
    late Directory tree;
    setUp(() {
      tree = Directory.systemTemp.createTempSync('galley_zip_');
      addTearDown(() => tree.deleteSync(recursive: true));
      Directory('${tree.path}/in/sub').createSync(recursive: true);
      File('${tree.path}/in/pocketbase').writeAsStringSync('#!/bin/sh\n');
      File('${tree.path}/in/sub/notes.md').writeAsStringSync('notes ' * 100);
      Process.runSync('chmod', ['755', '${tree.path}/in/pocketbase']);
    });

    Future<Uint8List> zipped(List<String> flags) async {
      final made = await Process.run('zip', [
        ...flags,
        '-q',
        '../out.zip',
        '.',
      ], workingDirectory: '${tree.path}/in');
      expect(made.exitCode, 0, reason: '${made.stderr}');
      return File('${tree.path}/out.zip').readAsBytesSync();
    }

    test('reads its files and directories, and keeps the execute bit', () async {
      final entries = readZip(await zipped(['-r']));
      expect(readable(entries), {
        'pocketbase': '#!/bin/sh\n',
        'sub/': null,
        'sub/notes.md': 'notes ' * 100,
      });
      expect(
        [
          for (final e in entries)
            if (e.executable) e.path,
        ],
        ['pocketbase'],
      );
    });

    test('refuses the symbolic link it stores', () async {
      Link('${tree.path}/in/escape').createSync('/etc');
      expect(
        () async => readZip(await zipped(['-ry'])),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'escape is a "0o120000" entry: only files and directories are unpacked',
          ),
        ),
      );
    });
  }, skip: Platform.isWindows || !File('/usr/bin/zip').existsSync() ? 'no zip here' : null);
}
