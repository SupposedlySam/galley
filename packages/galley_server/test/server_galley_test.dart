import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:galley_core/galley_core.dart';
import 'package:galley_server/galley_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

// ServerGalley against a server held in memory. What the server itself refuses (its rules and
// hooks) is tested against a real one, through galley_cli's `LocalServer` (host_test.dart);
// these test what the client makes of what it is answered.

final home = FrameKey({'screen': 'home'});

/// One finished round of one frame, `home`, with a tree of a root and a button, and its image.
Map<String, List<int>> roundFiles({String note = ''}) {
  final tree = FrameTree(
    bounds: const LogicalRect(0, 0, 400, 800),
    nodes: [
      WidgetNode(indexPath: const [], type: 'App', rect: const LogicalRect(0, 0, 400, 800)),
      WidgetNode(
        indexPath: const [0],
        type: 'FilledButton',
        rect: const LogicalRect(10, 10, 100, 40),
      ),
    ],
  );
  final record = FrameRecord(
    key: home,
    scenario: 'base',
    uri: Uri.parse('/home'),
    landing: LandedAt(Uri.parse('/home')),
    status: FrameStatus.rendered,
    device: DeviceProfile.pixel7,
    essential: true,
    errors: const [],
    tree: 'trees/0.json',
  ).toJson()..['image'] = 'frames/0.png';
  List<int> j(Object? o) => utf8.encode(jsonEncode(o));
  return {
    'index.json': j(RoundManifest(frames: ['records/0.json'], planned: 1).toJson()),
    'records/0.json': j(record),
    'trees/0.json': j(tree.toJson()),
    'frames/0.png': [1, 2, 3, ...utf8.encode(note)],
  };
}

/// A Galley server in memory: one galley, `g1`, whose owner is `u1` (alias Owner) and whose
/// reviewer is `u2` (alias Rae). It answers the requests ServerGalley makes, and records each
/// list's filter.
final class FakeServer {
  FakeServer() {
    members.addAll([
      {'id': 'm1', 'galley': 'g1', 'user': 'u1', 'alias': 'Owner', 'role': 'owner'},
      {'id': 'm2', 'galley': 'g1', 'user': 'u2', 'alias': 'Rae', 'role': 'reviewer'},
    ]);
  }

  final members = <Map<String, Object?>>[];
  final rounds = <Map<String, Object?>>[];
  final files = <Map<String, Object?>>[];
  final marks = <Map<String, Object?>>[];
  final events = <Map<String, Object?>>[];
  final bytes = <String, List<int>>{};

  /// The filter of every list, by collection.
  final filters = <String, List<String?>>{};

  /// How many file reads were sent.
  var fileReads = 0;

  /// Collections whose list is answered 401, as a server does once a token has run out.
  final signedOut = <String>{};

  var _ids = 0;
  String _id(String prefix) => '$prefix${++_ids}';
  static const created = '2026-11-27 14:34:47.123Z';

  /// Adds finished round [number] with [content] and [placements], and returns its id.
  /// [tamper] replaces a file's bytes after the manifest is made from them.
  String addRound(
    int number,
    Map<String, List<int>> content, {
    Object? placements,
    Map<String, List<int>> tamper = const {},
  }) {
    final id = _id('r');
    rounds.add({
      'id': id,
      'galley': 'g1',
      'number': number,
      'finished': true,
      'placements': placements,
      'manifest': [
        for (final MapEntry(:key, :value) in content.entries)
          {'path': key, 'sha256': '${sha256.convert(value)}', 'size': value.length},
      ],
    });
    for (final MapEntry(:key, :value) in content.entries) {
      final f = _id('f');
      files.add({
        'id': f,
        'collectionName': 'files',
        'round': id,
        'path': key,
        'file': '${key.replaceAll('/', '_')}_abc123',
      });
      bytes[f] = tamper[key] ?? value;
    }
    return id;
  }

  late final client = MockClient((request) async {
    final s = request.url.pathSegments;
    http.Response ok(Object? body) => http.Response(jsonEncode(body), 200);
    if (s case ['api', 'collections', final c, 'records'] when request.method == 'GET') {
      if (signedOut.contains(c)) {
        return http.Response(
          jsonEncode({'message': 'The request requires valid record authorization token.'}),
          401,
        );
      }
      (filters[c] ??= []).add(request.url.queryParameters['filter']);
      return ok({'items': _collection(c)});
    }
    if (s case ['api', 'collections', 'marks', 'records', final id]) {
      return ok(marks.singleWhere((m) => m['id'] == id));
    }
    if (s case ['api', 'collections', final c, 'records'] when request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final id = _id(c[0]);
      final row = {'id': id, ...body, 'created': created};
      if (c == 'events') {
        row['seq'] = events.where((e) => e['mark'] == body['mark']).length + 1;
      }
      _collection(c).add(row);
      return ok(row);
    }
    if (s case ['api', 'files', 'token']) return ok({'token': 'ft'});
    if (s case ['api', 'files', 'files', final id, _]) {
      fileReads++;
      if (request.url.queryParameters['token'] != 'ft') return http.Response('{}', 404);
      return http.Response.bytes(bytes[id]!, 200);
    }
    return http.Response(jsonEncode({'message': 'no route ${request.url}'}), 404);
  });

  List<Map<String, Object?>> _collection(String c) => switch (c) {
    'members' => members,
    'rounds' => rounds,
    'files' => files,
    'marks' => marks,
    'events' => events,
    _ => throw ArgumentError(c),
  };
}

void main() {
  late FakeServer fake;
  ServerGalley as(String user, String email) => ServerGalley(
    PocketBase(fake.client, Uri.parse('http://127.0.0.1:8090/'), backoff: (_) => Duration.zero),
    galleyId: 'g1',
    session: Session(userId: user, email: email, token: 'tok-$user'),
  );
  setUp(() => fake = FakeServer());

  test('lists the finished rounds of its galley, in number order', () async {
    fake
      ..addRound(2, roundFiles())
      ..addRound(1, roundFiles());
    // The fake answers in the order asked for; the client asks the server to sort.
    fake.rounds.sort((a, b) => (a['number'] as int).compareTo(b['number'] as int));
    expect(await as('u2', 'rae@x.test').rounds(), [1, 2]);
    expect(fake.filters['rounds'], ['galley = "g1" && finished = true']);
  });

  test('reads a round, every JSON file checked against the manifest\'s SHA-256', () async {
    fake.addRound(1, roundFiles());
    final galley = as('u2', 'rae@x.test');
    final stored = await galley.round(1);
    expect(stored.frames.map((f) => f.record.key), [home]);
    expect(stored.frames.single.tree!.nodes.map((n) => n.type), ['App', 'FilledButton']);
    // The JSON files only: index, record, tree. The image is the canvas's to read.
    expect(fake.fileReads, 3);
    expect(
      '${galley.file(1, 'frames/0.png')}',
      'http://127.0.0.1:8090/api/files/files/f5/frames_0.png_abc123?token=ft',
    );
    expect(() => galley.file(1, 'frames/9.png'), throwsA(isA<Refused>()));
    expect(() => galley.file(2, 'frames/0.png'), throwsA(isA<Refused>()));
  });

  test('a file that is not what the manifest lists is refused, naming it', () async {
    final files = roundFiles();
    fake.addRound(1, files, tamper: {'trees/0.json': utf8.encode('{"bounds": "x"}')});
    await expectLater(
      as('u2', 'rae@x.test').round(1),
      throwsA(
        isA<Refused>()
            .having((r) => r.kind, 'kind', RefusalKind.damaged)
            .having((r) => r.message, 'message', contains('trees/0.json'))
            .having(
              (r) => r.message,
              'message',
              contains('${sha256.convert(files['trees/0.json']!)}'),
            ),
      ),
    );
  });

  group('raise', () {
    test('pins the widget on the newest finished round, as the signed-in member', () async {
      fake.addRound(1, roundFiles());
      final r2 = fake.addRound(2, roundFiles());
      final raised = await as(
        'u2',
        'rae@x.test',
      ).raise(frame: home, target: const AtPoint(20, 20), note: 'too tight', by: 'Rae');
      expect(raised.round, 2);
      expect(raised.node.type, 'FilledButton');
      expect(raised.mark.by, 'Rae');
      expect(raised.mark.at, DateTime.parse(FakeServer.created));
      expect(fake.marks, hasLength(1));
      expect(fake.marks.single, containsPair('round', r2));
      expect(fake.marks.single, containsPair('author', 'u2'));
      expect(fake.marks.single, containsPair('frame', '$home'));
    });

    test('is refused before anything is sent for another member\'s alias, a frame the round '
        'lacks, a miss, or a blank note', () async {
      fake.addRound(1, roundFiles());
      final rae = as('u2', 'rae@x.test');
      Future<void> refused(Future<Object?> raise, String why) => expectLater(
        raise,
        throwsA(isA<Refused>().having((r) => r.message, 'message', contains(why))),
      );
      await refused(
        rae.raise(frame: home, target: const AtPoint(20, 20), note: 'x', by: 'Owner'),
        'as Rae, not Owner',
      );
      await refused(
        rae.raise(
          frame: FrameKey({'screen': 'away'}),
          target: const AtPoint(1, 1),
          note: 'x',
          by: 'Rae',
        ),
        'has no frame screen=away',
      );
      await refused(
        rae.raise(frame: home, target: const AtNode([7]), note: 'x', by: 'Rae'),
        'in frame screen=home',
      );
      await refused(
        rae.raise(frame: home, target: const AtPoint(20, 20), note: ' ', by: 'Rae'),
        'says what is wrong',
      );
      await refused(
        as(
          'u9',
          'stranger@x.test',
        ).raise(frame: home, target: const AtPoint(1, 1), note: 'x', by: 'S'),
        'not a member',
      );
      expect(fake.marks, isEmpty);
    });
  });

  group('marks', () {
    test('each where it was last placed, with its events in order, scoped to the galley', () async {
      fake.addRound(1, roundFiles());
      final rae = as('u2', 'rae@x.test'), owner = as('u1', 'owner@x.test');
      final m = (await rae.raise(
        frame: home,
        target: const AtPoint(20, 20),
        note: 'tight',
        by: 'Rae',
      )).mark;
      // Not yet carried: Raised, in the round it was raised on.
      var placed = await owner.marks();
      expect(placed.map((p) => (p.mark.id, p.round, p.carried.placement.name)), [
        (m.id, 1, 'raised'),
      ]);

      // Round 2 carries it.
      fake.addRound(
        2,
        roundFiles(),
        placements: Placements([Carried(m, const Unplaced('its frame has no tree'), m.anchor)])
            .toJson(),
      );
      final answered = await owner.record(
        m.id,
        (at) => Answered(
          Answer.wontFix(note: 'by design'),
          by: 'Owner',
          at: at,
        ),
      );
      expect(answered.status, MarkStatus.answered);
      expect(answered.history.single.by, 'Owner');
      await rae.record(m.id, (at) => Reopened('still tight', by: 'Rae', at: at));

      placed = await rae.marks();
      expect(placed.map((p) => (p.mark.id, p.round, p.carried.placement.name)), [
        (m.id, 2, 'unplaced'),
      ]);
      expect(placed.single.mark.history.map((e) => (e.runtimeType, e.by)), [
        (Answered, 'Owner'),
        (Reopened, 'Rae'),
      ]);
      expect(fake.events.map((e) => e['seq']), [1, 2]);
      expect(fake.events.map((e) => e['author']), ['u1', 'u2']);
      // A member of two galleys reads only this one's.
      expect(fake.filters['marks'], everyElement('round.galley = "g1"'));
      expect(fake.filters['events']!.where((f) => f == 'mark.round.galley = "g1"'), hasLength(2));
      expect(fake.filters['members'], everyElement('galley = "g1"'));
    });

    test('a list the server refuses is that refusal, whichever of the four it is', () async {
      fake.addRound(1, roundFiles());
      for (final c in ['members', 'rounds', 'marks', 'events']) {
        fake.signedOut
          ..clear()
          ..add(c);
        await expectLater(
          as('u1', 'owner@x.test').marks(),
          throwsA(
            isA<Refused>()
                .having((r) => r.kind, 'kind', RefusalKind.environment)
                .having((r) => r.message, 'message', contains('sign in again')),
          ),
          reason: c,
        );
      }
      fake.signedOut.clear();
      expect(await as('u1', 'owner@x.test').marks(), isEmpty, reason: 'the control');
    });

    test('a mark by someone who is not a member is damage, not a mark by nobody', () async {
      fake.addRound(1, roundFiles());
      final m = (await as(
        'u2',
        'rae@x.test',
      ).raise(frame: home, target: const AtPoint(20, 20), note: 'tight', by: 'Rae')).mark;
      fake.marks.single['author'] = 'u7';
      await expectLater(
        as('u1', 'owner@x.test').marks(),
        throwsA(
          isA<Refused>()
              .having((r) => r.kind, 'kind', RefusalKind.damaged)
              .having((r) => r.message, 'message', allOf(contains('u7'), contains(m.id))),
        ),
      );
    });
  });
}
