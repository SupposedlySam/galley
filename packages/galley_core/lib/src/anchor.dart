import 'frame_tree.dart';
import 'geometry.dart';
import 'json.dart';
import 'source_location.dart';

/// Everything known about the widget a mark was pinned to, kept so the widget can be found
/// again in a later round (docs/DESIGN.md D6).
///
/// It is a copy, not a reference. The tree it came from is replaced by the next round, and the
/// anchor has to outlive it.
final class Anchor {
  /// An anchor from its parts.
  Anchor({
    required this.type,
    required IndexPath indexPath,
    required this.rect,
    this.key,
    this.semanticsLabel,
    this.location,
  }) : indexPath = List.unmodifiable(indexPath);

  /// The anchor for [node], as captured.
  factory Anchor.of(WidgetNode node) => Anchor(
    type: node.type,
    indexPath: node.indexPath,
    rect: node.rect,
    key: node.key,
    semanticsLabel: node.semanticsLabel,
    location: node.location,
  );

  /// Reads the form [toJson] writes.
  factory Anchor.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    return Anchor(
      type: r.string('type'),
      indexPath: r.integers('path'),
      rect: r.read('rect', LogicalRect.fromJson),
      key: r.optionalString('key'),
      semanticsLabel: r.optionalString('semantics'),
      location: r.readOptional('location', SourceLocation.fromJson),
    );
  }

  /// The widget's runtime type when it was pinned.
  final String type;

  /// The widget's index path when it was pinned.
  final IndexPath indexPath;

  /// The widget's box when it was pinned.
  final LogicalRect rect;

  /// The widget's key when it was pinned, or null.
  final String? key;

  /// The widget's semantics label when it was pinned, or null.
  final String? semanticsLabel;

  /// Where the widget was constructed, or null.
  final SourceLocation? location;

  /// The JSON form [Anchor.fromJson] reads.
  JsonMap toJson() => {
    'type': type,
    'path': indexPath,
    'rect': rect.toJson(),
    if (key != null) 'key': key,
    if (semanticsLabel != null) 'semantics': semanticsLabel,
    if (location != null) 'location': location!.toJson(),
  };
}

/// Where in its anchor widget a mark was dropped, as fractions of the widget's size.
///
/// Fractions, not pixels, so a pin on a button's label stays on the label when the button
/// grows. Both are in 0..1 inclusive.
final class PinOffset {
  /// An offset from its fractions.
  const PinOffset(this.dx, this.dy)
    : assert(dx >= 0 && dx <= 1, 'dx is a fraction of the width'),
      assert(dy >= 0 && dy <= 1, 'dy is a fraction of the height');

  /// The offset of the point ([x], [y]) inside [rect], clamped to its edges.
  factory PinOffset.within(LogicalRect rect, double x, double y) => PinOffset(
    rect.width == 0 ? 0 : ((x - rect.left) / rect.width).clamp(0, 1),
    rect.height == 0 ? 0 : ((y - rect.top) / rect.height).clamp(0, 1),
  );

  /// Reads the form [toJson] writes.
  factory PinOffset.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    final dx = r.number('dx');
    final dy = r.number('dy');
    if (dx < 0 || dx > 1 || dy < 0 || dy > 1) {
      throw FormatException('$context: dx and dy are fractions in 0..1, got $dx, $dy');
    }
    return PinOffset(dx, dy);
  }

  /// Fraction of the anchor's width from its left edge.
  final double dx;

  /// Fraction of the anchor's height from its top edge.
  final double dy;

  /// The point this offset names inside [rect].
  (double x, double y) pointIn(LogicalRect rect) =>
      (rect.left + dx * rect.width, rect.top + dy * rect.height);

  /// The JSON form [PinOffset.fromJson] reads.
  JsonMap toJson() => {'dx': dx, 'dy': dy};
}
