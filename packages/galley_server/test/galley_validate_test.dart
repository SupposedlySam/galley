import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The program as a hook runs it: one argument in, one line of JSON out, and exit 0 always,
/// because PocketBase's `$os.exec` drops a failed command's output (DESIGN D15).
void main() {
  late Directory dir;
  late String exe;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('galley_validate_');
    exe = '${dir.path}/galley_validate';
    // Compiled, as `galley host` runs it: `dart run` would also pass, and prove less.
    final built = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/galley_validate.dart',
      '-o',
      exe,
    ]);
    expect(built.exitCode, 0, reason: '${built.stderr}');
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  Future<(int, List<Object?>)> run(List<String> args) async {
    final r = await Process.run(exe, args);
    final lines = const LineSplitter().convert('${r.stdout}');
    return (r.exitCode, [for (final l in lines) jsonDecode(l)]);
  }

  test('answers each request on one line, and exits 0 whatever it says', () async {
    final asked = [
      [
        jsonEncode({'write': 'member', 'alias': 'Rae', 'aliases': <String>[]}),
      ],
      [
        jsonEncode({
          'write': 'member',
          'alias': 'Rae',
          'aliases': ['rae'],
        }),
      ],
      ['{not json'],
      <String>[],
      ['{}', '{}'],
    ];
    final ran = [for (final a in asked) await run(a)];
    expect([for (final (code, _) in ran) code], [0, 0, 0, 0, 0]);
    expect(
      [for (final (_, lines) in ran) lines],
      [
        [
          {'ok': true},
        ],
        [
          {'refused': 'a member of this galley is already "Rae"'},
        ],
        [
          {'refused': startsWith('the request is not JSON: ')},
        ],
        [
          {'refused': 'galley_validate takes one argument, the request as JSON'},
        ],
        [
          {'refused': 'galley_validate takes one argument, the request as JSON'},
        ],
      ],
    );
  });
}
