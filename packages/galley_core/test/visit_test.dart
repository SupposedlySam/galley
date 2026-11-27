import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

void main() {
  group('a visit', () {
    test('a first visit has nothing before it; each newer round moves the last one back', () {
      final first = visitTo(2, null);
      expect((first.latest, first.before), (2, null));
      final second = visitTo(3, first);
      expect((second.latest, second.before), (3, 2));
      // Rounds skipped, as when a reviewer was away for two: the one they saw is kept.
      final third = visitTo(6, second);
      expect((third.latest, third.before), (6, 3));
    });

    test('a reload, or an older round opened, leaves it as it was', () {
      final v = visitTo(3, visitTo(2, null));
      for (final n in [3, 2, 1]) {
        final again = visitTo(n, v);
        expect((again.latest, again.before), (3, 2), reason: 'round $n');
      }
    });

    test('reads back what it writes, and refuses rounds that cannot be', () {
      for (final v in [Visit(1), Visit(4, before: 2)]) {
        final back = Visit.fromJson(v.toJson(), 'visit');
        expect((back.latest, back.before), (v.latest, v.before));
      }
      expect(Visit(1).toJson(), {'latest': 1});
      expect(Visit(4, before: 2).toJson(), {'latest': 4, 'before': 2});
      for (final bad in [
        {'latest': 0},
        {'latest': 3, 'before': 3},
        {'latest': 3, 'before': 4},
        {'latest': 3, 'before': 0},
        {'before': 1},
        {'latest': '3'},
      ]) {
        expect(
          () => Visit.fromJson(bad, 'visits.rae'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('visits'))),
          reason: '$bad',
        );
      }
    });
  });
}
