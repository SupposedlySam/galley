# Changelog

All notable changes to this package. It follows [semantic versioning](https://semver.org): before
1.0, a minor version is a breaking change, and every other release, new features included, is a
patch (DESIGN D8).

## 0.3.10 (unreleased)

- `galley pull --json` gives each mark's `raised_in`, the round it was raised on, beside
  `round`, where it was last placed. On this machine it is the first round whose placements
  record the mark as raised; a mark no round records is `null`.

The reviewer's side of the canvas (ROADMAP step 7):
- What waits on you: above every mark, the marks you raised that were answered, the one
  answered longest ago first, each with its answer. Saying "Looks right" or "Not yet" on one
  opens the next; the last opens the list.
- An answered mark's thread shows the widget as you marked it, cropped from the frame of the
  round it was raised on, beside the same widget in the round shown. Each round is read once.
  What cannot be shown is said: the round raised on is not recorded, the frame is not in it,
  or no image was captured.
- Verify and reopen read "Looks right" and "Not yet".

## 0.3.9 (unreleased)

A Galley server on this machine (DESIGN D15):
- `galley host` runs PocketBase 0.40.6 with `galley_server`'s schema and hooks, on loopback.
  PocketBase is pinned by each platform's archive SHA-256 (`PinnedPocketBase`) and fetched once
  into the galley cache, like the canvas. The validator the hooks call is compiled from the
  source this CLI resolved, into the cache, keyed by a hash of that source and of the Dart that
  compiled it. Its data is kept under `galley/host` in the platform's user data directory
  (`dataDirectory`), or `--data`, readable by its owner only. Sign-in codes are written to its
  `otp` directory, not mailed. `--owner <email>` makes the user who makes a galley.
- `LocalServer` is that server, for tests and tools: `start`, `ensureUser`, `close`.
- The canvas cache is now a cache of any pinned archive: `ArchiveCache` and `PinnedArchive`.
  `CanvasCache` is a thin adapter over it. Zips are read by `readZip`, which unpacks files and
  directories only, and keeps the owner execute bit.
- The server's rules are tested here, through `LocalServer`: one galley's members never see or
  write another's, an invite lets its invitee in once as a reviewer, a revoked reviewer loses
  access and keeps their membership, nothing is deleted, every write is judged (a manifest past
  128 KiB included), and sign-in attempts are rate limited. A round takes only the files its
  manifest lists, at their sizes, once, and finishes only with every file and every earlier
  mark placed; a reviewer sees it only then. A mark is raised by a member, as themselves, on the
  newest finished round. Only the owner answers, the server numbers events, and five verifies
  sent at once land once. The first run fetches PocketBase.
- The superuser's password is passed after `--`, so one that starts with `-` (1 in 32 of them)
  is not read as a flag.
- `galley_server`'s `ServerGalley` is tested against that server: a reviewer signed in by a
  code reads a pushed round and its image, raises a mark, is refused a verify before an answer,
  and verifies once the owner has answered; the next round carries the mark, and its history is
  the owner's answer and the reviewer's verify.

A galley on a server (DESIGN D15, "The commands follow the galley"):
- `galley login <url> --email <you>` signs in by the code the server mails (or `galley host`
  writes). The session is kept in the user cache, one file per server, readable by the user
  alone, never in `.galley/`.
- `galley link <url> --create <name> --alias <you>` makes a galley you own; `--galley <id>`
  links one you are a member of, or joins one you are invited to (with `--alias`). The link is
  `.galley/server.json`, which names the server and galley only. `galley unlink` removes it.
- While linked, `mark`, `pull`, `answer`, `verify`, `reopen` and `withdraw` act on the server
  as your alias there. `--by` is refused and `GALLEY_BY` ignored. `pack` and `serve` are
  refused: `galley push` renders a round and pushes it, and `serve` names the galley's canvas
  on the server. One invited and not yet joined, with a link from a teammate's checkout, is
  told how to join.
- `galley push` renders into `.galley/push/` and pushes it. A push that stops keeps the render,
  and `galley push --resume` sends it without rendering again.
- `galley invite <email>`, `galley members` and `galley revoke <alias> [--restore]`.
- `package:http` is now a dependency.

The canvas on a server (DESIGN D15, "The canvas is served by the server"):
- `galley host` serves the canvas at its root, from the same origin as the API: the pinned
  release's, from the cache, or `--web <dir>`. Without one it says why and serves the API.
- `galley link` and `galley invite` print the galley's canvas, `<server>/?galley=<id>`.
- The canvas (galley_web) at that address signs a reviewer in by the code the server mails,
  joins an invited one under the alias they give, and opens the galley as them, their alias
  shown and fixed, with a way to sign out. A revoked reviewer, or someone neither a member nor
  invited, is told so. The sign-in is kept in the browser's `localStorage` and renewed on each
  visit; a renewal the server refuses is said, and the kept sign-in is not cleared.
- Two starts of `galley host` at once, in one process or two, each compile the validator in a
  directory of their own; a name made of the pid alone was shared, and one start failed.

## 0.3.8

The canvas, served:
- `galley serve` serves the canvas at `/` with no `--web`: the build attached to the release
  `pinnedCanvas` names, fetched once into `$GALLEY_CACHE` (else the platform's user cache
  directory, under `galley/`), checked against its SHA-256 before anything is unpacked, and
  unpacked whole or not at all (DESIGN D14). After that it starts with no network. When there
  is no canvas, the API is still served, and `serve` says why at start and at `/`. `--web
  <dir>` serves another build.
- The archive is read by `readTarGz`: ustar, with pax headers for long names, of files and
  directories only. A link, a device, or a path that would leave its directory is refused.
- `GalleyServer.start` takes a `CanvasSource` in place of `web`. `placementName` is now
  `Placement.name`, in `galley_core`.
- A round's placements naming a mark that is not there is refused naming both files: the
  placements, and the mark's file to put back.
- `POST /api/marks` with `at` given as a pin's `{"dx", "dy"}` is 400, saying to give `[x, y]`.
- A new dependency, `crypto`, for the SHA-256.

## 0.3.7

From the first app to call `galley serve`, and for the canvas:
- `galley withdraw <mark> --note --by`, and `POST /api/marks/<id>/events` with
  `{"event": "withdrawn"}`: the supported way to take back a test mark or a duplicate, in
  place of deleting its file. Only whoever raised the mark may.
- A galley that does not hold together (a placement naming a deleted mark, a mark or record
  that does not read) is `Refused.damaged`, naming the file: 500 from the server, not a 400
  that blames the request, and refused when `galley serve` starts. `Refused` and
  `RefusalKind` moved to `refused.dart`, still exported.
- `POST /api/marks` takes `node` and `at` together: that widget, pinned where it was clicked.
  A point outside it is 422. `AtNode` has an optional `at`.
- A refused event says the core's reason, which for a withdrawal by someone else names who
  raised the mark.

## 0.3.6

Fixes from the first app to call `galley serve`:
- A refusal says what kind it is, and the server answers it as such: 422 for a well-formed
  request that cannot be (a blank note, a frame the round lacks, a commit that is not one),
  404 for a mark that is not there, and 409 only for an event the mark's status does not allow.
  0.3.5 answered all of them 409. `Refused` now has four constructors, one per `RefusalKind`.
- `POST /api/marks` takes the frame as its key string, the form a mark's JSON carries, as well
  as an object of axes.
- The server answers on `::1` as well as `127.0.0.1`, at the same port.

## 0.3.5

- `galley serve`: the galley over HTTP on loopback, for the canvas (DESIGN D13). It serves the
  rounds' files, every mark as a work item, a new mark, and an event on a mark, all through the
  same `LocalGalley` as the commands. A request whose Host is not loopback is refused, as is a
  POST that is not JSON. Event times are the server's, and a fix's commit is stored in full.
- `GalleyServer` is public, and `LocalGalley.workItems` takes `imageAt` to name an image.
- `LocalGalley` takes the app's `repository`, and `fullCommit` is the check `answer fixed`
  makes.

## 0.3.4

Fixes from the first app to run `pack`:

- `galley pack -- <args>` passes the args to `flutter test`, so a galley test skipped by its
  tag runs with `-- --run-skipped`. Before, `pack` could not run it at all.
- A `--flutter` that is not an executable (`"fvm flutter"`) is refused with exit 1 and says to
  give one executable, instead of crashing with exit 255.
- A refused event says the verb: "cannot be answered now", not "cannot be answer now".
- `pull --json` image paths are normalized: no `/./` when `--app` is `.`.
- `LocalGalley`, the service under the commands (raise, record, work items), is public, for
  `galley serve` to share. A blank note given to `mark` is now refused with exit 1, as the
  service refuses it, not 64.

## 0.3.3

- First release. The `galley` command keeps a galley in `.galley/` (DESIGN D12): `pack` runs
  the app's galley test into a new round and carries every mark into it; `mark` pins a note to
  a widget of the latest round; `pull` (and `pull --json`) lists the open marks and where each
  one is now; `answer` (fixed with a commit, wont-fix or question), `verify` and `reopen`
  append to a mark's history, which is never rewritten.
