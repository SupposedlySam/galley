import 'package:flutter_test/flutter_test.dart';
import 'package:galley_core/galley_core.dart';
import 'package:galley_server/galley_server.dart';
import 'package:galley_web/src/entry_page.dart';
import 'package:galley_web/src/server_entry.dart';
import 'package:galley_web/src/session_store.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

const _rae = Session(userId: 'u-rae', email: 'rae@example.com', token: 't1');
const _renewed = Session(userId: 'u-rae', email: 'rae@example.com', token: 't2');

Member _member({bool revoked = false}) => Member(
  id: 'm1',
  galley: 'g1',
  user: 'u-rae',
  alias: 'Rae',
  role: MemberRole.reviewer,
  revoked: revoked,
);

/// A server as the entry sees it: one code (`246810`), and where Rae stands in the galley.
final class _FakeDoor implements Door {
  Standing standing_ = Joined(_member());
  Refused? refreshRefused;
  Refused? standingRefused;
  final requested = <String>[];
  final joined = <String>[];
  final galleys = <Session>[];

  @override
  Future<String> requestCode(String email) async {
    requested.add(email);
    return 'otp-1';
  }

  @override
  Future<Session> withCode(String otpId, String code) async {
    expect(otpId, 'otp-1');
    if (code.trim() != '246810') throw const Refused.invalid('Invalid or expired OTP.');
    return _rae;
  }

  @override
  Future<Session> refresh(Session session) async {
    if (refreshRefused case final e?) throw e;
    expect(session.token, _rae.token);
    return _renewed;
  }

  @override
  Future<Standing> standing(Session session) async {
    if (standingRefused case final e?) throw e;
    return standing_;
  }

  @override
  Future<Member> join(Session session, {required String alias}) async {
    joined.add(alias);
    standing_ = Joined(_member());
    return _member();
  }

  @override
  Galley galley(Session session) {
    galleys.add(session);
    return FakeGalley(files: roundFiles([keyOf('home', pixel7)]));
  }
}

void main() {
  late _FakeDoor door;
  setUp(() => door = _FakeDoor());

  ServerEntry entryOf(SessionStore store) => ServerEntry(door, store);

  group('a new visit', () {
    test('asks for an email, refuses one that is not, mails a code, and takes only the right '
        'one', () async {
      final store = MemorySessionStore();
      final entry = entryOf(store);
      await entry.start();
      expect(entry.step, isA<AskingEmail>().having((s) => s.why, 'why', isNull));

      await entry.sendCode('rae');
      expect(entry.step, isA<AskingEmail>().having((s) => s.why, 'why', contains('not an email')));
      expect(door.requested, isEmpty);

      await entry.sendCode('  rae@example.com ');
      expect(door.requested, ['rae@example.com']);
      expect(entry.step, isA<AskingCode>().having((s) => s.email, 'email', 'rae@example.com'));

      await entry.signIn('111111');
      expect(entry.step, isA<AskingCode>().having((s) => s.why, 'why', contains('Invalid')));
      expect(store.read(), isNull);
      expect(door.galleys, isEmpty);

      await entry.signIn('246810');
      expect(store.read()?.token, _rae.token);
      final canvas = (entry.step as Entered).canvas;
      expect((canvas.signedIn?.alias, canvas.signedIn?.email), ('Rae', 'rae@example.com'));
      expect(canvas.reviewer, 'Rae');
      expect(door.galleys, [_rae]);
      // The server signs with the alias; a typed name could only be refused.
      expect(() => canvas.reviewer = 'Someone', throwsStateError);
      expect(canvas.reviewer, 'Rae');
    });

    test('a second press while a request is out sends nothing', () async {
      final entry = entryOf(MemorySessionStore());
      await entry.start();
      final first = entry.sendCode('rae@example.com');
      expect(entry.busy, isTrue);
      await entry.sendCode('rae@example.com');
      await first;
      expect(door.requested, ['rae@example.com']);
      expect(entry.busy, isFalse);
    });

    test('an invited user joins by the alias they give, and not by a blank one', () async {
      door.standing_ = const InvitedTo();
      final entry = entryOf(MemorySessionStore(_rae));
      await entry.start();
      expect(entry.step, isA<AskingAlias>().having((s) => s.email, 'email', 'rae@example.com'));

      await entry.join('  ');
      expect(entry.step, isA<AskingAlias>().having((s) => s.why, 'why', isNotNull));
      expect(door.joined, isEmpty);

      await entry.join(' Rae ');
      expect(door.joined, ['Rae']);
      expect(entry.step, isA<Entered>());
    });
  });

  group('a kept sign-in', () {
    test('is renewed and kept again, and leads straight in', () async {
      final store = MemorySessionStore(_rae);
      final entry = entryOf(store);
      await entry.start();
      expect(store.read()?.token, _renewed.token);
      expect(entry.step, isA<Entered>());
      expect(door.galleys, [_renewed]);
      expect(door.requested, isEmpty);
    });

    test('that is not renewed says so, names whose it was, and is not forgotten', () async {
      door.refreshRefused = const Refused.environment(
        'The request requires valid record '
        'authorization token.',
      );
      final store = MemorySessionStore(_rae);
      final entry = entryOf(store);
      await entry.start();
      expect(
        entry.step,
        isA<AskingEmail>().having(
          (s) => s.why,
          'why',
          allOf(contains('rae@example.com'), contains('requires valid'), contains('Sign in')),
        ),
      );
      expect(store.read()?.token, _rae.token);
      expect(door.galleys, isEmpty);
    });

    test('is forgotten on signing out', () async {
      final store = MemorySessionStore(_rae);
      final entry = entryOf(store);
      await entry.start();
      (entry.step as Entered).canvas.signedIn!.signOut();
      expect(store.read(), isNull);
      expect(entry.step, isA<AskingEmail>().having((s) => s.why, 'why', isNull));
    });
  });

  group('a member not let in', () {
    test('is told why: revoked, or neither a member nor invited', () async {
      final cases = {
        RevokedFrom(_member(revoked: true)): ['revoked by its owner', 'What they wrote is kept'],
        const Outside(): ['not a member', '`galley invite rae@example.com`'],
      };
      for (final MapEntry(key: standing, value: says) in cases.entries) {
        door.standing_ = standing;
        final entry = entryOf(MemorySessionStore(_rae));
        await entry.start();
        expect(
          entry.step,
          isA<Barred>().having(
            (s) => s.message,
            'message',
            allOf([for (final s in says) contains(s)]),
          ),
          reason: '$standing',
        );
      }
      expect(door.galleys, isEmpty);
    });

    test('when the server does not say, is told that, and gets in on a retry', () async {
      door.standingRefused = const Refused.environment('connection refused');
      final entry = entryOf(MemorySessionStore(_rae));
      await entry.start();
      expect(
        entry.step,
        isA<Barred>().having((s) => s.message, 'message', contains('connection refused')),
      );
      door.standingRefused = null;
      await entry.retry();
      expect(entry.step, isA<Entered>());
    });
  });

  group('the page', () {
    testWidgets('asks for the email, then the code, and the canvas names the member with a way '
        'out', (tester) async {
      tester.view
        ..physicalSize = const Size(1600, 1000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = MemorySessionStore();
      await tester.pumpWidget(ServerCanvasApp(entry: entryOf(store)));
      await tester.pump();
      expect(find.text('Mail me a code'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'rae@example.com');
      await tester.tap(find.text('Mail me a code'));
      await tester.pump();
      expect(find.text('A code was mailed to rae@example.com.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '246810');
      await tester.tap(find.text('Sign in'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Reviewing as Rae (rae@example.com)'), findsOneWidget);
      // No name field: the server signs with the alias.
      expect(find.widgetWithText(TextField, 'Reviewing as'), findsNothing);
      expect(find.text('Round 1 · 1 frames · 0 marks'), findsOneWidget);

      await tester.tap(find.text('Sign out'));
      await tester.pump();
      expect(store.read(), isNull);
      expect(find.text('Mail me a code'), findsOneWidget);
    });
  });
}
