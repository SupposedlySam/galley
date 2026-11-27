import 'package:galley_core/galley_core.dart';

import 'rows.dart';

/// The most files one round's manifest may list (DESIGN D15). The first adopting app's round
/// is about 310; this leaves room for an app many times its size, and stops a manifest that
/// would take the server's disk a file at a time.
const maxManifestFiles = 5000;

/// The largest file a round may hold, in bytes (DESIGN D15). A frame's PNG at three times a
/// tablet's pixels is a few megabytes; a file past this is not a frame.
const maxFileBytes = 20 * 1024 * 1024;

/// What the server's hooks ask before a write lands, and the answer: `{"ok": true}`, or
/// `{"refused": "<why>"}`, which the hook returns to the writer as a 400.
///
/// The hooks gather what PocketBase knows (the row being written, the rows it depends on,
/// and the writer's role and alias) and pass it here as [request]. Every judgment of what may
/// be written is made here, over galley_core, inside the write's transaction (DESIGN D15).
/// Rejected: the same rules written again in the hooks' JavaScript. The copy would be every
/// rule below, and a test comparing the two could only cover the cases someone listed.
///
/// Who may write at all (a member who is not revoked, the owner for a round) is the
/// collections' API rules, which PocketBase applies before a hook runs. What they may write,
/// which depends on the content and the mark's history, is decided here.
///
/// A request this does not read is refused, not passed: the hook sent something it should
/// not, and a write nobody judged must not land.
///
/// The writes, by `write`:
/// - `mark`: `mark` (frame, anchor, pin, note), `round` (number, finished, frames), and
///   `newest`, the newest finished round's number.
/// - `event`: `mark` and `history` (the rows [markOfRow] reads), `event` (the columns
///   [eventRow] writes), and the writer's `role` and `by`.
/// - `round`: `round` (number, frames, manifest) and `newest`, the highest number the galley
///   has, finished or not, or null.
/// - `file`: `round` (finished, manifest), the file's `path` and `size`, and `existing`, the
///   paths the round has files for.
/// - `finish`: `round` (number, finished, manifest), `files`, `placements` (the round's, in
///   the form [Placements.toJson] writes), and `marks`, the rows of every mark raised on an
///   earlier round.
/// - `member`: the `alias` an invitee chose, and `aliases`, the galley's others.
JsonMap judge(Object? request) {
  try {
    final r = JsonReader(request, 'request');
    final why = switch (r.string('write')) {
      'mark' => _mark(r),
      'event' => _event(r),
      'round' => _round(r),
      'file' => _file(r),
      'finish' => _finish(r),
      'member' => _member(r),
      final other => throw FormatException('request.write: no write "$other"'),
    };
    return why == null ? {'ok': true} : {'refused': why};
  } on FormatException catch (e) {
    return {'refused': e.message};
  }
}

String? _mark(JsonReader r) {
  final mark = r.read('mark', JsonReader.new);
  final round = r.read('round', JsonReader.new);
  final n = round.integer('number'), newest = r.optionalInteger('newest');
  final frame = _frameKey(mark.string('frame'), 'request.mark.frame');
  // Read for what they say, so a malformed anchor or pin is refused with its field named.
  mark
    ..read('anchor', Anchor.fromJson)
    ..read('pin', PinOffset.fromJson);
  if (!round.boolean('finished')) return 'round $n is still being pushed';
  if (n != newest) return 'round $n is out: round $newest is the newest; reload';
  if (!_frames(round).contains(frame)) return 'round $n has no frame $frame';
  return markNoteRefusal(mark.string('note'));
}

String? _event(JsonReader r) {
  final mark = markOfRow(r.read('mark', (j, _) => j), r.list('history'), 'request.mark');
  final by = r.string('by');
  final event = eventOfRow({
    ...r.read('event', _object),
    'by': by,
    // The server's `created` is the event's time; any time judges the same.
    'at': DateTime.now().toUtc().toIso8601String(),
  }, 'request.event');
  if (event is Answered && r.string('role') != 'owner') {
    return "only the galley's owner answers a mark";
  }
  if (eventRefusal(event) case final why?) return why;
  try {
    mark.record(event);
    return null;
  } on StateError catch (e) {
    return e.message;
  }
}

String? _round(JsonReader r) {
  final round = r.read('round', JsonReader.new);
  final n = round.integer('number'), next = (r.optionalInteger('newest') ?? 0) + 1;
  _frames(round);
  _manifest(round);
  return n == next ? null : 'round $n is not next: the next round is $next';
}

String? _file(JsonReader r) {
  final round = r.read('round', JsonReader.new);
  final path = r.string('path'), size = r.integer('size');
  if (round.boolean('finished')) {
    return 'the round is finished, and a finished round is not changed';
  }
  final listed = _manifest(round)[path];
  if (listed == null) return 'the round\'s manifest does not list $path';
  if (r.list('existing').contains(path)) return 'the round already has $path';
  if (size != listed.size) return '$path is $size bytes, and the manifest says ${listed.size}';
  return null;
}

String? _finish(JsonReader r) {
  final round = r.read('round', JsonReader.new);
  final n = round.integer('number');
  if (round.boolean('finished')) return 'round $n is already finished';
  final files = {for (final (i, p) in r.list('files').indexed) _string(p, 'request.files[$i]')};
  final missing = [
    for (final p in _manifest(round).keys)
      if (!files.contains(p)) p,
  ];
  if (missing.isNotEmpty) {
    return 'round $n is missing ${missing.length} of its files: ${missing.take(3).join(', ')}'
        '${missing.length > 3 ? ', ...' : ''}';
  }
  final marks = <String, Mark>{};
  for (final (i, row) in r.list('marks').indexed) {
    final mark = markOfRow(row, const [], 'request.marks[$i]');
    marks[mark.id] = mark;
  }
  final placements = Placements.fromJson(
    r.read('placements', (j, _) => j),
    'request.placements',
    (id) => marks[id],
  );
  final unplaced = [
    for (final id in marks.keys)
      if (placements.of(id) == null) id,
  ];
  if (unplaced.isNotEmpty) {
    // A mark raised while the push ran: the push carries again and finishes then.
    return 'round $n does not place ${unplaced.join(', ')}; carry every mark again';
  }
  for (final c in placements.carried) {
    if (c.placement is Raised) return 'mark ${c.mark.id} was raised on an earlier round, not $n';
  }
  return null;
}

/// 1 to 40 letters, digits, spaces, `.`, `-` or `'`: a name a person reads in a thread and
/// types in `--by`-free commands, with nothing in it a terminal or a page would act on.
final _alias = RegExp(r"^[\p{L}\p{N} .'\-]{1,40}$", unicode: true);

String? _member(JsonReader r) {
  final alias = r.string('alias');
  if (!_alias.hasMatch(alias)) {
    return 'an alias is 1 to 40 letters, digits, spaces, ".", "-" or "\'": "$alias" is not';
  }
  if (alias.trim() != alias) return 'an alias does not start or end with a space';
  final same = {
    for (final (i, a) in r.list('aliases').indexed) _aliasKey(_string(a, 'request.aliases[$i]')),
  };
  if (same.contains(_aliasKey(alias))) return 'a member of this galley is already "$alias"';
  return null;
}

/// What two aliases share when a reader would take them for one: case and runs of spaces
/// are ignored, so "Sam  Lee" and "sam lee" are one person, and `Withdrawn` compares `by`.
String _aliasKey(String alias) => alias.toLowerCase().replaceAll(RegExp(' +'), ' ');

/// A round's frame keys, each read as the core reads it.
Set<FrameKey> _frames(JsonReader round) => {
  for (final (i, k) in round.list('frames').indexed)
    _frameKey(_string(k, 'request.round.frames[$i]'), 'request.round.frames[$i]'),
};

/// A round's manifest by path, refused unless every entry is a safe relative path, a SHA-256
/// and a size within [maxFileBytes], with no path twice and at most [maxManifestFiles].
Map<String, ({String sha256, int size})> _manifest(JsonReader round) {
  final entries = round.list('manifest');
  if (entries.length > maxManifestFiles) {
    throw FormatException(
      'request.round.manifest: ${entries.length} files, more than $maxManifestFiles',
    );
  }
  final byPath = <String, ({String sha256, int size})>{};
  for (final (i, e) in entries.indexed) {
    final context = 'request.round.manifest[$i]';
    final f = JsonReader(e, context);
    final path = f.string('path'), sha256 = f.string('sha256'), size = f.integer('size');
    if (!_safePath(path)) {
      throw FormatException('$context.path: "$path" is not a relative path inside the round');
    }
    if (!_sha256.hasMatch(sha256)) {
      throw FormatException('$context.sha256: expected 64 lower-case hex digits');
    }
    if (size < 0 || size > maxFileBytes) {
      throw FormatException('$context.size: $size bytes, outside 0 to $maxFileBytes');
    }
    if (byPath.containsKey(path)) throw FormatException('$context.path: $path is listed twice');
    byPath[path] = (sha256: sha256, size: size);
  }
  return byPath;
}

final _sha256 = RegExp(r'^[0-9a-f]{64}$');

/// Relative, with no empty, `.` or `..` segment and no backslash: a reader joins it to the
/// round's own location, and must never be led out of it.
bool _safePath(String path) =>
    path.isNotEmpty &&
    !path.contains(r'\') &&
    !path.split('/').any((s) => s.isEmpty || s == '.' || s == '..');

FrameKey _frameKey(String source, String context) {
  try {
    return FrameKey.parse(source);
  } on FormatException catch (e) {
    throw FormatException('$context: ${e.message}');
  }
}

JsonMap _object(Object? value, String context) =>
    value is JsonMap ? value : throw FormatException('$context: expected an object');

String _string(Object? value, String context) =>
    value is String ? value : throw FormatException('$context: expected a string');
