import 'anchor.dart';
import 'frame_key.dart';
import 'frame_tree.dart';
import 'json.dart';
import 'mark.dart';
import 'pin.dart';
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

  /// Every mark, where it was last placed, whatever its status.
  Future<List<PlacedMark>> marks();

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

/// A mark where it was last placed: in [round], or in none when no round has placed it yet.
final class PlacedMark {
  /// [carried] in [round].
  const PlacedMark(this.round, this.carried);

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
    );
  }

  /// The round it was last placed in, or null.
  final int? round;

  /// The mark, its placement there, and its anchor.
  final Carried carried;

  /// The mark.
  Mark get mark => carried.mark;
}

/// Every mark of [galley] waiting on an answer (every mark, with [all]), where it was last
/// placed, as the JSON `pull --json` prints and `galley serve` sends. [PlacedMark.fromJson]
/// reads one back.
///
/// `image` names the frame's PNG in the round the mark was last placed in, or is null when no
/// round placed it or the frame has no image. [imageAt] names it from the round and the
/// image's path in it. By default it is [Galley.file]: a path for a file on this machine, which
/// an agent can open, and the URL otherwise.
Future<List<JsonMap>> workItems(
  Galley galley, {
  bool all = false,
  String Function(int round, String image)? imageAt,
}) async {
  final name = imageAt ?? (n, image) => _named(galley.file(n, image));
  final rounds = <int, Future<StoredRound>>{};
  return [
    for (final p in await galley.marks())
      if (all || p.mark.status.awaitsAnswer) await _item(galley, p, rounds, name),
  ];
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
    'placement': p.carried.placement.name,
    'where': p.carried.placement.toJson(),
    'anchor': p.carried.anchor.toJson(),
    'image': image == null ? null : name(n!, image),
    'mark': p.mark.toJson(),
  };
}
