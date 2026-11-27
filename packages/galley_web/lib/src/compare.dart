import 'dart:math' as math;

import 'package:galley_core/galley_core.dart';
import 'package:material_ui/material_ui.dart';

import 'canvas_model.dart';
import 'marks.dart';

/// An answered mark's widget as the reviewer marked it, beside the same widget in the round
/// shown: what they check the answer against before saying "Looks right" or "Not yet".
///
/// Both sides are crops of the frame around the widget, not the whole frames: at the width of
/// the panel a whole phone screen is too small to see a padding change in. Rejected: an overlay
/// of the two rounds on the board, which is a later feature (ROADMAP, "Not on this path") and
/// which would hide the board the reviewer is using to find the next mark.
class Compare extends StatefulWidget {
  /// [mark], as raised and as shown in [shown].
  const Compare({super.key, required this.model, required this.shown, required this.mark});

  /// Where the round it was raised on is read from.
  final CanvasModel model;

  /// The round shown.
  final Shown shown;

  /// The mark.
  final PlacedMark mark;

  @override
  State<Compare> createState() => _CompareState();
}

class _CompareState extends State<Compare> {
  // Kept, so a rebuild (each keystroke in the note below) does not ask again and flash empty.
  late Future<Before> _before = widget.model.before(widget.mark);

  @override
  void didUpdateWidget(Compare old) {
    super.didUpdateWidget(old);
    final m = widget.mark;
    if (m.mark.id != old.mark.mark.id || m.raisedIn != old.mark.raisedIn) {
      _before = widget.model.before(m);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.mark;
    final shown = widget.shown;
    final now = shown.round.round.frame(m.mark.frame)?.record;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: FutureBuilder(
            future: _before,
            builder: (context, snap) => switch (snap.data) {
              null => const _Side(label: 'As you marked it', child: _Waiting()),
              BeforeUnknown(:final why) => _Side(label: 'As you marked it', child: _Missing(why)),
              BeforeIn(:final n, :final record) => _Side(
                label: 'As you marked it, round $n',
                child: _cropOf(
                  n,
                  record,
                  m.mark.anchor.rect,
                  m.mark.pin.pointIn(m.mark.anchor.rect),
                ),
              ),
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _Side(
            label: 'Now, round ${shown.n}',
            child: switch ((shown.notDrawn(m), now, m.carried.box, m.carried.pin)) {
              (final why?, _, _, _) => _Missing('not shown: $why'),
              (null, final record?, final box?, (final x, final y)) => _cropOf(
                shown.n,
                record,
                box,
                (x, y),
              ),
              // A mark drawn on the round is on a frame of it with a box; anything else is a
              // round and a placement that disagree, said rather than drawn as nothing.
              _ => _Missing('round ${shown.n} does not place it on frame ${m.mark.frame}'),
            },
          ),
        ),
      ],
    );
  }

  Widget _cropOf(int n, FrameRecord record, LogicalRect box, (double, double) pin) =>
      switch (record.image) {
        null => const _Missing('no image was captured of this frame'),
        final image => Crop(
          image: '${widget.model.api.file(n, image)}',
          frame: (width: record.device.logicalWidth, height: record.device.logicalHeight),
          box: box,
          pin: pin,
          color: statusColor(widget.mark.mark.status),
        ),
      };
}

/// The part of a frame [frame] across shown around [box]: [box] with [margin] on every side,
/// kept inside the frame. A box larger than the frame is the frame.
///
/// The margin is there so the reviewer sees what is next to the widget too: a fix to a
/// button's padding shows in the gap to its neighbour, not in the button.
LogicalRect cropAround(
  LogicalRect box,
  ({double width, double height}) frame, {
  double margin = 24,
}) {
  double clamp(double v, double max) => v.clamp(0, max).toDouble();
  final left = clamp(box.left - margin, frame.width);
  final top = clamp(box.top - margin, frame.height);
  final right = clamp(box.left + box.width + margin, frame.width);
  final bottom = clamp(box.top + box.height + margin, frame.height);
  return LogicalRect(left, top, right - left, bottom - top);
}

/// [image], a frame [frame] across, cropped to the region around [box], with [box] outlined
/// and the pin at [pin] (both in the frame's logical pixels), scaled to the width it is given
/// and to at most [maxHeight].
class Crop extends StatelessWidget {
  /// A crop of [image].
  const Crop({
    super.key,
    required this.image,
    required this.frame,
    required this.box,
    required this.pin,
    required this.color,
    this.maxHeight = 220,
  });

  /// The frame's PNG.
  final String image;

  /// The frame's logical size: the size its tree's boxes are in.
  final ({double width, double height}) frame;

  /// The widget.
  final LogicalRect box;

  /// Where the mark is pinned.
  final (double, double) pin;

  /// The mark's colour.
  final Color color;

  /// The tallest the crop is drawn.
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final region = cropAround(box, frame);
    return LayoutBuilder(
      builder: (context, constraints) {
        // A region with no area (a widget of no size at the frame's edge) draws as the frame.
        final shown = region.width > 0 && region.height > 0
            ? region
            : LogicalRect(0, 0, frame.width, frame.height);
        final scale = math.min(constraints.maxWidth / shown.width, maxHeight / shown.height);
        final (x, y) = pin;
        return ClipRect(
          child: SizedBox(
            width: shown.width * scale,
            height: shown.height * scale,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(
                  left: -shown.left * scale,
                  top: -shown.top * scale,
                  width: frame.width * scale,
                  height: frame.height * scale,
                  child: Image.network(
                    image,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (context, error, _) => _Missing('the image did not load: $error'),
                  ),
                ),
                Positioned(
                  left: (box.left - shown.left) * scale,
                  top: (box.top - shown.top) * scale,
                  width: box.width * scale,
                  height: box.height * scale,
                  child: DecoratedBox(
                    decoration: BoxDecoration(border: Border.all(color: color, width: 1.5)),
                  ),
                ),
                Positioned(
                  left: (x - shown.left) * scale - 5,
                  top: (y - shown.top) * scale - 5,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black54),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: 4),
      child,
    ],
  );
}

class _Waiting extends StatelessWidget {
  const _Waiting();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 48, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
}

/// What could not be shown, and why: never an empty box.
class _Missing extends StatelessWidget {
  const _Missing(this.why);

  final String why;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(8),
    color: Colors.white10,
    child: Text(why, style: Theme.of(context).textTheme.bodySmall),
  );
}
