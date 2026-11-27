import 'frame_key.dart';
import 'record.dart';
import 'round.dart';

/// How a frame of the round a reviewer is shown compares with the same frame, by key (D5), in
/// a round they saw before (docs/DESIGN.md D17).
sealed class FrameChange {
  const FrameChange(this.key);

  /// The frame.
  final FrameKey key;
}

/// In the round shown, and not in the earlier one.
final class FrameAdded extends FrameChange {
  /// [key], new.
  const FrameAdded(super.key);

  @override
  String toString() => 'FrameAdded($key)';
}

/// In both, and its pixels differ.
final class FrameChanged extends FrameChange {
  /// [key], changed.
  const FrameChanged(super.key);

  @override
  String toString() => 'FrameChanged($key)';
}

/// In both, with the same pixels.
final class FrameSame extends FrameChange {
  /// [key], the same.
  const FrameSame(super.key);

  @override
  String toString() => 'FrameSame($key)';
}

/// In the earlier round, and not in the round shown: its screen, state or device left the
/// plan, or the round was filtered.
final class FrameGone extends FrameChange {
  /// [key], gone.
  const FrameGone(super.key);

  @override
  String toString() => 'FrameGone($key)';
}

/// In both, and not compared: one of the two has no digest of its pixels, and [why] says
/// which. Never read as the same.
final class FrameUncompared extends FrameChange {
  /// [key], not compared, because of [why].
  const FrameUncompared(super.key, this.why);

  /// Why not.
  final String why;

  @override
  String toString() => 'FrameUncompared($key, $why)';
}

/// Every frame of [shown], round [shownN], as it compares with [since], round [sinceN]: one
/// change per frame of [shown], in its order, then a [FrameGone] for each frame of [since] that
/// [shown] does not have, in [since]'s order.
///
/// Changed means the pixels differ ([FrameRecord.pixels]): the packer renders every frame twice
/// and refuses one that differs (D4), so pixels that differ between rounds are the app's
/// change, not a clock or an animation. Every frame is returned, the same ones too, so a
/// caller counts what it looked at.
///
/// Rejected: comparing the trees. A colour or an image changes no box, and the reviewer looks
/// at pixels.
List<FrameChange> changesSince(
  List<RoundFrame> since,
  List<RoundFrame> shown, {
  required int sinceN,
  required int shownN,
}) {
  final before = {for (final f in since) f.record.key: f.record};
  final now = {for (final f in shown) f.record.key};
  return [
    for (final f in shown)
      switch ((before[f.record.key]?.pixels, f.record.pixels)) {
        _ when !before.containsKey(f.record.key) => FrameAdded(f.record.key),
        (null, _) => FrameUncompared(
          f.record.key,
          _undigested(before[f.record.key]!.image, sinceN),
        ),
        (_, null) => FrameUncompared(f.record.key, _undigested(f.record.image, shownN)),
        (final a?, final b?) => a == b ? FrameSame(f.record.key) : FrameChanged(f.record.key),
      },
    for (final f in since)
      if (!now.contains(f.record.key)) FrameGone(f.record.key),
  ];
}

String _undigested(String? image, int n) => image == null
    ? 'nothing was captured of it in round $n'
    : 'round $n did not record a digest of its pixels: it was packed before 0.3.10';
