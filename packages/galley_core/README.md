# galley_core

The shared model of [Galley](https://github.com/SupposedlySam/galley), in pure Dart, so the
renderer, the server, the CLI and the viewer agree on one definition of each:

- `FrameKey`: a frame's identity, the sorted axis values, with no hash in it.
- `FrameTree` and `WidgetNode`: the app's widgets on a frame, with rects, keys, source
  locations and semantics labels.
- `Anchor` and `Reanchorer`: where a mark is pinned, and finding it again in the next round as
  Exact, Moved or Lost, never a guess.
- `Mark`: a mark's status as a fold over its append-only events.
- `FramePlanner`: the essential set plus pairwise cover, deterministic.
- `DeviceProfile`: device presets, each saying whether its numbers are measured or assumed.
- `FrameRecord`: what one rendered frame was, landed and reported.

It depends on nothing but the Dart SDK. Most apps use it through
[`galley`](https://github.com/SupposedlySam/galley/tree/main/packages/galley).
