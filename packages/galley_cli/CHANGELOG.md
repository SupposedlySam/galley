# Changelog

All notable changes to this package. It follows [semantic versioning](https://semver.org): before
1.0, a minor version is a breaking change, and every other release, new features included, is a
patch (DESIGN D8).

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
