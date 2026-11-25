import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

void main() {
  const a = LogicalRect(0, 0, 100, 100);

  test('overlap is 1 for the same rect and 0 for disjoint ones', () {
    expect(a.overlapWith(a), 1);
    expect(a.overlapWith(const LogicalRect(200, 0, 100, 100)), 0);
  });

  test('touching edges do not overlap', () {
    expect(a.intersection(const LogicalRect(100, 0, 10, 10)), isNull);
  });

  test('half-shifted is a third', () {
    // Overlap 50×100, union 150×100.
    expect(a.overlapWith(const LogicalRect(50, 0, 100, 100)), closeTo(1 / 3, 1e-12));
  });

  test('empty rects are identical only at the same place', () {
    const e = LogicalRect(5, 5, 0, 0);
    expect(e.overlapWith(e), 1);
    expect(e.overlapWith(const LogicalRect(6, 5, 0, 0)), 0);
    expect(e.overlapWith(a), 0);
  });

  test('json refuses a negative size and round-trips', () {
    expect(
      () => LogicalRect.fromJson({'left': 0, 'top': 0, 'width': -1, 'height': 1}, 'r'),
      throwsFormatException,
    );
    expect(LogicalRect.fromJson(a.toJson(), 'r'), a);
  });
}
