# galley_cli

The `galley` command. It keeps a galley (rounds of an app's frames, and the marks pinned to
them) in a directory, `.galley/` in the app's root by default (DESIGN D12). Pure Dart: it runs
the app's galley test with `flutter test` and reads what it wrote, and never imports Flutter.

```sh
dart run galley_cli:galley pack [--test test/galley_test.dart] [--flutter flutter]
dart run galley_cli:galley mark --frame '<key>' (--node 0.2 | --at x,y) --note '...' [--by me]
dart run galley_cli:galley pull [--json] [--all]
dart run galley_cli:galley answer <mark> fixed --commit <sha> [--note '...'] [--by me]
dart run galley_cli:galley answer <mark> wont-fix|question --note '...' [--by me]
dart run galley_cli:galley verify <mark> [--by me]
dart run galley_cli:galley reopen <mark> --note '...' [--by me]
dart run galley_cli:galley withdraw <mark> --note '...' [--by me]
dart run galley_cli:galley serve [--port 7340] [--web <dir>]
```

Global options: `--app` (the app's root, default `.`) and `--galley` (default `<app>/.galley`).
`--by` defaults to `GALLEY_BY`. Exit codes: 0 done, 1 refused (with the reason on stderr),
64 a usage error.

Keep `.galley/` out of git (or commit it). An untracked galley makes every later round look as
if the app's tree had uncommitted changes (DESIGN D11).

`serve` serves the galley over HTTP on loopback until Ctrl-C (DESIGN D13): `GET /api/galley`,
`GET /api/marks` (what `pull --json --all` lists, with each image as a URL), `GET
/api/rounds/<n>/<file>`, `POST /api/marks` and `POST /api/marks/<id>/events`. A POST is
`application/json`, and a request whose Host is not loopback is refused. A frame is its key or
its axes, and the widget is its `node`, a point `at`, or both. A malformed request is 400, a
well-formed one that cannot be 422, a mark that is not there 404, an event its mark does not
allow 409, and a galley whose own files do not read 500, naming the file (`serve` checks at
start too).

At `/` it serves the canvas: the build attached to the release `pinnedCanvas` names, fetched
on the first start into `$GALLEY_CACHE` (else the platform's user cache directory, under
`galley/`), checked against its SHA-256 before anything is unpacked, and unpacked whole or not
at all (DESIGN D14). Later starts need no network. When there is no canvas, `serve` says why
and serves the API; `/` answers 404 with the same reason. `--web <dir>` serves a built canvas
in its place.

`pull --json` is for an agent working through the marks:

```json
{"latest_round": 2, "items": [{"id": "m3f…", "status": "open", "round": 2, "raised_in": 1,
  "placement": "moved", "where": {…}, "anchor": {…}, "image": "/abs/path/frames/….png", "mark": {…}}]}
```
