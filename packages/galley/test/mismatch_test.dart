import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:galley/src/capture.dart';
import 'package:galley/src/packer.dart';
import 'package:galley/src/render.dart';
import 'package:galley_core/galley_core.dart';

/// A 4 × 4 frame at ratio 1, all black, with [lit] pixels white.
FramePixels _pixels({List<(int, int)> lit = const []}) {
  final rgba = Uint8List(4 * 4 * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 255;
  }
  for (final (x, y) in lit) {
    final i = (y * 4 + x) * 4;
    rgba[i] = rgba[i + 1] = rgba[i + 2] = 255;
  }
  return FramePixels(width: 4, height: 4, png: Uint8List(0), rgba: rgba);
}

FrameTree _tree({String label = 'a'}) => FrameTree(
  bounds: const LogicalRect(0, 0, 4, 4),
  nodes: [
    WidgetNode(indexPath: const [], type: 'Frame', rect: const LogicalRect(0, 0, 4, 4)),
    WidgetNode(indexPath: const [0], type: 'Card', rect: const LogicalRect(0, 0, 4, 2)),
    WidgetNode(
      indexPath: const [0, 0],
      type: 'Text',
      rect: const LogicalRect(2, 0, 2, 2),
      semanticsLabel: label,
    ),
  ],
);

RenderOutcome _outcome(FramePixels pixels, FrameTree tree) => RenderOutcome(
  errors: const [],
  frozen: false,
  landing: LandedAt(Uri.parse('/')),
  findings: const [],
  tree: tree,
  pixels: pixels,
);

void main() {
  group('digest', () {
    // Computed apart from the code under test: Python's hashlib over the size, big-endian, and
    // the RGBA bytes.
    test('is the SHA-256 of the width, the height and the RGBA bytes', () {
      expect(_pixels().digest, 'ff6ef4cfe219a8273e96da4c1f712dbae8845fee5ea60a02f81d868da9579ad8');
      final other = FramePixels(width: 8, height: 2, png: Uint8List(0), rgba: _pixels().rgba);
      expect(
        other.digest,
        'cc0614d3fdd5771b88c9ac6391a672869afca95225022821daf2d5a9b07c9615',
        reason: 'the same bytes at another size are another image',
      );
    });

    test('changes with one pixel, and not with the PNG', () {
      expect(_pixels(lit: [(1, 2)]).digest, isNot(_pixels().digest));
      final png = FramePixels(width: 4, height: 4, png: Uint8List(9), rgba: _pixels().rgba);
      expect(png.digest, _pixels().digest);
    });
  });

  test('identical renders do not mismatch', () {
    expect(mismatchOf(_outcome(_pixels(), _tree()), _outcome(_pixels(), _tree()), 1), isNull);
  });

  test('a pixel change names its region and the deepest widget holding all of it', () {
    final m = mismatchOf(
      _outcome(_pixels(), _tree()),
      _outcome(_pixels(lit: [(3, 1)]), _tree()),
      1,
    );
    expect(m, contains('(3.0, 1.0) 1.0×1.0'));
    expect(m, contains('culprit: Text at 0.0'));
  });

  test('a region wider than the Text is pinned on its parent, not on the Text', () {
    final m = mismatchOf(
      _outcome(_pixels(), _tree()),
      _outcome(_pixels(lit: [(1, 0), (3, 1)]), _tree()),
      1,
    );
    expect(m, contains('culprit: Card at 0'));
  });

  test('same pixels, different tree: the node and the field that differ are named', () {
    final m = mismatchOf(
      _outcome(_pixels(), _tree(label: 'build 1')),
      _outcome(_pixels(), _tree(label: 'build 2')),
      1,
    );
    expect(
      m,
      'recorded different widgets twice at Text at 0.0: semantics "build 1" then "build 2"',
    );
  });

  test('a size change is a mismatch, not a crash', () {
    final big = FramePixels(width: 8, height: 4, png: Uint8List(0), rgba: Uint8List(8 * 4 * 4));
    expect(
      mismatchOf(_outcome(_pixels(), _tree()), _outcome(big, _tree()), 1),
      contains('4×4 then 8×4'),
    );
  });
}
