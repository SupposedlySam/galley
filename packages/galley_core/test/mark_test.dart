import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

import 'trees.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 25, 9);
  DateTime t(int minutes) => t0.add(Duration(minutes: minutes));

  Mark fresh() => Mark(
    id: 'm1',
    frame: FrameKey({'screen': 'home', 'device': 'pixel-7'}),
    anchor: Anchor.of(node([0], 'Text', label: 'Hours', at: loc(3))),
    pin: const PinOffset(0.25, 0.5),
    note: 'Hours are cut off at 2x text',
    by: 'designer-a',
    at: t0,
  );

  final fix = Answered(
    Answer.fixed(commit: 'abc1234'),
    by: 'claude',
    at: t(1),
  );
  final verify = Verified(by: 'designer-a', at: t(2));
  Reopened reopen(int m) => Reopened('still clipped', by: 'designer-a', at: t(m));

  group('status', () {
    test('a new mark is open', () => expect(fresh().status, MarkStatus.open));

    test('verified and withdrawn are final, and every other status waits on someone', () {
      expect(
        [for (final s in MarkStatus.values) (s, s.isFinal)],
        [
          (MarkStatus.open, false),
          (MarkStatus.answered, false),
          (MarkStatus.verified, true),
          (MarkStatus.reopened, false),
          (MarkStatus.withdrawn, true),
        ],
      );
    });

    test('open → answered → verified', () {
      final m = fresh().record(fix);
      expect(m.status, MarkStatus.answered);
      expect(m.record(verify).status, MarkStatus.verified);
    });

    test('answered → reopened → answered again, with all of it kept', () {
      final m = fresh()
          .record(fix)
          .record(reopen(2))
          .record(
            Answered(
              Answer.fixed(commit: 'def5678'),
              by: 'claude',
              at: t(3),
            ),
          );
      expect(m.status, MarkStatus.answered);
      expect(m.history, hasLength(3));
      expect(m.history.whereType<Answered>().map((e) => e.answer.commit), ['abc1234', 'def5678']);
    });

    for (final (name, build) in <(String, Mark Function())>[
      ('verify an open mark', () => fresh().record(verify)),
      ('reopen an open mark', () => fresh().record(reopen(1))),
      ('answer an answered mark', () => fresh().record(fix).record(fix)),
      ('touch a verified mark', () => fresh().record(fix).record(verify).record(reopen(3))),
    ]) {
      test('refuses to $name', () => expect(build, throwsStateError));
    }

    group('withdrawn', () {
      Withdrawn withdraw(String by) => Withdrawn('a duplicate of m2', by: by, at: t(5));
      final answered = fresh().record(fix);
      final reopened = answered.record(reopen(2));

      test('by whoever raised it, from every status that is not final', () {
        for (final (from, m) in [
          (MarkStatus.open, fresh()),
          (MarkStatus.answered, answered),
          (MarkStatus.reopened, reopened),
        ]) {
          expect(m.status, from);
          final w = m.record(withdraw('designer-a'));
          expect(w.status, MarkStatus.withdrawn, reason: '$from');
          expect(w.status.awaitsAnswer, isFalse);
          expect(w.history, [...m.history, isA<Withdrawn>()], reason: 'kept, then appended');
          expect(w.note, m.note);
        }
      });

      test('not by anyone else, and the refusal says who may', () {
        expect(
          () => fresh().record(withdraw('claude')),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'mark m1 was raised by designer-a, and only they can withdraw it',
            ),
          ),
        );
      });

      test('not once final, and never twice', () {
        final verified = answered.record(verify);
        final withdrawn = fresh().record(withdraw('designer-a'));
        for (final (m, status) in [(verified, 'verified'), (withdrawn, 'withdrawn')]) {
          expect(
            () => m.record(withdraw('designer-a')),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                'mark m1 is $status, and cannot be withdrawn now',
              ),
            ),
          );
        }
        expect(() => withdrawn.record(fix), throwsStateError);
        expect(() => withdrawn.record(verify), throwsStateError);
      });

      test('must say why', () {
        expect(() => Withdrawn(' ', by: 'designer-a', at: t0), throwsArgumentError);
      });

      test('a stored withdrawal by someone else is a FormatException naming the rule', () {
        final json = fresh().toJson()..['history'] = [withdraw('claude').toJson()];
        expect(
          () => Mark.fromJson(json, 'mark'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'mark.history: mark m1, event 0: was raised by designer-a, and only they can '
                  'withdraw it',
            ),
          ),
        );
      });
    });

    test('recording returns a copy and leaves the original alone', () {
      final m = fresh();
      m.record(fix);
      expect(m.status, MarkStatus.open);
      expect(m.history, isEmpty);
    });
  });

  group('answers', () {
    test('a fix needs a commit SHA', () {
      expect(() => Answer.fixed(commit: 'main'), throwsArgumentError);
      expect(Answer.fixed(commit: 'abc1234').commit, 'abc1234');
    });

    test("won't-fix and question need a note", () {
      expect(() => Answer.wontFix(note: '  '), throwsArgumentError);
      expect(() => Answer.question(note: ''), throwsArgumentError);
      expect(Answer.question(note: 'Which size?').note, 'Which size?');
    });

    test('a reopen must say what is still wrong', () {
      expect(() => Reopened(' ', by: 'a', at: t0), throwsArgumentError);
    });
  });

  group('json', () {
    test('round-trips a mark with every kind of event', () {
      final m = fresh()
          .record(
            Answered(
              Answer.question(note: 'Which device?'),
              by: 'claude',
              at: t(1),
            ),
          )
          .record(reopen(2))
          .record(
            Answered(
              Answer.wontFix(note: 'by design'),
              by: 'claude',
              at: t(3),
            ),
          )
          .record(verify);
      final back = Mark.fromJson(m.toJson(), 'mark');
      expect(back.toJson(), m.toJson());
      expect(back.status, MarkStatus.verified);
      final withdrawn = fresh().record(Withdrawn('a test', by: 'designer-a', at: t(1)));
      final w = Mark.fromJson(withdrawn.toJson(), 'mark');
      expect(w.toJson(), withdrawn.toJson());
      expect(w.status, MarkStatus.withdrawn);
      expect((w.history.single as Withdrawn).note, 'a test');
      expect(back.frame, m.frame);
      expect(back.history.map((e) => e.runtimeType), [Answered, Reopened, Answered, Verified]);
    });

    test('an illegal stored history is a FormatException, not a quietly open mark', () {
      final json = fresh().toJson()..['history'] = [verify.toJson()];
      expect(
        () => Mark.fromJson(json, 'mark'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('history'))),
      );
    });

    test('a time without a zone is refused', () {
      final json = fresh().toJson()..['at'] = '2026-11-25T09:00:00';
      expect(() => Mark.fromJson(json, 'mark'), throwsFormatException);
    });

    test('a non-canonical frame key is refused', () {
      final json = fresh().toJson()..['frame'] = 'screen=home;device=pixel-7';
      expect(() => Mark.fromJson(json, 'mark'), throwsFormatException);
    });

    test('an unknown answer kind is refused', () {
      expect(() => Answer.fromJson({'kind': 'maybe'}, 'a'), throwsFormatException);
      expect(
        () => Answer.fromJson({'kind': 'fixed', 'commit': 'nope'}, 'a'),
        throwsFormatException,
      );
    });
  });
}
