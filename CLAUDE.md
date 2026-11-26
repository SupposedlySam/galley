# Galley

Galley is a design-review canvas for Flutter apps. Every screen × state × device of an app is
rendered as a frame. Reviewers pin marks to widgets, Claude answers them, and the reviewers
verify the answers. Rounds stack, and nothing is erased.

## Read first
- [README.md](README.md): what exists today and how an app adopts it.
- [docs/DESIGN.md](docs/DESIGN.md): the principles, the decisions, and what each one rejected.
- [docs/BOUNDARY.md](docs/BOUNDARY.md): what we assume about Flutter, with citations.
- [docs/ROADMAP.md](docs/ROADMAP.md): the steps to the first reviewed round, in order.
- [docs/READINGS.md](docs/READINGS.md): when each doc was last read whole. Update it when you
  read one.

## Rules
- **SOLID, behind small interfaces.** The app's only code is a `GalleyHost` (DESIGN D2′).
  Galley never imports an app.
- **Respect the package boundaries in DESIGN D1.** `galley_core` is pure Dart. Logic that two
  layers need lives there, once.
- **Follow the principles in DESIGN.md**: an unknown is never nothing, nothing is erased, no
  real backends in a frame.
- **Assert on the population, not just the absence**, and mutate the code to prove a test is
  load-bearing. Carry-forward and re-anchoring are tested to that bar.
- **Keep the reasoning next to the code:** what was observed, and why the obvious alternative
  was rejected.
- **This repo stands alone.** No names of other projects, people or machines in tracked files.
  Context about a particular adopting app goes in `CLAUDE.local.md`, which is not committed.
- **Versioning** follows DESIGN D8: one semantic version for both packages, a `CHANGELOG.md`
  entry per package for every release, and a `v<version>` tag.

## Checks
```sh
dart format -l 100 packages
(cd packages/galley_core && dart analyze && dart test)
(cd packages/galley && flutter analyze && flutter test)
```
