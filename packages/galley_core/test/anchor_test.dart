import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

import 'trees.dart';

void main() {
  test('an anchor copies every field of its node and round-trips', () {
    final n = node(
      [0, 3],
      'Text',
      rect: const LogicalRect(1, 2, 3, 4),
      key: 'k',
      label: 'L',
      at: loc(7, 9),
    );
    final a = Anchor.of(n);
    expect(a.toJson(), {...n.toJson()});
    expect(Anchor.fromJson(a.toJson(), 'a').toJson(), a.toJson());
  });

  test('optional fields are omitted, not written as null', () {
    final json = Anchor.of(node([], 'App')).toJson();
    expect(json.keys, unorderedEquals(['type', 'path', 'rect']));
  });

  group('pin offset', () {
    const rect = LogicalRect(100, 50, 200, 100);

    test('names the same point after the widget grows', () {
      final pin = PinOffset.within(rect, 150, 75);
      expect((pin.dx, pin.dy), (0.25, 0.25));
      expect(pin.pointIn(const LogicalRect(0, 0, 400, 200)), (100.0, 50.0));
    });

    test('clamps a point outside the widget to its edge', () {
      final pin = PinOffset.within(rect, 0, 1000);
      expect((pin.dx, pin.dy), (0.0, 1.0));
    });

    test('a zero-size widget pins at its origin', () {
      final pin = PinOffset.within(const LogicalRect(5, 5, 0, 0), 9, 9);
      expect((pin.dx, pin.dy), (0.0, 0.0));
    });

    test('json refuses a fraction outside 0..1', () {
      expect(() => PinOffset.fromJson({'dx': 1.5, 'dy': 0}, 'pin'), throwsFormatException);
      expect(PinOffset.fromJson({'dx': 1, 'dy': 0}, 'pin').dx, 1);
    });
  });
}
