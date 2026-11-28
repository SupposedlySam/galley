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
  "placement": "moved", "where": {…}, "anchor": {…}, "image": "/abs/path/frames/….png", "mark": {…}}],
  "damaged": []}
```

`damaged` lists, by id and why, the marks a galley on a server holds and cannot read (a row
edited by hand, or written by someone who is not a member). They are not work items, and
nothing can answer them until the server's superuser mends them; while one is listed,
`galley push` is refused. On this machine it is always empty: a local galley that does not
read is refused whole (DESIGN D12).

A galley can live on a Galley server instead (DESIGN D15). Its commands:

```sh
dart run galley_cli:galley host [--port 8090] [--data <dir>] [--owner you@example.com] [--web <dir>]
dart run galley_cli:galley bundle <dir> [--platform linux_amd64|linux_arm64] [--web <dir>]
dart run galley_cli:galley login <url> --email you@example.com
dart run galley_cli:galley link <url> (--create '<name>' | --galley <id>) [--alias <name>]
dart run galley_cli:galley push [--resume]
dart run galley_cli:galley invite <email>
dart run galley_cli:galley members
dart run galley_cli:galley revoke <alias> [--restore]
dart run galley_cli:galley unlink
```

`host` runs one on this machine, and writes each sign-in code to a file instead of mailing it.
`bundle` writes the same server to `<dir>` for a host elsewhere: PocketBase, the validator
compiled for that platform, the schema and hooks, the canvas, and a `run` and `Dockerfile`.
The server's settings are its environment's (`GALLEY_URL`, `GALLEY_SMTP_*`, `GALLEY_MAIL_*`,
`GALLEY_PROXY_HEADER`, `GALLEY_OWNERS`), applied on every start (DESIGN D18).
[docs/HOSTING.md](../../docs/HOSTING.md) hosts it on Fly.io.
