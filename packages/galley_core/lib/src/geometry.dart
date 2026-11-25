import 'dart:math' as math;

import 'json.dart';

/// A rectangle in a frame's logical pixels, with the origin at the frame's top left.
///
/// This is Galley's own type rather than `dart:ui`'s `Rect`, so the server, the CLI and the
/// re-anchoring logic stay pure Dart (docs/DESIGN.md D1).
final class LogicalRect {
  /// A rectangle from its top-left corner and size. Width and height must not be negative.
  const LogicalRect(this.left, this.top, this.width, this.height)
    : assert(width >= 0, 'width must not be negative'),
      assert(height >= 0, 'height must not be negative');

  /// Reads the form [toJson] writes.
  factory LogicalRect.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    final width = r.number('width');
    final height = r.number('height');
    // Checked before constructing: the constructor's asserts are off in a release build (the
    // server), so they cannot be what refuses a bad file.
    if (width < 0 || height < 0) {
      throw FormatException('$context: negative size $width×$height');
    }
    return LogicalRect(r.number('left'), r.number('top'), width, height);
  }

  /// Distance from the frame's left edge.
  final double left;

  /// Distance from the frame's top edge.
  final double top;

  /// Width, never negative.
  final double width;

  /// Height, never negative.
  final double height;

  /// The right edge.
  double get right => left + width;

  /// The bottom edge.
  double get bottom => top + height;

  /// Width times height.
  double get area => width * height;

  /// The overlap of this and [other], or null when they do not overlap.
  LogicalRect? intersection(LogicalRect other) {
    final l = math.max(left, other.left);
    final t = math.max(top, other.top);
    final r = math.min(right, other.right);
    final b = math.min(bottom, other.bottom);
    if (r <= l || b <= t) return null;
    return LogicalRect(l, t, r - l, b - t);
  }

  /// Intersection over union: 1 for identical rectangles, 0 for disjoint ones.
  ///
  /// Two empty rectangles at the same place count as identical (1): a zero-size widget
  /// that has not moved has not moved.
  double overlapWith(LogicalRect other) {
    if (area == 0 && other.area == 0) return this == other ? 1 : 0;
    final overlap = intersection(other)?.area ?? 0;
    final union = area + other.area - overlap;
    return union == 0 ? 0 : overlap / union;
  }

  /// The JSON form [LogicalRect.fromJson] reads.
  JsonMap toJson() => {'left': left, 'top': top, 'width': width, 'height': height};

  @override
  bool operator ==(Object other) =>
      other is LogicalRect &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'LogicalRect($left, $top, $width × $height)';
}
