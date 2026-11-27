# galley_web

The canvas: the latest round of a galley on one board, and the marks pinned to it. It is a
Flutter web app, served by `galley serve` from the same origin as the galley's API, and it
sees the galley only through that API (`lib/src/api.dart`), so a different backend changes
nothing else here.

- **The board.** Rows are flows (the first segment of a screen's path) and columns are states
  (one screen in one scenario). Each frame sits in its device's outline, at one frame pixel to
  one board pixel at 100%, with pan and zoom. It opens fitted to the window. Below 40% a frame
  is drawn as a thumbnail with a badge counting the marks that wait on someone.
- **Marking.** A click on a frame offers every widget of the frame's tree under the point,
  deepest first, and raises a mark on the one chosen, pinned where it was clicked.
- **Threads.** Every mark is listed beside the board, including those the board cannot draw,
  each with the reason. A mark's thread shows its history, and offers what the reviewer may
  do next: verify or reopen an answer, and withdraw a mark they raised.
- **Who is reviewing** is the name in the panel, or `?by=<name>` in the address.

It loads nothing from outside the machine that serves it: CanvasKit and Roboto are in the
build, and the engine's font fallback points at the canvas's own server (`web/
flutter_bootstrap.js`). A glyph no bundled font has, an emoji for one, is drawn as a box.

## How it reaches an app

It is not a package an app depends on. Each release that changes it attaches its build to the
release, `galley_web-<version>.tar.gz`. `galley_cli` pins that archive's SHA-256, and `galley
serve` fetches it once into a cache outside the app and checks it before unpacking (DESIGN
D14). [docs/RELEASING.md](../../docs/RELEASING.md) says how it is built and pinned.

## Working on it

```sh
flutter build web --release --no-web-resources-cdn --no-wasm-dry-run
dart run galley_cli:galley serve --web <this package>/build/web   # from the app's root
flutter test
```

`--web` serves this build in place of the pinned one.
