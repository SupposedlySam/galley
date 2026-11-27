import 'dart:convert';
import 'dart:io';

import 'package:galley_core/galley_core.dart';

/// A galley kept as a directory: every mark, and every round with where each mark is in it.
///
/// ```
/// <galley>/
///   marks/<id>.json              one Mark each, its history only ever appended to
///   rounds/<n>/                  a round as the packer wrote it: round.json, index.json,
///                                records/, frames/, trees/
///   rounds/<n>/placements.json   where every mark is in that round
/// ```
///
/// A mark is one file so that two people answering two marks never write the same file.
/// Placements are per round because the next round is carried from the last one (DESIGN D12).
final class GalleyDirectory {
  /// The galley at [path]. Nothing is created until something is written.
  GalleyDirectory(this.path);

  /// Where the galley is.
  final String path;

  String get _marks => '$path/marks';
  String get _rounds => '$path/rounds';

  /// The directory of round [n].
  String roundPath(int n) => '$_rounds/$n';

  // ---- marks ----

  /// Every mark, oldest first.
  List<Mark> marks() {
    final dir = Directory(_marks);
    if (!dir.existsSync()) return const [];
    final marks = [
      for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')))
        Mark.fromJson(_decode(f), f.path),
    ];
    return marks..sort((a, b) {
      final byTime = a.at.compareTo(b.at);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
  }

  /// The mark with [id], or null.
  Mark? mark(String id) {
    final f = File(_markFile(id));
    return f.existsSync() ? Mark.fromJson(_decode(f), f.path) : null;
  }

  /// Writes [mark], new or with events appended. Throws a [StateError] for any other change.
  ///
  /// Nothing is erased (DESIGN.md): the stored mark's note, anchor and every past event must
  /// be in the new one as they were. Rejected: trusting callers to append. A command that
  /// rebuilt a mark from its arguments would drop its history without a word.
  void saveMark(Mark mark) {
    if (!FrameKey.isValidId(mark.id)) {
      throw ArgumentError.value(mark.id, 'mark.id', 'is not usable as a file name');
    }
    final stored = this.mark(mark.id);
    if (stored != null) {
      final before = stored.toJson(), after = mark.toJson();
      final pastEvents = before.remove('history') as List<Object?>;
      final events = after.remove('history') as List<Object?>;
      final kept =
          jsonEncode(before) == jsonEncode(after) &&
          events.length >= pastEvents.length &&
          jsonEncode(pastEvents) == jsonEncode(events.sublist(0, pastEvents.length));
      if (!kept) {
        throw StateError('mark ${mark.id}: a mark is only ever appended to, never rewritten');
      }
    }
    _write(_markFile(mark.id), mark.toJson());
  }

  String _markFile(String id) => '$_marks/$id.json';

  // ---- rounds ----

  /// The numbers of the rounds that finished (that have an `index.json`), lowest first.
  List<int> rounds() => [
    for (final n in _roundNumbers())
      if (File('${roundPath(n)}/index.json').existsSync()) n,
  ];

  /// The number the next round gets: one past every round directory, finished or not, so a
  /// round that died halfway is kept to be looked at, not written over.
  int nextRound() {
    final all = _roundNumbers();
    return all.isEmpty ? 1 : all.last + 1;
  }

  List<int> _roundNumbers() {
    final dir = Directory(_rounds);
    if (!dir.existsSync()) return const [];
    return [
      for (final d in dir.listSync().whereType<Directory>())
        ?int.tryParse(d.uri.pathSegments.where((s) => s.isNotEmpty).last),
    ]..sort();
  }

  /// Round [n] as stored.
  Future<StoredRound> readRound(int n) => StoredRound.read(_DirectoryFiles(roundPath(n)));

  /// Where every mark is in round [n], or null when it was never carried (it has no
  /// `placements.json`).
  Placements? placements(int n) {
    final f = File('${roundPath(n)}/placements.json');
    if (!f.existsSync()) return null;
    final byId = {for (final m in marks()) m.id: m};
    return Placements.fromJson(_decode(f), f.path, (id) => byId[id]);
  }

  /// Writes round [n]'s placements.
  void savePlacements(int n, Placements placements) =>
      _write('${roundPath(n)}/placements.json', placements.toJson());

  /// Every mark as it was last placed, and in which round: the latest round that placed it, or
  /// no round and as raised when none did (a mark file written by hand). This is what the next
  /// round is carried from.
  ///
  /// A round with no `placements.json` is skipped: a pack that died after rendering and before
  /// carrying. Its marks are carried from the round before.
  List<({int? round, Carried carried})> lastPlaced() {
    final placed = [
      for (final n in rounds().reversed)
        if (placements(n) case final p?) (n, p),
    ];
    return [
      for (final m in marks())
        placed
                .map((e) => e.$2.of(m.id) == null ? null : (round: e.$1, carried: e.$2.of(m.id)!))
                .nonNulls
                .firstOrNull ??
            (round: null, carried: Carried.raised(m)),
    ];
  }

  /// Writes [json] to [path] whole or not at all: a reader never sees half a file.
  static void _write(String path, JsonMap json) {
    final tmp = File('$path.tmp')..parent.createSync(recursive: true);
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
    tmp.renameSync(path);
  }

  static Object? _decode(File f) {
    try {
      return jsonDecode(f.readAsStringSync());
    } on FormatException catch (e) {
      throw FormatException('${f.path}: not JSON (${e.message})');
    }
  }
}

final class _DirectoryFiles implements RoundFiles {
  _DirectoryFiles(this.root);
  final String root;

  @override
  Future<Object?> json(String path) async {
    final f = File('$root/$path');
    if (!f.existsSync()) throw RoundFileMissing(path);
    return GalleyDirectory._decode(f);
  }
}
