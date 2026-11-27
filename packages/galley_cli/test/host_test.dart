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

/// The cache `galley host` uses on this machine, so the suite fetches nothing a user already
/// has. Rejected: a fresh cache per run. Every run would download 13 MB and compile the
/// validator again.
final cache = ArchiveCache(
  cacheDirectory(Platform.environment) ?? (throw StateError('set GALLEY_CACHE, or HOME')),
  fetch: httpFetch,
);

Future<LocalServer> host(String data) => LocalServer.start(data: data, cache: cache, port: 0);

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
    test('deletes nothing: no collection has a delete rule, and no relation cascades', () async {
      final token = await server.superuserToken();
      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.getUrl(server.url.resolve('/api/collections?perPage=100'));
      request.headers.set('Authorization', token);
      final items =
          (jsonDecode(await utf8.decodeStream(await request.close())) as Map)['items'] as List;
      final galleys = [
        for (final c in items.cast<Map<String, Object?>>())
          if (c['system'] != true) c,
      ];
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
