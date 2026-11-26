# Changelog

All notable changes to this package. It follows [semantic versioning](https://semver.org): before
1.0, a minor version may break the API and a patch never does.

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
