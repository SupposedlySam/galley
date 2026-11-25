import 'frame_key.dart';

/// One dimension a frame varies along, such as `device` or `text-scale`, with the values the app
/// declared for it.
///
/// The first value is the **reference**: the one every subject is shown in by default (the
/// essential set, [FramePlanner]). With Galley's default axes that is the gesture phone at 1.0×
/// text.
final class FrameAxis {
  /// An axis from its id and values, reference first. Throws an [ArgumentError] if an id is not a
  /// valid [FrameKey] id, [values] is empty, or a value repeats.
  FrameAxis(this.id, List<String> values) : values = List.unmodifiable(values) {
    if (!FrameKey.isValidId(id)) throw ArgumentError.value(id, 'id', 'not a valid axis id');
    if (values.isEmpty) {
      throw ArgumentError.value(values, 'values', 'axis "$id" needs at least one value');
    }
    final seen = <String>{};
    for (final value in values) {
      if (!FrameKey.isValidId(value)) {
        throw ArgumentError.value(value, 'values', 'not a valid value id on axis "$id"');
      }
      if (!seen.add(value)) {
        throw ArgumentError.value(value, 'values', 'repeats on axis "$id"');
      }
    }
  }

  /// The axis id, as it appears in a [FrameKey].
  final String id;

  /// Its values, reference first.
  final List<String> values;

  /// The value a subject takes on this axis in the essential set.
  String get reference => values.first;
}

/// A frame the plan asks for.
final class PlannedFrame {
  /// A planned frame.
  const PlannedFrame(this.key, {required this.essential});

  /// Its key: the subject's axes plus one value on every [FrameAxis].
  final FrameKey key;

  /// Whether it is the subject on every axis's reference value. These are what the canvas shows
  /// by default; the others are there when a reviewer expands a subject (pitch § The explosion).
  final bool essential;
}

/// Chooses which frames a round renders, so that the round stays small and still shows every
/// subject on every axis value.
///
/// A **subject** is what a frame shows before the axes are applied: its scenario, screen and
/// variant, as a partial key. The app's applicability is already in the subjects (a variant only
/// multiplies its own screen), so the planner does not need to know about it.
///
/// The plan is:
/// 1. **The essential set:** every subject on the reference value of every axis.
/// 2. **Pairwise cover:** frames added until every pair of values from two different factors
///    appears in at least one frame. The factors are the subject (as one factor) and each axis.
///
/// Treating the subject as a factor is the choice that matters. It means every screen is seen on
/// every device and at every text scale, and every device meets every text scale somewhere.
/// Rejected: covering pairs among the axes only. That shows the small phone at 2.0× on *one*
/// screen and calls the job done, which is not a review anyone would sign.
///
/// Rejected: the full cartesian product. A mid-sized app's 60 screens × 12 states × 4 devices × 2
/// themes × 3 text scales × 2 locales is about 35,000 frames; pairwise cover is a few times the
/// subject count.
///
/// The construction is greedy (in the AETG family) and fully deterministic. The same input gives
/// the same frames in the same order, so a round's frame list does not churn between packs.
final class FramePlanner {
  /// The planner.
  const FramePlanner();

  /// The frames for [subjects] across [axes].
  ///
  /// Throws an [ArgumentError] if [subjects] is empty, two subjects are the same, two axes share an
  /// id, or a subject already sets an axis that [axes] also varies.
  List<PlannedFrame> plan({
    required List<Map<String, String>> subjects,
    required List<FrameAxis> axes,
  }) {
    _check(subjects, axes);
    // Factor 0 is the subject; factor i > 0 is axes[i - 1]. A row is one value index per factor.
    final sizes = [subjects.length, for (final a in axes) a.values.length];
    final uncovered = _allPairs(sizes);
    final rows = <List<int>>[];

    void add(List<int> row) {
      rows.add(row);
      for (var i = 0; i < row.length; i++) {
        for (var j = i + 1; j < row.length; j++) {
          uncovered.remove(_Pair(i, row[i], j, row[j]));
        }
      }
    }

    for (var s = 0; s < subjects.length; s++) {
      add([s, for (final _ in axes) 0]);
    }
    final essentialCount = rows.length;

    while (uncovered.isNotEmpty) {
      add(_rowFor(uncovered.first, sizes, uncovered));
    }

    return [
      for (final (r, row) in rows.indexed)
        PlannedFrame(
          FrameKey({
            ...subjects[row[0]],
            for (final (a, axis) in axes.indexed) axis.id: axis.values[row[a + 1]],
          }),
          essential: r < essentialCount,
        ),
    ];
  }

  /// A row that covers [seed] and, value by value, as many other [uncovered] pairs as it can.
  ///
  /// Each remaining factor takes the value that covers the most uncovered pairs with the factors
  /// already fixed. A tie goes to the lowest index, so the reference value wins one. Every row
  /// covers at least [seed], so the loop that calls this ends, and no row repeats an earlier one.
  static List<int> _rowFor(_Pair seed, List<int> sizes, Set<_Pair> uncovered) {
    final row = List<int?>.filled(sizes.length, null);
    row[seed.i] = seed.a;
    row[seed.j] = seed.b;
    for (var f = 0; f < sizes.length; f++) {
      if (row[f] != null) continue;
      var best = 0;
      var bestGain = -1;
      for (var v = 0; v < sizes[f]; v++) {
        var gain = 0;
        for (var g = 0; g < sizes.length; g++) {
          final fixed = row[g];
          if (fixed == null) continue;
          final pair = g < f ? _Pair(g, fixed, f, v) : _Pair(f, v, g, fixed);
          if (uncovered.contains(pair)) gain++;
        }
        if (gain > bestGain) {
          best = v;
          bestGain = gain;
        }
      }
      row[f] = best;
    }
    return [for (final v in row) v!];
  }

  /// Every pair of values from two different factors, in a fixed order.
  ///
  /// The order is what makes the plan deterministic: [plan] seeds each new row with the first
  /// pair still uncovered. A set literal is a [LinkedHashSet], which keeps insertion order.
  static Set<_Pair> _allPairs(List<int> sizes) {
    final pairs = <_Pair>{};
    for (var i = 0; i < sizes.length; i++) {
      for (var j = i + 1; j < sizes.length; j++) {
        for (var a = 0; a < sizes[i]; a++) {
          for (var b = 0; b < sizes[j]; b++) {
            pairs.add(_Pair(i, a, j, b));
          }
        }
      }
    }
    return pairs;
  }

  static void _check(List<Map<String, String>> subjects, List<FrameAxis> axes) {
    if (subjects.isEmpty) {
      throw ArgumentError.value(subjects, 'subjects', 'a plan needs at least one subject');
    }
    final axisIds = <String>{};
    for (final axis in axes) {
      if (!axisIds.add(axis.id)) throw ArgumentError.value(axis.id, 'axes', 'repeats');
    }
    final seen = <FrameKey>{};
    for (final (i, subject) in subjects.indexed) {
      final clash = subject.keys.where(axisIds.contains);
      if (clash.isNotEmpty) {
        throw ArgumentError.value(
          subject,
          'subjects[$i]',
          'sets ${clash.join(', ')}, which the axes also vary',
        );
      }
      if (!seen.add(FrameKey(subject))) {
        throw ArgumentError.value(subject, 'subjects[$i]', 'repeats an earlier subject');
      }
    }
  }
}

/// Value [a] of factor [i] together with value [b] of factor [j], where [i] < [j].
final class _Pair {
  const _Pair(this.i, this.a, this.j, this.b);

  final int i;
  final int a;
  final int j;
  final int b;

  @override
  bool operator ==(Object other) =>
      other is _Pair && other.i == i && other.a == a && other.j == j && other.b == b;

  @override
  int get hashCode => Object.hash(i, a, j, b);
}
