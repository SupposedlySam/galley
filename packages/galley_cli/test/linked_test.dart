@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:galley_cli/galley_cli.dart';
import 'package:galley_cli/src/linked.dart';
import 'package:galley_core/galley_core.dart';
import 'package:galley_server/galley_server.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/pocketbase.dart' hide Answer;
import 'support/round.dart';

// A galley on a real server, pushed, joined and reviewed: galley_server's RoundPush,
// GalleyMembers and ServerAccount, and the CLI's commands once `.galley/` is linked
// (docs/DESIGN.md D15, "The commands follow the galley"). What the server refuses is its
// rules' and hooks' (host_test.dart); these prove the client takes the path they allow.

/// Every request it sends goes through [before] first, which may do something in between, or
/// throw as a dropped connection would.
final class _Between extends http.BaseClient {
  _Between(this._inner);
  final http.Client _inner;
  Future<void> Function(http.BaseRequest request)? before;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await before?.call(request);
    return _inner.send(request);
  }
}

bool _finishing(http.BaseRequest r) =>
    r.method == 'PATCH' && r.url.path.contains('/collections/rounds/records/');

bool _uploading(http.BaseRequest r) =>
    r.method == 'POST' && r.url.path.endsWith('/collections/files/records');

void main() {
  late Directory tmp;
  late LocalServer server;
  final inner = http.Client();
  final client = _Between(inner);
  var emails = 0;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('galley_linked_');
    server = await host('${tmp.path}/data');
  });
  tearDownAll(() async {
    inner.close();
    await server.close();
    tmp.deleteSync(recursive: true);
  });
  tearDown(() => client.before = null);

  PocketBase pocketBase() => PocketBase(client, server.url);

  /// A new user, signed in through [SignIn] by the code the server writes in place of mail.
  Future<Session> signIn(String email) async {
    await server.ensureUser(email);
    final sign = SignIn(pocketBase());
    late String otpId;
    final code = await codeAfter(server.otpDirectory, email, () async {
      otpId = await sign.requestCode(email);
    });
    return sign.withCode(otpId, code!);
  }

  /// A fresh owner with a galley, and a reviewer, Rae, who has joined it.
  Future<({ServerGalley owner, ServerGalley rae, String id})> galleyOfTwo() async {
    final n = ++emails;
    final ownerSession = await signIn('owner$n@example.com');
    final id = await ServerAccount(pocketBase(), ownerSession).create('G$n', alias: 'Owner');
    await GalleyMembers(
      pocketBase(),
      galleyId: id,
      session: ownerSession,
    ).invite('Rae$n@Example.com');
    final raeSession = await signIn('rae$n@example.com');
    await ServerAccount(pocketBase(), raeSession).join(id, alias: 'Rae');
    return (
      owner: ServerGalley(pocketBase(), galleyId: id, session: ownerSession),
      rae: ServerGalley(pocketBase(), galleyId: id, session: raeSession),
      id: id,
    );
  }

  /// The round support/round.dart writes, rendered in a directory of its own.
  Future<({List<PushFile> files, StoredRound stored, String dir})> rendered() async {
    final dir = Directory('${tmp.path}/render${++emails}').path;
    writeRoundAt(dir);
    // As `galley pack` leaves one: the local carry-forward's placements, which the server
    // computes for itself and must never be sent.
    File('$dir/placements.json').writeAsStringSync('{"marks":[]}');
    return (
      files: await pushFilesOf(dir),
      stored: await GalleyDirectory.readRendered(dir, 'the render'),
      dir: dir,
    );
  }

  Future<Pushed> push(ServerGalley as, {void Function(String)? uploaded}) async {
    final r = await rendered();
    return RoundPush(as).push(
      frames: [for (final f in r.stored.frames) f.record.key],
      files: r.files,
      round: r.stored.round,
      uploaded: uploaded,
    );
  }

  group('members', () {
    test('where a user stands: outside, invited, joined, revoked, and joined again', () async {
      final owner = await signIn('stander-owner@example.com');
      final id = await ServerAccount(pocketBase(), owner).create('Stand', alias: 'O');
      final other = await ServerAccount(pocketBase(), owner).create('Other', alias: 'O');
      final members = GalleyMembers(pocketBase(), galleyId: id, session: owner);
      final user = await signIn('stander@example.com');
      final account = ServerAccount(pocketBase(), user);
      Future<String> of(String galley) async => switch (await account.standingIn(galley)) {
        Joined(:final member) => 'joined ${member.alias}',
        RevokedFrom(:final member) => 'revoked ${member.alias}',
        InvitedTo() => 'invited',
        Outside() => 'outside',
      };
      expect(await of(id), 'outside');
      await members.invite('stander@example.com');
      expect(await of(id), 'invited');
      // An invite is to one galley: the owner's other one is still outside.
      expect(await of(other), 'outside');
      await account.join(id, alias: 'S');
      expect(await of(id), 'joined S');
      await members.setRevoked('S');
      expect(await of(id), 'revoked S');
      await members.setRevoked('S', revoked: false);
      expect(await of(id), 'joined S');
      expect(await of(other), 'outside');
    });

    test(
      'a galley is made with its owner, who invites a reviewer, who joins it by the invite',
      () async {
        final owner = await signIn('maker@example.com');
        final account = ServerAccount(pocketBase(), owner);
        final id = await account.create('Made', alias: 'Maker');
        expect(id, matches(RegExp(r'^[a-z0-9]{15}$')));
        expect((await account.memberships()).map((m) => (m.galley, m.alias, m.role)), [
          (id, 'Maker', MemberRole.owner),
        ]);

        final members = GalleyMembers(pocketBase(), galleyId: id, session: owner);
        await members.invite('  Joiner@Example.COM ');
        final joiner = await signIn('joiner@example.com');
        final joining = ServerAccount(pocketBase(), joiner);
        expect(await joining.invites(), [id]);
        expect(await joining.memberships(), isEmpty);
        final joined = await joining.join(id, alias: 'Jo');
        expect((joined.alias, joined.role, joined.revoked), ('Jo', MemberRole.reviewer, false));
        // The invite is burned: a second join has none to use.
        expect(await joining.invites(), isEmpty);
        await expectLater(joining.join(id, alias: 'Jo2'), throwsA(isA<Refused>()));
        expect((await members.members()).map((m) => (m.alias, m.role.name, m.revoked)), [
          ('Maker', 'owner', false),
          ('Jo', 'reviewer', false),
        ]);
      },
    );

    test('a revoked reviewer is told so, not shown an empty galley, and a restored one reads '
        'it again', () async {
      final g = await galleyOfTwo();
      await push(g.owner);
      expect(await g.rae.rounds(), [1]);
      final members = GalleyMembers(pocketBase(), galleyId: g.id, session: g.owner.session);

      final revoked = await members.setRevoked('Rae');
      expect(revoked.revoked, isTrue);
      final isRevoked = throwsA(
        isA<Refused>()
            .having((r) => r.kind, 'kind', RefusalKind.missing)
            .having((r) => r.message, 'message', contains('revoked')),
      );
      // A fresh reader each time: what one read before is not what the server says now.
      ServerGalley rae() => ServerGalley(pocketBase(), galleyId: g.id, session: g.rae.session);
      await expectLater(rae().rounds(), isRevoked);
      await expectLater(rae().marks(), isRevoked);
      await expectLater(rae().round(1), isRevoked);
      // The owner still reads the galley whole.
      expect(await g.owner.rounds(), [1]);

      await members.setRevoked('Rae', revoked: false);
      expect(await rae().rounds(), [1]);
      await expectLater(
        members.setRevoked('Nobody'),
        throwsA(isA<Refused>().having((r) => r.message, 'message', contains('Owner, Rae'))),
      );
    });

    test('an empty galley is empty for a member', () async {
      final g = await galleyOfTwo();
      expect(await g.rae.rounds(), isEmpty);
      expect(await g.rae.marks(), isEmpty);
    });
  });

  group('push', () {
    test('a round is pushed whole, read back as it was rendered, and the next one carries '
        'every mark', () async {
      final g = await galleyOfTwo();
      final landed = <String>[];
      final first = await push(g.owner, uploaded: landed.add);
      expect((first.number, first.resumed), (1, false));
      expect(first.carried, isEmpty);
      final r = await rendered();
      expect(landed..sort(), [for (final f in r.files) f.path]);
      expect(landed, isNot(contains('placements.json')));

      final stored = await g.rae.round(1);
      expect(stored.frames.map((f) => f.record.key), [drawn, blank]);
      expect(await pocketBase().bytes(g.rae.file(1, 'frames/drawn.png')), png);

      final raised = await g.rae.raise(
        frame: drawn,
        target: const AtPoint(20, 20),
        note: 'The card is cramped',
        by: 'Rae',
      );
      final second = await push(g.owner);
      expect(second.number, 2);
      expect(second.carried.map((c) => (c.mark.id, c.placement.name)), [(raised.mark.id, 'exact')]);
      expect((await g.rae.marks()).map((p) => (p.mark.id, p.round)), [(raised.mark.id, 2)]);
      expect(await g.rae.rounds(), [1, 2]);
    });

    test('a mark raised while the round is finished is carried in a second try', () async {
      final g = await galleyOfTwo();
      await push(g.owner);
      String? raisedId;
      var finishes = 0;
      client.before = (request) async {
        if (!_finishing(request)) return;
        // The first finish carries the marks read before this one is raised; the server
        // refuses it, and the push carries again.
        if (++finishes == 1) {
          raisedId = (await g.rae.raise(
            frame: drawn,
            target: const AtPoint(20, 20),
            note: 'Raised mid-push',
            by: 'Rae',
          )).mark.id;
        }
      };
      final pushed = await push(g.owner);
      expect(finishes, 2);
      expect(pushed.number, 2);
      expect(pushed.carried.map((c) => c.mark.id), [raisedId]);
      expect((await g.owner.marks()).map((p) => (p.mark.id, p.round)), [(raisedId, 2)]);
    });

    test(
      'a push that stopped is finished by the same files, sending only what is missing',
      () async {
        final g = await galleyOfTwo();
        var uploads = 0;
        client.before = (request) async {
          if (_uploading(request) && ++uploads == 3) {
            throw http.ClientException('the connection dropped');
          }
        };
        await expectLater(
          push(g.owner),
          throwsA(isA<Refused>().having((r) => r.message, 'message', contains('dropped'))),
        );
        client.before = null;
        // Begun and not finished: no reviewer sees it.
        expect(await g.rae.rounds(), isEmpty);

        final landed = <String>[];
        final resumed = await push(g.owner, uploaded: landed.add);
        expect((resumed.number, resumed.resumed), (1, true));
        final all = (await rendered()).files.length;
        expect(landed.length, lessThan(all));
        expect(landed, isNotEmpty);
        expect(await g.rae.rounds(), [1]);
        expect((await g.rae.round(1)).frames, hasLength(2));
      },
    );

    test('a round begun with other files is refused, naming it, and nothing is numbered past '
        'it', () async {
      final g = await galleyOfTwo();
      final r = await rendered();
      // Begun by hand with one file of the two-frame round's, and never finished.
      await pocketBase().send(
        'POST',
        pocketBase().api(['collections', 'rounds', 'records']),
        token: g.owner.session.token,
        body: {
          'galley': g.id,
          'number': 1,
          'frames': ['$drawn', '$blank'],
          'manifest': [
            {
              'path': r.files.first.path,
              'sha256': r.files.first.sha256,
              'size': r.files.first.size,
            },
          ],
        },
      );
      await expectLater(
        push(g.owner),
        throwsA(
          isA<Refused>()
              .having((e) => e.kind, 'kind', RefusalKind.conflict)
              .having((e) => e.message, 'message', contains('round 1 was begun')),
        ),
      );
      final rows = await pocketBase().list(
        'rounds',
        filter: 'galley = "${g.id}"',
        token: g.owner.session.token,
      );
      expect(rows.map((row) => (row['number'], row['finished'])), [(1, false)]);
    });

    test('a file that changed after it was listed is refused before it is sent', () async {
      final g = await galleyOfTwo();
      final r = await rendered();
      final changed = [
        for (final f in r.files)
          f.path == 'frames/drawn.png'
              ? PushFile(
                  path: f.path,
                  sha256: f.sha256,
                  size: f.size,
                  read: () async => Uint8List.fromList([...png.reversed]),
                )
              : f,
      ];
      await expectLater(
        RoundPush(g.owner).push(
          frames: [for (final f in r.stored.frames) f.record.key],
          files: changed,
          round: r.stored.round,
        ),
        throwsA(
          isA<Refused>().having((e) => e.message, 'message', contains('frames/drawn.png changed')),
        ),
      );
      final files = await pocketBase().list('files', token: g.owner.session.token);
      expect(files.map((f) => f['path']), isNot(contains('frames/drawn.png')));
      expect(await g.rae.rounds(), isEmpty);
    });

    test('a round that lists a path twice is refused before anything is begun', () async {
      final g = await galleyOfTwo();
      final r = await rendered();
      await expectLater(
        RoundPush(g.owner).push(
          frames: [for (final f in r.stored.frames) f.record.key],
          files: [...r.files, r.files.first],
          round: r.stored.round,
        ),
        throwsA(
          isA<Refused>().having(
            (e) => e.message,
            'message',
            contains('lists ${r.files.first.path} twice'),
          ),
        ),
      );
      final rows = await pocketBase().list(
        'rounds',
        filter: 'galley = "${g.id}"',
        token: g.owner.session.token,
      );
      expect(rows, isEmpty);
      // The same files, once each, are pushed: the refusal was the repeat, not the round.
      expect((await push(g.owner)).number, 1);
    });

    test('only the owner pushes', () async {
      final g = await galleyOfTwo();
      await expectLater(push(g.rae), throwsA(isA<Refused>()));
      expect(await g.owner.rounds(), isEmpty);
      final rows = await pocketBase().list(
        'rounds',
        filter: 'galley = "${g.id}"',
        token: g.owner.session.token,
      );
      expect(rows, isEmpty);
    });
  });

  group('commands', () {
    /// One person at their own machine: their own app, `.galley/` and sign-ins.
    ({Future<int> Function(List<String>) run, StringBuffer out, StringBuffer err, String app})
    machine(String name, {RoundRenderer? renderer}) {
      final app = Directory('${tmp.path}/$name')..createSync();
      final out = StringBuffer(), err = StringBuffer();
      String? email;
      return (
        run: (args) {
          out.clear();
          err.clear();
          if (args.first == 'login') {
            email = args[args.indexOf('--email') + 1].toLowerCase();
            final f = File('${server.otpDirectory}/$email');
            if (f.existsSync()) f.deleteSync();
          }
          return runGalley(
            ['--app', app.path, ...args],
            GalleyContext(
              out: out,
              err: err,
              client: client,
              environment: {'GALLEY_CACHE': '${app.path}/cache', 'GALLEY_BY': 'Ambient'},
              renderer: ({required app, required test, required flutter, required testArgs}) =>
                  renderer ?? (throw StateError('$name renders nothing')),
              // The code the server wrote for this email, waited for as a person would. A
              // blocking wait is fine: the server is another process.
              readLine: () {
                final f = File('${server.otpDirectory}/$email');
                for (var i = 0; i < 50; i++) {
                  if (f.existsSync() && f.readAsStringSync().endsWith('\n')) {
                    return f.readAsStringSync().trim();
                  }
                  sleep(const Duration(milliseconds: 100));
                }
                return null;
              },
            ),
          );
        },
        out: out,
        err: err,
        app: app.path,
      );
    }

    test('an owner links, pushes and answers; a reviewer joins, marks and verifies; each as '
        'their alias', () async {
      await server.ensureUser('cli-owner@example.com');
      final owner = machine('owner', renderer: _Rendering());
      final url = '${server.url}';
      expect(await owner.run(['login', url, '--email', 'CLI-Owner@example.com']), 0);
      expect('${owner.out}', contains('as cli-owner@example.com'));
      expect(owner.err.toString(), contains('Type the code'));
      // The token is the user's, in their cache, readable by them alone; never in `.galley/`.
      final sessions = Directory('${owner.app}/cache/sessions').listSync();
      expect(sessions, hasLength(1));
      if (!Platform.isWindows) {
        expect(sessions.single.statSync().modeString(), 'rw-------');
        expect(Directory('${owner.app}/cache/sessions').statSync().modeString(), 'rwx------');
      }

      expect(await owner.run(['push']), 1);
      expect('${owner.err}', contains('not linked to a server'));
      expect(await owner.run(['link', url, '--create', 'CLI', '--alias', 'Ann']), 0);
      final link = jsonDecode(File('${owner.app}/.galley/server.json').readAsStringSync());
      expect((link as Map).keys, ['url', 'galley']);
      expect(File('${owner.app}/.galley/server.json').readAsStringSync(), isNot(contains('token')));
      final id = link['galley'] as String;
      // The canvas is at the server's root, and the link names the galley (galley host).
      final canvas = Uri.parse(url).replace(path: '/', queryParameters: {'galley': id});
      expect('${owner.out}', contains('Its canvas: $canvas\n'));

      expect(await owner.run(['pack']), 1);
      expect('${owner.err}', contains('`galley push`'));
      expect(await owner.run(['serve']), 1);
      expect('${owner.err}', allOf(contains('linked to'), contains('on the server: $canvas.')));

      expect(await owner.run(['push']), 0, reason: '${owner.err}');
      expect('${owner.out}', contains('Round 1: 2 of 2 planned frames'));
      expect(Directory('${owner.app}/.galley/push').existsSync(), isFalse);

      expect(await owner.run(['invite', 'cli-rae@example.com']), 0, reason: '${owner.err}');
      expect('${owner.out}', contains('They open $canvas and sign in with that email'));
      final rae = machine('rae');
      expect(await rae.run(['login', url, '--email', 'cli-rae@example.com']), 0);
      // The link holds no token, so it may come from a teammate's checkout before Rae joins:
      // the commands say how to join, not "not a member".
      File('${rae.app}/.galley/server.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(File('${owner.app}/.galley/server.json').readAsStringSync());
      expect(await rae.run(['pull']), 1);
      expect(
        '${rae.err}',
        allOf(contains('is invited to galley $id'), contains('--galley $id --alias <your name>')),
      );
      File('${rae.app}/.galley/server.json').deleteSync();
      expect(await rae.run(['link', url, '--galley', id]), 64);
      expect('${rae.err}', contains('--alias'));
      expect(
        await rae.run(['link', url, '--galley', id, '--alias', 'Rae']),
        0,
        reason: '${rae.err}',
      );
      expect(await rae.run(['invite', 'x@example.com']), 1);
      expect('${rae.err}', contains('only the galley\'s owner invites'));
      expect(await owner.run(['members']), 0);
      expect('${owner.out}', 'Ann  owner\nRae  reviewer\n');

      final mark = ['mark', '--frame', '$drawn', '--at', '20,20', '--note', 'Cramped'];
      expect(await rae.run([...mark, '--by', 'Someone']), 64);
      expect('${rae.err}', contains('--by is not given'));
      expect(await rae.run(mark), 0, reason: '${rae.err}');
      final markId = '${rae.out}'.split(':').first;
      expect('${rae.out}', contains('in round 1'));

      expect(await owner.run(['pull', '--json']), 0);
      final pulled = jsonDecode('${owner.out}') as Map;
      expect(pulled['latest_round'], 1);
      expect(
        [
          for (final i in (pulled['items'] as List).cast<Map<String, Object?>>())
            (i['id'], (i['mark'] as Map)['by']),
        ],
        [(markId, 'Rae')],
      );

      expect(await owner.run(['answer', markId, 'wont-fix', '--note', 'By design']), 0);
      expect('${owner.out}', '$markId: answered\n');
      expect(await owner.run(['push']), 0, reason: '${owner.err}');
      expect('${owner.out}', contains('$markId  exact'));
      expect(await rae.run(['verify', markId]), 0, reason: '${rae.err}');
      expect('${rae.out}', '$markId: verified\n');

      expect(await rae.run(['pull', '--json', '--all']), 0);
      final item = ((jsonDecode('${rae.out}') as Map)['items'] as List).single as Map;
      expect(item['round'], 2);
      expect(
        [
          for (final e in ((item['mark'] as Map)['history'] as List).cast<Map<String, Object?>>())
            (e['event'], e['by']),
        ],
        [('answered', 'Ann'), ('verified', 'Rae')],
      );

      // The ambient GALLEY_BY signs nothing on the server; the alias does.
      expect('${rae.out}', isNot(contains('Ambient')));

      expect(await owner.run(['revoke', 'Rae']), 0);
      expect(await rae.run(['pull']), 1);
      // Told by the command, before it reads the galley, naming the galley and the server.
      expect(
        '${rae.err}',
        allOf(contains('access to galley $id on $url'), contains('was revoked by its owner')),
      );
      expect(await rae.run(['mark', '--frame', '$drawn', '--at', '20,20', '--note', 'x']), 1);
      expect(
        '${rae.err}',
        allOf(contains('access to galley $id on $url'), contains('was revoked by its owner')),
      );
      expect(await owner.run(['revoke', 'Rae', '--restore']), 0);
      expect(await rae.run(['pull']), 0, reason: '${rae.err}');

      expect(await rae.run(['unlink']), 0);
      expect(File('${rae.app}/.galley/server.json').existsSync(), isFalse);
      expect(await rae.run(['pull', '--all']), 0);
      expect('${rae.out}', 'No marks.\n');
    });

    test(
      'a push that stopped keeps its render, and --resume sends it without rendering again',
      () async {
        await server.ensureUser('resumer@example.com');
        final rendering = _Rendering();
        final owner = machine('resumer', renderer: rendering);
        final url = '${server.url}';
        expect(await owner.run(['login', url, '--email', 'resumer@example.com']), 0);
        expect(await owner.run(['link', url, '--create', 'Resumed', '--alias', 'R']), 0);

        var uploads = 0;
        client.before = (request) async {
          if (_uploading(request) && ++uploads == 2) throw http.ClientException('dropped');
        };
        expect(await owner.run(['push']), 1);
        expect('${owner.err}', contains('kept in ${owner.app}/.galley/push'));
        expect('${owner.err}', contains('--resume'));
        client.before = null;
        expect(rendering.renders, 1);

        expect(await owner.run(['push']), 1);
        expect('${owner.err}', contains('a push stopped'));
        expect(await owner.run(['push', '--resume']), 0, reason: '${owner.err}');
        expect(rendering.renders, 1);
        expect('${owner.out}', contains('Round 1, which an earlier push began,'));
        expect(Directory('${owner.app}/.galley/push').existsSync(), isFalse);
        expect(await owner.run(['push', '--resume']), 1);
        expect('${owner.err}', contains('no render kept'));
      },
    );
  });
}

/// Renders support/round.dart's round, and counts how often.
final class _Rendering implements RoundRenderer {
  var renders = 0;

  @override
  Future<int> render(String outDir) async {
    renders++;
    writeRoundAt(outDir);
    return 0;
  }
}
