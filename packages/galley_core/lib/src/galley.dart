import 'anchor.dart';
import 'frame_key.dart';
import 'frame_tree.dart';
import 'json.dart';
import 'mark.dart';
import 'pin.dart';
import 'refused.dart';
import 'write_rules.dart';
import 'round.dart';
import 'stored_round.dart';

/// A galley, wherever it is kept: its finished rounds, every mark where it was last placed, and
/// the two writes a person makes, raising a mark and recording an event on one.
///
/// The commands, `galley serve` and the canvas each speak to a galley only through this: on
/// this machine (D12), through `galley serve` (D13), or on a server (D15). Rejected: a shape
/// per backend, which 0.3.8 had in three (the CLI's `LocalGalley`, the JSON `galley serve`
/// answers, the canvas's `GalleyApi`), and which a server would have made four. Each command
/// would then have had a path per galley, and the paths would have drifted.
///
/// Every refusal is a [Refused].
abstract interface class Galley {
  /// The finished rounds, oldest first.
  Future<List<int>> rounds();

  /// Finished round [n]: its index, every record and every tree.
  Future<StoredRound> round(int n);

  /// Where the file at [path] of round [n], such as a frame's PNG, is read from: a file on
  /// this machine, or a URL.
  Uri file(int n, String path);

  /// Every mark, where it was last placed, whatever its status; and every mark that does not
  /// read, with why.
  Future<GalleyMarks> marks();

  /// Raises a mark on the widget [target] names in [frame] of the latest round, saying [note],
  /// by [by], and places it there as Raised. Returns the mark, the widget it was pinned to, and
  /// the round.
  Future<({Mark mark, WidgetNode node, int round})> raise({
    required FrameKey frame,
    required PinTarget target,
    required String note,
    required String by,
  });

  /// Records the event [event] builds on the mark [id], and returns the mark as it is now.
  ///
  /// The galley gives the time: a history ordered by clocks the reviewers set is not an order
  /// (D13). A galley behind a server builds the event with its own clock to send it, and the
  /// mark it returns has the server's time.
  Future<Mark> record(String id, MarkEvent Function(DateTime at) event);
}

/// Every mark of a galley as read: those that read, where each was last placed, and those that
/// do not, with why.
///
/// On a server, one mark that does not read must not hide every other member's marks (D15):
/// it is listed as [DamagedMark], and the rest are read. On this machine a galley that does not
/// hold together is refused whole (D12), so [damaged] is empty there. Rejected: dropping a mark
/// that does not read, which shows a galley with one mark fewer as if it were whole; and
/// refusing the whole read, as 0.3.9 did, which leaves three reviewers with nothing to review
/// because of one row.
final class GalleyMarks {
  /// [placed], and [damaged].
  GalleyMarks(List<PlacedMark> placed, {List<DamagedMark> damaged = const []})
    : placed = List.unmodifiable(placed),
      damaged = List.unmodifiable(damaged);

  /// Reads the JSON [WorkItems.toJson] writes, of every mark: what `galley serve` sends.
  factory GalleyMarks.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    return GalleyMarks(
      r.readList('items', PlacedMark.fromJson),
      damaged: r.readList('damaged', DamagedMark.fromJson),
    );
  }

  /// The marks that read.
  final List<PlacedMark> placed;

  /// The marks that do not.
  final List<DamagedMark> damaged;

  /// [placed], refused while any mark is [damaged]: for a writer that must carry every mark,
  /// such as a push, which a server refuses to finish unless every earlier mark is placed.
  List<PlacedMark> get whole => switch (damaged) {
    [] => placed,
    [final d, ...] => throw Refused.damaged(
      'mark ${d.id} does not read (${d.why})'
      '${damaged.length > 1 ? ', nor ${damaged.length - 1} more' : ''}; every mark must be '
      'carried, so this is refused until it is mended',
    ),
  };
}

/// A mark that does not read, by its [id], and [why].
final class DamagedMark {
  /// Mark [id], which does not read because of [why].
  const DamagedMark(this.id, this.why);

  /// Reads the JSON [toJson] writes.
  factory DamagedMark.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    return DamagedMark(r.string('id'), r.string('why'));
  }

  /// The mark's id.
  final String id;

  /// Why it does not read.
  final String why;

  /// `{"id", "why"}`.
  JsonMap toJson() => {'id': id, 'why': why};
}

/// A mark where it was last placed: in [round], or in none when no round has placed it yet;
/// and the round it was raised on, [raisedIn].
final class PlacedMark {
  /// [carried] in [round], raised on round [raisedIn].
  const PlacedMark(this.round, this.carried, {required this.raisedIn});

  /// Reads one of [workItems]: the form `galley pull --json` prints and `galley serve` sends.
  factory PlacedMark.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    return PlacedMark(
      r.optionalInteger('round'),
      Carried(
        r.read('mark', Mark.fromJson),
        r.read('where', Placement.fromJson),
        r.read('anchor', Anchor.fromJson),
      ),
      raisedIn: r.optionalInteger('raised_in'),
    );
  }

  /// The round it was last placed in, or null.
  final int? round;

  /// The round it was raised on, or null when no galley records which: a mark file written by
  /// hand, or work items printed before 0.3.10.
  ///
  /// A reviewer checks an answer against the frame they marked, so the canvas shows the mark's
  /// widget in this round beside the latest. Required, with null as "not known", so that no
  /// backend can leave it out by forgetting it. Rejected: reading it from the mark's time
  /// against each round's, since the packer's clock and the server's need not agree; and a
  /// field on [Mark], whose JSON every existing galley already wrote without it.
  final int? raisedIn;

  /// The mark, its placement there, and its anchor.
  final Carried carried;

  /// The mark.
  Mark get mark => carried.mark;
}

/// What `pull --json` prints and `galley serve` sends: the latest round, the marks as work
/// items, and the marks that do not read.
final class WorkItems {
  /// The work of a galley whose newest finished round is [latestRound].
  const WorkItems(this.latestRound, this.items, this.damaged);

  /// The newest finished round, or null before the first.
  final int? latestRound;

  /// The marks as work items; [PlacedMark.fromJson] reads one back.
  final List<JsonMap> items;

  /// The marks that do not read. Listed apart, and always, so an agent working through
  /// [items] is told a mark is missing from them rather than shown fewer.
  final List<DamagedMark> damaged;

  /// `{"latest_round", "items", "damaged"}`; with every mark, what [GalleyMarks.fromJson] reads.
  JsonMap toJson() => {
    'latest_round': latestRound,
    'items': items,
    'damaged': [for (final d in damaged) d.toJson()],
  };
}

/// Every mark of [galley] waiting on an answer (every mark, with [all]), where it was last
/// placed, as work items; and every mark that does not read, whatever its status, since its
/// status is not known.
///
/// `image` names the frame's PNG in the round the mark was last placed in, or is null when no
/// round placed it or the frame has no image. [imageAt] names it from the round and the
/// image's path in it. By default it is [Galley.file]: a path for a file on this machine, which
/// an agent can open, and the URL otherwise.
Future<WorkItems> workItems(
  Galley galley, {
  bool all = false,
  String Function(int round, String image)? imageAt,
}) async {
  final name = imageAt ?? (n, image) => _named(galley.file(n, image));
  final rounds = <int, Future<StoredRound>>{};
  // One after the other: a record's `.wait` throws a ParallelWaitError, which would hide the
  // Refused that says what was refused.
  final latest = (await galley.rounds()).lastOrNull;
  final marks = await galley.marks();
  return WorkItems(latest, [
    for (final p in marks.placed)
      if (all || p.mark.status.awaitsAnswer) await _item(galley, p, rounds, name),
  ], marks.damaged);
}

String _named(Uri file) => file.isScheme('file') ? file.toFilePath() : '$file';

Future<JsonMap> _item(
  Galley galley,
  PlacedMark p,
  Map<int, Future<StoredRound>> rounds,
  String Function(int, String) name,
) async {
  final n = p.round;
  final stored = n == null ? null : await (rounds[n] ??= galley.round(n));
  final image = stored?.round.frame(p.mark.frame)?.record.image;
  return {
    'id': p.mark.id,
    'status': p.mark.status.name,
    'round': n,
    'raised_in': p.raisedIn,
    'placement': p.carried.placement.name,
    'where': p.carried.placement.toJson(),
    'anchor': p.carried.anchor.toJson(),
    'image': image == null ? null : name(n!, image),
    'mark': p.mark.toJson(),
  };
}

/// The widget [target] names in [frame] of [round] (round number [n]), and where on it a new
/// mark saying [note] by [by] is pinned; refused, with the reason, when the mark cannot be.
///
/// Every [Galley.raise] asks this before it writes anything, so a mark raised on this machine
/// and one raised on a server are refused for the same reasons in the same words. Rejected:
/// leaving the server to judge the pin alone, which it can only do by reading the round's
/// trees in a hook, on every mark.
({WidgetNode node, PinOffset pin}) raiseTarget(
  Round round,
  int n, {
  required FrameKey frame,
  required PinTarget target,
  required String note,
  required String by,
}) {
  final found = round.frame(frame);
  if (found == null) throw Refused.invalid('round $n has no frame $frame');
  final tree = found.tree;
  if (tree == null) {
    throw Refused.conflict('frame $frame in round $n has no tree to pin a widget of');
  }
  final ({WidgetNode node, PinOffset pin}) resolved;
  try {
    resolved = target.resolve(tree);
  } on PinMissed catch (e) {
    throw Refused.invalid('${e.message} in frame $frame');
  }
  if (markNoteRefusal(note) case final why?) throw Refused.invalid(why);
  if (by.trim().isEmpty) throw const Refused.invalid('a mark says who raised it');
  return resolved;
}
