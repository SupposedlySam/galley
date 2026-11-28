# Changelog

All notable changes to this package. It follows [semantic versioning](https://semver.org): before
1.0, a minor version is a breaking change, and every other release, new features included, is a
patch (DESIGN D8).

## 0.3.12

- `GalleyHost.screenNames`: what reviewers call the app's screens, by the uri a scenario lists,
  such as `{Uri.parse('/bloom'): 'The Batch'}`. The packer records each in its frames'
  `screen_name`; frame keys do not change. A uri no scenario lists, or a blank name, refuses
  the round, naming the uri. `GalleyFrame.screenName` carries it to `mount`.

## 0.3.11

- No changes. Released with `galley_cli` 0.3.11 (DESIGN D8).

## 0.3.10

- The packer records each frame's `pixels`, a SHA-256 of its width, height and RGBA bytes, from
  the render it checked twice (`FramePixels.digest`), so a later round can say which frames
  changed (DESIGN D17). It depends on `crypto`. The round's files are otherwise the same.

## 0.3.9

- A widget's source location is recorded as a path inside the app's package
  (`lib/screens/home.dart`), not the absolute `file://` URI the compiler records. A round no
  longer carries the machine's paths to its reviewers, and two checkouts of an app record the
  same location (DESIGN D6). `pull --json` lists it the same way: relative to the app's root.

## 0.3.8

- No changes. Released with `galley_core` and `galley_cli` 0.3.8, and the canvas (DESIGN D8).

## 0.3.7

- No changes. Released with `galley_core` and `galley_cli` 0.3.7 (DESIGN D8).

## 0.3.6

- No changes. Released with `galley_cli` 0.3.6 (DESIGN D8).

## 0.3.5

- No changes. Released with `galley_cli` 0.3.5 (DESIGN D8).

## 0.3.4

- No changes. Released with `galley_cli` 0.3.4 (DESIGN D8).

## 0.3.3

- No change to the renderer. Released with `galley_cli` 0.3.3, which runs this package's galley
  test to pack a round (DESIGN D12).

## 0.3.2

- The round now has a `round.json`: the commit the app was rendered from, whether its tree had
  uncommitted changes, the Flutter version and the time. Outside git, the commit and tree state
  are written as unknown with git's reason, and the round still packs.

## 0.3.1

- The round's `index.json` is written through galley_core's `RoundManifest`. Its content is
  unchanged.

## 0.3.0

- New finding, `broken-word-unseen`: a word broken across lines in text that was laid out but is
  not in the picture, such as a lazy list's rows below the fold or text under a clip. Those
  breaks were reported as `broken-word` before, so a card could list a word its frame did not
  show. A frame's `broken-word` count can therefore fall, and `broken-word-unseen` is new.

## 0.2.1

- Fix: `broken-word` found no breaks in a face whose glyph boxes are taller than its line, which
  is common for display faces at a large text scale. Galley now places the two carets at each
  offset, one on each side of a possible break, and compares their x. Text that is centered,
  right-aligned or right-to-left, and lines that mix font sizes, are tested.

## 0.2.0

- New finding, `broken-word`: a line break that falls inside a word, such as a label too wide
  for a small phone at a large text scale. It lists the words with `|` where they broke. A
  round that had no findings may now have some; nothing that passed now fails.
- The README shows how to keep a round out of a plain `flutter test` with a tag.

## 0.1.3

- A round ends with one line saying how many frames rendered and where they went. Without
  `GALLEY_OUT` the line says nothing was written and how to keep the round. Before, such a run
  passed with no files and no word about why.
- `GalleyHost.mount` says that a test of the app's own, pumping one mounted app after another,
  needs a new key above each, as Galley uses.

## 0.1.2

- Fixed: a `mount` that awaited real work (a file write, a database a fake opens) hung the
  run with no output. `mount` now runs on the real clock, in `tester.runAsync`.
- A mount that does not finish within 30 s of real time is an error card naming the frame,
  not a stalled run. `FrameRenderer.mountBudget` sets the budget.

## 0.1.1

- Licensed under the MIT License.

## 0.1.0

First release: the renderer.

- `GalleyHost`, `GalleyScenario` and `GalleyFrame`: an app's whole integration.
- `GalleyAxes`: devices, text scales, brightness, platforms and locales, applied through
  Flutter's test hooks and reset after every frame.
- `galley(host)`: one test per planned frame, each rendered twice. A difference is an error
  that names the widget that changed. With `GALLEY_OUT`, writes `index.json` and a PNG, tree
  and record per frame.
- The landing is read from the app's `Router` and checked against the frame's uri.
- The app's fonts and Roboto are loaded, network images are drawn as placeholders, and
  animations that never settle are frozen after 10 s. Each workaround is a finding on the frame,
  as are pixels the app never paints.
