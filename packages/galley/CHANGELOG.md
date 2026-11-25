# Changelog

All notable changes to this package. It follows [semantic versioning](https://semver.org): before
1.0, a minor version may break the API and a patch never does.

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
