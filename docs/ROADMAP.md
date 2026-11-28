# Roadmap: to the first reviewed round

**Done means:** outside reviewers have marked a real round. The marks were answered, and the
next round was pushed. Every open mark was carried forward as Exact, Moved or Lost. The
reviewers then verified or reopened each answer, and nothing was erased.

Each step below ends in a release that an adopting app can run against its own round. A step
is done when that check passes on a real app, not only on this repo's fixtures. Every release
is a patch unless it breaks a host (DESIGN D8).

| # | Release | What lands | How an app checks it |
|---|---|---|---|
| 1 | 0.3.1 ✅ | galley_core carries marks into a round: Raised, Reanchored (Exact, Moved, Lost), Unplaced, Retired (DESIGN D6). `RoundManifest` is `index.json`. | Nothing changes for the app: the same round, the same `index.json`. |
| 2 | 0.3.2 ✅ | **The round records where it came from.** A `round.json` with provenance (commit, dirty tree, Flutter version, time) next to the records (DESIGN D11). A mark's placement in a round (`Carried`) reads and writes JSON, joining the marks, answers and events core already had. Where a galley keeps them on disk lands with the CLI, its first reader. | Run the galley test. `round.json` names the commit you rendered. |
| 3 | ✅ 0.3.3, checked on the adopting app; 0.3.4 fixes the two `pack` gaps it found | **`galley_cli`, local:** `pack` runs the app's galley test into a new round directory (DESIGN D12). `pull --json` lists open marks as work items. `answer <mark> fixed --commit <sha>` (or `wont-fix`, or `question`, with a note) records an answer. There is no server yet: a galley is a directory. | `galley pack` twice gives two rounds. A test mark carries from one into the other, and `pull --json` shows where it landed. |
| 4 | none ✅ PocketBase (DESIGN D7) | **The server spike (D7).** A local instance of each candidate, measured against D7: email-code sign-in, a non-member reads nothing (live streams included), invites, a frame image behind membership, and the upload time of a real-sized round. The result is a decision in DESIGN D7, with the table. | Nothing to run. The decision says what hosting needs, so the owner can take it to whoever pays. |
| 5 | 0.3.5: `galley serve` (DESIGN D13); 0.3.6 and 0.3.7 fixes from the app's first calls (0.3.7: `withdraw`, a damaged galley named, a widget pinned where clicked); 0.3.8: the canvas, fetched and checked by `serve` (DESIGN D14) | **`galley_web`, the canvas, on your own machine.** `galley serve` serves a local galley to the viewer on localhost. Frames sit in device outlines, rows are flows and columns are states, with pan and zoom. Pin-to-widget snaps to the frame's tree, and a mark has a thread. | The app's owner marks their own round in a browser, and `pull --json` lists those marks. |
| 6 | 0.3.9 ✅ | **`galley_server`:** sign-in, galleys, members, invites, rounds, frames, marks, replies, answers, and images behind membership. `galley push` uploads a round and carries every mark into it on the server. The viewer reads from the server. A widget's source location reaches a reviewer relative to the app's root, never as the owner's absolute path. | Push to a local server, sign in by code, mark, `pull --json`, answer, push again: every mark is placed. |
| 7 | 0.3.10 ✅ | **The reviewer's side:** the "what's for me" landing, and the verify queue (old crop, new frame at the anchor, the answer's note, then Looks right or Not yet), and the frames changed since your last visit (D17). | Answer a mark and push. The reviewer sees it in their queue and verifies it. |
| 8 | none | **Hosting**, as decided in step 4, and the first invites. | The Done line above, with real reviewers. |

## Why this order

- **The core first.** The CLI, the server and the viewer all carry marks and read rounds. Doing
  that once, in galley_core, keeps them from disagreeing (DESIGN D1).
- **The CLI before the server.** An answer is a commit plus a note, written by whoever fixed
  the mark. That loop can be built and tested with a galley that is only a directory.
- **The spike before the server, and in parallel with the viewer.** The spike decides hosting,
  and the canvas does not depend on it.
- **The viewer before the server.** The canvas is the bet's largest unknown. Running it first
  against a local galley lets the app's owner judge it before anyone is invited.

## No interim for outside reviewers

Reviewers who are not on the owner's machine need steps 6 to 8. Step 5 gets the owner marking
early, but its store is part of the product, not a prototype: `galley serve` is how a galley
is reviewed offline, and how the viewer is tested.

Rejected: putting the round's PNGs in a shared folder or a hosted static page for comments. Its
comments would not be pinned to widgets, so none of them could be carried into the next round.
Every comment made there would need typing in again.

## Not on this path

The later list in DESIGN D1's packages: overlays, comparing rounds, the MCP server, coverage,
lenses, multiplayer cursors, digest email, dedupe across rounds, other frame sources, and live
frames.
