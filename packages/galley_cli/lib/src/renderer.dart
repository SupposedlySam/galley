import 'dart:io';

/// Writes a round into a directory. `pack` asks for one, then reads what was written.
abstract interface class RoundRenderer {
  /// Renders a round into [outDir], which does not exist yet, and returns the exit code.
  ///
  /// A non-zero code does not mean there is no round: the galley test fails each frame that
  /// errors, and still writes the round with those frames in it.
  Future<int> render(String outDir);
}

/// Runs the app's galley test, the same command its owner runs by hand (README).
final class FlutterTestRenderer implements RoundRenderer {
  /// Runs [test] in the app at [app] with the `flutter` at [flutter].
  const FlutterTestRenderer({required this.app, required this.test, this.flutter = 'flutter'});

  /// The app's root, where its pubspec is.
  final String app;

  /// The galley test, relative to [app].
  final String test;

  /// The flutter command. Rejected: picking one from `FLUTTER_ROOT` or an fvm config. The app's
  /// owner already chose which Flutter `flutter` means here, and a second rule would disagree
  /// with theirs.
  final String flutter;

  @override
  Future<int> render(String outDir) async {
    final process = await Process.start(
      flutter,
      ['test', test, '--dart-define=GALLEY_OUT=${Directory(outDir).absolute.path}'],
      workingDirectory: app,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
}
