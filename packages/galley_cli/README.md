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
```

Global options: `--app` (the app's root, default `.`) and `--galley` (default `<app>/.galley`).
`--by` defaults to `GALLEY_BY`. Exit codes: 0 done, 1 refused (with the reason on stderr),
64 a usage error.

Keep `.galley/` out of git (or commit it). An untracked galley makes every later round look as
if the app's tree had uncommitted changes (DESIGN D11).

`pull --json` is for an agent working through the marks:

```json
{"latest_round": 2, "items": [{"id": "m3f…", "status": "open", "round": 2, "placement": "moved",
  "where": {…}, "anchor": {…}, "image": "/abs/path/frames/….png", "mark": {…}}]}
```
