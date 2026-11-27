import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

import 'trees.dart';

void main() {
  // A card at (0, 0), 200 by 100, with a label at (10, 10), 50 by 20, inside it.
  final t = tree([
    root,
    node([0], 'Card', rect: const LogicalRect(0, 0, 200, 100)),
    node([0, 0], 'Label', rect: const LogicalRect(10, 10, 50, 20)),
  ]);

  (String, double, double) pinned(PinTarget target) {
    final (:node, :pin) = target.resolve(t);
    return (node.type, pin.dx, pin.dy);
  }

  group('AtPoint', () {
    test('names the deepest widget there, pinned at the point', () {
      expect(pinned(const AtPoint(20, 15)), ('Label', 0.2, 0.25));
      expect(pinned(const AtPoint(100, 50)), ('Card', 0.5, 0.5));
      expect(pinned(const AtPoint(300, 400)), ('App', 0.75, 0.5));
    });

    test('names nothing outside every widget, and says where it looked', () {
      expect(
        () => const AtPoint(500, 50).resolve(t),
        throwsA(isA<PinMissed>().having((e) => e.message, 'message', 'no widget at 500.0,50.0')),
      );
    });
  });

  group('AtNode', () {
    test('alone, pins the widget at its centre', () {
      expect(pinned(const AtNode([0])), ('Card', 0.5, 0.5));
      expect(pinned(const AtNode([0, 0])), ('Label', 0.5, 0.5));
    });

    test('with a point, pins that widget there, even over a deeper one', () {
      // The label is under (20, 15); the card was chosen.
      expect(pinned(const AtNode([0], at: (x: 20, y: 15))), ('Card', 0.1, 0.15));
    });

    test('with a point on an edge, the edge is on the widget', () {
      expect(pinned(const AtNode([0], at: (x: 200, y: 100))), ('Card', 1.0, 1.0));
      expect(pinned(const AtNode([0], at: (x: 0, y: 0))), ('Card', 0.0, 0.0));
    });

    test('with a point past any edge, is refused naming the widget', () {
      for (final (x, y) in [(201.0, 50.0), (100.0, 101.0), (-1.0, 50.0), (100.0, -1.0)]) {
        expect(
          () => AtNode(const [0], at: (x: x, y: y)).resolve(t),
          throwsA(
            isA<PinMissed>().having((e) => e.message, 'message', '0 at $x,$y is outside Card'),
          ),
          reason: '$x,$y',
        );
      }
    });

    test('names nothing at a path the tree does not have', () {
      expect(
        () => const AtNode([7]).resolve(t),
        throwsA(isA<PinMissed>().having((e) => e.message, 'message', 'no widget at 7')),
      );
    });
  });

  group('as JSON', () {
    test('is read back as the same target', () {
      for (final target in [
        const AtPoint(20, 15),
        const AtNode([0, 0]),
        const AtNode([0], at: (x: 20, y: 15)),
      ]) {
        final back = PinTarget.fromJson(target.toJson(), 'request');
        expect('$back', '$target');
        expect(back.runtimeType, target.runtimeType);
        expect(pinned(back), pinned(target));
      }
    });

    test('names the fields it takes when given neither', () {
      expect(
        () => PinTarget.fromJson({'note': 'x'}, 'request'),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', startsWith('request: give')),
        ),
      );
    });

    test("says a pin's {dx, dy} is not a point, rather than reading it as one", () {
      expect(
        () => PinTarget.fromJson({
          'node': [0],
          'at': {'dx': 0.5, 'dy': 0.5},
        }, 'request'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            startsWith('request.at: [x, y]'),
          ),
        ),
      );
    });
  });
}
