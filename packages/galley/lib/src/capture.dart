import 'dart:developer' as developer;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:galley_core/galley_core.dart';

/// Records a mounted frame's widgets as a [FrameTree] (DESIGN D4).
///
/// **Which widgets.** Only those constructed in the app's own source: widgets whose creation
/// location is under one of [roots]. That is the widget inspector's "summary tree", the widgets a
/// developer wrote, and it is what a designer means by "this button".
///
/// Rejected: every element that owns a box. Then the deepest node under a pin is a framework
/// `RichText` or `_InkFeatures`. Its creation location is inside Flutter, shared by every `Text`
/// on the screen, so it anchors no better than an index path.
///
/// **The root** is synthetic: a `Frame` node covering the whole view, with path `[]`. The app's
/// outermost recorded widgets are its children. A pin on bare background anchors to it.
final class TreeRecorder {
  /// A recorder that keeps widgets constructed under [roots], which are absolute directory
  /// paths. Packages in the pub cache and the Flutter SDK are never kept, even when a root
  /// contains them.
  TreeRecorder({required List<String> roots}) : roots = List.unmodifiable(roots);

  /// The source directories whose widgets count as the app's.
  final List<String> roots;

  /// The type name of the synthetic root.
  static const rootType = 'Frame';

  /// The tree of [tester]'s current frame.
  ///
  /// Throws a [StateError] when widget-creation tracking is off. Without it no widget has a
  /// location, the tree would be the root alone, and an empty tree must never read as a screen
  /// with nothing on it.
  FrameTree record(WidgetTester tester) {
    if (!WidgetInspectorService.instance.isWidgetCreationTracked()) {
      throw StateError(
        'widget creation tracking is off, so Galley cannot tell which widgets are the app\'s. '
        'Run under `flutter test` without --no-track-widget-creation.',
      );
    }
    final view = tester.view;
    final bounds = LogicalRect(
      0,
      0,
      view.physicalSize.width / view.devicePixelRatio,
      view.physicalSize.height / view.devicePixelRatio,
    );
    final nodes = <WidgetNode>[WidgetNode(indexPath: const [], type: rootType, rect: bounds)];
    final childCounts = <String, int>{};

    void visit(Element element, List<int> parentPath) {
      var path = parentPath;
      final node = _nodeFor(element, parentPath, childCounts);
      if (node != null) {
        nodes.add(node);
        path = node.indexPath;
      }
      element.visitChildElements((child) => visit(child, path));
    }

    final root = tester.binding.rootElement;
    if (root != null) visit(root, const []);
    return FrameTree(bounds: bounds, nodes: nodes);
  }

  WidgetNode? _nodeFor(Element element, List<int> parentPath, Map<String, int> childCounts) {
    final location = developer.CreationLocation.of(element.widget);
    if (location == null || !_isAppSource(location.file)) return null;
    final box = element.renderObject;
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;

    final parentKey = parentPath.join('.');
    final index = childCounts[parentKey] ?? 0;
    childCounts[parentKey] = index + 1;
    final rect = MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
    return WidgetNode(
      indexPath: [...parentPath, index],
      type: element.widget.runtimeType.toString(),
      rect: LogicalRect(rect.left, rect.top, rect.width, rect.height),
      key: stableKey(element.widget.key),
      semanticsLabel: _semanticsLabel(box),
      location: SourceLocation(location.file, location.line, location.column),
    );
  }

  bool _isAppSource(String file) {
    final path = file.startsWith('file://') ? Uri.parse(file).toFilePath() : file;
    if (path.contains('/.pub-cache/') || path.contains('/packages/flutter/lib/')) return false;
    return roots.any((r) => path.startsWith(r.endsWith('/') ? r : '$r/'));
  }

  /// The key as a string that is the same in every run, or null.
  ///
  /// Only a [ValueKey] qualifies. A [GlobalKey], [ObjectKey] or [UniqueKey] prints an identity
  /// hash, which differs between the two renders of one frame. Recording it would fail every
  /// such frame as non-deterministic and anchor no mark across rounds.
  static String? stableKey(Key? key) => key is ValueKey ? key.toString() : null;

  /// The label of the semantics node [box] contributes to: its own, or its nearest ancestor's.
  static String? _semanticsLabel(RenderObject box) {
    RenderObject? r = box;
    while (r != null) {
      final node = r.debugSemantics;
      if (node != null) {
        final label = node.label;
        return label.isEmpty ? null : label;
      }
      r = r.parent;
    }
    return null;
  }
}

/// The pixels of a frame: PNG for the record, raw RGBA for comparing two renders.
final class FramePixels {
  /// Pixels of a [width] × [height] image.
  const FramePixels({
    required this.width,
    required this.height,
    required this.png,
    required this.rgba,
  });

  /// Width, in physical pixels.
  final int width;

  /// Height, in physical pixels.
  final int height;

  /// The image, PNG encoded.
  final Uint8List png;

  /// The image, four bytes a pixel, row by row.
  final Uint8List rgba;

  /// The smallest rectangle, in logical pixels at [pixelRatio], holding every pixel that
  /// differs from [other]. Null when none does. Throws an [ArgumentError] when the sizes differ.
  LogicalRect? diffBounds(FramePixels other, double pixelRatio) {
    if (other.width != width || other.height != height) {
      throw ArgumentError('cannot diff $width×$height against ${other.width}×${other.height}');
    }
    var minX = width, minY = height, maxX = -1, maxY = -1;
    for (var y = 0; y < height; y++) {
      final row = y * width * 4;
      for (var x = 0; x < width; x++) {
        final i = row + x * 4;
        if (rgba[i] != other.rgba[i] ||
            rgba[i + 1] != other.rgba[i + 1] ||
            rgba[i + 2] != other.rgba[i + 2] ||
            rgba[i + 3] != other.rgba[i + 3]) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < 0) return null;
    return LogicalRect(
      minX / pixelRatio,
      minY / pixelRatio,
      (maxX - minX + 1) / pixelRatio,
      (maxY - minY + 1) / pixelRatio,
    );
  }

  /// How many pixels are not fully opaque.
  ///
  /// An app paints every pixel of a real screen or the window background shows through, black
  /// or white depending on the device's theme. A frame with unpainted pixels would show whatever
  /// the viewer puts behind it. So Galley says so instead of picking a color.
  int get unpainted {
    var count = 0;
    for (var i = 3; i < rgba.length; i += 4) {
      if (rgba[i] != 255) count++;
    }
    return count;
  }

  /// Captures the whole view of [tester], as the screen shows it.
  ///
  /// The render view's layer is drawn at its physical size. Encoding needs real async work, so
  /// it runs in [WidgetTester.runAsync]: inside fake async the image futures never complete.
  static Future<FramePixels> capture(WidgetTester tester) async {
    final renderView = tester.binding.renderViews.single;
    final layer = renderView.debugLayer! as OffsetLayer;
    final pixels = await tester.runAsync(() async {
      final image = await layer.toImage(renderView.paintBounds);
      try {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final rgba = await image.toByteData();
        return FramePixels(
          width: image.width,
          height: image.height,
          png: png!.buffer.asUint8List(),
          rgba: rgba!.buffer.asUint8List(),
        );
      } finally {
        image.dispose();
      }
    });
    if (pixels == null) throw StateError('capturing the frame did not complete');
    return pixels;
  }
}
