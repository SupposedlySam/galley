import 'dart:convert';
import 'dart:io';

import 'package:galley_core/galley_core.dart';

/// Reads where a round comes from: the commit and tree state of the git checkout holding
/// [dir], the Flutter version under `FLUTTER_ROOT` in [environment], and [now].
///
/// Every fact that cannot be read is [Unrecorded] with the reason, never a blank or a guess
/// (DESIGN.md, "An unknown is never nothing"). A round packed outside git still packs: its
/// frames are worth reviewing, and the reviewer is told the commit is unknown.
///
/// The packer calls this before it writes anything. Read after, a round written inside the
/// checkout to a directory git does not ignore would make its own tree look dirty.
RoundProvenance readProvenance({
  required String dir,
  required Map<String, String> environment,
  required DateTime now,
}) {
  final head = _git(dir, ['rev-parse', 'HEAD']);
  final status = _git(dir, ['status', '--porcelain']);
  return RoundProvenance(
    commit: switch (head) {
      Known(:final value) when isCommitSha(value.trim()) => Known(value.trim()),
      Known(:final value) => Unrecorded('git rev-parse HEAD answered "${value.trim()}"'),
      final Unrecorded<String> u => Unrecorded(u.reason),
    },
    // Untracked files count: a new file the app imports changes what renders. Ignored files do
    // not, so a build directory does not make every tree dirty.
    dirty: switch (status) {
      Known(:final value) => Known(value.trim().isNotEmpty),
      final Unrecorded<String> u => Unrecorded(u.reason),
    },
    flutter: _flutterVersion(environment),
    at: now.toUtc(),
  );
}

/// The standard output of `git <args>` run in [dir], or why there is none.
Recorded<String> _git(String dir, List<String> args) {
  final ProcessResult result;
  try {
    result = Process.runSync('git', args, workingDirectory: dir);
  } on ProcessException catch (e) {
    return Unrecorded('git could not be run: ${e.message}');
  }
  if (result.exitCode != 0) {
    final said = '${result.stderr}'.trim().split('\n').first;
    return Unrecorded(
      'git ${args.join(' ')} exited ${result.exitCode}${said.isEmpty ? '' : ': $said'}',
    );
  }
  return Known('${result.stdout}');
}

/// The framework version in `$FLUTTER_ROOT/bin/cache/flutter.version.json`.
///
/// Observed: `flutter test` sets `FLUTTER_ROOT` for the test process, and that file holds
/// `"frameworkVersion": "3.50.0"`. Rejected: running `flutter --version` from the test. It
/// takes seconds, it can be a different Flutter from the one running the test (whichever is
/// first on PATH), and it can try to update itself.
Recorded<String> _flutterVersion(Map<String, String> environment) {
  final root = environment['FLUTTER_ROOT'];
  if (root == null || root.isEmpty) return Unrecorded('FLUTTER_ROOT is not set');
  final file = File('$root/bin/cache/flutter.version.json');
  try {
    final json = jsonDecode(file.readAsStringSync());
    final version = json is Map ? json['frameworkVersion'] : null;
    if (version is String && version.isNotEmpty) return Known(version);
    return Unrecorded('${file.path} has no frameworkVersion');
  } on FileSystemException catch (e) {
    return Unrecorded('${file.path} could not be read: ${e.osError?.message ?? e.message}');
  } on FormatException {
    return Unrecorded('${file.path} is not JSON');
  }
}
