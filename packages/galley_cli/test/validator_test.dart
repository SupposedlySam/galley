@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:galley_cli/src/host.dart';
import 'package:test/test.dart';

void main() {
  test('two compiles at once, in one process, each finish, and leave only the validator', () async {
    final root = Directory.systemTemp.createTempSync('galley_validate_');
    addTearDown(() => root.deleteSync(recursive: true));
    final both = await Future.wait([compiledValidator(root.path), compiledValidator(root.path)]);
    expect(both.toSet(), hasLength(1));
    final left = Directory('${root.path}/validate').listSync().map((e) => e.path).toList();
    expect(left, [both.first]);
    expect(FileStat.statSync(both.first).modeString(), startsWith('rwx'));
    // A third finds it, and compiles nothing.
    final before = File(both.first).lastModifiedSync();
    expect(await compiledValidator(root.path), both.first);
    expect(File(both.first).lastModifiedSync(), before);
  });
}
