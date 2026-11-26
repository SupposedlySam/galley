# Changelog

All notable changes to this package. It follows [semantic versioning](https://semver.org): before
1.0, a minor version may break the API and a patch never does.

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
