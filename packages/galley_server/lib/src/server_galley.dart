import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:galley_core/galley_core.dart';

import 'pocketbase.dart';
import 'rows.dart';
import 'sign_in.dart';

/// A [Galley] kept on a Galley server (docs/DESIGN.md D15), read and written as [session]'s
/// user, who must be one of its members.
///
/// The server judges every write (the hooks call galley_validate), so this checks only what
/// gives a better answer before a request is sent: the widget a mark is pinned to, which the
/// server cannot see without reading the round's trees. Everything else is the server's word,
/// passed on as a [Refused].
final class ServerGalley implements Galley {
  /// The galley [galleyId] on [server], as [session]'s user. [now] is the clock an event is
  /// built with before it is sent; the server stores its own time instead (D13).
  ServerGalley(
    this.server, {
    required this.galleyId,
    required this.session,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The server.
  final PocketBase server;

  /// The galley's record id.
  final String galleyId;

  /// Who is signed in.
  final Session session;

  final DateTime Function() _now;

  /// How many of a round's files are fetched at once while it is read. Enough to hide the
  /// latency of one request behind the others; few enough not to meet the rate limiter.
  static const fetchesAtOnce = 8;

  /// A file token lasts 180 seconds (PocketBase v0.40.6, `core/settings_model.go`); one is
  /// fetched again once this much of that has passed, so a URL handed out is good for at least
  /// the rest.
  static const fileTokenReuse = Duration(seconds: 120);

  final _rounds = <int, _RoundRecord>{};
  final _files = <int, Map<String, JsonMap>>{};
  ({String token, DateTime at})? _fileToken;

  String get _token => session.token;

  @override
  Future<List<int>> rounds() async => [for (final r in await _finishedRounds()) r.number];

  @override
  Future<StoredRound> round(int n) async {
    final record = await _round(n);
    final files = await _filesOf(n, record);
    final reader = _ServerRoundFiles(this, n, record, files);
    await reader.prefetch();
    return StoredRound.read(reader);
  }

  /// The URL of the file at [path] in round [n], with a file token that is good for at least
  /// the next minute. The round must have been read by [round] first: the URL names the file's
  /// record, which only that reading lists.
  ///
  /// Rejected: a URL with no token, which would be a locator nobody can open (the files are
  /// protected), and a token good for longer, which PocketBase does not issue.
  @override
  Uri file(int n, String path) {
    final record = _files[n]?[path];
    if (record == null) {
      throw Refused.conflict(
        _files.containsKey(n)
            ? 'round $n has no file $path'
            : 'round $n has not been read yet: read it before naming its files',
      );
    }
    final token = _fileToken;
    final url = _fileUrl(record);
    return token == null ? url : url.replace(queryParameters: {'token': token.token});
  }

  @override
  Future<List<PlacedMark>> marks() async {
    final (marks: marks, rounds: finished) = await _everything();
    final placements = <int, Placements>{
      for (final r in finished.reversed)
        if (r.placements != null)
          r.number: _placements(r, {for (final m in marks.values) m.mark.id: m.mark}),
    };
    return [for (final m in marks.values) _lastPlaced(m, finished, placements)];
  }

  @override
  Future<({Mark mark, WidgetNode node, int round})> raise({
    required FrameKey frame,
    required PinTarget target,
    required String note,
    required String by,
  }) async {
    final aliases = await _aliases();
    final mine = aliases[session.userId];
    if (mine == null) throw Refused.missing('${session.email} is not a member of this galley');
    if (by != mine) {
      throw Refused.invalid('${session.email} raises marks in this galley as $mine, not $by');
    }
    final finished = await _finishedRounds();
    if (finished.isEmpty) throw const Refused.conflict('the galley has no finished round yet');
    final newest = finished.last;
    final stored = await round(newest.number);
    final (:node, :pin) = raiseTarget(
      stored.round,
      newest.number,
      frame: frame,
      target: target,
      note: note,
      by: by,
    );
    final row = await server.send(
      'POST',
      server.api(['collections', 'marks', 'records']),
      token: _token,
      body: {
        'round': newest.id,
        'frame': '$frame',
        'anchor': Anchor.of(node).toJson(),
        'pin': pin.toJson(),
        'note': note,
        'author': session.userId,
      },
    );
    final mark = _markOf(_object(row, 'the new mark'), const [], aliases);
    return (mark: mark, node: node, round: newest.number);
  }

  /// The server numbers the event and takes its author and time; [event] is built with this
  /// machine's clock only to be sent.
  ///
  /// Not retried: of two events sent to one mark at once, the server judges the second against
  /// a history that holds the first (its writes are one transaction at a time), so a refusal
  /// is the answer the user should see, and sending it again would only be refused again.
  @override
  Future<Mark> record(String id, MarkEvent Function(DateTime at) event) async {
    final e = event(_now().toUtc());
    if (eventRefusal(e) case final why?) throw Refused.invalid(why);
    await server.send(
      'POST',
      server.api(['collections', 'events', 'records']),
      token: _token,
      body: {'mark': id, ...eventRow(e), 'author': session.userId},
    );
    final row = _object(
      await server.send('GET', server.api(['collections', 'marks', 'records', id]), token: _token),
      'mark $id',
    );
    final events = await server.list(
      'events',
      filter: 'mark = ${_quoted(id)}',
      sort: 'seq',
      token: _token,
    );
    return _markOf(row, events, await _aliases());
  }

  // --- Reading -------------------------------------------------------------------------------

  Future<List<_RoundRecord>> _finishedRounds() async {
    final rows = await server.list(
      'rounds',
      filter: 'galley = ${_quoted(galleyId)} && finished = true',
      sort: 'number',
      token: _token,
    );
    final rounds = [for (final r in rows) _RoundRecord.of(r)];
    for (final r in rounds) {
      _rounds[r.number] = r;
    }
    return rounds;
  }

  Future<_RoundRecord> _round(int n) async {
    if (_rounds[n] case final known?) return known;
    final rows = await server.list(
      'rounds',
      filter: 'galley = ${_quoted(galleyId)} && finished = true && number = $n',
      token: _token,
    );
    if (rows.isEmpty) throw Refused.missing('the galley has no finished round $n');
    return _rounds[n] = _RoundRecord.of(rows.single);
  }

  Future<Map<String, JsonMap>> _filesOf(int n, _RoundRecord round) async {
    if (_files[n] case final known?) return known;
    final rows = await server.list('files', filter: 'round = ${_quoted(round.id)}', token: _token);
    return _files[n] = {
      for (final f in rows) JsonReader(f, 'a file of round $n').string('path'): f,
    };
  }

  /// Every mark of the galley with its events, and the finished rounds.
  Future<({Map<String, _MarkRows> marks, List<_RoundRecord> rounds})> _everything() async {
    final galley = _quoted(galleyId);
    final aliasesOf = _aliases();
    final finishedOf = _finishedRounds();
    final marksOf = server.list('marks', filter: 'round.galley = $galley', token: _token);
    final eventsOf = server.list(
      'events',
      filter: 'mark.round.galley = $galley',
      sort: 'mark,seq',
      token: _token,
    );
    // The four at once, through Future.wait: the record's `.wait` would hand a refusal on as a
    // ParallelWaitError, which nothing upstream reads (measured: a 401 on any one list did).
    // Future.wait throws the first error as it is and handles the rest.
    await Future.wait([aliasesOf, finishedOf, marksOf, eventsOf]);
    final (aliases, finished, marks, events) = (
      await aliasesOf,
      await finishedOf,
      await marksOf,
      await eventsOf,
    );
    final eventsByMark = <String, List<JsonMap>>{};
    for (final e in events) {
      (eventsByMark[JsonReader(e, 'an event').string('mark')] ??= []).add(e);
    }
    final numberOf = {for (final r in finished) r.id: r.number};
    return (
      marks: {
        for (final row in marks)
          JsonReader(row, 'a mark').string('id'): _MarkRows(
            _markOf(row, eventsByMark[row['id']] ?? const [], aliases),
            numberOf[row['round']],
          ),
      },
      rounds: finished,
    );
  }

  /// Each member's alias by user id: the `by` of everything they wrote. A revoked member is
  /// listed too, so what they wrote still says who wrote it.
  Future<Map<String, String>> _aliases() async {
    final rows = await server.list(
      'members',
      filter: 'galley = ${_quoted(galleyId)}',
      token: _token,
    );
    return {
      for (final m in rows)
        JsonReader(m, 'a member').string('user'): JsonReader(m, 'a member').string('alias'),
    };
  }

  /// A mark row and its event rows as the core's [Mark], through the reader the validator
  /// uses (`markOfRow`), with each author read as their alias and `at` as the server's time.
  Mark _markOf(JsonMap row, List<JsonMap> events, Map<String, String> aliases) {
    final id = '${row['id']}';
    String by(JsonMap r) => switch (aliases[r['author']]) {
      final alias? => alias,
      null => throw Refused.damaged('${r['author']}, who wrote to mark $id, is not a member'),
    };
    try {
      return markOfRow(
        {...row, 'by': by(row), 'at': row['created']},
        [
          for (final e in events) {...e, 'by': by(e), 'at': e['created']},
        ],
        'mark $id',
      );
    } on FormatException catch (e) {
      throw Refused.damaged('the server\'s mark $id does not read: ${e.message}');
    }
  }

  Placements _placements(_RoundRecord round, Map<String, Mark> marks) {
    try {
      return Placements.fromJson(
        round.placements,
        'round ${round.number}.placements',
        (id) => marks[id],
      );
    } on FormatException catch (e) {
      throw Refused.damaged('round ${round.number}\'s placements do not read: ${e.message}');
    }
  }

  /// Where [m] was last placed: the newest finished round whose placements carry it, else the
  /// round it was raised on, as Raised. A mark with neither was raised on a round that is not
  /// finished, which the server refuses; it is read as damage, not hidden.
  PlacedMark _lastPlaced(
    _MarkRows m,
    List<_RoundRecord> finished,
    Map<int, Placements> placements,
  ) {
    for (final r in finished.reversed) {
      if (placements[r.number]?.of(m.mark.id) case final carried?) {
        return PlacedMark(r.number, carried);
      }
    }
    final raisedOn = m.round;
    if (raisedOn == null) {
      throw Refused.damaged('mark ${m.mark.id} was raised on a round that is not finished');
    }
    return PlacedMark(raisedOn, Carried.raised(m.mark));
  }

  Uri _fileUrl(JsonMap record) {
    final r = JsonReader(record, 'a file');
    return server.api(['files', r.string('collectionName'), r.string('id'), r.string('file')]);
  }

  /// A file token, fetched again once [fileTokenReuse] has passed.
  Future<String> _freshFileToken() async {
    final held = _fileToken;
    final now = DateTime.now();
    if (held != null && now.difference(held.at) < fileTokenReuse) return held.token;
    final reply = await server.send('POST', server.api(['files', 'token']), token: _token);
    final token = JsonReader(reply, 'files/token').string('token');
    _fileToken = (token: token, at: now);
    return token;
  }

  /// [value] as a PocketBase filter string. A record id is 15 lower-case letters and digits,
  /// but the quoting does not rest on that.
  static String _quoted(String value) => jsonEncode(value);

  static JsonMap _object(Object? json, String context) => switch (json) {
    final JsonMap m => m,
    _ => throw Refused.environment('the server answered $context with something not a record'),
  };
}

final class _RoundRecord {
  _RoundRecord(this.id, this.number, this.manifest, this.placements);

  factory _RoundRecord.of(JsonMap row) {
    final r = JsonReader(row, 'a round');
    final number = r.integer('number');
    try {
      final manifest = <String, ({String sha256, int size})>{
        for (final (i, e) in r.list('manifest').indexed)
          JsonReader(e, 'round $number.manifest[$i]').string('path'): (
            sha256: JsonReader(e, 'round $number.manifest[$i]').string('sha256'),
            size: JsonReader(e, 'round $number.manifest[$i]').integer('size'),
          ),
      };
      return _RoundRecord(r.string('id'), number, manifest, row['placements']);
    } on FormatException catch (e) {
      throw Refused.damaged('round $number does not read: ${e.message}');
    }
  }

  final String id;
  final int number;
  final Map<String, ({String sha256, int size})> manifest;
  final Object? placements;
}

final class _MarkRows {
  _MarkRows(this.mark, this.round);
  final Mark mark;

  /// The finished round it was raised on, or null when that round is not finished.
  final int? round;
}

/// One round's files on the server, each checked against the manifest's SHA-256 as it is read.
final class _ServerRoundFiles implements RoundFiles {
  _ServerRoundFiles(this._galley, this._n, this._round, this._files);

  final ServerGalley _galley;
  final int _n;
  final _RoundRecord _round;
  final Map<String, JsonMap> _files;
  final _read = <String, Future<Uint8List>>{};

  /// Fetches every JSON file of the round, [ServerGalley.fetchesAtOnce] at a time.
  /// [StoredRound.read] asks for them one after another, which over HTTP is one round trip per
  /// frame, twice: about 600 for the first adopting app's round.
  Future<void> prefetch() async {
    final paths = [
      for (final p in _files.keys)
        if (p.endsWith('.json')) p,
    ];
    var next = 0;
    Future<void> worker() async {
      while (next < paths.length) {
        await _bytes(paths[next++]);
      }
    }

    // Future.wait, not `.wait`: the record extension wraps a failure in a ParallelWaitError,
    // and the caller is owed the Refused that says which file is wrong.
    await Future.wait([for (var i = 0; i < ServerGalley.fetchesAtOnce; i++) worker()]);
  }

  @override
  Future<Object?> json(String path) async {
    if (!_files.containsKey(path)) throw RoundFileMissing(path);
    final bytes = await _bytes(path);
    return jsonDecode(utf8.decode(bytes));
  }

  Future<Uint8List> _bytes(String path) => _read[path] ??= () async {
    final token = await _galley._freshFileToken();
    final url = _galley._fileUrl(_files[path]!).replace(queryParameters: {'token': token});
    final bytes = await _galley.server.bytes(url);
    final listed = _round.manifest[path];
    final actual = '${sha256.convert(bytes)}';
    if (listed == null || listed.sha256 != actual) {
      throw Refused.damaged(
        'round $_n\'s $path is not the file its manifest lists: its SHA-256 is $actual, and the '
        'manifest says ${listed?.sha256 ?? 'nothing'}',
      );
    }
    return bytes;
  }();
}
