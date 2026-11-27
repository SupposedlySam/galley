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
///   visits.json                  each reviewer's last two rounds opened, by name (D17)
/// ```
///
/// A mark is one file so that two people answering two marks never write the same file.
/// Placements are per round because the next round is carried from the last one (DESIGN D12).
///
/// A stored file that does not read is [Refused.damaged], naming it: never a FormatException,
/// which callers take as a bad request or bad input. Observed on the adopting app: a mark file
/// deleted by hand, with a round's placements still naming it, made every POST a 400 that
/// blamed the request.
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
        _read(f, Mark.fromJson),
    ];
    return marks..sort((a, b) {
      final byTime = a.at.compareTo(b.at);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
  }

  /// The mark with [id], or null.
  Mark? mark(String id) {
    final f = File(_markFile(id));
    return f.existsSync() ? _read(f, Mark.fromJson) : null;
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
  Future<StoredRound> readRound(int n) => readRendered(roundPath(n), 'round $n');

  /// The round rendered at [dir], which [name]s in a refusal: a stored round, or a render a
  /// push is sending.
  static Future<StoredRound> readRendered(String dir, String name) async {
    try {
      return await StoredRound.read(_DirectoryFiles(dir));
    } on FormatException catch (e) {
      throw Refused.damaged('$name: ${e.message}');
    } on RoundFileMissing catch (e) {
      throw Refused.damaged('$name in $dir: ${e.path} is listed and not there');
    }
  }

  /// Where every mark is in round [n], or null when it was never carried (it has no
  /// `placements.json`).
  Placements? placements(int n) {
    final f = File('${roundPath(n)}/placements.json');
    if (!f.existsSync()) return null;
    final byId = {for (final m in marks()) m.id: m};
    // Naming both files: the one that refers to the mark, and the one to put back. The core's
    // FormatException names only the first, which is all a pure reader knows (seen on the first
    // adopting app, whose owner had to work out that the missing file was the mark's).
    Mark markOf(String id) =>
        byId[id] ??
        (throw Refused.damaged(
          'the galley does not hold together: ${f.path} places mark "$id", and there is no '
          'mark "$id": ${_markFile(id)} is not there',
        ));
    return _read(f, (json, context) => Placements.fromJson(json, context, markOf));
  }

  /// Reads every mark and every round's placements, and returns. Refused, naming the file,
  /// when the galley does not hold together, so a server finds it at start, not at a request.
  ///
  /// Records and trees are left to the request that needs them: they are the packer's output,
  /// a round of them is large, and a damaged one is refused when it is read, all the same.
  void check() {
    for (final n in rounds()) {
      placements(n);
    }
    marks();
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
  List<PlacedMark> lastPlaced() {
    final placed = [
      for (final n in rounds().reversed)
        if (placements(n) case final p?) (n, p),
    ];
    return [for (final m in marks()) _lastPlacedOf(m, placed)];
  }

  /// [m] in the newest of [placed] that places it, else as raised in none; with the round
  /// whose placements hold it as Raised, which `raise` writes and no later round does. That
  /// round is null when none does, as for a mark file written by hand.
  static PlacedMark _lastPlacedOf(Mark m, List<(int, Placements)> placed) {
    final raisedIn = [
      for (final (n, p) in placed)
        if (p.of(m.id)?.placement is Raised) n,
    ].firstOrNull;
    for (final (n, p) in placed) {
      if (p.of(m.id) case final c?) return PlacedMark(n, c, raisedIn: raisedIn);
    }
    return PlacedMark(null, Carried.raised(m), raisedIn: raisedIn);
  }

  // ---- visits ----

  String get _visitsFile => '$path/visits.json';

  /// Each reviewer's [Visit], by the name they review as; empty before the first.
  ///
  /// One file, not one per reviewer: a name is what the reviewer typed, and is not a file
  /// name. Only `galley serve` writes it, one request at a time, so no two writers race.
  Map<String, Visit> visits() {
    final f = File(_visitsFile);
    if (!f.existsSync()) return const {};
    return _read(f, (json, context) {
      if (json is! JsonMap) throw FormatException('$context: expected an object');
      return {
        for (final MapEntry(:key, :value) in json.entries)
          key: Visit.fromJson(value, '$context.$key'),
      };
    });
  }

  /// Writes every reviewer's visit.
  void saveVisits(Map<String, Visit> visits) => _write(_visitsFile, {
    for (final MapEntry(:key, :value) in visits.entries) key: value.toJson(),
  });

  /// Writes [json] to [path] whole or not at all: a reader never sees half a file.
  static void _write(String path, JsonMap json) {
    final tmp = File('$path.tmp')..parent.createSync(recursive: true);
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
    tmp.renameSync(path);
  }

  /// [f] decoded and read by [parse], with the file's path as the context of what it says.
  static T _read<T>(File f, T Function(Object? json, String context) parse) {
    try {
      return parse(_decode(f), f.path);
    } on FormatException catch (e) {
      throw Refused.damaged('the galley does not hold together: ${e.message}');
    }
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
