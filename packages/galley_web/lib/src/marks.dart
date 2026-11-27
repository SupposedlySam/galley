import 'package:galley_core/galley_core.dart';
import 'package:material_ui/material_ui.dart';

/// The colour a mark's [status] is drawn in, on the board and in the panel alike, so a pin and
/// its row in the list read as one thing.
///
/// Red waits on the app (open, reopened), amber waits on the reviewer (answered), green and
/// grey are done. Rejected: one colour per status with no grouping, which makes a reviewer
/// learn five colours to answer the one question they have: is this waiting on me?
Color statusColor(MarkStatus status) => switch (status) {
  MarkStatus.open || MarkStatus.reopened => const Color(0xFFE5675A),
  MarkStatus.answered => const Color(0xFFE0B341),
  MarkStatus.verified => const Color(0xFF5DB37E),
  MarkStatus.withdrawn => const Color(0xFF8A919C),
};

/// A mark pinned to a frame: a dot of one size on screen at any zoom, ringed when selected.
class Pin extends StatelessWidget {
  /// A pin for [mark], at the board's [scale].
  const Pin({
    super.key,
    required this.mark,
    required this.scale,
    required this.selected,
    required this.onTap,
  });

  /// The mark.
  final Mark mark;

  /// The board's zoom, divided out so the pin is [size] screen pixels across.
  final double scale;

  /// Whether its thread is open.
  final bool selected;

  /// Opens its thread.
  final VoidCallback onTap;

  /// Its diameter on screen.
  static const size = 22.0;

  @override
  Widget build(BuildContext context) {
    final d = size / scale;
    return Tooltip(
      message: '${mark.status.name} · ${mark.by}: ${mark.note}',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: d,
          height: d,
          decoration: BoxDecoration(
            color: statusColor(mark.status),
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Colors.white : Colors.black54,
              width: (selected ? 3 : 1.5) / scale,
            ),
            boxShadow: [BoxShadow(blurRadius: 4 / scale, color: Colors.black54)],
          ),
        ),
      ),
    );
  }
}
