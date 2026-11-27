import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:galley_core/galley_core.dart';

import 'server_galley.dart';

/// One file of a rendered round, read only when it is uploaded: a round's PNGs are hundreds
/// of megabytes together, and are never all held at once.
final class PushFile {
  /// The file at [path] in the round, of [size] bytes with [sha256], read by [read].
  const PushFile({
    required this.path,
    required this.sha256,
    required this.size,
    required this.read,
  });

  /// Its path inside the round, as the round's records name it.
  final String path;

  /// Its SHA-256, as lower-case hex: what a reader checks it against (ServerGalley.round).
  final String sha256;

  /// Its size in bytes: what the server checks it against as it is uploaded.
  final int size;

  /// Its bytes.
  final Future<Uint8List> Function() read;

  JsonMap get _entry => {'path': path, 'sha256': sha256, 'size': size};
}

/// What a push did: the round's [number], every mark as [carried] into it, and whether it
/// [resumed] a round an earlier push had begun.
typedef Pushed = ({int number, List<Carried> carried, bool resumed});

/// Pushing a rendered round to a Galley server as its owner (docs/DESIGN.md D15, "A round is
/// finished last, and whole").
///
/// The round is created with its manifest, its files are uploaded, every mark is carried into
/// it, and it is finished with those placements. Until it is finished no reviewer sees it,
/// and nobody can raise a mark on it, so a reviewer never sees half a round.
final class RoundPush {
  /// Pushing to [galley], whose session must be its owner's.
  RoundPush(this.galley);

  /// The galley, as its owner.
  final ServerGalley galley;

  /// How many files are uploaded at once. As [ServerGalley.fetchesAtOnce]: the latency of one
  /// hidden behind the others, and few enough not to meet the rate limiter.
  static const uploadsAtOnce = 8;

  /// How many times a finish is tried while marks are being raised under it.
  static const finishTries = 3;

  /// Pushes [files], whose frames are [frames], carrying every mark through [round], the
  /// round as read from those files. [uploaded] is told each path as it lands.
  ///
  /// When the newest round on the server is one an earlier push created and did not finish,
  /// and it lists exactly these files, this push finishes it, uploading only what is missing.
  /// An unfinished round can be neither changed nor deleted (the rules allow one update, the
  /// finish), so a push of other files is refused while it stands, naming it.
  ///
  /// Rejected: numbering the push past an unfinished round. The server refuses it (a round
  /// is next after the highest, finished or not), and if it did not, the galley's rounds would
  /// have a gap no reviewer could read.
  Future<Pushed> push({
    required List<FrameKey> frames,
    required List<PushFile> files,
    required Round round,
    void Function(String path)? uploaded,
  }) async {
    final manifest = [for (final f in files) f._entry];
    final repeated = _repeated(files);
    if (repeated != null) throw Refused.invalid('the round lists $repeated twice');
    // Before the round is made, not only at its finish: a mark that does not read cannot be
    // carried, so the finish would be refused, and the round made for it would stand
    // unfinished, refusing every other push until it is finished or a superuser removes it.
    // The finish reads the marks again; this read only refuses early.
    (await galley.marks()).whole;
    final (:id, :number, :resumed) = await _roundFor(frames, manifest);
    final server = galley.server, token = galley.session.token;

    final existing = {
      for (final row in await server.list('files', filter: 'round = ${_q(id)}', token: token))
        JsonReader(row, 'a file').string('path'),
    };
    final missing = [
      for (final f in files)
        if (!existing.contains(f.path)) f,
    ];
    var next = 0;
    Future<void> worker() async {
      while (next < missing.length) {
        final f = missing[next++];
        final bytes = await f.read();
        // Checked here because the server checks only the size: a file changed since the
        // manifest was made would be read back as damage by every reviewer.
        final actual = '${sha256.convert(bytes)}';
        if (bytes.length != f.size || actual != f.sha256) {
          throw Refused.conflict(
            '${f.path} changed while the round was pushed: it is ${bytes.length} bytes with '
            'SHA-256 $actual, and the manifest says ${f.size} bytes with ${f.sha256}',
          );
        }
        await server.upload(
          'files',
          fields: {'round': id, 'path': f.path},
          field: 'file',
          filename: f.path.split('/').last,
          bytes: bytes,
          token: token,
        );
        uploaded?.call(f.path);
      }
    }

    // Future.wait, not the record's `.wait`: a ParallelWaitError would hide the Refused that
    // says which file the server refused.
    await Future.wait([for (var i = 0; i < uploadsAtOnce; i++) worker()]);

    for (var attempt = 1; ; attempt++) {
      final marks = (await galley.marks()).whole;
      final carried = round.carryAll([for (final m in marks) m.carried]);
      try {
        await server.send(
          'PATCH',
          server.api(['collections', 'rounds', 'records', id]),
          token: token,
          body: {'finished': true, 'placements': Placements(carried).toJson()},
        );
        return (number: number, carried: carried, resumed: resumed);
      } on Refused {
        // A mark raised on the previous round after the marks were read: the server refuses a
        // finish that does not place it. Carry again. Anything else is refused as it was.
        // Rejected: reading the refusal's words to tell the two apart; they are the server's
        // to change, and the marks themselves say whether one is new.
        final known = {for (final m in marks) m.mark.id};
        final now = (await galley.marks()).whole;
        final grown = now.any((m) => !known.contains(m.mark.id));
        if (!grown || attempt >= finishTries) rethrow;
      }
    }
  }

  /// The round to push into: a new one, numbered after the highest the galley has, or the
  /// unfinished one an earlier push of these same files left.
  Future<({String id, int number, bool resumed})> _roundFor(
    List<FrameKey> frames,
    List<JsonMap> manifest,
  ) async {
    final server = galley.server, token = galley.session.token;
    // The owner lists unfinished rounds too (the rounds' list rule).
    final rows = await server.list(
      'rounds',
      filter: 'galley = ${_q(galley.galleyId)}',
      sort: '-number',
      token: token,
    );
    final keys = [for (final f in frames) '$f'];
    if (rows.firstOrNull case final newest?) {
      final r = JsonReader(newest, 'a round');
      final n = r.integer('number');
      if (!r.boolean('finished')) {
        if (_sameManifest(newest['manifest'], manifest) && _sameFrames(newest['frames'], keys)) {
          return (id: r.string('id'), number: n, resumed: true);
        }
        throw Refused.conflict(
          'round $n was begun by an earlier push and not finished, and it lists other files '
          'than these. Push the files it was begun with to finish it; an unfinished round is '
          'not changed or deleted, except by the server\'s superuser.',
        );
      }
    }
    final number = rows.isEmpty ? 1 : JsonReader(rows.first, 'a round').integer('number') + 1;
    final made = await server.send(
      'POST',
      server.api(['collections', 'rounds', 'records']),
      token: token,
      body: {'galley': galley.galleyId, 'number': number, 'frames': keys, 'manifest': manifest},
    );
    return (id: JsonReader(made, 'the new round').string('id'), number: number, resumed: false);
  }

  static String? _repeated(List<PushFile> files) {
    final seen = <String>{};
    return files.map((f) => f.path).where((p) => !seen.add(p)).firstOrNull;
  }

  /// Whether the [stored] manifest lists the same files as [ours], each at the same SHA-256
  /// and size, in any order. Compared as values, not as text: the server's JSON need not keep
  /// an entry's keys in the order they were sent.
  static bool _sameManifest(Object? stored, List<JsonMap> ours) {
    String entry(Object? e) {
      final r = JsonReader(e, 'a manifest entry');
      return '${r.string('path')}\u0000${r.string('sha256')}\u0000${r.integer('size')}';
    }

    if (stored is! List || stored.length != ours.length) return false;
    final theirs = {for (final e in stored) entry(e)};
    return theirs.length == ours.length && ours.every((e) => theirs.contains(entry(e)));
  }

  /// Whether the [stored] frames are [ours], in the same order.
  static bool _sameFrames(Object? stored, List<String> ours) =>
      stored is List &&
      stored.length == ours.length &&
      [for (var i = 0; i < ours.length; i++) stored[i] == ours[i]].every((same) => same);

  static String _q(String value) => jsonEncode(value);
}
