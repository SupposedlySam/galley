# What Galley assumes about the layers below it

Every assumption here has a citation and the date it was checked. A design decision in
[DESIGN.md](DESIGN.md) that rests on one of these says which. When a citation stops being
true, fix this file and every decision that cites it in the same change.

## Flutter (3.50.0; checked 2026-11-25)

Paths are under the SDK's `packages/`.

### Creation locations
- `flutter test` tracks widget creation by default. `track-widget-creation` has
  `defaultsTo: true` (`flutter_tools/lib/src/runner/options/common_options.dart:144-146`), and
  the test command registers it (`flutter_tools/lib/src/commands/test.dart:84`).
- The public accessor is `dart:developer`'s `CreationLocation.of(widget)`, with fields `file`
  (a `file:///` URI), `line` and `column` (`bin/cache/dart-sdk/lib/developer/creation_tracking.dart:45-70`).
  The framework's private `_getCreationLocation` uses it (`flutter/lib/src/widgets/widget_inspector.dart:4358`).
- **The transform skips constructors with optional positional parameters**, so `of` returns
  null for them (`creation_tracking.dart:~34-42`). An anchor must not require a creation
  location.
- A path-dependency package's widgets are tracked too. This was measured in a scratch app on
  2026-11-25; the transform's own source was not read.
- The location is the constructor **call site**, not the widget's class definition.

### Flutter test hooks
- Text scale, brightness, locale and accessibility features are set through
  `tester.platformDispatcher.*TestValue` (`flutter_test/lib/src/window.dart:284-377, 768`).
  Size and pixel ratio are set through `tester.view` (`window.dart:1049, 1128`).
- **None are reset between tests.** `binding.postTest` does not reset them
  (`flutter_test/lib/src/binding.dart:2195`). Reset with `tester.view.reset()` and
  `tester.platformDispatcher.clearAllTestValues()` (`window.dart:804`).
- `debugDefaultTargetPlatformOverride` is not reset by those calls either, and the binding's
  invariant check fails if it is left set (`binding.dart:2030-2052`).

### Pixels
- A full-screen capture is `renderViews.first.debugLayer as OffsetLayer`, then `toImage`, inside
  `tester.runAsync`. Without `runAsync` it deadlocks in fake async
  (`flutter_test/lib/src/_matchers_io.dart:26-35, 97-121`).
- Measured 2026-11-25: 50 frames at 1080×2400 and pixel ratio 2.75, each pumped, settled and
  PNG-encoded, took 2.6 s in one test body.
- `flutter test` runs with `--use-test-fonts` (Ahem;
  `flutter_tools/lib/src/test/flutter_tester_device.dart:118`). Real glyphs need `FontLoader`.
  Roboto is not in an app's `FontManifest.json`; the SDK keeps it in
  `bin/cache/artifacts/material_fonts/Roboto-*.ttf`.
- A `Text` with no `Material` ancestor gets the fallback error style, in `monospace`. Two
  different strings in it rendered pixel-identical in the test font (measured 2026-11-25), so a
  pixel check alone cannot tell them apart.
- Shadows are disabled in tests (`binding.dart:2342`, `painting/debug.dart:42`).

### Overflow
- A `RenderFlex` overflow is reported only at paint time, only with asserts on, and once per
  render object (`rendering/flex.dart:1441`, `rendering/debug_overflow_indicator.dart:285-330`).
- `takeException` returns only the first exception (`binding.dart:1641`). Collect every
  exception with a scoped `FlutterError.onError`.
- `RenderParagraph` has no public overflow flag. Compare `size` against `textSize`, which is
  public (`rendering/paragraph.dart:988-995, 1214`).

### Semantics
- Turn semantics on with `tester.ensureSemantics()`, and dispose the handle before the test
  ends (`flutter_test/lib/src/controller.dart:2368`, `widget_tester.dart:1067-1083`).
- A node's rect is local; a global rect composes the ancestors' `transform`s.
- There is no public map from a node back to a widget. Go from element to node with
  `renderObject.debugSemantics` (`rendering/object.dart:3899`), climbing parents while
  `isMergedIntoParent`.

### Flutter previews
- `package:flutter/widget_previews.dart` exists. `Preview` is a const annotation
  (`flutter/lib/src/widget_previews/widget_previews.dart:66-87`), and `MultiPreview` is at `:244`.
- Discovery is static, through the analyzer
  (`flutter_tools/lib/src/widget_preview/preview_detector.dart:7-10`). There is no runtime
  registry.

### Settling
- `pumpAndSettle(duration, phase, timeout)` signals a timeout only as
  `FlutterError('pumpAndSettle timed out')`, with no type of its own
  (`flutter_test/lib/src/widget_tester.dart`, `pumpAndSettle`). Galley matches the message.
- `TickerMode(enabled: false)` above the app stops every ticker, so one more pump captures a
  still frame.

### The fake clock
- A testWidgets body runs inside FakeAsync. Its timers and microtasks wait for a pump, so an
  awaited real future (file I/O, a socket) never completes, and a `.timeout` set in that zone
  never fires. Observed 2026-11-25: a mount that wrote a file stalled the run with no output,
  and `--timeout 20s` did not end it.
- `tester.runAsync(cb)` runs `cb` in a zone whose timers and microtasks go to the root zone
  (`flutter_test/lib/src/binding.dart`, `runAsync`). An error inside it is reported to
  `FlutterError` and the future completes with null; it is not rethrown. So Galley catches
  inside the callback. Calls cannot nest: a second `runAsync` before the first completes fails.

### State across `pumpWidget`
- A widget of the same type in the same slot keeps its `State` across `pumpWidget` calls in one
  test. A new `UniqueKey` above it forces a fresh mount. Observed 2026-11-25.

### Text scale
- `MediaQuery.textScalerOf` returns a `SystemTextScaler` that reads the dispatcher **live**. A
  scale read after the test values are cleared reports 1.0, so read it during the build.

### Network images
- flutter_test answers every HTTP request with an empty 400 (`flutter_test/lib/src/_binding_io.dart`,
  `_MockHttpOverrides`).
- `NetworkImage` asks `debugNetworkImageHttpClientProvider` (`painting/debug.dart`) for a client
  before its shared one (`painting/_network_image_io.dart`, `_httpClient`). The hook must be
  unset when the test ends (`debugAssertAllPaintingVarsUnset`).

### Landing
- `Router.routeInformationParser` is null for nested routers and set on the app's own. The
  landing is `routerDelegate.currentConfiguration`, restored by
  `parser.restoreRouteInformation(...)`, whose `uri` is what the platform would show
  (`widgets/router.dart`).

### Material
- `package:flutter/material.dart` is deprecated in 3.50 in favor of `package:material_ui`.
  Galley's own tests import `package:material_ui/material_ui.dart`; the library does not import
  Material at all.

### Packaging
- A path dependency on a package that declares `resolution: workspace`, from a project outside
  the workspace, resolves: `pub get` exits 0 and a round runs (measured 2026-11-25 with a
  scratch consumer).
