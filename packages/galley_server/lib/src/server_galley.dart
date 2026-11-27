import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:galley_core/galley_core.dart';

import 'membership.dart';
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
  Future<GalleyMarks> marks() async {
    final (:marks, :damaged, rounds: finished) = await _everything();
    final known = {for (final m in marks.values) m.mark.id: m.mark};
    final unread = {for (final d in damaged) d.id};
    final placements = <int, Placements>{
      for (final r in finished.reversed)
        if (r.placements != null) r.number: _placements(r, known, unread),
    };
    final placed = <PlacedMark>[];
    final alsoDamaged = <DamagedMark>[];
    for (final m in marks.values) {
      try {
        placed.add(_lastPlaced(m, finished, placements));
      } on Refused catch (e) {
        if (e.kind != RefusalKind.damaged) rethrow;
        alsoDamaged.add(DamagedMark(m.mark.id, e.message));
      }
    }
    return GalleyMarks(placed, damaged: [...damaged, ...alsoDamaged]);
  }

  @override
  Future<({Mark mark, WidgetNode node, int round})> raise({
    required FrameKey frame,
    required PinTarget target,
    required String note,
    required String by,
  }) async {
    final members = await _members();
    final aliases = _aliasesOf(members);
    final mine = _mine(members).alias;
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
    return _markOf(row, events, _aliasesOf(await _members()));
  }

  /// [by] must be the member's alias, as for [raise]. The visit is kept in the member's own
  /// `visits` row, which only they read, and the server judges it with [visitTo] (D17).
  ///
  /// A write refused because the row changed since it was read (the same member, in another
  /// tab) is read and sent again, once: the server judged it against the other tab's visit.
  @override
  Future<int?> opened(int n, {required String by}) async {
    final mine = _mine(await _members());
    if (by != mine.alias) {
      throw Refused.invalid(
        '${session.email} opens rounds in this galley as ${mine.alias}, not $by',
      );
    }
    await _round(n);
    return _visit(n, mine, again: true);
  }

  Future<int?> _visit(int n, Member mine, {required bool again}) async {
    final rows = await server.list('visits', filter: 'member = ${_quoted(mine.id)}', token: _token);
    final row = rows.firstOrNull;
    final kept = row == null ? null : _visitOf(row);
    final next = visitTo(n, kept);
    if (next == kept) return next.before;
    try {
      await server.send(
        row == null ? 'POST' : 'PATCH',
        server.api(['collections', 'visits', 'records', if (row != null) '${row['id']}']),
        token: _token,
        body: {if (row == null) 'member': mine.id, ...next.toJson()},
      );
    } on Refused catch (e) {
      if (!again || e.kind != RefusalKind.invalid) rethrow;
      return _visit(n, mine, again: false);
    }
    return next.before;
  }

  /// A visits row as the core's [Visit]: PocketBase stores an unset `before` as 0.
  static Visit _visitOf(JsonMap row) {
    try {
      return Visit.fromJson({
        'latest': row['latest'],
        if (row['before'] case final before? when before != 0) 'before': before,
      }, 'visit ${row['id']}');
    } on FormatException catch (e) {
      throw Refused.damaged('the server\'s ${e.message}');
    }
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
    // No rounds is also what the server lists for someone who may not read them (a list rule
    // filters; it does not refuse). It is said to be nothing only for a member.
    if (rounds.isEmpty) _mine(await _members());
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
    if (rows.isEmpty) {
      _mine(await _members());
      throw Refused.missing('the galley has no finished round $n');
    }
    return _rounds[n] = _RoundRecord.of(rows.single);
  }

  Future<Map<String, JsonMap>> _filesOf(int n, _RoundRecord round) async {
    if (_files[n] case final known?) return known;
    final rows = await server.list('files', filter: 'round = ${_quoted(round.id)}', token: _token);
    return _files[n] = {
      for (final f in rows) JsonReader(f, 'a file of round $n').string('path'): f,
    };
  }

  /// Every mark of the galley with its events, the marks that do not read, and the finished
  /// rounds.
  Future<({Map<String, _MarkRows> marks, List<DamagedMark> damaged, List<_RoundRecord> rounds})>
  _everything() async {
    final galley = _quoted(galleyId);
    final membersOf = _members();
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
    await Future.wait([membersOf, finishedOf, marksOf, eventsOf]);
    final (members, finished, marks, events) = (
      await membersOf,
      await finishedOf,
      await marksOf,
      await eventsOf,
    );
    // As for the rounds: no marks is nothing only for a member.
    _mine(members);
    final aliases = _aliasesOf(members);
    final eventsByMark = <String, List<JsonMap>>{};
    for (final e in events) {
      (eventsByMark[JsonReader(e, 'an event').string('mark')] ??= []).add(e);
    }
    final numberOf = {for (final r in finished) r.id: r.number};
    final read = <String, _MarkRows>{};
    final damaged = <DamagedMark>[];
    for (final row in marks) {
      // A row with no id cannot be named, so it is not a damaged mark but a damaged list, and
      // refused as one.
      final id = JsonReader(row, 'a mark').string('id');
      try {
        read[id] = _MarkRows(
          _markOf(row, eventsByMark[id] ?? const [], aliases),
          numberOf[row['round']],
        );
      } on Refused catch (e) {
        if (e.kind != RefusalKind.damaged) rethrow;
        damaged.add(DamagedMark(id, e.message));
      }
    }
    return (marks: read, damaged: damaged, rounds: finished);
  }

  /// The galley's members, as the signed-in user may list them: every one, revoked ones too,
  /// for a member; only their own membership for one who was revoked.
  Future<List<Member>> _members() =>
      GalleyMembers(server, galleyId: galleyId, session: session).members();

  /// Each member's alias by user id: the `by` of everything they wrote. A revoked member is
  /// listed too, so what they wrote still says who wrote it.
  static Map<String, String> _aliasesOf(List<Member> members) => {
    for (final m in members) m.user: m.alias,
  };

  /// The signed-in user's membership, refused when they have none or it was revoked: what the
  /// server lists them then is empty, and must not be read as an empty galley.
  Member _mine(List<Member> members) {
    final mine = members.where((m) => m.user == session.userId).firstOrNull;
    if (mine == null) throw Refused.missing('${session.email} is not a member of this galley');
    if (mine.revoked) {
      throw Refused.missing(
        '${session.email}\'s access to this galley was revoked by its owner; what they wrote '
        'is kept',
      );
    }
    return mine;
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

  /// [round]'s placements of [marks]. Those of a mark in [unread] are left out: a placement is
  /// read with its mark, and that mark is listed as damaged already, so its placement would
  /// only refuse every other one of the round. A placement of a mark that is in neither is
  /// still refused: the round names a mark the galley does not have.
  Placements _placements(_RoundRecord round, Map<String, Mark> marks, Set<String> unread) {
    final json = switch (round.placements) {
      final Map<String, Object?> map && {'placements': final List<Object?> all}
          when unread.isNotEmpty =>
        {
          ...map,
          'placements': [
            for (final c in all)
              if (!(c is Map && unread.contains(c['mark']))) c,
          ],
        },
      final other => other,
    };
    try {
      return Placements.fromJson(json, 'round ${round.number}.placements', (id) => marks[id]);
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
        return PlacedMark(r.number, carried, raisedIn: m.round);
      }
    }
    final raisedOn = m.round;
    if (raisedOn == null) {
      throw Refused.damaged('mark ${m.mark.id} was raised on a round that is not finished');
    }
    return PlacedMark(raisedOn, Carried.raised(m.mark), raisedIn: raisedOn);
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
