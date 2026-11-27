# Changelog

All notable changes to this package. It follows [semantic versioning](https://semver.org): before
1.0, a minor version is a breaking change, and every other release, new features included, is a
patch (DESIGN D8).

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
