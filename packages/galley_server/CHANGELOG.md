# Changelog

All notable changes to this package. It follows [semantic versioning](https://semver.org): before
1.0, a minor version is a breaking change, and every other release, new features included, is a
patch (DESIGN D8).

## 0.3.9 (unreleased)

The first release of the package (DESIGN D15):
- `judge`, over `galley_core`: whether a write to a Galley server may say what it says. A mark
  on the newest finished round, an event its mark's history allows, the next round, a file its
  manifest lists, a finish that places every earlier mark, and a member's alias.
- `galley_validate`, the judge as a program for PocketBase's hooks. It takes the path of a file
  holding the request, since Linux caps one argument at 128 KiB, and always exits 0 with
  `{"ok": true}` or `{"refused": "<why>"}`.
- `lib/pocketbase`: the schema (`pb_migrations`) and hooks (`pb_hooks`). They are written for
  PocketBase 0.40.6, and `galley host` runs them. Nothing is deleted, every write is judged in
  a transaction of its own, and sign-in is by a code mailed to an invited email.
