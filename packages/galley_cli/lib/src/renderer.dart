import 'dart:io';

import 'local_galley.dart';

/// Writes a round into a directory. `pack` asks for one, then reads what was written.
abstract interface class RoundRenderer {
  /// Renders a round into [outDir], which does not exist yet, and returns the exit code.
  ///
  /// A non-zero code does not mean there is no round: the galley test fails each frame that
  /// errors, and still writes the round with those frames in it.
  Future<int> render(String outDir);
}

/// Makes the renderer `pack` asks for: the app at [app], its galley test [test], the
/// [flutter] executable, and [testArgs] passed on to `flutter test`.
typedef MakeRenderer = RoundRenderer Function({
  required String app,
  required String test,
  required String flutter,
  required List<String> testArgs,
});

/// Runs the app's galley test, the same command its owner runs by hand (README).
final class FlutterTestRenderer implements RoundRenderer {
  /// Runs [test] in the app at [app] with the `flutter` at [flutter], passing [testArgs] on.
  const FlutterTestRenderer({
    required this.app,
    required this.test,
    this.flutter = 'flutter',
    this.testArgs = const [],
  });

  /// The app's root, where its pubspec is.
  final String app;

  /// The galley test, relative to [app].
  final String test;

  /// The flutter command. Rejected: picking one from `FLUTTER_ROOT` or an fvm config. The app's
  /// owner already chose which Flutter `flutter` means here, and a second rule would disagree
  /// with theirs.
  ///
  /// One executable, not a command line: `fvm flutter` is refused, not split into words.
  /// Rejected: splitting on spaces. A path with a space in it (`Application Support`) would be
  /// split too, and quoting rules would be a second shell to get wrong. fvm's own `flutter`
  /// is an executable: give its absolute path.
  final String flutter;

  /// Passed to `flutter test` after the test, from `galley pack -- <args>`. An app whose galley
  /// test is skipped by default, so its ordinary test run leaves it out, passes
  /// `--run-skipped`. Rejected: always passing `--run-skipped`. It would also run every test
  /// the app skipped inside its galley test on purpose, and `pack` cannot tell which is which.
  final List<String> testArgs;

  @override
  Future<int> render(String outDir) async {
    final Process process;
    try {
      process = await Process.start(
        flutter,
        ['test', test, '--dart-define=GALLEY_OUT=${Directory(outDir).absolute.path}', ...testArgs],
        workingDirectory: app,
        mode: ProcessStartMode.inheritStdio,
      );
    } on ProcessException catch (e) {
      throw Refused(
        'could not run "$flutter" (${e.message}). --flutter is one executable, not a command: '
        'for fvm, give the absolute path of its flutter',
      );
    }
    return process.exitCode;
  }
}
