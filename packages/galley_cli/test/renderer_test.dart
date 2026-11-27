import 'dart:io';

import 'package:galley_cli/galley_cli.dart';
import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('renderer_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a --flutter that is a command line is refused, not crashed on', () async {
    final r = FlutterTestRenderer(
      app: dir.path,
      test: 'test/galley_test.dart',
      flutter: 'fvm flutter',
    );
    await expectLater(
      r.render('${dir.path}/out'),
      throwsA(isA<Refused>().having((e) => e.message, 'message', contains('one executable'))),
    );
  });

  test('flutter test gets the test, the output, then the test args, in that order', () async {
    final seen = File('${dir.path}/args.txt');
    final flutter = File('${dir.path}/flutter')
      ..writeAsStringSync(
        '#!/bin/sh\nfor a in "\$@"; do echo "\$a"; done > "${seen.path}"\nexit 3\n',
      );
    Process.runSync('chmod', ['+x', flutter.path]);
    final r = FlutterTestRenderer(
      app: dir.path,
      test: 'test/galley_test.dart',
      flutter: flutter.path,
      testArgs: ['--run-skipped'],
    );
    expect(await r.render('${dir.path}/out'), 3, reason: 'the exit code is passed back');
    expect(seen.readAsLinesSync(), [
      'test',
      'test/galley_test.dart',
      '--dart-define=GALLEY_OUT=${Directory('${dir.path}/out').absolute.path}',
      '--run-skipped',
    ]);
  }, testOn: 'posix');
}
