import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The program as a hook runs it: the path of the request in, one line of JSON out, and exit 0
/// always, because PocketBase's `$os.exec` drops a failed command's output (DESIGN D15).
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

  /// Runs it with [args], and reads each line it wrote as JSON.
  Future<(int, List<Object?>)> run(List<String> args) async {
    final r = await Process.run(exe, args);
    final lines = const LineSplitter().convert('${r.stdout}');
    return (r.exitCode, [for (final l in lines) jsonDecode(l)]);
  }

  var n = 0;
  String requestFile(String text) {
    final f = File('${dir.path}/request-${n++}.json')..writeAsStringSync(text);
    return f.path;
  }

  test('answers each request on one line, and exits 0 whatever it says', () async {
    // Past Linux's 128 KiB cap on one argument: the reason the request is a file.
    final large = jsonEncode({
      'write': 'member',
      'alias': 'Rae',
      'aliases': [for (var i = 0; i < 20000; i++) 'reviewer $i'],
    });
    expect(large.length, greaterThan(128 * 1024));
    final asked = [
      [
        requestFile(jsonEncode({'write': 'member', 'alias': 'Rae', 'aliases': <String>[]})),
      ],
      [
        requestFile(
          jsonEncode({
            'write': 'member',
            'alias': 'Rae',
            'aliases': ['rae'],
          }),
        ),
      ],
      [requestFile(large)],
      [requestFile('{not json')],
      ['${dir.path}/no-such-request.json'],
      <String>[],
      [requestFile('{}'), requestFile('{}')],
    ];
    final ran = [for (final a in asked) await run(a)];
    expect([for (final (code, _) in ran) code], [0, 0, 0, 0, 0, 0, 0]);
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
          {'ok': true},
        ],
        [
          {'refused': startsWith('the request is not JSON: ')},
        ],
        [
          {'refused': startsWith('the validator failed: Bad state: could not read the request: ')},
        ],
        [
          {'refused': 'galley_validate takes one argument, the path of the request'},
        ],
        [
          {'refused': 'galley_validate takes one argument, the path of the request'},
        ],
      ],
    );
  });
}
