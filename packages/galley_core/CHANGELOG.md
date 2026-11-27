# Changelog

All notable changes to this package. It follows [semantic versioning](https://semver.org): before
1.0, a minor version is a breaking change, and every other release, new features included, is a
patch (DESIGN D8).

## 0.3.10 (unreleased)

What changed since a reviewer's last visit (DESIGN D17):
- `FrameRecord.pixels`: the SHA-256, in lower-case hex, of the frame's pixels, set by the
  packer. Optional, and refused without an `image`; rounds packed before 0.3.10 have none.
- `changesSince(since, shown, sinceN:, shownN:)`: every frame of a round as it compares with an
  earlier one, as `FrameAdded`, `FrameChanged`, `FrameSame`, `FrameGone` or `FrameUncompared`
  (with why: no digest, or no image).
- `Visit` and `visitTo`: a reviewer's last round opened and the one before it, which a reload
  does not move. `Galley.opened(n, by:)` records a visit and returns the round opened before.
  Not breaking under D8: an app's host does not implement or call `Galley`.

- `PlacedMark.raisedIn`: the round the mark was raised on, beside the round it was last placed
  in. Null when no galley records it: a hand-written mark, or work items written before
  0.3.10. Work items carry it as `raised_in`, read back as null when absent.
- `Galley.marks` returns `GalleyMarks`, not a list: the marks `placed`, and those `damaged`
  (`DamagedMark`, an id and why), so one mark that does not read no longer refuses every
  other one (DESIGN D15). `GalleyMarks.whole` is the placed marks, refused while any is
  damaged, for a writer that must carry every mark. `workItems` returns `WorkItems`, whose
  JSON is `{latest_round, items, damaged}`; `GalleyMarks.fromJson` reads it back and requires
  `damaged`. Not breaking under D8: an app's host does not implement or call `Galley`.

## 0.3.9 (unreleased)

- `raiseTarget`: the widget a new mark pins in a round's frame, and where on it, or the refusal
  of the mark (no such frame, no tree, a miss, a blank note, nobody raising it). Every
  `Galley.raise` asks it before writing, so a mark raised on this machine and one raised on a
  server are refused for the same reasons, in the same words. `LocalGalley.raise` now does.
- `SourceLocation.sameFile` and `sameSite`. The location matchers use them, so a mark raised on
  a round that recorded absolute `file://` locations is still carried by its location into a
  round that records them inside the package (DESIGN D6).

## 0.3.8

For the canvas, which reads rounds and marks through these rather than working them out again
(DESIGN D1):
- `FrameTree.allAt(x, y)`: every widget whose box holds the point, deepest first, and among
  equal depths the one painted last. `deepestAt` is its first.
- `Placement.name`: the word a person reads for a placement (raised, exact, moved, lost,
  unplaced, retired), so the commands and the canvas say the same word.
- `Carried.box` and `Carried.pin`: the widget's box in the placement's round, and where the pin
  is in it. Null when the mark is on no widget there (lost, unplaced, retired).
- `MarkStatus.isFinal`: verified or withdrawn.
- `JsonReader.optionalInteger`.

## 0.3.7

- `Withdrawn`: whoever raised a mark takes it back, saying why. `MarkStatus.withdrawn` is
  final, and the mark keeps its history and is carried like any other (DESIGN D6). Withdrawn by
  anyone else is refused, when written and when read.
- `MarkEvent.apply` takes the mark's `raisedBy`, and every event has a `verb` and a `refusal`
  saying why it is not allowed. `Mark.record` throws a `StateError` with that reason.

## 0.3.6

- No changes. Released with `galley_cli` 0.3.6 (DESIGN D8).

## 0.3.5

- No changes. Released with `galley_cli` 0.3.5 (DESIGN D8).

## 0.3.4

- No changes. Released with `galley_cli` 0.3.4 (DESIGN D8).

## 0.3.3

- New: `StoredRound.read(RoundFiles)` reads a round as stored: its provenance (Unrecorded for a
  round packed before 0.3.2), its index, its records and their trees. A missing tree leaves
  its frame treeless, so its marks are Unplaced; a missing record or a malformed file is
  refused.
- New: `Placements`, where every mark is in one round, at most once each, as JSON.
- New: `Round.frame(key)`.

## 0.3.2

- New: `RoundProvenance`, a round's `round.json`: the commit, whether the tree was dirty, the
  Flutter version and the time. Each fact is `Known` or `Unrecorded` with a reason, never blank.
- New: `Placement` and `Carried` read and write JSON. A carried mark is stored by its id.
- New: `isCommitSha`, the rule marks and rounds share for a commit.

## 0.3.1

- New: carrying marks into a round (`Round`, `RoundFrame`, `Carried`, `Placement`). Every mark
  gets one placement per round: Raised; Reanchored, with an Exact, Moved or Lost result;
  Unplaced, when its frame errored or has no tree; or Retired, when its frame is gone. The next
  round looks for the widget where it was last found, and the mark keeps its anchor as raised.
- New: `RoundManifest`, the `index.json` a round is listed by. It reads every index the packer
  has written since 0.1.0.

## 0.3.0

- No changes. Released with galley 0.3.0.

## 0.2.1

- No changes. Released with galley 0.2.1.

## 0.2.0

- No changes. Released with `galley` 0.2.0, which shares its version (DESIGN D8).

## 0.1.3

- No changes. Released with `galley` 0.1.3, which shares its version (DESIGN D8).

## 0.1.2

- No changes. Released with `galley` 0.1.2, which shares its version (DESIGN D8).

## 0.1.1

- Licensed under the MIT License.

## 0.1.0

First release.

- `FrameKey`, `FrameAxis`, `FrameTree`, `WidgetNode`, `SourceLocation` and logical geometry,
  with JSON codecs that refuse malformed input instead of defaulting.
- `FrameTree.deepestContaining`, the deepest widget holding a region.
- `Anchor` and `Reanchorer`: matchers that narrow by key, semantics label, exact location,
  file + type, then index path + type. The result is Exact (IoU ≥ 0.9), Moved, or Lost with
  its candidates.
- `Mark` with an append-only event log; illegal sequences are refused on write and on read.
- `FramePlanner`: the essential set plus deterministic pairwise cover, with the subject as a
  factor.
- `DeviceProfile` presets (`pixel7`, `smallPhone`) with insets and their provenance.
- `FrameRecord`, `FrameStatus`, `Landing` (`LandedAt`, `LandingUnknown`) and `Finding`.
