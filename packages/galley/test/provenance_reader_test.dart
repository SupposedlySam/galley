import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:galley/src/provenance_reader.dart';
import 'package:galley_core/galley_core.dart';

/// Real git in temp checkouts, not a faked process: what is assumed about git here is its exit
/// codes and output, and only git can say whether that holds.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('galley_prov_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String git(String dir, List<String> args) {
    final r = Process.runSync('git', [
      '-c', 'user.name=galley', '-c', 'user.email=galley@example.invalid',
      '-c', 'commit.gpgsign=false', ...args, //
    ], workingDirectory: dir);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return '${r.stdout}'.trim();
  }

  Directory checkout() {
    final d = Directory('${tmp.path}/app')..createSync();
    git(d.path, ['init', '-q']);
    File('${d.path}/.gitignore').writeAsStringSync('build/\n');
    File('${d.path}/main.dart').writeAsStringSync('void main() {}\n');
    git(d.path, ['add', '.']);
    git(d.path, ['commit', '-q', '-m', 'one']);
    return d;
  }

  Directory flutterRoot(String versionJson) {
    final root = Directory('${tmp.path}/flutter');
    Directory('${root.path}/bin/cache').createSync(recursive: true);
    File('${root.path}/bin/cache/flutter.version.json').writeAsStringSync(versionJson);
    return root;
  }

  RoundProvenance read(String dir, [Map<String, String> env = const {}]) =>
      readProvenance(dir: dir, environment: env, now: DateTime.utc(2026, 11, 26, 12));

  test('a clean checkout names its HEAD and is not dirty; the time is kept', () {
    final app = checkout();
    final p = read(app.path);
    expect((p.commit as Known<String>).value, git(app.path, ['rev-parse', 'HEAD']));
    expect((p.dirty as Known<bool>).value, isFalse);
    expect(p.at, DateTime.utc(2026, 11, 26, 12));
  });

  test('read from a subdirectory, it is the same checkout', () {
    final app = checkout();
    final sub = Directory('${app.path}/test')..createSync();
    expect((read(sub.path).commit as Known<String>).value, git(app.path, ['rev-parse', 'HEAD']));
  });

  test('an edit, or a new file, is dirty; an ignored build directory is not', () {
    final app = checkout();
    Directory('${app.path}/build/galley').createSync(recursive: true);
    File('${app.path}/build/galley/round.json').writeAsStringSync('{}');
    expect((read(app.path).dirty as Known<bool>).value, isFalse, reason: 'ignored');

    File('${app.path}/new.dart').writeAsStringSync('');
    expect((read(app.path).dirty as Known<bool>).value, isTrue, reason: 'untracked');
    File('${app.path}/new.dart').deleteSync();
    expect((read(app.path).dirty as Known<bool>).value, isFalse, reason: 'the control');

    File('${app.path}/main.dart').writeAsStringSync('void main() { print(1); }\n');
    expect((read(app.path).dirty as Known<bool>).value, isTrue, reason: 'edited');
  });

  test('outside git, the commit and the tree are unknown, with git\'s reason', () {
    final p = read(tmp.path);
    expect(p.commit, isA<Unrecorded<String>>());
    expect((p.commit as Unrecorded).reason, allOf(contains('rev-parse'), contains('exited')));
    expect((p.dirty as Unrecorded).reason, contains('status'));
  });

  test('a repository with no commit yet has no HEAD to name', () {
    final d = Directory('${tmp.path}/empty')..createSync();
    git(d.path, ['init', '-q']);
    expect((read(d.path).commit as Unrecorded).reason, contains('rev-parse'));
  });

  test('the Flutter version is read from FLUTTER_ROOT, and each way it fails says why', () {
    final root = flutterRoot('{"frameworkVersion": "3.50.0", "channel": "stable"}');
    expect((read(tmp.path, {'FLUTTER_ROOT': root.path}).flutter as Known<String>).value, '3.50.0');

    expect((read(tmp.path).flutter as Unrecorded).reason, 'FLUTTER_ROOT is not set');
    expect(
      (read(tmp.path, {'FLUTTER_ROOT': '${tmp.path}/nowhere'}).flutter as Unrecorded).reason,
      contains('could not be read'),
    );
    flutterRoot('not json');
    expect(
      (read(tmp.path, {'FLUTTER_ROOT': root.path}).flutter as Unrecorded).reason,
      contains('not JSON'),
    );
    flutterRoot('{"channel": "stable"}');
    expect(
      (read(tmp.path, {'FLUTTER_ROOT': root.path}).flutter as Unrecorded).reason,
      contains('no frameworkVersion'),
    );
  });

  test('the Flutter running this test is read, not only a fixture', () {
    final p = read(tmp.path, Platform.environment);
    expect((p.flutter as Known<String>).value, matches(RegExp(r'^\d+\.\d+\.\d+')));
  });
}
