import 'dart:math' as math;

import 'package:galley_core/galley_core.dart';
import 'package:material_ui/material_ui.dart';

import 'api.dart';
import 'board.dart';
import 'canvas_model.dart';
import 'composer.dart';
import 'marks.dart';

/// One frame in its device's outline, with its caption above, its marks pinned to it, and the
/// widget under the cursor outlined. A click raises a mark there.
///
/// The frame's screen is drawn at its logical size, so a point in it is a point in the frame's
/// tree with no conversion: the board's zoom is the [InteractiveViewer]'s, outside it.
class FrameTile extends StatefulWidget {
  /// The tile for [tile].
  const FrameTile({
    super.key,
    required this.tile,
    required this.model,
    required this.shown,
    required this.scale,
    required this.thumbnail,
  });

  /// Which frame, and where.
  final BoardTile tile;

  /// What a reviewer does.
  final CanvasModel model;

  /// The round it is in, with the marks.
  final Shown shown;

  /// The board's zoom: pins and outlines keep one size on screen whatever it is.
  final double scale;

  /// Whether it is drawn small: its image decoded small, and its mark count shown large.
  final bool thumbnail;

  @override
  State<FrameTile> createState() => _FrameTileState();
}

class _FrameTileState extends State<FrameTile> {
  /// The width of the bezel's outline, within [Board.bezel].
  static const _rim = 1.0;

  WidgetNode? _hovered;

  RoundFrame get _frame => widget.tile.frame;
  FrameRecord get _record => _frame.record;

  @override
  Widget build(BuildContext context) {
    final screen = widget.tile.screen;
    final pins = widget.shown.pinnedOn(_record.key);
    final waiting = pins.where((m) => !m.mark.status.isFinal).length;
    return SizedBox(
      width: screen.width + 2 * Board.bezel,
      height: Board.tileLabel + screen.height + 2 * Board.bezel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: Board.tileLabel, child: _caption(waiting, pins.length - waiting)),
          // The rim is drawn inside the bezel, not around it: a border adds its width to the
          // padding, and at `Board.bezel` of padding the tile came out 2 pixels larger than its
          // box. Observed in a widget test: the column overflowed by 2, and the screen was
          // squeezed to 409 of its 411 pixels, so a click landed off the tree's coordinates.
          Container(
            padding: const EdgeInsets.all(Board.bezel - _rim),
            decoration: BoxDecoration(
              color: const Color(0xFF2B3038),
              borderRadius: BorderRadius.circular(Board.bezel * 2),
              border: Border.all(color: const Color(0xFF454C57), width: _rim),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Board.bezel),
              child: SizedBox(
                width: screen.width,
                height: screen.height,
                child: _screen(pins, waiting),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The tile's caption, with its findings and how many of its marks still wait on someone.
  /// A verified or withdrawn mark is counted apart: it stays pinned (nothing is erased), but a
  /// count in the colour of an open mark that included it would send a reviewer to a frame with
  /// nothing left to do. Observed: a frame whose two marks were verified and withdrawn showed
  /// a red 2.
  Widget _caption(int waiting, int closed) {
    final findings = _record.findings;
    return Row(
      children: [
        Flexible(
          child: Text(
            widget.tile.caption,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: Colors.white60),
          ),
        ),
        if (findings.isNotEmpty)
          Tooltip(
            message: findings.join('\n'),
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: _Counted(Icons.warning_amber, findings.length, const Color(0xFFE0B341)),
            ),
          ),
        if (waiting + closed > 0)
          Tooltip(
            message: '$waiting waiting, $closed closed',
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: waiting > 0
                  ? _Counted(Icons.circle, waiting, const Color(0xFFE5675A))
                  : _Counted(Icons.check_circle_outline, closed, Colors.white38),
            ),
          ),
      ],
    );
  }

  Widget _screen(List<PlacedMark> pins, int waiting) {
    final record = _record;
    if (record.status == FrameStatus.error) {
      return _Card(
        title: 'This frame did not render',
        lines: record.errors,
        color: const Color(0xFF5A2A2A),
      );
    }
    final image = record.image;
    final tree = _frame.tree;
    return MouseRegion(
      cursor: tree == null ? MouseCursor.defer : SystemMouseCursors.precise,
      onHover: (e) => _hover(tree?.deepestAt(e.localPosition.dx, e.localPosition.dy)),
      onExit: (_) => _hover(null),
      child: GestureDetector(
        onTapUp: (e) => _tap(context, tree, e.localPosition),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (image == null)
              const _Card(
                title: 'No image was captured',
                lines: ['Its widgets can still be marked, from the tree.'],
                color: Color(0xFF2A3A5A),
              )
            else
              Image.network(
                '${widget.model.api.file(widget.shown.n, image)}',
                fit: BoxFit.fill,
                cacheWidth: widget.thumbnail ? 256 : null,
                filterQuality: FilterQuality.medium,
                errorBuilder: (context, error, _) => _Card(
                  title: 'The image did not load',
                  lines: [image, '$error'],
                  color: const Color(0xFF5A2A2A),
                ),
              ),
            if (_hovered case final node?) _Outline(node, scale: widget.scale),
            if (widget.thumbnail && waiting > 0)
              Center(
                child: _Count(waiting, scale: widget.scale, fitting: widget.tile.screen.width),
              ),
            for (final m in pins)
              if (m.carried.pin case (final x, final y))
                Positioned(
                  left: x,
                  top: y,
                  child: FractionalTranslation(
                    translation: const Offset(-0.5, -0.5),
                    child: Pin(
                      mark: m.mark,
                      scale: widget.scale,
                      selected: widget.model.selected == m.mark.id,
                      onTap: () => widget.model.select(m.mark.id),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  void _hover(WidgetNode? node) {
    if (!identical(node, _hovered)) setState(() => _hovered = node);
  }

  Future<void> _tap(BuildContext context, FrameTree? tree, Offset at) async {
    if (tree == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This frame has no widget tree, so nothing in it can be pinned.'),
        ),
      );
      return;
    }
    await showComposer(
      context,
      model: widget.model,
      frame: _record.key,
      candidates: tree.allAt(at.dx, at.dy),
      at: (x: at.dx, y: at.dy),
    );
  }
}

/// An icon and a count, in a caption. Icons, not characters such as '⚠': Roboto has no such
/// glyph, and the engine would fetch a fallback font for it (web/flutter_bootstrap.js).
class _Counted extends StatelessWidget {
  const _Counted(this.icon, this.count, this.color);

  final IconData icon;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 13, color: color),
      const SizedBox(width: 3),
      Text('$count', style: TextStyle(fontSize: 13, color: color)),
    ],
  );
}

/// The widget under the cursor: its box, and its type above it.
class _Outline extends StatelessWidget {
  const _Outline(this.node, {required this.scale});

  final WidgetNode node;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final r = node.rect;
    return Positioned(
      left: r.left,
      top: r.top,
      width: r.width,
      height: r.height,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF4FC3F7), width: 2 / scale),
            color: const Color(0x224FC3F7),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: ColoredBox(
              color: const Color(0xFF4FC3F7),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 4 / scale),
                child: Text(
                  node.type,
                  style: TextStyle(fontSize: 12 / scale, color: Colors.black),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How many of a frame's marks wait on someone, drawn large when the board is zoomed out.
///
/// It grows to 14 screen pixels, but its text never past a sixth of the frame's width, so it
/// stays inside the frame. Observed: uncapped at the first adopter's fitted zoom (about 6%),
/// its text was over 200 logical pixels and the badge covered its frame and the next.
class _Count extends StatelessWidget {
  const _Count(this.count, {required this.scale, required this.fitting});

  final int count;
  final double scale;
  final double fitting;

  @override
  Widget build(BuildContext context) {
    final size = math.min(14 / scale, fitting / 6);
    return IgnorePointer(
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: size * 0.7, vertical: size * 0.3),
        decoration: BoxDecoration(
          color: const Color(0xDDE5675A),
          borderRadius: BorderRadius.circular(size),
        ),
        child: Text(
          '$count waiting',
          style: TextStyle(fontSize: size, color: Colors.white),
        ),
      ),
    );
  }
}

/// A frame with nothing to draw, and why.
class _Card extends StatelessWidget {
  const _Card({required this.title, required this.lines, required this.color});

  final String title;
  final List<String> lines;
  final Color color;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: color,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          for (final l in lines) Text(l, style: const TextStyle(fontSize: 13)),
        ],
      ),
    ),
  );
}
