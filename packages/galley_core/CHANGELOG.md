# Changelog

All notable changes to this package. It follows [semantic versioning](https://semver.org): before
1.0, a minor version is a breaking change, and every other release, new features included, is a
patch (DESIGN D8).

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
