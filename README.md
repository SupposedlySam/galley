# Galley

A design-review canvas for Flutter apps. Every screen × state × device of an app is rendered as
a **frame**. Reviewers pin marks to widgets, the marks are answered, and the reviewers verify
the answers. Rounds stack, and nothing is erased.

**Status: 0.3.12, the local loop, its canvas, and a server.** Galley renders and records a round of
frames from inside an app's own `flutter test`, and `galley_cli` keeps rounds and marks in a local
galley: pack, mark, pull, answer, verify, with every mark carried into the next round. `galley
serve` serves that galley on this machine, with the canvas, where its owner marks the round in a
browser. A galley can also live on a Galley server, where reviewers sign in by a mailed code and
mark it on the same canvas; `galley host` runs one on this machine, and `galley bundle` writes one
out for a host ([docs/HOSTING.md](docs/HOSTING.md)). What is left: [the plan](docs/ROADMAP.md).

| Package | What it is |
|---|---|
| [`galley`](packages/galley) | Flutter, test-time. The `GalleyHost` an app implements, the built-in axes, the renderer and the packer. |
| [`galley_core`](packages/galley_core) | Pure Dart. Frame keys, frame trees, anchors and re-anchoring, marks, the round planner, frame records and the stored round. |
| [`galley_cli`](packages/galley_cli) | Dart. The `galley` command: a local galley of rounds and marks. |
| [`galley_web`](packages/galley_web) | Flutter web. The canvas `galley serve` serves. Not a dependency: it ships built, with each release that changes it. |

## Adopting it

Add Galley as a dev dependency, pinned to a release tag:

```yaml
dev_dependencies:
  galley:
    git:
      url: https://github.com/SupposedlySam/galley
      path: packages/galley
      ref: v0.3.12
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
      ref: v0.3.12
```

Add `.galley/` to `.gitignore`. Otherwise the earlier rounds make every later round look as if
the tree had uncommitted changes.

```sh
dart run galley_cli:galley pack                    # renders round n+1, carries every mark into it
dart run galley_cli:galley mark --frame '<key>' --node 0.2 --note 'too tight' --by me
dart run galley_cli:galley pull --json             # open marks, where each is now, with its PNG
dart run galley_cli:galley answer <mark> fixed --commit <sha> --by me
dart run galley_cli:galley verify <mark> --by me   # or: reopen <mark> --note '...' --by me
dart run galley_cli:galley withdraw <mark> --note 'a duplicate of m3' --by me   # yours only
```

`pack` runs `flutter test test/galley_test.dart` (`--test` to change it) and prints how many
frames rendered, the commit, and where every mark landed: exact, moved, lost, unplaced or
retired. Whatever follows `--` goes to `flutter test`, so a galley test skipped by its tag (above)
is packed with `galley pack -- --run-skipped`. `--flutter` names one executable, not a command:
under fvm, give the absolute path of its `flutter`. `pull` lists what waits on an answer;
`pull --all` adds the answered marks waiting on a reviewer, and the closed ones. `--by` defaults
to `GALLEY_BY`. Reviewers will mark on the canvas; `mark` is for the
app's owner and for tests. A mark is never deleted: whoever raised one takes it back with
`withdraw`, and it is kept, with its history, waiting on no one. Do not delete files under
`.galley/`; a galley that does not hold together is refused, naming the file.

`galley serve` serves the galley on `http://localhost:7340/` (`--port` to change it) until
Ctrl-C: the rounds' files, every mark, and new marks and events through the same checks as the
commands (DESIGN D13). It listens on loopback only. At `/` is the canvas: open
`http://localhost:7340/?by=<your name>`. Zoomed out, each frame is named across its top, and
a click opens it; on an open frame, click a widget to mark it (widgets filling one box are
offered as one, by what is on screen), and answer, verify or reopen in its thread. Screens are
shown by the names the host gives them (`GalleyHost.screenNames`), `/` as `home`. Above the marks, the answers waiting on you are listed, the
oldest first. Each one's thread shows the widget as you marked it beside the same widget now,
and "Looks right" or "Not yet" moves on to the next (DESIGN D16). Above those, the frames new
or changed since the round you opened before are listed and marked on the board (DESIGN D17);
`serve` keeps each reviewer's last visit in `.galley/visits.json`. The canvas is a build
attached to the release, fetched once
into a cache outside the app (`GALLEY_CACHE`, else the user cache directory) and checked
against the hash this release pins before it is unpacked (DESIGN D14). With no network on the
first start, `serve` says there is no canvas and serves the API. `--web <dir>` serves another
build.

The canvas draws with WebGL. Headless Chrome, as a script checking it runs, has none unless it
is started with `--enable-unsafe-swiftshader` (software WebGL); without it the page stays
blank.

### A galley on a server

For reviewers who are not at the owner's machine, a galley lives on a Galley server (DESIGN
D15). `galley host` runs one on this machine, writing sign-in codes to a directory rather than
mailing them, and serves the canvas at its root (the pinned release's, or `--web <dir>`).
`galley bundle <dir>` writes the same server out for a Linux host, set by its environment, with
its codes mailed through your relay: [docs/HOSTING.md](docs/HOSTING.md) hosts it on Fly.io.

```sh
dart run galley_cli:galley login <url> --email you@example.com   # asks for the mailed code
dart run galley_cli:galley link <url> --create 'My app' --alias Sam
dart run galley_cli:galley push                    # renders a round and pushes it
dart run galley_cli:galley invite reviewer@example.com
dart run galley_cli:galley members                 # or: revoke <alias> [--restore]
```

`link` and `invite` print the galley's canvas, `<url>/?galley=<id>`. A reviewer opens it, signs
in with the email they were invited by and the code mailed to it, and says the alias to sign
their marks with; the browser keeps the sign-in. One who would rather use the CLI runs `login`,
then `link <url> --galley <id> --alias <name>`. While `.galley/` is linked, `mark`, `pull`,
`answer`, `verify`, `reopen` and `withdraw` act on the server as your alias there: `--by` is
refused and `GALLEY_BY` ignored. `pack` and `serve` are refused, and `serve` names the canvas
on the server. A push that stops keeps its render in `.galley/push/`, and
`galley push --resume` sends it. `.galley/server.json` names only the server and galley; the
sign-in is kept in the user cache, readable by you alone. `galley unlink` goes back to the
local galley, whose marks are not imported.

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
- [docs/HOSTING.md](docs/HOSTING.md): hosting a Galley server for reviewers, on Fly.io.
- [docs/RELEASING.md](docs/RELEASING.md): cutting a release, and building and pinning the canvas.
- [llms.txt](llms.txt): the same, for an agent.

## Developing

Flutter 3.50.0 (`.fvmrc`). The packages are a pub workspace.

```sh
flutter pub get
dart format -l 100 packages
(cd packages/galley_core && dart analyze && dart test)
(cd packages/galley && flutter analyze && flutter test)
(cd packages/galley_cli && dart analyze && dart test)
(cd packages/galley_web && flutter analyze && flutter test)
```

## License

MIT. See [LICENSE](LICENSE).
