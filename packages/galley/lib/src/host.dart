import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:galley_core/galley_core.dart';

import 'axes.dart';

/// The app's whole integration with Galley: one class, in the app's own `test/` (DESIGN D2′).
///
/// Galley never imports the app, and the app's `lib/` never imports Galley. The host is where the
/// two meet. It says which states exist and which screens each one shows, and it knows how to
/// mount the app on its fakes. Galley derives the frames, applies the axes, settles, captures,
/// checks determinism and reports. An app's entry is one line:
///
/// ```dart
/// void main() => galley(MyAppHost());
/// ```
abstract class GalleyHost {
  /// A const constructor, so a host can be const.
  const GalleyHost();

  /// The app's states, each with the screens it shows.
  List<GalleyScenario> get scenarios;

  /// Designs under decision. Each is a value on the `variant` axis, crossed pairwise with the
  /// others. Empty means the app has no variant axis.
  List<String> get variants => const [];

  /// The built-in axes and the values this app declares for them.
  GalleyAxes get axes => GalleyAxes();

  /// The directories, relative to the package root `flutter test` runs in, whose widgets are
  /// the app's: they make up the frame tree that marks anchor to (TreeRecorder).
  ///
  /// The default is `lib`. An app whose widgets also live in local packages names those
  /// packages too, such as `['lib', 'packages/ui']`.
  List<String> get sourceRoots => const ['lib'];

  /// The app, mounted on fakes in [frame]'s scenario, opening at [frame]'s uri.
  ///
  /// Called once per render, and every frame renders twice (DESIGN D4). So build fresh fakes on
  /// every call. A fake shared between calls lets the second render see the first one's changes,
  /// and the frame becomes a determinism error that is really a test-setup bug.
  Future<Widget> mount(GalleyFrame frame);

  /// Gets from where [mount] opened to [frame]'s screen, when no uri reaches it.
  ///
  /// The exception, not the rule. A screen that holds in-memory state (a plan built on the
  /// screen before, a running timer) is reached by scripted taps from the scenario. Galley
  /// settles before and after. It then checks where the app landed against [GalleyFrame.uri],
  /// so an arrival that stops short is an error card, not a frame of the wrong screen.
  Future<void> arrive(WidgetTester tester, GalleyFrame frame) async {}
}

/// One of the app's states, and the screens it is reviewed on.
final class GalleyScenario {
  /// A scenario named [name], shown on [screens].
  ///
  /// [name] becomes the `scenario` value of every frame key, so it is spelled as a [FrameKey] id:
  /// letters, digits, `_`, `-` and `.`.
  GalleyScenario(this.name, {required List<Uri> screens}) : screens = List.unmodifiable(screens) {
    if (!FrameKey.isValidId(name)) {
      throw ArgumentError.value(name, 'name', 'must be letters, digits, "_", "-" or "."');
    }
    if (screens.isEmpty) {
      throw ArgumentError.value(screens, 'screens', 'scenario "$name" shows no screen');
    }
  }

  /// The scenario's id.
  final String name;

  /// Where it is reviewed. Each uri is a screen, opened by [GalleyHost.mount] and, when no uri
  /// reaches it, finished by [GalleyHost.arrive].
  final List<Uri> screens;

  @override
  String toString() => name;
}

/// The frame being rendered: a scenario, a screen, and its value on every axis.
final class GalleyFrame {
  /// A frame. Built by Galley from the plan, not by the app.
  const GalleyFrame({
    required this.key,
    required this.scenario,
    required this.uri,
    required this.essential,
    this.variant,
  });

  /// Its identity across rounds (DESIGN D5).
  final FrameKey key;

  /// The state it shows.
  final GalleyScenario scenario;

  /// The screen it shows.
  final Uri uri;

  /// The variant, or null when the app has none.
  final String? variant;

  /// Whether it is in the essential set (DESIGN D9).
  final bool essential;

  @override
  String toString() => '$key';
}
