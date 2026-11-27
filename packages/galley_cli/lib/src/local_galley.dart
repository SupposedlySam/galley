import 'dart:io';

import 'package:galley_core/galley_core.dart';

import 'galley_directory.dart';

/// What a person or an agent does to a local galley: raise a mark, record an event on one, and
/// list them as work items. The `galley` commands and `galley serve` both call this, so a mark
/// raised from the canvas is the same as one raised from the command line.
final class LocalGalley {
  /// The galley in [directory], with [now] for event times and [newId] for new marks.
  LocalGalley(this.directory, {required this.now, required this.newId});

  /// Where the galley is kept.
  final GalleyDirectory directory;

  /// The time an event is recorded at.
  final DateTime Function() now;

  /// A new mark's id.
  final String Function() newId;

  /// The latest finished round. Refused when there is none.
  int latestRound() {
    final rounds = directory.rounds();
    if (rounds.isEmpty) throw Refused('${directory.path} has no rounds yet: run `galley pack`');
    return rounds.last;
  }

  /// Raises a mark on the widget at [target] in [frame] of the latest round, and places it
  /// there as Raised. Returns the mark and the widget it was pinned to.
  ///
  /// Everything is checked before an id is taken or a file written, so a refused mark leaves
  /// no trace.
  Future<({Mark mark, WidgetNode node, int round})> raise({
    required FrameKey frame,
    required PinTarget target,
    required String note,
    required String by,
  }) async {
    final n = latestRound();
    final found = (await directory.readRound(n)).round.frame(frame);
    if (found == null) throw Refused('round $n has no frame $frame');
    final tree = found.tree;
    if (tree == null) throw Refused('frame $frame in round $n has no tree to pin a widget of');
    final (node, pin) = switch (target) {
      AtPoint(:final x, :final y) => switch (tree.deepestAt(x, y)) {
        final node? => (node, PinOffset.within(node.rect, x, y)),
        null => (null, null),
      },
      AtNode(:final path) => (tree.at(path), const PinOffset(0.5, 0.5)),
    };
    if (node == null || pin == null) throw Refused('no widget at $target in frame $frame');
    if (note.trim().isEmpty) throw const Refused('a mark says what is wrong');
    if (by.trim().isEmpty) throw const Refused('a mark says who raised it');

    final mark = Mark(
      id: newId(),
      frame: frame,
      anchor: Anchor.of(node),
      pin: pin,
      note: note,
      by: by,
      at: now().toUtc(),
    );
    final placements = directory.placements(n) ?? Placements(const []);
    directory
      ..saveMark(mark)
      ..savePlacements(n, placements.plus([Carried.raised(mark)]));
    return (mark: mark, node: node, round: n);
  }

  /// Appends the event [build] makes to the mark [id], and returns the mark as it is now.
  /// Refused when there is no such mark, or when its status does not allow the event.
  Mark record(String id, MarkEvent Function(DateTime at) build) {
    final mark = directory.mark(id);
    if (mark == null) throw Refused('no mark "$id" in ${directory.path}');
    final event = build(now().toUtc());
    final Mark next;
    try {
      next = mark.record(event);
    } on StateError {
      throw Refused('mark $id is ${mark.status.name}, and cannot be ${_verb(event)} now');
    }
    directory.saveMark(next);
    return next;
  }

  /// [path] made absolute with no `.` or `..` in it. `--app` defaults to `.`, and an agent
  /// handed `app/./.galley/...` has a path that works and reads as a mistake.
  static String _absolute(String path) => File(path).absolute.uri.normalizePath().toFilePath();

  static String _verb(MarkEvent e) => switch (e) {
    Answered() => 'answered',
    Verified() => 'verified',
    Reopened() => 'reopened',
  };

  /// Every mark waiting on an answer (every mark, with [all]), where it was last placed, as the
  /// JSON `pull --json` prints and `galley serve` returns.
  ///
  /// `image` is an absolute path to the frame's PNG in the round the mark was last placed in,
  /// or null when that round is unknown or the frame has no image.
  Future<List<JsonMap>> workItems({bool all = false}) async {
    final rounds = <int, StoredRound>{};
    return [
      for (final p in directory.lastPlaced())
        if (all || p.carried.mark.status.awaitsAnswer) await _item(p.round, p.carried, rounds),
    ];
  }

  Future<JsonMap> _item(int? n, Carried carried, Map<int, StoredRound> rounds) async {
    final stored = n == null ? null : rounds[n] ??= await directory.readRound(n);
    final image = stored?.round.frame(carried.mark.frame)?.record.image;
    return {
      'id': carried.mark.id,
      'status': carried.mark.status.name,
      'round': n,
      'placement': placementName(carried.placement),
      'where': carried.placement.toJson(),
      'anchor': carried.anchor.toJson(),
      'image': image == null ? null : _absolute('${directory.roundPath(n!)}/$image'),
      'mark': carried.mark.toJson(),
    };
  }
}

/// Where a new mark is pinned: a point in the frame, or a widget by its index path.
sealed class PinTarget {
  const PinTarget();
}

/// The deepest widget at ([x], [y]) in logical pixels, pinned at that point within it.
final class AtPoint extends PinTarget {
  /// The point ([x], [y]).
  const AtPoint(this.x, this.y);

  /// Logical pixels from the frame's left.
  final double x;

  /// Logical pixels from the frame's top.
  final double y;

  @override
  String toString() => '$x,$y';
}

/// The widget at index [path] in the frame's tree, pinned at its centre.
final class AtNode extends PinTarget {
  /// The widget at [path].
  const AtNode(this.path);

  /// Child indexes from the root.
  final List<int> path;

  @override
  String toString() => path.join('.');
}

/// What was asked cannot be done, and [message] says why. The CLI prints it and exits 1; the
/// server answers 409 with it.
final class Refused implements Exception {
  /// Refused, because of [message].
  const Refused(this.message);

  /// Why.
  final String message;

  @override
  String toString() => 'Refused: $message';
}

/// The word a person reads for [p].
String placementName(Placement p) => switch (p) {
  Raised() => 'raised',
  Reanchored(result: final Located l) => l.isExact ? 'exact' : 'moved',
  Reanchored(result: Lost()) => 'lost',
  Unplaced() => 'unplaced',
  Retired() => 'retired',
};
