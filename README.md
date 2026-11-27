# Galley

A design-review canvas for Flutter apps. Every screen × state × device of an app is rendered as
a **frame**. Reviewers pin marks to widgets, the marks are answered, and the reviewers verify
the answers. Rounds stack, and nothing is erased.

**Status: 0.3.4, the local loop.** Galley renders and records a round of frames from inside an
app's own `flutter test`, and `galley_cli` keeps rounds and marks in a local galley: pack,
mark, pull, answer, verify, with every mark carried into the next round. The canvas and the
server that reviewers use are not built yet ([the plan](docs/ROADMAP.md)).

| Package | What it is |
|---|---|
| [`galley`](packages/galley) | Flutter, test-time. The `GalleyHost` an app implements, the built-in axes, the renderer and the packer. |
| [`galley_core`](packages/galley_core) | Pure Dart. Frame keys, frame trees, anchors and re-anchoring, marks, the round planner, frame records and the stored round. |
| [`galley_cli`](packages/galley_cli) | Dart. The `galley` command: a local galley of rounds and marks. |

## Adopting it

Add Galley as a dev dependency, pinned to a release tag:

```yaml
dev_dependencies:
  galley:
    git:
      url: https://github.com/SupposedlySam/galley
      path: packages/galley
      ref: v0.3.4
```

Write one host in `test/`. It is the app's only Galley code:

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:galley/galley.dart';

void main() => galley(MyAppHost());

class MyAppHost extends GalleyHost {
  @override
  List<GalleyScenario> get scenarios => [
    GalleyScenario('signed-in', screens: [Uri.parse('/home'), Uri.parse('/settings')]),
    GalleyScenario('empty', screens: [Uri.parse('/home')]),
  ];

  // Optional: the defaults are two phones, text at 1.0× and 2.0×, light and dark.
  @override
  GalleyAxes get axes => GalleyAxes(brightness: [Brightness.dark]);

  // Optional: where the app's widgets are, relative to the package root. Default: lib.
  @override
  List<String> get sourceRoots => const ['lib', 'packages/ui'];

  // Called for every render, on the real clock. Build fresh fakes each time.
  @override
  Future<Widget> mount(GalleyFrame frame) async =>
      MyApp(fakes: Fakes.forScenario(frame.scenario.name), opening: frame.uri);

  // Optional: only for screens no uri reaches.
  @override
  Future<void> arrive(WidgetTester tester, GalleyFrame frame) async {}
}
```

Render a round:

```sh
flutter test test/galley_test.dart --dart-define=GALLEY_OUT=build/galley/round-1
```

Without `GALLEY_OUT` the same file is a CI check: every frame is its own test, and a frame
that errs fails it. Either way, the run ends with one line saying how many frames rendered and
where they went.

A round takes a while, so an app may keep it out of a plain `flutter test`. Tag the file and
skip the tag in `dart_test.yaml`:

```dart
@Tags(['galley'])
library;
```

```yaml
# dart_test.yaml
tags:
  galley:
    skip: "a Galley round; run with --run-skipped"
```

Then `flutter test --run-skipped test/galley_test.dart` runs it. Galley does not skip itself
when `GALLEY_OUT` is unset, because that is how it runs as a CI check, and an unset value must
not quietly turn the check off.

## Running rounds: `galley_cli`

`galley_cli` keeps a galley in `.galley/` and runs the round for you (DESIGN D12). Add it next
to `galley`, at the same tag:

```yaml
dev_dependencies:
  galley_cli:
    git:
      url: https://github.com/SupposedlySam/galley
      path: packages/galley_cli
      ref: v0.3.4
```

Add `.galley/` to `.gitignore`. Otherwise the earlier rounds make every later round look as if
the tree had uncommitted changes.

```sh
dart run galley_cli:galley pack                    # renders round n+1, carries every mark into it
dart run galley_cli:galley mark --frame '<key>' --node 0.2 --note 'too tight' --by me
dart run galley_cli:galley pull --json             # open marks, where each is now, with its PNG
dart run galley_cli:galley answer <mark> fixed --commit <sha> --by me
dart run galley_cli:galley verify <mark> --by me   # or: reopen <mark> --note '...' --by me
```

`pack` runs `flutter test test/galley_test.dart` (`--test` to change it) and prints how many
frames rendered, the commit, and where every mark landed: exact, moved, lost, unplaced or
retired. Whatever follows `--` goes to `flutter test`, so a galley test skipped by its tag (above)
is packed with `galley pack -- --run-skipped`. `--flutter` names one executable, not a command:
under fvm, give the absolute path of its `flutter`. `pull` lists what waits on an answer;
`pull --all` adds the answered marks waiting on a reviewer, and the closed ones. `--by` defaults
to `GALLEY_BY`. Reviewers will mark on the canvas; `mark` is for the
app's owner and for tests.

## What a round contains

`GALLEY_OUT` gets `index.json`, `round.json` (the commit, whether the tree had uncommitted
changes, the Flutter version and the time) and, per frame, a PNG, a JSON tree of the app's widgets (type,
key, rect, source location, semantics label) and a JSON record.

Galley picks the frames itself. Each screen is shown on the reference value of every axis, and
then pairwise cover adds frames until every pair of values from two axes meets somewhere, with
the screen counted as an axis (DESIGN D9).

Every frame is rendered twice. If the two renders differ, the frame is an error naming the
widget that changed. A frame is also an error if anything throws, or if the app lands on a
different uri than the frame asked for. Galley reads that uri from the app's `Router`.

What a frame had to fake is listed on it as a **finding**: an unknown landing, an animation
frozen after 10 s, a font that was not loaded, a network image drawn as a placeholder, pixels
the app never painted, a word broken across lines, inside the picture or out of it (DESIGN D10).

## Docs

- [docs/DESIGN.md](docs/DESIGN.md): the principles, every decision, and what each rejected.
- [docs/BOUNDARY.md](docs/BOUNDARY.md): what Galley assumes about Flutter, with citations.
- [docs/ROADMAP.md](docs/ROADMAP.md): the steps to the first reviewed round, each one checkable.
- [llms.txt](llms.txt): the same, for an agent.

## Developing

Flutter 3.50.0 (`.fvmrc`). The packages are a pub workspace.

```sh
flutter pub get
dart format -l 100 packages
(cd packages/galley_core && dart analyze && dart test)
(cd packages/galley && flutter analyze && flutter test)
(cd packages/galley_cli && dart analyze && dart test)
```

## License

MIT. See [LICENSE](LICENSE).
