import 'anchor.dart';
import 'frame_key.dart';
import 'frame_tree.dart';
import 'json.dart';
import 'mark.dart';
import 'reanchor.dart';
import 'record.dart';

/// What a round's `index.json` says: the records it holds and how many frames were planned.
///
/// The packer writes it and everything downstream reads it (the CLI, the server), through this
/// one type (DESIGN D1: logic two layers need lives in the core, once).
final class RoundManifest {
  /// A manifest. Throws an [ArgumentError] if a record path repeats or there are more records
  /// than planned frames.
  RoundManifest({required List<String> frames, required this.planned})
    : frames = List.unmodifiable(frames) {
    if (planned < frames.length) {
      throw ArgumentError.value(planned, 'planned', 'is less than the ${frames.length} records');
    }
    final seen = <String>{};
    for (final f in frames) {
      if (!seen.add(f)) throw ArgumentError.value(f, 'frames', 'repeats');
    }
  }

  /// Reads the form [toJson] writes. This is the form the packer has written since 0.1.0.
  factory RoundManifest.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    final frames = [
      for (final (i, f) in r.list('frames').indexed)
        f is String ? f : throw FormatException('$context.frames[$i]: expected a string'),
    ];
    try {
      return RoundManifest(frames: frames, planned: r.integer('planned'));
    } on ArgumentError catch (e) {
      throw FormatException('$context.${e.name}: ${e.message}');
    }
  }

  /// Each frame's record, relative to the round directory, in render order.
  final List<String> frames;

  /// How many frames the plan asked for.
  final int planned;

  /// How many planned frames have no record: a filtered run (`--plain-name`) or one cut short.
  /// A round with some missing is not a whole round, and a reviewer is told so.
  int get missing => planned - frames.length;

  /// The JSON form [RoundManifest.fromJson] reads.
  JsonMap toJson() => {'frames': frames, 'planned': planned};
}

/// One frame of a round as carry-forward sees it: its record, and its tree if one was read.
final class RoundFrame {
  /// A frame. [tree] is null when the record names no tree, or when it does and the caller
  /// could not read it. Throws an [ArgumentError] for a tree the record says was never
  /// recorded: one of the two is wrong, and carry-forward cannot tell which.
  RoundFrame(this.record, this.tree) {
    if (tree != null && record.tree == null) {
      throw ArgumentError.value(record.key, 'tree', 'given for a record that names no tree');
    }
  }

  /// What the packer kept about the frame.
  final FrameRecord record;

  /// Its widget tree, or null.
  final FrameTree? tree;
}

/// Where a mark is in one round.
sealed class Placement {
  const Placement();

  /// Reads the form [toJson] writes.
  factory Placement.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    return switch (r.string('kind')) {
      'raised' => const Raised(),
      'located' => Reanchored(
        Located(
          node: r.read('node', WidgetNode.fromJson),
          decidedBy: _evidence(r, 'decided_by'),
          considered: r.integer('considered'),
          overlap: r.number('overlap'),
        ),
      ),
      'lost' => Reanchored(Lost(r.readList('candidates', WidgetNode.fromJson))),
      'unplaced' => Unplaced(r.string('reason')),
      'retired' => const Retired(),
      final other => throw FormatException('$context.kind: unknown placement "$other"'),
    };
  }

  /// The JSON form [Placement.fromJson] reads.
  JsonMap toJson();

  static Evidence _evidence(JsonReader r, String key) {
    final name = r.string(key);
    return Evidence.values.firstWhere(
      (e) => e.name == name,
      orElse: () => throw FormatException('${r.context}.$key: unknown evidence "$name"'),
    );
  }
}

/// The mark was raised in this round, on the widget it names. Nothing was looked up.
final class Raised extends Placement {
  /// Raised.
  const Raised();

  @override
  JsonMap toJson() => {'kind': 'raised'};
}

/// The mark's frame is in the round with a tree, and its widget was looked up: [result] says
/// whether it was found ([Located], Exact or Moved) or not ([Lost]).
final class Reanchored extends Placement {
  /// Looked up, with [result].
  const Reanchored(this.result);

  /// What the lookup found.
  final Reanchoring result;

  @override
  JsonMap toJson() => switch (result) {
    Located(:final node, :final decidedBy, :final considered, :final overlap) => {
      'kind': 'located',
      'node': node.toJson(),
      'decided_by': decidedBy.name,
      'considered': considered,
      'overlap': overlap,
    },
    Lost(:final candidates) => {
      'kind': 'lost',
      'candidates': [for (final n in candidates) n.toJson()],
    },
  };
}

/// The mark's frame is in the round, but whether its widget is there cannot be judged, for
/// [reason]: the frame errored, or has no tree.
///
/// Kept apart from [Lost] on purpose. Lost says "the widget is not there", which is a claim
/// about the app; an error frame says nothing about the app's widgets, and a frame that landed
/// on the wrong screen would make every mark Lost for a reason that is not theirs (DESIGN.md,
/// "An unknown is never nothing").
final class Unplaced extends Placement {
  /// Not judged, for [reason].
  const Unplaced(this.reason);

  /// Why it could not be judged.
  final String reason;

  @override
  JsonMap toJson() => {'kind': 'unplaced', 'reason': reason};
}

/// The mark's frame is not in the round: the screen, state or axis value was removed. The mark
/// and its history are kept, and it is placed again in any later round that has the frame
/// (DESIGN D6).
final class Retired extends Placement {
  /// Retired.
  const Retired();

  @override
  JsonMap toJson() => {'kind': 'retired'};
}

/// A mark, where it is in one round, and the anchor the next round looks for.
final class Carried {
  /// [mark] at [placement], to be looked for next round at [anchor].
  const Carried(this.mark, this.placement, this.anchor);

  /// A mark in the round it was raised in.
  Carried.raised(this.mark) : placement = const Raised(), anchor = mark.anchor;

  /// Reads the form [toJson] writes, finding the mark by its id with [markOf].
  ///
  /// A placement names its mark by id and does not copy it: the mark's history grows after the
  /// round, and a copy kept per round would go stale. A placement whose mark [markOf] does not
  /// have is refused.
  factory Carried.fromJson(Object? json, String context, Mark? Function(String id) markOf) {
    final r = JsonReader(json, context);
    final id = r.string('mark');
    final mark = markOf(id);
    if (mark == null) throw FormatException('$context.mark: no mark "$id"');
    return Carried(
      mark,
      r.read('placement', Placement.fromJson),
      r.read('anchor', Anchor.fromJson),
    );
  }

  /// The mark, unchanged. Its own [Mark.anchor] stays the anchor as raised.
  final Mark mark;

  /// Where it is in this round.
  final Placement placement;

  /// What the next round looks for: the widget as it was last found.
  ///
  /// The next round compares with where the widget was last seen, not where it was raised, so
  /// Moved means "moved since the last round". A widget that moved once is Moved once and then
  /// Exact. Rejected: always looking from the raised anchor. A widget that moved once would be
  /// Moved in every later round, and a flag that never clears is one reviewers learn to ignore.
  /// Its evidence also goes stale: a call site shifts with each edit above it, and the last
  /// found node has the current one.
  ///
  /// When the widget is not found ([Lost], [Unplaced], [Retired]) this is the last anchor that
  /// was, so a later round that has it again can still find it.
  final Anchor anchor;

  /// The JSON form [Carried.fromJson] reads.
  JsonMap toJson() => {'mark': mark.id, 'placement': placement.toJson(), 'anchor': anchor.toJson()};
}

/// A round's frames, for carrying marks into it.
///
/// Pure: the caller reads the records and trees, so the CLI, the server and a test can all
/// carry marks the same way.
final class Round {
  /// A round of [frames]. Throws an [ArgumentError] if two share a key.
  Round(List<RoundFrame> frames, {this.reanchorer = const Reanchorer()})
    : _byKey = {for (final f in frames) f.record.key: f} {
    if (_byKey.length != frames.length) {
      final seen = <FrameKey>{};
      final repeat = frames.firstWhere((f) => !seen.add(f.record.key));
      throw ArgumentError.value(repeat.record.key, 'frames', 'has two frames with this key');
    }
  }

  /// How marks are looked up in a frame's tree.
  final Reanchorer reanchorer;

  final Map<FrameKey, RoundFrame> _byKey;

  /// The frame with [key], or null when the round does not have it.
  RoundFrame? frame(FrameKey key) => _byKey[key];

  /// [previous] carried into this round.
  Carried carry(Carried previous) {
    final mark = previous.mark;
    Carried keep(Placement p) => Carried(mark, p, previous.anchor);

    final frame = _byKey[mark.frame];
    if (frame == null) return keep(const Retired());
    final record = frame.record;
    if (record.status == FrameStatus.error) {
      return keep(Unplaced('the frame is an error: ${record.errors.join('; ')}'));
    }
    final tree = frame.tree;
    if (tree == null) {
      return keep(
        Unplaced(
          record.tree == null
              ? 'no tree was recorded for the frame'
              : 'the frame\'s tree ${record.tree} was not read',
        ),
      );
    }
    final result = reanchorer.locate(previous.anchor, tree);
    return Carried(
      mark,
      Reanchored(result),
      result is Located ? Anchor.of(result.node) : previous.anchor,
    );
  }

  /// Every mark in [previous] carried into this round, in the same order: one result per mark,
  /// whatever its status. A verified mark is carried too, since nothing is erased, and a
  /// reviewer may want to see that a fix still holds.
  List<Carried> carryAll(List<Carried> previous) => [for (final c in previous) carry(c)];
}

/// Where every mark is in one round: one [Carried] per mark, stored as the round's
/// `placements.json`.
///
/// Kept per round, not on the mark, because a mark has a placement in every round it was
/// carried into, and the next round is carried from the last one.
final class Placements {
  /// [carried], at most one per mark. Throws an [ArgumentError] if a mark repeats: a mark is in
  /// one place in a round, and two entries would leave the next round to guess which.
  Placements(List<Carried> carried) : carried = List.unmodifiable(carried) {
    for (final c in carried) {
      if (!identical(_byId.putIfAbsent(c.mark.id, () => c), c)) {
        throw ArgumentError.value(c.mark.id, 'carried', 'places this mark twice');
      }
    }
  }

  /// Reads the form [toJson] writes, finding each mark with [markOf] (see [Carried.fromJson]).
  factory Placements.fromJson(Object? json, String context, Mark? Function(String id) markOf) {
    final r = JsonReader(json, context);
    final carried = r.readList('placements', (j, c) => Carried.fromJson(j, c, markOf));
    try {
      return Placements(carried);
    } on ArgumentError catch (e) {
      throw FormatException('$context.placements: mark "${e.invalidValue}" ${e.message}');
    }
  }

  /// Every placement, in the order they were made.
  final List<Carried> carried;

  final _byId = <String, Carried>{};

  /// Where the mark with [id] is, or null when this round does not place it.
  Carried? of(String id) => _byId[id];

  /// These placements with [more] added. Throws an [ArgumentError] if one places a mark
  /// already placed.
  Placements plus(List<Carried> more) => Placements([...carried, ...more]);

  /// The JSON form [Placements.fromJson] reads.
  JsonMap toJson() => {
    'placements': [for (final c in carried) c.toJson()],
  };
}
