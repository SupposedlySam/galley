import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

/// The subjects of a realistic round: [count] screens in one scenario.
List<Map<String, String>> screens(int count) => [
  for (var i = 0; i < count; i++) {'scenario': 'offSeason', 'screen': 's$i'},
];

final roundZeroAxes = [
  FrameAxis('device', ['gesture', 'small']),
  FrameAxis('text-scale', ['1.0', '2.0']),
  FrameAxis('brightness', ['dark']),
  FrameAxis('locale', ['en']),
];

/// Every pair the plan must cover, as `factor=value` strings, where the subject is one factor.
Set<(String, String)> requiredPairs(List<Map<String, String>> subjects, List<FrameAxis> axes) {
  final factors = <List<String>>[
    [for (final s in subjects) 'subject=${FrameKey(s)}'],
    for (final a in axes) [for (final v in a.values) '${a.id}=$v'],
  ];
  return {
    for (var i = 0; i < factors.length; i++)
      for (var j = i + 1; j < factors.length; j++)
        for (final x in factors[i])
          for (final y in factors[j]) (x, y),
  };
}

/// The pairs [frames] cover, in the same form.
Set<(String, String)> coveredPairs(
  List<PlannedFrame> frames,
  List<Map<String, String>> subjects,
  List<FrameAxis> axes,
) {
  final covered = <(String, String)>{};
  for (final f in frames) {
    final subject = subjects.singleWhere((s) => s.entries.every((e) => f.key[e.key] == e.value));
    final row = ['subject=${FrameKey(subject)}', for (final a in axes) '${a.id}=${f.key[a.id]}'];
    for (var i = 0; i < row.length; i++) {
      for (var j = i + 1; j < row.length; j++) {
        covered.add((row[i], row[j]));
      }
    }
  }
  return covered;
}

void main() {
  const planner = FramePlanner();

  group('FramePlanner', () {
    test('covers every pair of values from two factors, the subject included', () {
      final subjects = screens(7);
      final frames = planner.plan(subjects: subjects, axes: roundZeroAxes);
      final required = requiredPairs(subjects, roundZeroAxes);
      // The denominator: 7×2 + 7×2 + 7 + 7 (subject × each axis) + 2×2 + 2 + 2 + 2 + 2 + 1 = 55.
      expect(required, hasLength(55));
      expect(coveredPairs(frames, subjects, roundZeroAxes), containsAll(required));
    });

    test('shows every screen on every device and at every text scale', () {
      final subjects = screens(5);
      final frames = planner.plan(subjects: subjects, axes: roundZeroAxes);
      for (final s in subjects) {
        final mine = frames.where((f) => f.key['screen'] == s['screen']);
        expect({for (final f in mine) f.key['device']}, {'gesture', 'small'}, reason: s['screen']);
        expect({for (final f in mine) f.key['text-scale']}, {'1.0', '2.0'}, reason: s['screen']);
      }
    });

    test('the essential set is each subject exactly once, on every reference value', () {
      final subjects = screens(6);
      final frames = planner.plan(subjects: subjects, axes: roundZeroAxes);
      final essential = frames.where((f) => f.essential).toList();
      expect(essential, hasLength(subjects.length));
      expect([for (final f in essential) f.key['screen']], [for (final s in subjects) s['screen']]);
      for (final f in essential) {
        for (final a in roundZeroAxes) {
          expect(f.key[a.id], a.reference, reason: '${f.key}');
        }
      }
      // And nothing else is marked essential, even when it lands on the reference values.
      expect(frames.where((f) => !f.essential), isNotEmpty);
      expect(frames.take(subjects.length).every((f) => f.essential), isTrue);
      expect(frames.skip(subjects.length).every((f) => !f.essential), isTrue);
    });

    test('no frame repeats', () {
      final frames = planner.plan(subjects: screens(9), axes: roundZeroAxes);
      expect({for (final f in frames) f.key}, hasLength(frames.length));
    });

    test('stays within 2 × subjects + 2 for Round 0, against a lower bound of 2 × subjects', () {
      // Each screen needs both devices, so at least two frames each. The greedy plan must not
      // wander far from that, or a round stops being "a few times the subject count".
      for (final n in [1, 2, 5, 20, 60]) {
        final frames = planner.plan(subjects: screens(n), axes: roundZeroAxes);
        expect(frames.length, inInclusiveRange(2 * n, 2 * n + 2), reason: '$n subjects');
      }
    });

    test('is exactly this for two screens, and a tie goes to the reference value', () {
      // Worked by hand. After the essential pair, the seed (a, small) takes 2.0, which covers
      // two pairs. The seed (b, small) ties between 1.0 and 2.0 at one pair each, and the tie
      // goes to the reference 1.0. That leaves one frame for (b, 2.0) and (gesture, 2.0).
      // Breaking ties the other way costs a sixth frame.
      final frames = planner.plan(
        subjects: [
          {'screen': 'a'},
          {'screen': 'b'},
        ],
        axes: [
          FrameAxis('device', ['gesture', 'small']),
          FrameAxis('text-scale', ['1.0', '2.0']),
        ],
      );
      expect(
        [for (final f in frames) '${f.key} ${f.essential}'],
        [
          'device=gesture;screen=a;text-scale=1.0 true',
          'device=gesture;screen=b;text-scale=1.0 true',
          'device=small;screen=a;text-scale=2.0 false',
          'device=small;screen=b;text-scale=1.0 false',
          'device=gesture;screen=b;text-scale=2.0 false',
        ],
      );
    });

    test('is deterministic', () {
      final a = planner.plan(subjects: screens(11), axes: roundZeroAxes);
      final b = planner.plan(subjects: screens(11), axes: roundZeroAxes);
      expect([for (final f in a) '${f.key}'], [for (final f in b) '${f.key}']);
    });

    test('covers three-valued axes too', () {
      final axes = [
        FrameAxis('device', ['a', 'b', 'c']),
        FrameAxis('text-scale', ['1.0', '1.3', '2.0']),
        FrameAxis('platform', ['android', 'ios']),
      ];
      final subjects = screens(4);
      final frames = planner.plan(subjects: subjects, axes: axes);
      expect(coveredPairs(frames, subjects, axes), containsAll(requiredPairs(subjects, axes)));
    });

    test('with no axes, the plan is the subjects', () {
      final frames = planner.plan(subjects: screens(3), axes: const []);
      expect(
        [for (final f in frames) '${f.key}'],
        [
          'scenario=offSeason;screen=s0',
          'scenario=offSeason;screen=s1',
          'scenario=offSeason;screen=s2',
        ],
      );
      expect(frames.every((f) => f.essential), isTrue);
    });

    test('subjects with different axes (a variant on one screen) are planned side by side', () {
      final subjects = [
        {'screen': 'home'},
        {'screen': 'card', 'variant': 'a'},
        {'screen': 'card', 'variant': 'b'},
      ];
      final frames = planner.plan(subjects: subjects, axes: roundZeroAxes);
      expect(
        frames.where((f) => f.key['variant'] == null && f.key['screen'] == 'home'),
        isNotEmpty,
      );
      expect(
        coveredPairs(frames, subjects, roundZeroAxes),
        containsAll(requiredPairs(subjects, roundZeroAxes)),
      );
    });

    test('refuses a plan it could not keep honest', () {
      expect(() => planner.plan(subjects: const [], axes: roundZeroAxes), throwsArgumentError);
      expect(
        () => planner.plan(
          subjects: [
            {'screen': 'a'},
            {'screen': 'a'},
          ],
          axes: roundZeroAxes,
        ),
        throwsArgumentError,
      );
      expect(
        () => planner.plan(
          subjects: [
            {'screen': 'a', 'device': 'small'},
          ],
          axes: roundZeroAxes,
        ),
        throwsArgumentError,
      );
      expect(
        () => planner.plan(
          subjects: screens(1),
          axes: [
            FrameAxis('device', ['a']),
            FrameAxis('device', ['b']),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('FrameAxis', () {
    test('the reference is the first value', () {
      expect(FrameAxis('device', ['gesture', 'small']).reference, 'gesture');
    });

    test('refuses an empty, repeated or unspellable axis', () {
      expect(() => FrameAxis('device', const []), throwsArgumentError);
      expect(() => FrameAxis('device', ['a', 'a']), throwsArgumentError);
      expect(() => FrameAxis('device', ['a b']), throwsArgumentError);
      expect(() => FrameAxis('de=vice', ['a']), throwsArgumentError);
    });
  });
}
