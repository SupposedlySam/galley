import 'dart:math' as math;

import 'package:galley_core/galley_core.dart';
import 'package:material_ui/material_ui.dart';

import 'board.dart';
import 'canvas_model.dart';
import 'frame_tile.dart';

/// The board, panned and zoomed, drawing only what is in view.
///
/// A round of the first adopting app is 155 frames on a board about 20,000 pixels wide. Drawing
/// every frame at every frame would decode 155 PNGs to show the dozen on screen, so only tiles
/// that meet the view (and half a view around it, so a pan does not show blanks) are built.
/// Rejected: a [Stack] of every tile, which is that.
class BoardView extends StatefulWidget {
  /// The board of [shown].
  const BoardView({super.key, required this.model, required this.shown});

  /// What a reviewer does.
  final CanvasModel model;

  /// The round shown.
  final Shown shown;

  @override
  State<BoardView> createState() => BoardViewState();
}

/// The [BoardView]'s state, which can move the view to a frame.
class BoardViewState extends State<BoardView> {
  final _transform = TransformationController();
  Size? _viewport;

  /// Below this scale a frame is a thumbnail: decoded small, and drawn with its mark count.
  static const thumbnailBelow = 0.4;

  Board get _board => widget.shown.board;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// Moves the view to [frame] at full size, centred. Nothing happens when the round lacks it.
  void showFrame(FrameKey frame) {
    final tile = _board.tileOf(frame);
    final viewport = _viewport;
    if (tile == null || viewport == null) return;
    final s = math.min(1.0, (viewport.height - 48) / tile.screen.height);
    final cx = tile.screen.left + tile.screen.width / 2;
    final cy = tile.screen.top + tile.screen.height / 2;
    _transform.value = Matrix4.identity()
      ..translateByDouble(viewport.width / 2 - cx * s, viewport.height / 2 - cy * s, 0, 1)
      ..scaleByDouble(s, s, s, 1);
  }

  /// The board's zoom as [InteractiveViewer] reads it: [Matrix4.getMaxScaleOnAxis], the largest
  /// of the x, y and z scales. So every transform set here scales z with x and y, as the
  /// viewer's own zoom does. Observed: one that left z at 1 read as 100% at every zoom out,
  /// so no frame was ever a thumbnail and the flow names stayed too small to read.
  double get scale => _transform.value.getMaxScaleOnAxis();

  void _fit(Size viewport) {
    _viewport = viewport;
    if (_board.width == 0) return;
    final s = math.min(viewport.width / _board.width, viewport.height / _board.height) * 0.95;
    _transform.value = Matrix4.identity()
      ..translateByDouble(24, 24, 0, 1)
      ..scaleByDouble(s, s, s, 1);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (_viewport == null) _fit(size);
      _viewport = size;
      return ColoredBox(
        color: const Color(0xFF15181D),
        child: InteractiveViewer.builder(
          transformationController: _transform,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          minScale: 0.01,
          maxScale: 6,
          builder: (context, viewport) {
            final xs = [viewport.point0.x, viewport.point1.x, viewport.point2.x, viewport.point3.x];
            final ys = [viewport.point0.y, viewport.point1.y, viewport.point2.y, viewport.point3.y];
            final left = xs.reduce(math.min), right = xs.reduce(math.max);
            final top = ys.reduce(math.min), bottom = ys.reduce(math.max);
            final w = right - left, h = bottom - top;
            final view = LogicalRect(left - w / 2, top - h / 2, w * 2, h * 2);
            final scale = this.scale;
            return SizedBox(
              width: _board.width,
              height: _board.height,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final row in _board.rows)
                    if (row.rect.overlapWith(view) > 0) ...[
                      _flowLabel(row, scale),
                      for (final column in row.columns)
                        if (column.rect.overlapWith(view) > 0) ...[
                          _label(column.rect.left, column.rect.top, column.state, 20, scale),
                          for (final tile in column.tiles)
                            if (_outline(tile).overlapWith(view) > 0)
                              Positioned(
                                left: tile.screen.left - Board.bezel,
                                top: tile.screen.top - Board.bezel - Board.tileLabel,
                                child: FrameTile(
                                  key: ValueKey(tile.frame.record.key),
                                  tile: tile,
                                  model: widget.model,
                                  shown: widget.shown,
                                  scale: scale,
                                  thumbnail: scale < thumbnailBelow,
                                ),
                              ),
                        ],
                    ],
                ],
              ),
            );
          },
        ),
      );
    },
  );

  static LogicalRect _outline(BoardTile t) => LogicalRect(
    t.screen.left - Board.bezel,
    t.screen.top - Board.bezel - Board.tileLabel,
    t.screen.width + 2 * Board.bezel,
    t.screen.height + 2 * Board.bezel + Board.tileLabel,
  );

  /// A flow's name, which must be readable when the whole board is in view: that is when a
  /// reviewer picks a flow to zoom into. It grows to 14 screen pixels, up to the row's label
  /// and the gap above it, and its bottom stays on the row's label line, so it grows up into
  /// the gap and never over the frames. Rejected: capping it like a state's label, which on
  /// the first adopter's round (fitted at about 6%) drew every flow's name 5 pixels tall.
  Widget _flowLabel(BoardRow row, double scale) {
    const room = Board.rowLabel + Board.rowGap;
    return Positioned(
      left: row.rect.left,
      top: row.rect.top + Board.rowLabel - room,
      height: room,
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Text(
          row.flow,
          maxLines: 1,
          style: TextStyle(
            fontSize: (14 / scale).clamp(40, room * 0.8),
            fontWeight: FontWeight.w500,
            color: Colors.white70,
          ),
        ),
      ),
    );
  }

  /// A label that stays readable when zoomed out, growing to 12 screen pixels, but never past
  /// twice its size: further out it would cover the frames under it.
  Widget _label(double left, double top, String text, double size, double scale) => Positioned(
    left: left,
    top: top,
    child: Text(
      text,
      style: TextStyle(
        fontSize: (12 / scale).clamp(size, size * 2),
        fontWeight: FontWeight.w500,
        color: Colors.white70,
      ),
    ),
  );
}
