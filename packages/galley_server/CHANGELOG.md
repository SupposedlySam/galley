# Changelog

All notable changes to this package. It follows [semantic versioning](https://semver.org): before
1.0, a minor version is a breaking change, and every other release, new features included, is a
patch (DESIGN D8).

## 0.3.9

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
- `ServerGalley`, the `Galley` of a galley on a server: its finished rounds, each file checked
  against its manifest's SHA-256 (a mismatch is refused as damaged, naming the file), a file's
  URL for the canvas, every mark where it was last placed with its history, and raising and
  recording as the signed-in member, refused before anything is sent for what the core refuses.
  Lists are scoped to the galley, since the server's rules check membership, and a member of
  two galleys can read both.
- `PocketBase`, the REST client it speaks through: every page of a list, a 429 waited out and
  sent again, and every refusal in PocketBase's words as the `Refused` kind its status names.
  An answer that is not JSON, or no answer, is refused, never read as nothing.
- `SignIn`: a code requested for an email, and the `Session` it signs in.
- `Member`, `MemberRole`, `GalleyMembers` and `ServerAccount`: a galley made with its owner's
  membership in one batch, an invite, a join by it under an alias, the user's memberships and
  open invites, and a reviewer revoked or restored by the owner.
- `RoundPush`: a rendered round pushed as its owner. Created with its manifest, its files
  uploaded eight at a time (each checked against its SHA-256 before it is sent), every mark
  carried, and finished with those placements, tried again when a mark was raised under it. An
  unfinished round an earlier push left is finished by a push of the same files, uploading only
  what is missing; a push of other files is refused while it stands, naming it.
- `ServerGalley` tells a revoked member their access was revoked, and a non-member that they
  are not one, rather than showing either an empty galley.
- `ServerAccount.standingIn`: where the signed-in user stands in a galley, as a `Standing`:
  `Joined`, `RevokedFrom`, `InvitedTo` or `Outside`.
- `canvasLink`, `galleyOf` and `serverOf`: a galley's canvas on a server is
  `<server>/?galley=<id>`, said once for the CLI that prints it and the canvas that reads it.
- The package builds for the web: the canvas signs in and reads a galley through it.
