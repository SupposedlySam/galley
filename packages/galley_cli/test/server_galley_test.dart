@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:galley_cli/galley_cli.dart';
import 'package:galley_core/galley_core.dart';
import 'package:galley_server/galley_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/pocketbase.dart' hide Answer;

// galley_server's ServerGalley against a real server: signed in by a code, raising a mark on
// a round the owner pushed, answered, verified, and carried into the next round. Its unit tests
// (galley_server/test/server_galley_test.dart) prove what it makes of an answer; these prove
// that the answers are the ones a real server gives.

final home = FrameKey({'screen': 'home'});

/// The files of a round of one frame, `home`: a root and a button.
Map<String, List<int>> roundFiles() {
  List<int> j(Object? o) => utf8.encode(jsonEncode(o));
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
  return {
    'index.json': j(RoundManifest(frames: ['records/0.json'], planned: 1).toJson()),
    'records/0.json': j(record),
    'trees/0.json': j(tree.toJson()),
    'frames/0.png': [137, 80, 78, 71],
  };
}

void main() {
  late Directory tmp;
  late LocalServer server;
  late As owner;
  final client = http.Client();

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('galley_server_galley_');
    server = await host('${tmp.path}/data');
    await server.ensureUser('owner@example.com');
    owner = await As.signIn(server, 'owner@example.com');
  });
  tearDownAll(() async {
    client.close();
    await server.close();
    tmp.deleteSync(recursive: true);
  });

  PocketBase pocketBase() => PocketBase(client, server.url);

  /// [email] signed in through [SignIn], by the code the server writes in place of mail.
  Future<Session> signIn(String email) async {
    final sign = SignIn(pocketBase());
    late String otpId;
    final code = await codeAfter(server.otpDirectory, email, () async {
      otpId = await sign.requestCode(email);
    });
    return sign.withCode(otpId, code!);
  }

  /// Round [number] of [galley], pushed whole by the owner with [placements].
  Future<void> push(String galley, int number, [List<Object?> placements = const []]) async {
    final files = roundFiles();
    final made = await owner.create('rounds', {
      'galley': galley,
      'number': number,
      'frames': ['$home'],
      'manifest': [
        for (final MapEntry(:key, :value) in files.entries)
          {'path': key, 'sha256': '${sha256.convert(value)}', 'size': value.length},
      ],
    });
    final id = (made.body as Map)['id'] as String;
    for (final MapEntry(:key, :value) in files.entries) {
      final up = await owner.upload(
        'files',
        {'round': id, 'path': key},
        {'file': (name: key.split('/').last, bytes: value)},
      );
      expect(up.status, 200, reason: '${up.body}');
    }
    final done = await owner.update('rounds', id, {
      'finished': true,
      'placements': {'placements': placements},
    });
    expect(done.status, 200, reason: '${done.body}');
  }

  test('a reviewer raises a mark, the owner answers it, the reviewer verifies it, and the next '
      'round carries it', () async {
    final galley = await owner.makeGalley('Served');
    await owner.create('invites', {'galley': galley, 'email': 'rae@example.com'});
    final raeSession = await signIn('rae@example.com');
    final joined = await As.signIn(server, 'rae@example.com');
    expect(
      (await joined.create('members', {
        'galley': galley,
        'user': joined.id,
        'role': 'reviewer',
        'alias': 'Rae',
      })).status,
      200,
    );
    expect(raeSession.userId, joined.id);
    expect(raeSession.email, 'rae@example.com');
    await push(galley, 1);

    final ownerSession = await signIn('owner@example.com');
    final rae = ServerGalley(pocketBase(), galleyId: galley, session: raeSession);
    final ownerGalley = ServerGalley(pocketBase(), galleyId: galley, session: ownerSession);

    expect(await rae.rounds(), [1]);
    final stored = await rae.round(1);
    expect(stored.frames.single.tree!.nodes.map((n) => n.type), ['App', 'FilledButton']);
    final image = await pocketBase().bytes(rae.file(1, 'frames/0.png'));
    expect(image, [137, 80, 78, 71]);

    final raised = await rae.raise(
      frame: home,
      target: const AtPoint(20, 20),
      note: 'The button is too tight',
      by: 'Rae',
    );
    expect((raised.round, raised.node.type, raised.mark.by), (1, 'FilledButton', 'Rae'));
    expect(raised.mark.at.isUtc, isTrue);

    await expectLater(
      rae.record(raised.mark.id, (at) => Verified(by: 'Rae', at: at)),
      throwsA(isA<Refused>()),
    );
    final answered = await ownerGalley.record(
      raised.mark.id,
      (at) => Answered(
        Answer.wontFix(note: 'It is the system size'),
        by: 'Owner',
        at: at,
      ),
    );
    expect(answered.status, MarkStatus.answered);

    // Round 2 carries the mark; then the reviewer verifies it there.
    final placed = await ownerGalley.marks();
    expect(placed.map((p) => (p.mark.id, p.round, p.carried.placement.name)), [
      (raised.mark.id, 1, 'raised'),
    ]);
    // Round 2's files are round 1's, so round 1's frames carry the mark as round 2's would.
    final carried = (await ownerGalley.round(1)).round.carryAll([placed.single.carried]);
    await push(galley, 2, (Placements(carried).toJson()['placements'] as List).cast());

    final verified = await rae.record(raised.mark.id, (at) => Verified(by: 'Rae', at: at));
    expect(verified.status, MarkStatus.verified);

    final now = await rae.marks();
    expect(now.map((p) => (p.mark.id, p.round)), [(raised.mark.id, 2)]);
    expect(now.single.mark.history.map((e) => (e.runtimeType, e.by)), [
      (Answered, 'Owner'),
      (Verified, 'Rae'),
    ]);
    expect(await rae.rounds(), [1, 2]);
  });
}
