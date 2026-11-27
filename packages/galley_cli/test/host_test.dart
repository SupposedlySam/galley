@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:galley_cli/galley_cli.dart';
import 'package:test/test.dart';

import 'package:galley_cli/src/rest.dart';

import 'support/pocketbase.dart';

// galley_server's schema and hooks, on the PocketBase `galley host` runs (docs/DESIGN.md D15).
// They are tested here, not in galley_server, because this is where they are run: through
// LocalServer, with the validator it compiles. The first run fetches PocketBase into the
// galley cache, as `galley host` does; later runs find it there.

/// [path]'s permission bits, as `stat` shows them: `rwx------`.
String modeOf(String path) => FileStat.statSync(path).modeString().substring(0, 9);

void main() {
  late Directory tmp;
  late LocalServer server;
  late As owner;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('galley_host_');
    server = await host('${tmp.path}/data');
    await server.ensureUser('Owner@Example.com');
    owner = await As.signIn(server, 'owner@example.com');
  });
  tearDownAll(() async {
    await server.close();
    tmp.deleteSync(recursive: true);
  });

  /// A user who is in no galley yet.
  Future<As> stranger(String email) async {
    await server.ensureUser(email);
    return As.signIn(server, email);
  }

  /// Round [number] of [galley], with a one-file manifest unless given [manifest].
  Map<String, Object?> round(String galley, int number, [List<Object?>? manifest]) => {
    'galley': galley,
    'number': number,
    'frames': ['screen=home'],
    'manifest':
        manifest ??
        [
          {'path': 'index.json', 'sha256': 'a' * 64, 'size': 10},
        ],
  };

  /// A file of [size] bytes, for a manifest that says so.
  ({String name, List<int> bytes}) bytes(int size) => (name: 'f.bin', bytes: List.filled(size, 7));

  /// Uploads [size] bytes as [path] of [round] ([galley]'s), as [who].
  Future<Answer> upload(As who, String round, String path, int size) =>
      who.upload('files', {'round': round, 'path': path}, {'file': bytes(size)});

  /// Finishes [round] with [placements] (the core's Carried form), as [who].
  Future<Answer> finish(As who, String round, [List<Object?> placements = const []]) =>
      who.update('rounds', round, {
        'finished': true,
        'placements': {'placements': placements},
      });

  /// Round [number] of [galley], pushed whole: its one file uploaded, and finished with
  /// [placements]. Its id.
  Future<String> pushed(String galley, int number, [List<Object?> placements = const []]) async {
    final made = await owner.create('rounds', round(galley, number));
    if (made.status != 200) throw StateError('round $number was not made: ${made.body}');
    final id = (made.body as Map)['id'] as String;
    for (final a in [
      await upload(owner, id, 'index.json', 10),
      await finish(owner, id, placements),
    ]) {
      if (a.status != 200) throw StateError('round $number was not pushed: ${a.body}');
    }
    return id;
  }

  const anchor = {
    'type': 'Text',
    'path': [0, 2],
    'rect': {'left': 10, 'top': 20, 'width': 100, 'height': 40},
  };

  /// A mark on [round]'s home frame, raised by [who], or by [author] when given.
  Future<Answer> raise(As who, String round, {String? author, String frame = 'screen=home'}) =>
      who.create('marks', {
        'round': round,
        'frame': frame,
        'anchor': anchor,
        'pin': {'dx': 0.5, 'dy': 0.5},
        'note': 'The label is clipped',
        'author': author ?? who.id,
      });

  /// A reviewer of [galley], invited by the owner and in under [alias].
  Future<As> reviewerOf(String galley, String email, String alias) async {
    await owner.create('invites', {'galley': galley, 'email': email});
    final who = await As.signIn(server, email);
    final joined = await who.create('members', {
      'galley': galley,
      'user': who.id,
      'role': 'reviewer',
      'alias': alias,
    });
    if (joined.status != 200) throw StateError('$email did not join: ${joined.body}');
    return who;
  }

  group('galley host', () {
    test("keeps its data its owner's alone, and its superuser the same on every start", () async {
      final data = '${tmp.path}/again';
      final first = await host(data);
      final made = File('$data/superuser.json').readAsStringSync();
      await first.close();
      final second = await host(data);
      addTearDown(second.close);
      expect(File('$data/superuser.json').readAsStringSync(), made);
      expect(await second.superuserToken(), isNotEmpty);
      expect(
        {
          for (final p in [data, '$data/otp', '$data/superuser.json']) p: modeOf(p),
        },
        {data: 'rwx------', '$data/otp': 'rwx------', '$data/superuser.json': 'rw-------'},
      );
    });

    test('starts with a superuser password that looks like a flag', () async {
      final data = '${tmp.path}/dash';
      Directory(data).createSync(recursive: true);
      final password = '-Lte9LpujMm4fsxqlB0M24fz5D8Y6k58';
      File('$data/superuser.json').writeAsStringSync(
        jsonEncode({'email': 'galley-host@galley.invalid', 'password': password}),
      );
      final dashed = await host(data);
      addTearDown(dashed.close);
      expect(await dashed.superuserToken(), isNotEmpty);
      expect(File('$data/superuser.json').readAsStringSync(), contains(password));
    });

    test('logs what PocketBase says, and no SQL, though it runs from the cache', () async {
      final lines = <String>[];
      final logged = await LocalServer.start(
        data: '${tmp.path}/logged',
        cache: cache,
        port: 0,
        log: lines.add,
      );
      await logged.ensureUser('logged@example.com');
      await logged.close();
      expect(lines, contains(contains('Server started at http://127.0.0.1:')));
      expect(lines.where((l) => RegExp(r'^\[\d+(\.\d+)?m?s\]').hasMatch(l)), isEmpty);
      expect(lines.where((l) => l.contains('logged@example.com')), isEmpty);
    });

    test('makes a user for an email once, lower-cased', () async {
      final id = await server.ensureUser('Twice@Example.com');
      expect(await server.ensureUser('twice@example.com'), id);
      expect((await As.signIn(server, 'twice@example.com')).id, id);
    });
  });

  group('the host command', () {
    test('starts the server, makes the owner, says where codes go, and stops', () async {
      final data = '${tmp.path}/command';
      final (out, err) = (StringBuffer(), StringBuffer());
      late Answer health;
      late bool owner;
      final code = await runGalley(
        ['host', '--port', '0', '--data', data, '--owner', 'Cmd@Example.com'],
        GalleyContext(
          out: out,
          err: err,
          environment: {'GALLEY_CACHE': cache.root},
          untilStopped: () async {
            final url = RegExp(r'at (http://\S+)').firstMatch('$out')!.group(1)!;
            health = await send(Uri.parse(url), 'GET', '/api/health');
            // PocketBase answers a code request for anyone, and writes a code only for a user.
            final code = await codeAfter('$data/otp', 'cmd@example.com', () async {
              await send(
                Uri.parse(url),
                'POST',
                '/api/collections/users/request-otp',
                body: {'email': 'cmd@example.com'},
              );
            });
            owner = code != null && RegExp(r'^\d{8}$').hasMatch(code);
          },
        ),
      );
      expect((code, '$err'), (0, ''));
      expect(health.status, 200);
      expect(owner, isTrue, reason: '$out');
      expect('$out', contains('Sign-in codes are written to $data/otp'));
    });

    test('refuses a port that is not one, before starting anything', () async {
      final err = StringBuffer();
      final code = await runGalley([
        'host',
        '--port',
        '70000',
        '--data',
        '${tmp.path}/no',
      ], GalleyContext(out: StringBuffer(), err: err));
      expect(code, 64);
      expect('$err', contains('--port is 0 to 65535'));
      expect(Directory('${tmp.path}/no').existsSync(), isFalse);
    });
  });

  group('dataDirectory', () {
    test('is galley under the platform user data directory', () {
      expect(
        [
          for (final (env, os) in [
            ({'HOME': '/h'}, 'macos'),
            ({'HOME': '/h'}, 'linux'),
            ({'XDG_DATA_HOME': '/x', 'HOME': '/h'}, 'linux'),
            ({'XDG_DATA_HOME': '', 'HOME': '/h'}, 'linux'),
            ({'APPDATA': r'C:\A', 'HOME': '/h'}, 'windows'),
            ({'HOME': '/h'}, 'windows'),
            (<String, String>{}, 'linux'),
          ])
            dataDirectory(env, os: os),
        ],
        [
          '/h/Library/Application Support/galley',
          '/h/.local/share/galley',
          '/x/galley',
          '/h/.local/share/galley',
          r'C:\A/galley',
          null,
          null,
        ],
      );
    });
  });

  group('signing in', () {
    test('is by a code, and limited by address: guesses past two in three seconds wait', () async {
      final requested = await send(
        server.url,
        'POST',
        '/api/collections/users/request-otp',
        body: {'email': 'owner@example.com'},
      );
      final otpId = (requested.body as Map<String, Object?>)['otpId'];
      final guesses = [
        for (var i = 0; i < 4; i++)
          (await send(
            server.url,
            'POST',
            '/api/collections/users/auth-with-otp',
            body: {'otpId': otpId, 'password': '0000000$i'},
            tries: 1,
          )).status,
      ];
      expect(guesses, everyElement(anyOf(400, 429)), reason: 'no guess signs in');
      expect(guesses, contains(429), reason: '$guesses');
    });
  });

  group('the schema', () {
    /// Galley's collections as the server holds them, read as its superuser: PocketBase's own
    /// system collections left out.
    Future<List<Map<String, Object?>>> collections() async {
      final token = await server.superuserToken();
      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.getUrl(server.url.resolve('/api/collections?perPage=100'));
      request.headers.set('Authorization', token);
      final items =
          (jsonDecode(await utf8.decodeStream(await request.close())) as Map)['items'] as List;
      return [
        for (final c in items.cast<Map<String, Object?>>())
          if (c['system'] != true) c,
      ];
    }

    test('deletes nothing: no collection has a delete rule, and no relation cascades', () async {
      final galleys = await collections();
      expect(
        [for (final c in galleys) c['name']],
        unorderedEquals([
          'users',
          'galleys',
          'members',
          'invites',
          'rounds',
          'files',
          'marks',
          'events',
        ]),
      );
      expect(
        {for (final c in galleys) c['name']: c['deleteRule']},
        {for (final c in galleys) c['name']: null},
      );
      final relations = [
        for (final c in galleys)
          for (final f in (c['fields'] as List).cast<Map<String, Object?>>())
            if (f['type'] == 'relation') '${c['name']}.${f['name']}: ${f['cascadeDelete']}',
      ];
      expect(relations, hasLength(greaterThanOrEqualTo(8)), reason: 'the population looked at');
      expect(relations.where((r) => !r.endsWith(': false')), isEmpty);
    });

    // The hook's transaction is what keeps two events from taking one place in a history (an
    // event, below: five verifies at once land once, and no write ever reaches this index).
    // The index is the second guard, for a writer that is not the hook, so no write can show
    // it is there, and it is read here instead.
    test('holds a place in a history once: (mark, seq) is unique', () async {
      final events = (await collections()).singleWhere((c) => c['name'] == 'events');
      final indexes = (events['indexes'] as List).cast<String>();
      expect(
        indexes.map((i) => i.replaceAll(RegExp(r'\s+'), ' ').replaceAll('`', '')),
        contains(matches(RegExp(r'^CREATE UNIQUE INDEX \S+ ON events \(mark, seq\)$'))),
      );
    });
  });

  group('a write', () {
    test(
      "is judged: the validator's refusal is the answer, and what it was given is not kept",
      () async {
        final galley = await owner.makeGalley('Judged');
        final refused = await owner.create('rounds', round(galley, 2));
        expect(
          (refused.status, messageOf(refused)),
          (400, 'Round 2 is not next: the next round is 1.'),
        );
        final made = await owner.create('rounds', round(galley, 1));
        expect(made.status, 200, reason: '${made.body}');
        expect((made.body as Map)['number'], 1);
        final judged = Directory('${server.data}/pb_data/galley_judge');
        expect(judged.existsSync(), isTrue, reason: 'where the requests were written');
        expect(judged.listSync(), isEmpty);
      },
    );

    test('is judged when it is larger than one argument may be (128 KiB on Linux)', () async {
      final galley = await owner.makeGalley('Large');
      final manifest = [
        for (var i = 0; i < 1500; i++)
          {'path': 'frames/${'x' * 80}-$i.png', 'sha256': 'b' * 64, 'size': 1000},
      ];
      expect(jsonEncode(manifest).length, greaterThan(200 * 1024));
      final made = await owner.create('rounds', round(galley, 1, manifest));
      expect(made.status, 200, reason: '${messageOf(made)}');
      expect(((made.body as Map)['manifest'] as List).length, 1500);
      final refused = await owner.create('rounds', round(galley, 3, manifest));
      expect(messageOf(refused), 'Round 3 is not next: the next round is 2.');
    });
  });

  group('a round', () {
    test(
      'takes the files its manifest lists, at their sizes, once each, until it is finished',
      () async {
        final galley = await owner.makeGalley('Files');
        final made = await owner.create(
          'rounds',
          round(galley, 1, [
            {'path': 'a.png', 'sha256': 'a' * 64, 'size': 100},
            {'path': 'b.png', 'sha256': 'b' * 64, 'size': 50},
          ]),
        );
        final id = (made.body as Map)['id'] as String;

        Future<String?> refusal(String path, int size) async =>
            messageOf(await upload(owner, id, path, size));
        expect(await refusal('c.png', 100), "The round's manifest does not list c.png.");
        expect(await refusal('a.png', 99), 'A.png is 99 bytes, and the manifest says 100.');
        expect((await upload(owner, id, 'a.png', 100)).status, 200);
        expect(await refusal('a.png', 100), 'The round already has a.png.');

        final early = await finish(owner, id);
        expect(messageOf(early), 'Round 1 is missing 1 of its files: b.png.');
        expect((await upload(owner, id, 'b.png', 50)).status, 200);
        expect((await finish(owner, id)).status, 200);
        expect((await owner.view('rounds', id)).body, containsPair('finished', true));

        expect(
          await refusal('b.png', 50),
          'The round is finished, and a finished round is not changed.',
        );
        expect((await finish(owner, id)).status, 404, reason: 'a round is finished once');
        final files = await owner.records('files', filter: 'round = "$id"', sort: 'path');
        expect([for (final f in files) f['path']], ['a.png', 'b.png']);
      },
    );

    test('is seen by a reviewer, with its files, only once it is finished', () async {
      final galley = await owner.makeGalley('Unseen');
      final reviewer = await reviewerOf(galley, 'early@example.com', 'Early');
      final made = await owner.create(
        'rounds',
        round(galley, 1, [
          {'path': 'index.json', 'sha256': 'a' * 64, 'size': 10},
          {'path': 'b.json', 'sha256': 'b' * 64, 'size': 20},
        ]),
      );
      final id = (made.body as Map)['id'] as String;
      expect((await upload(owner, id, 'index.json', 10)).status, 200);
      expect(await reviewer.ids('rounds'), isEmpty);
      expect(await reviewer.ids('files'), isEmpty);
      // A file the manifest lists and nobody has sent: only the rule can refuse it.
      expect((await upload(reviewer, id, 'b.json', 20)).status, 400, reason: 'nor written');
      expect((await upload(owner, id, 'b.json', 20)).status, 200, reason: 'the control');
      expect((await finish(reviewer, id)).status, 404);

      expect((await finish(owner, id)).status, 200);
      expect(await reviewer.ids('rounds'), [id]);
      expect(await reviewer.ids('files'), hasLength(2));
    });

    test('finishes only once it places every mark raised before it, and raises none', () async {
      final galley = await owner.makeGalley('Placed');
      final first = await pushed(galley, 1);
      final mark = ((await raise(owner, first)).body as Map)['id'] as String;
      final made = await owner.create('rounds', round(galley, 2));
      final second = (made.body as Map)['id'] as String;
      expect((await upload(owner, second, 'index.json', 10)).status, 200);

      final unplaced = await finish(owner, second);
      expect(messageOf(unplaced), 'Round 2 does not place $mark; carry every mark again.');
      final raised = await finish(owner, second, [
        {
          'mark': mark,
          'placement': {'kind': 'raised'},
          'anchor': anchor,
        },
      ]);
      expect(messageOf(raised), 'Mark $mark was raised on an earlier round, not 2.');
      final unknown = await finish(owner, second, [
        {
          'mark': 'nosuchmark0000',
          'placement': {'kind': 'retired'},
          'anchor': anchor,
        },
      ]);
      expect(unknown.status, 400);
      expect((await owner.view('rounds', second)).body, containsPair('finished', false));

      final retired = await finish(owner, second, [
        {
          'mark': mark,
          'placement': {'kind': 'retired'},
          'anchor': anchor,
        },
      ]);
      expect(retired.status, 200, reason: '${retired.body}');
      expect(((await owner.view('rounds', second)).body as Map)['placements'], {
        'placements': [
          {
            'mark': mark,
            'placement': {'kind': 'retired'},
            'anchor': anchor,
          },
        ],
      });
    });
  });

  group('a mark', () {
    test('is raised by a member, as themselves, on a frame of the newest finished round', () async {
      final galley = await owner.makeGalley('Marked');
      final reviewer = await reviewerOf(galley, 'marker@example.com', 'Marker');
      final made = await owner.create('rounds', round(galley, 1));
      final first = (made.body as Map)['id'] as String;
      expect(messageOf(await raise(owner, first)), 'Round 1 is still being pushed.');
      expect((await upload(owner, first, 'index.json', 10)).status, 200);
      expect((await finish(owner, first)).status, 200);

      final mine = await raise(reviewer, first);
      expect(mine.status, 200, reason: '${mine.body}');
      expect((mine.body as Map)['author'], reviewer.id);
      expect((await raise(reviewer, first, author: owner.id)).status, 400, reason: 'as another');
      expect((await raise(await stranger('outsider@example.com'), first)).status, 400);
      expect(
        messageOf(await raise(reviewer, first, frame: 'screen=away')),
        'Round 1 has no frame screen=away.',
      );
      expect(
        messageOf(await raise(reviewer, first, frame: 'not a key')),
        startsWith('Request.mark.frame'),
      );

      await pushed(galley, 2, [
        {
          'mark': (mine.body as Map)['id'],
          'placement': {'kind': 'retired'},
          'anchor': anchor,
        },
      ]);
      expect(
        messageOf(await raise(reviewer, first)),
        'Round 1 is out: round 2 is the newest; reload.',
      );
      expect(await owner.ids('marks'), contains((mine.body as Map)['id']));
      expect(
        (await owner.records('marks', filter: 'round.galley = "$galley"')).length,
        1,
        reason: 'only the one that was allowed',
      );
    });
  });

  group('an event', () {
    test(
      'is an answer only from the owner, numbered by the server, in an order the core allows',
      () async {
        final galley = await owner.makeGalley('Answered');
        final reviewer = await reviewerOf(galley, 'asker@example.com', 'Asker');
        final first = await pushed(galley, 1);
        final mark = ((await raise(reviewer, first)).body as Map)['id'] as String;

        Future<Answer> event(As who, Map<String, Object?> body) =>
            who.create('events', {'mark': mark, 'author': who.id, ...body});
        const fixed = {'kind': 'answered', 'answer': 'fixed', 'commit': 'abc1234'};

        expect(messageOf(await event(reviewer, fixed)), "Only the galley's owner answers a mark.");
        expect(messageOf(await event(owner, {'kind': 'verified'})), contains('cannot be verified'));
        expect(
          (await event(owner, {...fixed, 'seq': 1})).status,
          400,
          reason: 'seq is the server\'s',
        );
        expect(
          (await event(owner, {...fixed, 'author': reviewer.id})).status,
          400,
          reason: 'as another',
        );
        expect(
          (await event(await stranger('meddler@example.com'), {'kind': 'verified'})).status,
          400,
        );

        final answered = await event(owner, fixed);
        expect(answered.status, 200, reason: '${answered.body}');
        expect((answered.body as Map)['seq'], 1);

        final reopened = await event(reviewer, {
          'kind': 'reopened',
          'note': 'Still clipped on the tablet',
        });
        expect(reopened.status, 200, reason: '${reopened.body}');
        expect((await event(owner, fixed)).status, 200, reason: 'answered again');

        // Five verifies at once: the server's writes take turns (main.pb.js), so the first lands
        // and the other four find the mark already verified, which is final.
        final verifies = await Future.wait([
          for (var i = 0; i < 5; i++) event(reviewer, {'kind': 'verified'}),
        ]);
        expect([for (final v in verifies) v.status]..sort(), [200, 400, 400, 400, 400]);
        for (final v in verifies.where((v) => v.status == 400)) {
          expect(messageOf(v), contains('cannot be verified'));
        }

        final history = await reviewer.records('events', filter: 'mark = "$mark"', sort: 'seq');
        expect(
          [for (final e in history) (e['seq'], e['kind'], e['author'])],
          [
            (1, 'answered', owner.id),
            (2, 'reopened', reviewer.id),
            (3, 'answered', owner.id),
            (4, 'verified', reviewer.id),
          ],
        );
      },
    );
  });

  group('a galley', () {
    test('is seen and written only by its own members', () async {
      final mine = await owner.makeGalley('Mine');
      expect((await owner.create('rounds', round(mine, 1))).status, 200);
      final other = await stranger('other@example.com');
      final theirs = await other.makeGalley('Theirs');

      expect(await other.ids('galleys'), [theirs]);
      expect(await other.ids('rounds'), isEmpty);
      expect(await owner.ids('galleys'), contains(mine));
      expect(await owner.ids('galleys'), isNot(contains(theirs)));
      expect((await other.view('galleys', mine)).status, 404);

      final pushed = await other.create('rounds', round(mine, 2));
      expect((pushed.status, messageOf(pushed)), (400, 'Failed to create record.'));
      final joined = await other.create('members', {
        'galley': mine,
        'user': other.id,
        'role': 'owner',
        'alias': 'Intruder',
      });
      expect(joined.status, 400, reason: 'an owner membership of a galley they do not own');
      expect(await other.ids('galleys'), [theirs]);
    });

    test('lets an invitee in once, as a reviewer, and nobody else', () async {
      final galley = await owner.makeGalley('Invited');
      final invited = await owner.create('invites', {
        'galley': galley,
        'email': 'Reviewer@Example.com',
      });
      expect(invited.status, 200, reason: '${invited.body}');
      expect((invited.body as Map)['email'], 'reviewer@example.com');

      final reviewer = await As.signIn(server, 'reviewer@example.com');
      final uninvited = await stranger('uninvited@example.com');
      expect(await reviewer.ids('galleys'), isEmpty);

      Future<Answer> accept(As who, {String role = 'reviewer', String alias = 'Rae'}) =>
          who.create('members', {'galley': galley, 'user': who.id, 'role': role, 'alias': alias});

      expect((await accept(reviewer, role: 'owner')).status, 400, reason: 'not as an owner');
      expect((await accept(uninvited)).status, 400, reason: 'no invite names them');
      expect((await accept(reviewer)).status, 200);
      expect(await reviewer.ids('galleys'), [galley]);
      expect((await accept(reviewer, alias: 'Rae2')).status, 400, reason: 'the invite is used');
      expect(await uninvited.ids('galleys'), isEmpty);

      final pushed = await reviewer.create('rounds', round(galley, 1));
      expect(pushed.status, 400, reason: 'a reviewer pushes no rounds');
    });

    test('takes a revoked reviewer\'s access, and keeps their membership', () async {
      final galley = await owner.makeGalley('Revoked');
      await owner.create('invites', {'galley': galley, 'email': 'gone@example.com'});
      final reviewer = await As.signIn(server, 'gone@example.com');
      final membership = await reviewer.create('members', {
        'galley': galley,
        'user': reviewer.id,
        'role': 'reviewer',
        'alias': 'Gone',
      });
      final id = (membership.body as Map)['id'] as String;
      expect(await reviewer.ids('galleys'), [galley]);

      final selfRestored = await reviewer.update('members', id, {'revoked': false});
      expect(selfRestored.status, 404, reason: 'a reviewer changes no membership');
      expect((await owner.update('members', id, {'revoked': true})).status, 200);

      expect(await reviewer.ids('galleys'), isEmpty);
      expect((await reviewer.view('galleys', galley)).status, 404);
      expect(await reviewer.ids('members'), [id], reason: 'they can still read that they were');
      expect((await reviewer.view('members', id)).body, containsPair('revoked', true));

      expect((await owner.update('members', id, {'revoked': false})).status, 200);
      expect(await reviewer.ids('galleys'), [galley]);
    });
  });
}
