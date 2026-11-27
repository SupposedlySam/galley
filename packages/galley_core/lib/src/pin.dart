import 'anchor.dart';
import 'frame_tree.dart';
import 'geometry.dart';
import 'json.dart';

/// Where a new mark is pinned: a point in the frame, or a widget by its index path.
///
/// Resolved here, in the core, because two layers raise marks: `galley serve` resolves the
/// target it is sent, and the canvas resolves its own before it writes to the server, which
/// cannot run Dart (DESIGN D15). Rejected: a copy in each. The two would drift on which widget
/// a click names.
sealed class PinTarget {
  const PinTarget();

  /// Reads the `node` and `at` of [request], the form [toJson] writes: `"node": [0, 1]` names a
  /// widget, `"at": [x, y]` a point in the frame's logical pixels, and both, the widget and
  /// where on it.
  factory PinTarget.fromJson(JsonMap request, String context) {
    final r = JsonReader(request, context);
    return switch ((request['node'], request['at'])) {
      (List<Object?>(), null) => AtNode(r.integers('node')),
      (List<Object?>(), [final num x, final num y]) => AtNode(
        r.integers('node'),
        at: (x: x.toDouble(), y: y.toDouble()),
      ),
      (null, [final num x, final num y]) => AtPoint(x.toDouble(), y.toDouble()),
      // A mark's `pin` comes back as {"dx", "dy"}, and the first adopting app sent that as
      // "at". Said, not accepted: a pin is a fraction of its widget, which is worked out from
      // where in the frame the click was. Rejected: taking either shape, two ways to say one
      // thing, one of which cannot be checked against the widget's box.
      (_, Map<String, Object?>()) => throw FormatException(
        '$context.at: [x, y] in the frame\'s logical pixels, not a pin\'s {"dx", "dy"}: the '
        'pin, a fraction of the widget, is worked out from it',
      ),
      _ => throw FormatException(
        '$context: give "node": [0, 1], "at": [x, y], or both (the widget, and where in it)',
      ),
    };
  }

  /// The `node` and `at` of a request, which [PinTarget.fromJson] reads.
  JsonMap toJson();

  /// The widget this names in [tree], and where on it. Throws [PinMissed] saying why when it
  /// names none.
  ({WidgetNode node, PinOffset pin}) resolve(FrameTree tree);
}

/// The deepest widget at ([x], [y]) in logical pixels, pinned at that point within it.
final class AtPoint extends PinTarget {
  /// The point ([x], [y]).
  const AtPoint(this.x, this.y);

  /// Logical pixels from the frame's left.
  final double x;

  /// Logical pixels from the frame's top.
  final double y;

  @override
  ({WidgetNode node, PinOffset pin}) resolve(FrameTree tree) => switch (tree.deepestAt(x, y)) {
    final node? => (node: node, pin: PinOffset.within(node.rect, x, y)),
    null => throw PinMissed('no widget at $this'),
  };

  @override
  JsonMap toJson() => {
    'at': [x, y],
  };

  @override
  String toString() => '$x,$y';
}

/// The widget at index [path] in the frame's tree, pinned at [at] inside it, or at its centre.
///
/// The canvas sends both: the reviewer clicks a point and then picks the widget, the deepest one
/// there or one of its ancestors. Rejected: sending only the point, which can name only the
/// deepest widget, so "the card" could never be marked by clicking its label.
final class AtNode extends PinTarget {
  /// The widget at [path], pinned at [at] (logical pixels in the frame), or at its centre.
  const AtNode(this.path, {this.at});

  /// Child indexes from the root.
  final IndexPath path;

  /// Where in the frame the pin was dropped, or null for the widget's centre. It must be
  /// inside the widget.
  final ({double x, double y})? at;

  @override
  ({WidgetNode node, PinOffset pin}) resolve(FrameTree tree) {
    final node = tree.at(path) ?? (throw PinMissed('no widget at $this'));
    return switch (at) {
      null => (node: node, pin: const PinOffset(0.5, 0.5)),
      (:final x, :final y) when _inside(node.rect, x, y) => (
        node: node,
        pin: PinOffset.within(node.rect, x, y),
      ),
      _ => throw PinMissed('$this is outside ${node.type}'),
    };
  }

  @override
  JsonMap toJson() => {
    'node': path,
    if (at case (:final x, :final y)) 'at': [x, y],
  };

  /// Whether ([x], [y]) is in [r], edges included: a pin on a widget's edge is on the widget.
  static bool _inside(LogicalRect r, double x, double y) =>
      x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;

  @override
  String toString() => switch (at) {
    null => path.join('.'),
    (:final x, :final y) => '${path.join('.')} at $x,$y',
  };
}

/// A [PinTarget] that names no widget of the tree, and why, in words a person can act on.
final class PinMissed implements Exception {
  /// Missed, because of [message].
  const PinMissed(this.message);

  /// Why.
  final String message;

  @override
  String toString() => message;
}
