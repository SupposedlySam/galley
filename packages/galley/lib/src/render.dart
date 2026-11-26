import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:galley_core/galley_core.dart';

import 'capture.dart';
import 'fonts.dart';
import 'host.dart';
import 'network.dart';
import 'words.dart';

/// One render of one frame: what was on screen and what went wrong on the way.
final class RenderOutcome {
  /// An outcome. [errors] is empty when nothing threw.
  const RenderOutcome({
    required this.errors,
    required this.frozen,
    required this.landing,
    required this.findings,
    this.tree,
    this.pixels,
  });

  /// Everything thrown or reported to `FlutterError`, one message each.
  final List<String> errors;

  /// Whether the frame was still animating when the settle budget ran out.
  final bool frozen;

  /// Where the app was at capture.
  final Landing landing;

  /// What a reviewer should know: placeholders, fonts, frozen.
  final List<Finding> findings;

  /// The recorded widgets, or null when the render failed before it got there.
  final FrameTree? tree;

  /// The pixels, or null when the render failed before it got there.
  final FramePixels? pixels;
}

/// Mounts, settles, arrives and captures one frame (DESIGN D2′, D4).
final class FrameRenderer {
  /// A renderer for [host], recording widgets with [recorder] and checking text against
  /// [fonts].
  const FrameRenderer({
    required this.host,
    required this.recorder,
    required this.fonts,
    this.mountBudget = defaultMountBudget,
  });

  /// How long, in real time, [GalleyHost.mount] may take.
  final Duration mountBudget;

  /// Thirty seconds. Seeding fakes takes milliseconds, so a mount still running at thirty is
  /// waiting on something that will not come, such as a real backend or a completer nobody
  /// completes. The budget turns that into an error card naming the frame. Without it the run
  /// stalls with no output.
  static const defaultMountBudget = Duration(seconds: 30);

  /// The app.
  final GalleyHost host;

  /// Which widgets count as the app's.
  final TreeRecorder recorder;

  /// The fonts that were loaded.
  final GalleyFonts fonts;

  /// How long, in fake time, a frame may animate before it is frozen.
  ///
  /// Ten seconds: a screen's entrance is under one. A frame still busy at ten has a repeating
  /// animation (a spinner, a shimmer), which never settles at any budget.
  static const settleBudget = Duration(seconds: 10);

  /// Renders [frame] in [tester]'s view, which the axes have already set up.
  ///
  /// It never throws for something the app did. A throw from `mount`, a build error, an
  /// `arrive` that fails: each becomes an error in the outcome, and the frame becomes an error
  /// card. It does throw for Galley's own misuse, such as creation tracking being off.
  Future<RenderOutcome> render(WidgetTester tester, GalleyFrame frame) async {
    final errors = <String>[];
    final findings = <Finding>[];
    final previousOnError = FlutterError.onError;
    // Scoped to this render, and put back in `finally`. flutter_test's own handler would fail the
    // test at the first error. Galley wants every error, so it can draw the error card.
    FlutterError.onError = (details) => errors.add(_describe(details));
    final placeholder = NetworkPlaceholder();
    final uninstall = placeholder.install();
    final tickers = ValueNotifier(true);
    var frozen = false;
    try {
      try {
        final app = await _mount(tester, frame);
        await tester.pumpWidget(
          ValueListenableBuilder<bool>(
            valueListenable: tickers,
            builder: (_, on, child) => TickerMode(enabled: on, child: child!),
            // A new key on every render. Without it, a second render of the same app type
            // into the same slot keeps the first render's State: its router, its controllers.
            // It then shows the first render's end state, and the determinism check compares
            // a frame with itself. Observed in Galley's own test of `arrive`.
            child: KeyedSubtree(key: UniqueKey(), child: app),
          ),
        );
        frozen = await _settle(tester, tickers);
        await host.arrive(tester, frame);
        frozen = await _settle(tester, tickers) || frozen;
      } on Object catch (e, stack) {
        errors.add('$e\n${_firstFrames(stack)}');
      }

      final landing = readLanding(tester);
      if (landing case LandedAt() when !landing.isAt(frame.uri)) {
        errors.add('expected ${frame.uri}, landed at ${landing.uri}');
      } else if (landing case LandingUnknown(:final reason)) {
        findings.add(
          Finding(
            kind: 'landing-unknown',
            message: 'Galley could not check that this is ${frame.uri}: $reason',
          ),
        );
      }
      if (frozen) {
        findings.add(
          Finding(
            kind: 'frozen',
            message:
                'still animating after ${settleBudget.inSeconds} s; captured with tickers '
                'stopped',
          ),
        );
      }

      final tree = recorder.record(tester);
      final pixels = await FramePixels.capture(tester);
      final view = tester.binding.renderViews.single;
      findings
        ..addAll(fonts.missingIn(view))
        ..addAll(brokenWordsIn(view));
      final unpainted = pixels.unpainted;
      if (unpainted > 0) {
        findings.add(
          Finding(
            kind: 'unpainted',
            message:
                '$unpainted of ${pixels.width * pixels.height} pixels are not opaque; a device '
                'shows its window background there',
          ),
        );
      }
      final urls = placeholder.requested.toSet();
      if (urls.isNotEmpty) {
        findings.add(
          Finding(
            kind: 'network-image',
            message: '${urls.length} image(s) drawn as gray placeholders: ${urls.join(', ')}',
          ),
        );
      }
      return RenderOutcome(
        errors: errors,
        frozen: frozen,
        landing: landing,
        findings: findings,
        tree: tree,
        pixels: pixels,
      );
    } finally {
      FlutterError.onError = previousOnError;
      uninstall();
      tickers.dispose();
    }
  }

  /// Runs [GalleyHost.mount] in real time, within [mountBudget].
  ///
  /// A testWidgets body runs on a fake clock, and only a pump moves it. Nothing pumps while the
  /// body awaits `mount`. So a mount that awaits real work, such as a file write or a database
  /// opened by a fake, never finishes, and the run stalls with no output. Observed in the first
  /// adopting app: its scenario seeding hung, and a timeout inside the mount never fired
  /// because fake time stood still. `tester.runAsync` runs the mount on the real clock.
  ///
  /// Galley owns this, not the host. The host has no tester in `mount`, and an async mount is
  /// the norm for an app that seeds fakes. Rejected: passing the tester to `mount`. Every host
  /// would then have to learn the trap.
  ///
  /// Errors are caught inside, not left to `runAsync`. `runAsync` reports an error to
  /// `FlutterError` and completes with null (flutter_test binding.dart, `runAsync`), which
  /// would lose the stack's link to the mount.
  ///
  /// What a mount starts also runs in real time: a timer it starts ticks on the wall clock, not
  /// the fake one. Timers that belong to the app start in its widgets, which are built after
  /// the mount, on the fake clock.
  Future<Widget> _mount(WidgetTester tester, GalleyFrame frame) async {
    final result = await tester.runAsync<_Mounted>(() async {
      try {
        return _Mounted.app(await host.mount(frame).timeout(mountBudget));
      } on TimeoutException {
        return _Mounted.failed(
          StateError(
            'mount did not finish within ${mountBudget.inMilliseconds / 1000} s of real time; '
            'it is waiting on something a fake never answers',
          ),
          StackTrace.current,
        );
      } on Object catch (e, stack) {
        return _Mounted.failed(e, stack);
      }
    });
    final mounted = result!;
    if (mounted.app case final app?) return app;
    Error.throwWithStackTrace(mounted.error!, mounted.stack!);
  }

  /// Settles, and freezes on timeout. Returns whether it had to freeze.
  ///
  /// flutter_test signals the timeout only as `FlutterError('pumpAndSettle timed out')`
  /// (widget_tester.dart, `pumpAndSettle`), with no type of its own. So the message is matched,
  /// and any other error is rethrown.
  static Future<bool> _settle(WidgetTester tester, ValueNotifier<bool> tickers) async {
    if (!tickers.value) {
      await tester.pump();
      return true;
    }
    try {
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        settleBudget,
      );
      return false;
    } on FlutterError catch (e) {
      if (!e.message.startsWith('pumpAndSettle timed out')) rethrow;
      tickers.value = false;
      await tester.pump();
      return true;
    }
  }

  /// Where the app's router says it is.
  ///
  /// It reads the outermost `Router` that has a parser, which is the app's own:
  /// `delegate.currentConfiguration`, restored by the parser to a `RouteInformation`. That is the
  /// uri the platform would show in its address bar. Nested routers have no parser.
  ///
  /// Rejected: matching the screen's widget type. It would make the app declare a widget per
  /// uri, which is a second, drifting copy of its router.
  static Landing readLanding(WidgetTester tester) {
    for (final element in tester.allElements) {
      final widget = element.widget;
      if (widget is! Router<Object?>) continue;
      final parser = widget.routeInformationParser;
      if (parser == null) continue;
      final config = widget.routerDelegate.currentConfiguration;
      if (config == null) return const LandingUnknown('the router has no current configuration');
      final info = parser.restoreRouteInformation(config);
      if (info == null) return const LandingUnknown('the parser restores no route information');
      return LandedAt(info.uri);
    }
    return const LandingUnknown('the app has no Router with a route information parser');
  }

  static String _describe(FlutterErrorDetails details) {
    final context = details.context?.toDescription();
    return '${details.exceptionAsString()}${context == null ? '' : ' ($context)'}';
  }

  static String _firstFrames(StackTrace stack) =>
      stack.toString().split('\n').where((l) => l.trim().isNotEmpty).take(6).join('\n');
}

/// What a mount produced: the app, or what it threw and where.
final class _Mounted {
  const _Mounted.app(Widget this.app) : error = null, stack = null;
  const _Mounted.failed(Object this.error, StackTrace this.stack) : app = null;

  final Widget? app;
  final Object? error;
  final StackTrace? stack;
}
