import 'dart:convert';

import 'package:galley_core/galley_core.dart';
import 'package:galley_server/galley_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  final base = Uri.parse('http://127.0.0.1:8090/');
  PocketBase over(Future<http.Response> Function(http.Request) answer) =>
      PocketBase(MockClient(answer), base, backoff: (_) => Duration.zero);
  http.Response json(Object? body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  group('api', () {
    test('puts every segment under /api, encoded', () {
      final pb = over((_) async => json(null));
      expect(
        '${pb.api(['files', 'files', 'abc', 'a b/c.png'], {'token': 't'})}',
        'http://127.0.0.1:8090/api/files/files/abc/a%20b%2Fc.png?token=t',
      );
      final under = PocketBase(
        MockClient((_) async => json(null)),
        Uri.parse('https://x.test/pb/'),
      );
      expect('${under.api(['health'])}', 'https://x.test/pb/api/health');
    });
  });

  group('list', () {
    test('reads every page, and stops at the first short one', () async {
      final pages = <String>[];
      final pb = over((r) async {
        final page = int.parse(r.url.queryParameters['page']!);
        pages.add('$page:${r.url.queryParameters['skipTotal']}:${r.url.queryParameters['filter']}');
        final count = page < 3 ? PocketBase.pageSize : 7;
        return json({
          'items': [
            for (var i = 0; i < count; i++) {'id': '$page-$i'},
          ],
        });
      });
      final all = await pb.list('marks', filter: 'a = "b"', token: 't');
      expect(all, hasLength(2 * PocketBase.pageSize + 7));
      expect(all.first['id'], '1-0');
      expect(all.last['id'], '3-6');
      expect(pages, ['1:true:a = "b"', '2:true:a = "b"', '3:true:a = "b"']);
    });

    test('a full last page costs one empty page more, not a missing one', () async {
      var asked = 0;
      final pb = over((r) async {
        asked++;
        return json({
          'items': [
            if (asked == 1)
              for (var i = 0; i < PocketBase.pageSize; i++) {'id': '$i'},
          ],
        });
      });
      expect(await pb.list('marks', token: 't'), hasLength(PocketBase.pageSize));
      expect(asked, 2);
    });
  });

  group('send', () {
    test('carries the token and the body, and reads the reply', () async {
      late http.Request seen;
      final pb = over((r) async {
        seen = r;
        return json({'ok': true});
      });
      expect(await pb.send('POST', pb.api(['x']), body: {'a': 1}, token: 'tok'), {'ok': true});
      expect(seen.method, 'POST');
      expect(seen.headers['Authorization'], 'tok');
      expect(jsonDecode(seen.body), {'a': 1});
    });

    test('waits out a 429 and sends again, up to the most tries', () async {
      var asked = 0;
      final waits = <int>[];
      final pb = PocketBase(
        MockClient((r) async {
          asked++;
          return asked < 3 ? json({'message': 'Too Many Requests.'}, 429) : json({'ok': 1});
        }),
        base,
        backoff: (attempt) {
          waits.add(attempt);
          return Duration.zero;
        },
      );
      expect(await pb.send('GET', pb.api(['x'])), {'ok': 1});
      expect(asked, 3);
      expect(waits, [1, 2]);

      asked = 0;
      final always = over((_) async {
        asked++;
        return json({'message': 'Too Many Requests.'}, 429);
      });
      await expectLater(
        always.send('GET', always.api(['x'])),
        throwsA(isA<Refused>().having((r) => r.kind, 'kind', RefusalKind.environment)),
      );
      expect(asked, PocketBase.tries);
    });

    test(
      'a refusal is PocketBase\'s message, with its fields, as the kind its status names',
      () async {
        Future<Refused> refusal(int status, Object? body) async {
          final pb = over((_) async => json(body, status));
          try {
            await pb.send('POST', pb.api(['x']));
          } on Refused catch (e) {
            return e;
          }
          fail('not refused');
        }

        final hook = await refusal(400, {
          'message': 'Round 1 is still being pushed.',
          'data': <String, Object?>{},
        });
        expect((hook.kind, hook.message), (RefusalKind.invalid, 'Round 1 is still being pushed.'));

        final field = await refusal(400, {
          'message': 'Failed to create record.',
          'data': {
            'seq': {'code': 'validation_not_unique', 'message': 'Value must be unique.'},
          },
        });
        expect(field.message, 'Failed to create record. (seq: Value must be unique.)');

        final missing = await refusal(404, {'message': 'The requested resource wasn\'t found.'});
        expect(missing.kind, RefusalKind.missing);

        final out = await refusal(401, {
          'message': 'The request requires valid record authorization token.',
        });
        expect(out.kind, RefusalKind.environment);
        expect(out.message, contains('sign in again'));

        final bare = await refusal(500, null);
        expect(
          (bare.kind, bare.message),
          (RefusalKind.damaged, 'http://127.0.0.1:8090/api/x answered 500'),
        );
      },
    );

    test('an answer that is not JSON is refused, not read as nothing', () async {
      final pb = over((_) async => http.Response('<html>proxy</html>', 200));
      await expectLater(
        pb.send('GET', pb.api(['x'])),
        throwsA(isA<Refused>().having((r) => r.message, 'message', contains('not with JSON'))),
      );
    });

    test('a server that cannot be reached is an environment refusal', () async {
      final pb = over((_) async => throw http.ClientException('connection refused'));
      await expectLater(
        pb.send('GET', pb.api(['x'])),
        throwsA(
          isA<Refused>()
              .having((r) => r.kind, 'kind', RefusalKind.environment)
              .having((r) => r.message, 'message', contains('connection refused')),
        ),
      );
    });
  });
}
