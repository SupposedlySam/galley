import 'dart:collection';

import 'geometry.dart';
import 'json.dart';
import 'source_location.dart';

/// The position of a node among its recorded ancestors: `[0, 2, 1]` is the second child of
/// the third child of the root's first child.
///
/// Only recorded nodes count (widgets that own a box; see [WidgetNode]), so a wrapper widget
/// with no box of its own does not shift its descendants' paths.
typedef IndexPath = List<int>;

/// One widget in a captured frame: what it is, where it is, and where it came from.
final class WidgetNode {
  /// A node from its parts. [indexPath] is copied; it is empty only for the root.
  WidgetNode({
    required IndexPath indexPath,
    required this.type,
    required this.rect,
    this.key,
    this.semanticsLabel,
    this.location,
  }) : indexPath = List.unmodifiable(indexPath);

  /// Reads the form [toJson] writes.
  factory WidgetNode.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    return WidgetNode(
      indexPath: r.integers('path'),
      type: r.string('type'),
      rect: r.read('rect', LogicalRect.fromJson),
      key: r.optionalString('key'),
      semanticsLabel: r.optionalString('semantics'),
      location: r.readOptional('location', SourceLocation.fromJson),
    );
  }

  /// Where this node sits among its recorded ancestors.
  final IndexPath indexPath;

  /// The widget's runtime type, such as `ElevatedButton`.
  final String type;

  /// The widget's box, in the frame's logical pixels.
  final LogicalRect rect;

  /// The widget's key as the app wrote it, or null when it has none.
  final String? key;

  /// The label of the semantics node this widget contributes to, or null when it has none.
  final String? semanticsLabel;

  /// Where the widget was constructed, or null when it was not tracked.
  final SourceLocation? location;

  /// The JSON form [WidgetNode.fromJson] reads.
  JsonMap toJson() => {
    'path': indexPath,
    'type': type,
    'rect': rect.toJson(),
    if (key != null) 'key': key,
    if (semanticsLabel != null) 'semantics': semanticsLabel,
    if (location != null) 'location': location!.toJson(),
  };

  @override
  String toString() => '$type${key == null ? '' : '($key)'} at ${indexPath.join('.')}';
}

/// Every recorded widget in one captured frame, in paint (pre-)order, plus the frame's size.
final class FrameTree {
  /// A tree from its nodes in pre-order.
  ///
  /// Throws an [ArgumentError] if two nodes share a path, a node's parent is missing, or the
  /// first node is not the root. A tree that broke these rules would make re-anchoring silently
  /// pick one of two widgets.
  factory FrameTree({required LogicalRect bounds, required List<WidgetNode> nodes}) {
    final byPath = HashMap<String, WidgetNode>();
    for (final (i, node) in nodes.indexed) {
      if (i == 0 && node.indexPath.isNotEmpty) {
        throw ArgumentError.value(node, 'nodes[0]', 'the first node must be the root (path [])');
      }
      if (i > 0 && node.indexPath.isEmpty) {
        throw ArgumentError.value(node, 'nodes[$i]', 'only the first node may be the root');
      }
      final path = _pathKey(node.indexPath);
      if (byPath.containsKey(path)) {
        throw ArgumentError.value(node, 'nodes[$i]', 'repeats path [$path]');
      }
      if (node.indexPath.isNotEmpty) {
        final parent = _pathKey(node.indexPath.sublist(0, node.indexPath.length - 1));
        if (!byPath.containsKey(parent)) {
          throw ArgumentError.value(
            node,
            'nodes[$i]',
            'parent [$parent] is missing or comes later',
          );
        }
      }
      byPath[path] = node;
    }
    return FrameTree._(bounds, List.unmodifiable(nodes), byPath);
  }

  /// Reads the form [toJson] writes.
  factory FrameTree.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    final bounds = r.read('bounds', LogicalRect.fromJson);
    final nodes = r.readList('nodes', WidgetNode.fromJson);
    try {
      return FrameTree(bounds: bounds, nodes: nodes);
    } on ArgumentError catch (e) {
      throw FormatException('$context: ${e.name}: ${e.message}');
    }
  }

  FrameTree._(this.bounds, this.nodes, this._byPath);

  /// The frame's own rectangle: its logical size, at the origin.
  final LogicalRect bounds;

  /// Every recorded node, in pre-order. The first is the root, when there is one.
  final List<WidgetNode> nodes;

  final Map<String, WidgetNode> _byPath;

  /// The node at [path], or null.
  WidgetNode? at(IndexPath path) => _byPath[_pathKey(path)];

  /// The deepest node whose box contains the point ([x], [y]), or null when none does.
  ///
  /// This is what the pin tool snaps to. Among nodes of equal depth, the one painted last
  /// (later in pre-order) wins, because it is the one on top.
  WidgetNode? deepestAt(double x, double y) => allAt(x, y).firstOrNull;

  /// Every node whose box contains the point ([x], [y]), deepest first, and among equal depths
  /// the one painted last first. The first is [deepestAt].
  ///
  /// The canvas offers these when a reviewer clicks: the label under the cursor, and the card
  /// around it. Rejected: the deepest node's ancestors. A child can overflow its parent, and an
  /// ancestor that does not contain the point cannot be pinned at it.
  List<WidgetNode> allAt(double x, double y) {
    final at = [
      for (final (i, node) in nodes.indexed)
        if (_contains(node.rect, x, y)) (i, node),
    ];
    at.sort((a, b) {
      final depth = b.$2.indexPath.length.compareTo(a.$2.indexPath.length);
      return depth != 0 ? depth : b.$1.compareTo(a.$1);
    });
    return [for (final (_, node) in at) node];
  }

  /// Half open, so a point on the edge two boxes share is in one of them, not both.
  static bool _contains(LogicalRect r, double x, double y) =>
      x >= r.left && x < r.right && y >= r.top && y < r.bottom;

  /// The deepest node whose box holds all of [region], or null when none does.
  ///
  /// This names the culprit of a region that changed: the smallest widget that could have drawn
  /// all of it. Ties go to the later node, the one on top, the same as in [deepestAt].
  WidgetNode? deepestContaining(LogicalRect region) {
    WidgetNode? best;
    for (final node in nodes) {
      final r = node.rect;
      if (region.left < r.left ||
          region.top < r.top ||
          region.right > r.right ||
          region.bottom > r.bottom) {
        continue;
      }
      if (best == null || node.indexPath.length >= best.indexPath.length) best = node;
    }
    return best;
  }

  /// The JSON form [FrameTree.fromJson] reads.
  JsonMap toJson() => {
    'bounds': bounds.toJson(),
    'nodes': [for (final n in nodes) n.toJson()],
  };

  static String _pathKey(IndexPath path) => path.join('.');
}
