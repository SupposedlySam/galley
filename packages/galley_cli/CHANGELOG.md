# Changelog

All notable changes to this package. It follows [semantic versioning](https://semver.org): before
1.0, a minor version is a breaking change, and every other release, new features included, is a
patch (DESIGN D8).

## 0.3.3

- First release. The `galley` command keeps a galley in `.galley/` (DESIGN D12): `pack` runs
  the app's galley test into a new round and carries every mark into it; `mark` pins a note to
  a widget of the latest round; `pull` (and `pull --json`) lists the open marks and where each
  one is now; `answer` (fixed with a commit, wont-fix or question), `verify` and `reopen`
  append to a mark's history, which is never rewritten.
