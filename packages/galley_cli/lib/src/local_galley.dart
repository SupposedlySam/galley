import 'dart:io';

import 'package:galley_core/galley_core.dart';

import 'galley_directory.dart';

/// A [Galley] on this machine, in `.galley/` (D12). The `galley` commands and `galley serve`
/// both call this, so a mark raised from the canvas is the same as one raised from the command
/// line.
final class LocalGalley implements Galley {
  /// The galley in [directory] of the app whose git repository is at [repository], with [now]
  /// for event times and [newId] for new marks.
  LocalGalley(this.directory, {required this.repository, required this.now, required this.newId});

  /// Where the galley is kept.
  final GalleyDirectory directory;

  /// The app's git repository, where a fix's commit must be.
  final String repository;

  /// The time an event is recorded at.
  final DateTime Function() now;

  /// A new mark's id.
  final String Function() newId;

  @override
  Future<List<int>> rounds() async => directory.rounds();

  @override
  Future<StoredRound> round(int n) => directory.readRound(n);

  @override
  Uri file(int n, String path) => Uri.file(_absolute('${directory.roundPath(n)}/$path'));

  @override
  Future<List<PlacedMark>> marks() async => directory.lastPlaced();

  /// The latest finished round. Refused when there is none.
  int latestRound() {
    final rounds = directory.rounds();
    if (rounds.isEmpty) {
      throw Refused.conflict('${directory.path} has no rounds yet: run `galley pack`');
    }
    return rounds.last;
  }

  /// Everything is checked before an id is taken or a file written, so a refused mark leaves
  /// no trace.
  @override
  Future<({Mark mark, WidgetNode node, int round})> raise({
    required FrameKey frame,
    required PinTarget target,
    required String note,
    required String by,
  }) async {
    final n = latestRound();
    final found = (await directory.readRound(n)).round.frame(frame);
    if (found == null) throw Refused.invalid('round $n has no frame $frame');
    final tree = found.tree;
    if (tree == null) {
      throw Refused.conflict('frame $frame in round $n has no tree to pin a widget of');
    }
    final WidgetNode node;
    final PinOffset pin;
    try {
      (:node, :pin) = target.resolve(tree);
    } on PinMissed catch (e) {
      throw Refused.invalid('${e.message} in frame $frame');
    }
    if (markNoteRefusal(note) case final why?) throw Refused.invalid(why);
    if (by.trim().isEmpty) throw const Refused.invalid('a mark says who raised it');

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

  /// Refused when there is no such mark, or when its status does not allow the event.
  @override
  Future<Mark> record(String id, MarkEvent Function(DateTime at) event) async {
    final mark = directory.mark(id);
    if (mark == null) throw Refused.missing('no mark "$id" in ${directory.path}');
    final e = event(now().toUtc());
    if (eventRefusal(e) case final why?) throw Refused.invalid(why);
    final Mark next;
    try {
      next = mark.record(e);
    } on StateError catch (e) {
      // The core says why, in the event's own words: a status that does not allow it, or a
      // withdrawal by someone who did not raise the mark.
      throw Refused.conflict(e.message);
    }
    directory.saveMark(next);
    return next;
  }

  /// [path] made absolute with no `.` or `..` in it. `--app` defaults to `.`, and an agent
  /// handed `app/./.galley/...` has a path that works and reads as a mistake.
  static String _absolute(String path) => File(path).absolute.uri.normalizePath().toFilePath();

  /// The full SHA of [given], which must be a commit in [repository].
  ///
  /// Stored in full: a short SHA that is unique today can be ambiguous next year. Checked,
  /// because "fixed in a commit that does not exist" cannot be verified by anyone.
  String fullCommit(String given) {
    final r = Process.runSync('git', [
      'rev-parse',
      '--verify',
      '--quiet',
      '$given^{commit}',
    ], workingDirectory: repository);
    if (r.exitCode != 0) {
      throw Refused.invalid('$given is not a commit in the repository at $repository');
    }
    return '${r.stdout}'.trim();
  }
}
