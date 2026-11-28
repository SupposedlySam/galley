@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:galley_cli/galley_cli.dart';
import 'package:galley_cli/src/rest.dart';
import 'package:galley_core/galley_core.dart' show Refused;
import 'package:test/test.dart';

import 'support/pocketbase.dart';
import 'support/smtp.dart';

// The operator's settings (DESIGN D18): a hosted server is set by its environment, which the
// hooks apply on every start. Tested through LocalServer, which passes the same variables a
// bundle's `run` does, to the same hooks.

void main() {
  late Directory data;
  setUp(() => data = Directory.systemTemp.createTempSync('galley_operator_'));
  tearDown(() => data.deleteSync(recursive: true));

  Future<LocalServer> start(Map<String, String> environment) async {
    final server = await LocalServer.start(
      data: data.path,
      cache: cache,
      port: 0,
      environment: environment,
    );
    addTearDown(server.close);
    return server;
  }

  Future<Map<String, Object?>> settings(LocalServer server) async {
    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.getUrl(server.url.resolve('/api/settings'));
    request.headers.set('Authorization', await server.superuserToken());
    return jsonDecode(await utf8.decodeStream(await request.close())) as Map<String, Object?>;
  }

  Future<Answer> requestCode(LocalServer server, String email) =>
      send(server.url, 'POST', '/api/collections/users/request-otp', body: {'email': email});

  group('mail', () {
    test(
      'set from the environment, a sign-in code is mailed through the relay, and signs in',
      () async {
        final relay = await SmtpSink.start();
        addTearDown(relay.close);
        final server = await start({
          'GALLEY_URL': 'https://galley.example.com/',
          'GALLEY_SMTP_HOST': '127.0.0.1',
          'GALLEY_SMTP_PORT': '${relay.port}',
          'GALLEY_SMTP_USERNAME': 'relay-user',
          'GALLEY_SMTP_PASSWORD': 'relay-secret',
          'GALLEY_MAIL_FROM': 'galley@example.com',
          'GALLEY_MAIL_NAME': 'Galley Review',
          'GALLEY_OWNERS': 'Op@Example.com',
        });

        final arriving = relay.next();
        final requested = await requestCode(server, 'op@example.com');
        expect(requested.status, 200, reason: '${requested.body}');
        final mail = await arriving;
        expect(mail, isNotNull, reason: 'the relay was sent nothing');
        expect(
          [mail!.auth, mail.from, ...mail.to],
          ['relay-user:relay-secret', 'galley@example.com', 'op@example.com'],
        );
        expect(mail.text, contains('From: Galley Review <galley@example.com>'));
        // Mailed, and so not written: GALLEY_OTP_LOG is set for every LocalServer.
        expect(File('${server.otpDirectory}/op@example.com').existsSync(), isFalse);

        // The code is the one 8-digit run in the mail that signs in. Every candidate is tried,
        // so the test does not depend on where PocketBase's template puts it.
        final candidates = {
          for (final m in RegExp(r'(?<![0-9])[0-9]{8}(?![0-9])').allMatches(mail.text)) m[0]!,
        };
        expect(candidates, isNotEmpty, reason: mail.text);
        final otpId = (requested.body as Map)['otpId'];
        final signedIn = [
          for (final code in candidates)
            if ((await send(
                  server.url,
                  'POST',
                  '/api/collections/users/auth-with-otp',
                  body: {'otpId': otpId, 'password': code},
                  tries: 1,
                )).status ==
                200)
              code,
        ];
        expect(signedIn, hasLength(1), reason: 'candidates $candidates');

        final set = await settings(server);
        expect((set['meta'] as Map)['appURL'], 'https://galley.example.com');
        expect(
          {
            for (final k in ['enabled', 'host', 'port', 'tls', 'username'])
              k: (set['smtp'] as Map)[k],
          },
          {
            'enabled': true,
            'host': '127.0.0.1',
            'port': relay.port,
            'tls': false,
            'username': 'relay-user',
          },
        );
      },
    );

    test('without a relay, the code is not mailed, and is written for a local run', () async {
      final server = await start({'GALLEY_OWNERS': 'op@example.com'});
      final code = await codeAfter(server.otpDirectory, 'op@example.com', () async {
        await requestCode(server, 'op@example.com');
      });
      expect(code, matches(RegExp(r'^[0-9]{8}$')));
      expect(((await settings(server))['smtp'] as Map)['enabled'], isFalse);
    });

    test('each start applies the environment as it is then', () async {
      final relay = await SmtpSink.start();
      addTearDown(relay.close);
      final mail = {'GALLEY_SMTP_HOST': '127.0.0.1', 'GALLEY_MAIL_FROM': 'galley@example.com'};
      final first = await start({...mail, 'GALLEY_SMTP_PORT': '2525'});
      expect(((await settings(first))['smtp'] as Map)['port'], 2525);
      await first.close();
      final second = await start({...mail, 'GALLEY_SMTP_PORT': '${relay.port}'});
      expect(((await settings(second))['smtp'] as Map)['port'], relay.port);
    });
  });

  group('a setting it cannot read stops the start, naming it', () {
    const mail = {'GALLEY_SMTP_HOST': 'smtp.example.com', 'GALLEY_MAIL_FROM': 'g@example.com'};
    for (final (environment, says) in [
      ({'GALLEY_SMTP_PORT': '587'}, 'GALLEY_SMTP_PORT set without GALLEY_SMTP_HOST'),
      ({'GALLEY_MAIL_FROM': 'g@example.com'}, 'GALLEY_MAIL_FROM set without GALLEY_SMTP_HOST'),
      ({'GALLEY_SMTP_HOST': 'smtp.example.com'}, 'GALLEY_SMTP_HOST needs GALLEY_MAIL_FROM'),
      ({...mail, 'GALLEY_SMTP_PORT': 'smtp'}, 'GALLEY_SMTP_PORT is not a port: smtp'),
      ({...mail, 'GALLEY_SMTP_PORT': '70000'}, 'GALLEY_SMTP_PORT is not a port: 70000'),
      ({...mail, 'GALLEY_SMTP_TLS': 'yes'}, 'GALLEY_SMTP_TLS is "true" or "false", not yes'),
      ({...mail, 'GALLEY_SMTP_USERNAME': 'u'}, 'are set together'),
      ({'GALLEY_URL': 'galley.example.com'}, 'GALLEY_URL is not an http(s) address'),
      ({'GALLEY_OWNERS': 'op@example.com, nobody'}, 'not an email: "nobody"'),
    ]) {
      test(environment.keys.join(' '), () async {
        await expectLater(
          start(environment),
          throwsA(isA<Refused>().having((r) => r.message, 'message', contains(says))),
        );
      });
    }
  });

  group('owners', () {
    test('each one listed can sign in, as lower case, and nobody else is made', () async {
      final owners = {'GALLEY_OWNERS': ' A@Example.com,b@example.com '};
      var server = await start(owners);
      // Twice: the second start finds them there.
      await server.close();
      server = await start(owners);

      final signedIn = [
        for (final email in ['a@example.com', 'b@example.com'])
          (await As.signIn(server, email)).email,
      ];
      expect(signedIn, ['a@example.com', 'b@example.com']);
      final stranger = await codeAfter(server.otpDirectory, 'c@example.com', () async {
        await requestCode(server, 'c@example.com');
      });
      expect(stranger, isNull, reason: 'a user nobody listed was made');
    });
  });

  group('behind a proxy', () {
    /// Four wrong codes for [otpId] from [client], as the proxy names it in X-Galley-Client;
    /// their statuses.
    Future<List<int>> guesses(LocalServer server, Object? otpId, String client, int n) async {
      final http = HttpClient();
      addTearDown(http.close);
      return [
        for (var i = 0; i < n; i++)
          await () async {
            final request = await http.postUrl(
              server.url.resolve('/api/collections/users/auth-with-otp'),
            );
            request.headers
              ..contentType = ContentType.json
              ..set('X-Galley-Client', client);
            request.write(jsonEncode({'otpId': otpId, 'password': '0000000$i'}));
            final response = await request.close();
            await response.drain<void>();
            return response.statusCode;
          }(),
      ];
    }

    test('the rate limit is each client\'s, by the header GALLEY_PROXY_HEADER names', () async {
      final server = await start({
        'GALLEY_PROXY_HEADER': 'X-Galley-Client',
        'GALLEY_OWNERS': 'op@example.com',
      });
      final otpId = ((await requestCode(server, 'op@example.com')).body as Map)['otpId'];
      final a = await guesses(server, otpId, '203.0.113.1', 4);
      final b = await guesses(server, otpId, '203.0.113.2', 1);
      expect(a, contains(429), reason: 'the limit was not reached: $a');
      // Every request came from 127.0.0.1. Read by that, B would share A's limit.
      expect(b, [400], reason: 'another client was limited by the first one\'s guesses');
    });
  });
}
