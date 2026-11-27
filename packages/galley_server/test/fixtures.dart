import 'package:galley_core/galley_core.dart';

/// The frame every fixture mark is on.
final home = FrameKey({'screen': 'home', 'device': 'pixel7'});

/// The anchor every fixture mark is pinned to, as the server stores it.
final anchor = Anchor(
  type: 'FilledButton',
  indexPath: const [0, 1],
  rect: const LogicalRect(10, 20, 100, 40),
).toJson();

/// A mark row as a hook passes it: `by` read through the author's membership, `at` the
/// server's `created`, in PocketBase's own form.
JsonMap markRow(String id, {String by = 'Rae', String frame = ''}) => {
  'id': id,
  'frame': frame.isEmpty ? '$home' : frame,
  'anchor': anchor,
  'pin': {'dx': 0.5, 'dy': 0.25},
  'note': 'make it primary',
  'by': by,
  'at': '2026-11-27 09:30:00.123Z',
};

/// An event row, with PocketBase's "" for every column the event does not use.
JsonMap eventRow0(
  String kind, {
  String by = 'Owner',
  String note = '',
  String answer = '',
  String commit = '',
}) => {
  'kind': kind,
  'note': note,
  'answer': answer,
  'commit': commit,
  'by': by,
  'at': '2026-11-27 10:00:00.000Z',
};
