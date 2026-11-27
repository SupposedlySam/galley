import 'package:galley_core/galley_core.dart';

import 'trees.dart';

// Builders for a round's frames and marks, shared by the carry and storage tests.

const buyRect = LogicalRect(10, 10, 100, 40);

FrameRecord frameRecord(
  FrameKey key, {
  FrameStatus status = FrameStatus.rendered,
  List<String> errors = const [],
  String? tree = 'trees/x.json',
}) => FrameRecord(
  key: key,
  scenario: 'base',
  uri: Uri.parse('/${key.values['screen']}'),
  landing: LandedAt(Uri.parse('/${key.values['screen']}')),
  status: status,
  device: DeviceProfile.pixel7,
  essential: true,
  errors: errors,
  tree: tree,
);

/// A tree with one keyed button at [rect].
FrameTree withBuy(LogicalRect rect, {String key = 'buy'}) => tree([
  root,
  node([0], 'FilledButton', rect: rect, key: key),
]);

Mark markOn(String id, FrameKey frame, {List<MarkEvent> history = const []}) => Mark(
  id: id,
  frame: frame,
  anchor: Anchor.of(withBuy(buyRect).nodes[1]),
  pin: const PinOffset(0.5, 0.5),
  note: 'too tight',
  by: 'reviewer',
  at: DateTime.utc(2026, 11, 26),
  history: history,
);
