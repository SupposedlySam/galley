# Galley design decisions

Each decision gives what was chosen, why, and what was rejected. A decision that is replaced
stays here, marked *Retracted*, next to the decision that replaced it. The facts these
decisions rest on are cited in [BOUNDARY.md](BOUNDARY.md). What exists today is in the
[README](../README.md).

## Principles

The decisions below follow from these. Code comments cite them by name.

- **An unknown is never nothing.** A frame that failed is an error card, not a missing frame.
  An anchor that was not found is Lost, not Exact. A landing Galley could not read is a
  finding, never a match. Empty, null and "could not read" must never be storable as "nothing
  is wrong".
- **Nothing is erased.** Rounds stack. A mark's history is an append-only log, and a frame
  that left the app is retired with its history kept.
- **No real backends in a frame.** Frames run on the app's fakes only.
- **The app writes one host file.** Galley never imports an app, and asks nothing of it beyond
  `GalleyHost` (D2′).
- **Assert on the population, not only the absence,** and mutate the code to prove a test is
  load-bearing. "No errors" is also what a broken producer returns.

## D1 · Packages split by what they may depend on (2026-11-25)

```
packages/
  galley_core/     pure Dart. Models, frame keys, anchors, re-anchoring, the .galley format.
                   Depends on nothing but the Dart SDK.
  galley/          Flutter, test-time. GalleyHost + FrameSource contracts, built-in axes,
                   the packer. Depends on galley_core and flutter_test.
  galley_cli/      planned: `galley pack | push | pull | answer`. Depends on galley_core,
                   never on Flutter.
apps/
  galley_server/   planned: the backend (D7). Depends on galley_core's wire types.
  galley_web/      planned: the reviewer canvas (Flutter web). Depends on galley_core.
```

- **Why:** carry-forward is the product, and it is pure logic over two trees. In
  `galley_core` it is tested in milliseconds with no Flutter binding, and the server, CLI and
  viewer all share one definition of a frame key and an anchor. If each layer had its own copy,
  they would drift. The first drift would show up as a mark landing on the wrong widget, which
  is the defect reviewers would trust the product least after.
- **Rejected:** one Flutter package. The CLI and server would then pull in Flutter to read a
  manifest.

## D2′ · The app's only code is one host file (2026-11-25, replaces D2)

Agreed with the first adopting app. The lens: protect the app's DX, keep Galley's lines out of
the app, and let Galley do the hard engineering.

```dart
abstract class GalleyHost {
  List<GalleyScenario> get scenarios;          // name + screens (List<Uri>)
  List<String> get variants => const [];
  GalleyAxes get axes => GalleyAxes();
  List<String> get sourceRoots => const ['lib'];
  Future<Widget> mount(GalleyFrame frame);     // scenario, uri, variant
  Future<void> arrive(WidgetTester t, GalleyFrame frame) async {}
}
```

- **Galley derives the frames** as scenarios × screens × axes, and its pairwise planner picks the
  combinations. The app keeps no screen catalog, because one grows with every screen added.
- **`arrive` is the exception, not the rule.** It is only for screens no URI reaches, such as
  a timer that holds in-memory state. It takes the frame because getting there is scripted from the
  scenario's state.
- **`mount` is called once per render**, so twice per frame (D4). It must build fresh fakes each
  time. If a fake is shared, the second render sees the first one's changes and the frame becomes
  a determinism error.
- **`mount` runs on the real clock**, in `tester.runAsync`, with 30 s of real time. A
  testWidgets body runs on a fake clock that only a pump moves, and nothing pumps while Galley
  awaits the mount. A mount that awaits real I/O therefore never finished, and the run stalled
  with no output (observed in the first adopting app, 0.1.1). Rejected: handing `mount` the
  tester, which would make every host learn the trap. `arrive` stays on the fake clock, because
  its taps and pumps need it.
- **What landed is read from the Router**, not asked of the host: the outermost `Router` with a
  parser, its delegate's `currentConfiguration` restored to a uri (BOUNDARY § Landing). An app
  with no Router gets a `landing-unknown` finding, never an assumed match.
- **Determinism belongs to Galley**, and so does saying where it broke:
  - *Not built yet:* the clock is pinned. testWidgets builds `FakeAsync()` with no initialTime (flutter_test
    `binding.dart:2591`), and FakeAsync seeds `package:clock` from the wall clock
    (`fake_async-1.3.3/lib/fake_async.dart:106`). So `clock.now()` differs from run to run.
    Galley zones in a fixed epoch that advances with fake time. `DateTime.now()` is out of its
    reach, which is the audit's job.
    - An app's own time seam wins, and Galley never moves it. An app whose test harness pins
      its own clock sees no change from the zone. A frame that needs another moment says so in
      its scenario.
  - Network images: flutter_test already answers every request with an empty 400
    (`_binding_io.dart:79`). Galley replaces that with a placeholder and records each URL on the
    frame.
  - Fonts come from the app's FontManifest. A family that is requested but not loaded is a
    finding.
  - A frame that never settles is captured with tickers off and marked frozen, never passed as
    clean.
  - When the two renders differ, the element trees are diffed. If the trees match but the pixels
    don't, the deepest widget inside the pixel diff's bounding box is named, with its source
    location.
  - *Not built yet:* `dart run galley:audit` reports `DateTime.now()`, `Random()` and wall-clock Timers in lib/.
    It is report-only unless `--strict`.
    - There are no inline suppressions (`// galley:allow`), because they would scatter Galley
      lines through the app.
    - A read inside a class that implements a one-method time seam is reported as the seam,
      not as a leak. That is the system `Clock`'s job.
    - Enforcement belongs to the app, in its own source rules.
- **The error headline is about the frame:** scenario, uri, axes, expected, landed and culprit.
  The stack goes in the details.
- **Rejected:** the app keeping a per-screen catalog (D2 below), and `GalleyScenario.apply`
  alongside `mount`, because that would put state setup in two places.

## D2 · The app's only code is a host and a catalog (2026-11-25) — *Retracted by D2′*

The app implements two interfaces, and Galley depends on nothing else of the app's (dependency
inversion):

- `FrameSource`: yields `FrameSpec`s. Each spec is a screen id, the flow it belongs to, the
  app's own state axes (scenario, variant), and the built-in axes that apply.
- `GalleyHost.arrive(GalleyTester, FrameSpec)`: puts the app into that frame. It mounts on fakes,
  applies the scenario, and then reaches the screen by **route or by scripted steps**. Some
  screens hold in-memory state that no URL can carry.

Galley applies the built-in axes itself, through Flutter's test hooks (BOUNDARY § Flutter test
hooks): device size and pixel ratio, text scale, brightness, platform and locale. It resets them
after every frame, because `flutter test` does not.

- **Rejected:** `Scenario.screens` as the only source of frames. A route alone cannot reach
  every screen. A scenario still names its screens; the host's
  catalog turns each one into an arrival.
- **Rejected for v1:** `RouteSource` and `PreviewSource`. Many apps have no route table (a
  router that parses with a switch has nothing to enumerate). Previews are found by the analyzer, not at runtime
  (BOUNDARY § Flutter previews). Both are later bets.

## D3 · The packer runs inside the app's own `flutter test` (2026-11-25)

`galley pack` runs `flutter test <the app's galley entry> --dart-define=GALLEY_OUT=<dir>`.
That puts the packer in the app's own test process, with the app's fonts, fakes and
`test/support` code, and with creation tracking on by default (BOUNDARY § Creation locations).

- **Why:** the fakes and harness that make a screen render headless already live in the
  app's tests. Moving them out into a package is a cost every adopting app would pay again.
- **Rejected:** a separate entrypoint on `flutter-tester`. That needs args smuggled through the environment and has no `WidgetTester`.

## D4 · A frame is captured as pixels plus a tree, and must render the same twice (2026-11-25)

For each frame the packer captures:
- the PNG of the root layer;
- every element that owns a `RenderBox`: its runtime type, key, global rect, creation location
  (file:line:column, via `dart:developer`'s `CreationLocation.of`), and the semantics label of
  the node it contributes to;
- every `FlutterError` raised while the frame mounted and settled, including overflows,
  collected through a scoped `FlutterError.onError`. `takeException` returns only the first.

It then **renders the frame again from scratch and compares**: pixels first, then the
recorded trees field by field. A frame that differs, threw,
or never settled becomes an error card that names the cause. It is never dropped. An empty
round must never read as "nothing to review".

- **Why twice:** a single clock read or unsettled animation would otherwise make the frame
  "changed" in every later round, and Compare would become noise.

## D5 · The frame key is the axis values, not the pixels (2026-11-25)

A frame key is the canonical, sorted `axis=value` list: screen, scenario, variant, device,
platform, brightness, text scale, locale. It carries no hash, so the same frame in round 5 is
"the same frame" as in round 4 even when its pixels changed. Content hashes identify an
image, and a frame key identifies a place in the review.

## D6 · A mark is anchored by layered evidence, and re-anchoring reports its confidence (2026-11-25)

A mark stores:
- the frame key;
- the anchor widget's key, semantics label, creation location and index path, and its rect;
- the pin's offset inside that widget, relative to the widget's size;
- a crop of the snapshot.

Carry-forward looks up the anchor in the new frame's tree in a fixed order: key, then semantics
label, then creation location, then index path. Each step falls back to the next only when the
previous one is absent or ambiguous. The result is **Exact** (found, rect similar), **Moved**
(found, rect elsewhere) or **Lost** (not found: the mark keeps its old crop as a ghost). A
frame missing from the new round is **retired**, with its history kept. Nothing is ever deleted.

*As built (`galley_core/lib/src/reanchor.dart`, 2026-11-25):*
- **Matchers narrow; they do not race.** Each matcher filters the candidates the earlier ones
  left. One left decides it. Several left carry on. None left means this evidence no longer
  holds, so it is skipped. A shared label plus a call site picks out one of three buttons,
  where "first matcher with a unique hit" would fall through to the index path.
  - The order is key, semantics label, exact location, then file + type, then index path +
    type.
  - File + type was added because a single line inserted above a widget breaks an exact
    location.
- **Ambiguous is Lost, with its candidates.** If the evidence runs out with several nodes
  left, the result is Lost and lists them. It never picks the first.
- **Index path needs the type too.** Rejected: a path alone. Some node sits at almost any path,
  so a deleted widget would be reported as found.
- **Exact means IoU ≥ 0.9.** That is about 5 px of drift on a 100 px wide box. Rejected: 1.0,
  which calls every sub-pixel re-layout Moved and trains reviewers to ignore the flag.
- **A mark's status is a fold over an append-only event log** (answered, verified, reopened).
  An illegal sequence is refused when it is written and again when it is read.

## D7 · Server: decided when it is built, against these constraints (2026-11-25)

Reviewers are outside the app's team, so the server needs:
- sign-in that needs no password, such as an emailed code;
- read rules applied to every read, live streams included, scoped to the galleys a reviewer
  was invited to;
- invites and accepting them;
- image storage behind the same rules;
- presence, later, for multiplayer.

Each candidate backend is measured against this list with a spike before the server is
written, and the gaps it leaves get a decision here.

## D8 · Released by git tag until pub.dev (2026-11-25)

The packages follow semantic versioning, and each release is a tag `v<version>` on the
GitHub repo. Before pub.dev, an app pins a tag:

```yaml
dev_dependencies:
  galley:
    git: {url: https://github.com/SupposedlySam/galley, path: packages/galley, ref: v0.1.2}
```

- **Why not a path dependency:** CI and fresh clones have no sibling checkout, so `pub get`
  fails for the whole app. A dev tool must not be able to break an app's release build.
- **One version for both packages** while they move together.
- **`galley` depends on `galley_core` by path** while apps pin a git tag: a git dependency
  resolves a relative path inside its own repo. A version constraint would send pub to pub.dev
  for a `galley_core` that is not there. The commit that publishes to pub.dev replaces the path
  with `^<version>` and removes `galley`'s `publish_to: none`, because pub.dev refuses path
  dependencies. Until then `publish_to: none` also stops an accidental publish.
- **Before 1.0**, a minor bump may break the API, and a patch never does (Dart's convention for
  0.x).

## D9 · A round is the essential set plus pairwise cover, with the subject as a factor (2026-11-25)

A **subject** is a frame before the axes are applied: its scenario, screen and variant. The
`FramePlanner` (`galley_core/lib/src/plan.dart`) plans a round in two steps:
- It takes every subject on every axis's reference value (the first value declared).
- It adds frames until every pair of values from two factors appears. The subject is one
  factor, and each axis is another.

- **Why the subject is a factor:** so that every screen is seen on every device and at every
  text scale. The default 2 devices × 2 text scales then costs 2n to 2n + 2 frames for n
  subjects, and 2n is the lower bound.
- **Rejected:** pairs among the axes only. That shows the small phone at 2.0× on one screen and
  counts the job done.
- **Rejected:** the full product. That is about 35,000 frames for a mid-sized app.
- **Deterministic greedy construction (AETG family).** Ties go to the lowest index, so they go
  to the reference value. The same input gives the same frames in the same order, so a round's
  frame list does not churn.
- *Mutation, 2026-11-25:* 11 of 13 mutants are killed.
  - Dropping either half of the seed pair survives, because greedy picks the seed's values
    anyway: they are its gain.
  - The seed is kept as the termination guarantee: every row covers at least one uncovered
    pair.

## D10 · What a render does for the app, and what it reports (2026-11-25)

`FrameRenderer` (`galley/lib/src/render.dart`) mounts, settles, arrives, settles, then reads
the landing, records the tree and captures pixels. Whatever it had to work around becomes a
**finding** on the frame, so the card says what is not real:

| Finding | When |
|---|---|
| `landing-unknown` | no `Router` with a parser, or it reports no configuration |
| `frozen` | still animating after 10 s of fake time; captured with tickers stopped |
| `missing-font` | text asks for a family that was not loaded |
| `default-font` | text names no family; a device would use its own font |
| `network-image` | a `NetworkImage` was drawn as a gray placeholder; the URLs are listed |
| `unpainted` | some pixels are not opaque; a device shows its window background there |

- **Errors are not findings.** A throw from mount, build or arrive, any `FlutterError`, a
  landing on another uri, or two renders that differ makes the frame an error. Each frame is
  its own test, and an error fails it with a headline: scenario, expected, landed, device,
  errors.
- **A mount that outruns its budget is an error**, not a stalled run: "mount did not finish
  within 30 s of real time".
- **Each render gets a new `KeyedSubtree(UniqueKey())`.** Without it the second render reuses
  the first one's State (its router, its controllers), shows the first one's end state, and the
  determinism check compares a frame with itself. Observed in Galley's own `arrive` test.
- **Unpainted pixels are reported, not filled.** Rejected: compositing over black or white. A
  real device's window background depends on its theme, and a guessed color would hide that
  the app paints nothing there.
- **The record** (`galley_core/lib/src/record.dart`) is one JSON file per frame. Its status is
  `rendered`, `frozen` or `error`, and the constructor refuses an error with no errors or errors
  on a non-error. A landing is a uri or an unknown with a reason, never both and never neither.
