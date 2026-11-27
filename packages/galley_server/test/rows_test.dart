import 'package:galley_core/galley_core.dart';
import 'package:galley_server/galley_server.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  final at = DateTime.utc(2026, 11, 27, 10);

  test('every event is written as columns and read back as itself', () {
    final events = <MarkEvent>[
      Answered(
        Answer.fixed(commit: 'abc1234'),
        by: 'Owner',
        at: at,
      ),
      Answered(
        Answer.fixed(commit: 'abc1234', note: 'padding'),
        by: 'Owner',
        at: at,
      ),
      Answered(
        Answer.wontFix(note: 'by design'),
        by: 'Owner',
        at: at,
      ),
      Answered(
        Answer.question(note: 'which one?'),
        by: 'Owner',
        at: at,
      ),
      Verified(by: 'Rae', at: at),
      Reopened('still tight', by: 'Rae', at: at),
      Withdrawn('dupe', by: 'Rae', at: at),
    ];
    final back = [
      for (final e in events)
        eventOfRow({...eventRow(e), 'by': e.by, 'at': '2026-11-27 10:00:00.000Z'}, 'row'),
    ];
    expect([for (final e in back) e.toJson()], [for (final e in events) e.toJson()]);
  });

  test('a column the event does not use is written empty, as PocketBase stores it', () {
    expect(eventRow(Verified(by: 'Rae', at: at)), {
      'kind': 'verified',
      'answer': '',
      'commit': '',
      'note': '',
    });
    expect(
      eventRow(
        Answered(
          Answer.fixed(commit: 'abc1234'),
          by: 'Owner',
          at: at,
        ),
      ),
      {'kind': 'answered', 'answer': 'fixed', 'commit': 'abc1234', 'note': ''},
    );
  });

  test('an empty note is no note, so the core refuses it where one is required', () {
    for (final kind in ['reopened', 'withdrawn']) {
      expect(
        () => eventOfRow(eventRow0(kind), 'row'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'row.note: missing, expected a string',
          ),
        ),
        reason: kind,
      );
    }
    expect(
      () => eventOfRow(eventRow0('answered', answer: 'wont_fix'), 'row'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('note'))),
    );
  });

  test("a mark row and its events fold into the core's mark", () {
    final mark = markOfRow(markRow('m1'), [
      eventRow0('answered', answer: 'wont_fix', note: 'by design'),
      eventRow0('reopened', by: 'Rae', note: 'it is not'),
    ], 'mark');
    expect(
      (mark.id, mark.frame, mark.by, mark.at, mark.status, mark.anchor.type, mark.pin.dy),
      (
        'm1',
        home,
        'Rae',
        DateTime.utc(2026, 11, 27, 9, 30, 0, 123),
        MarkStatus.reopened,
        'FilledButton',
        0.25,
      ),
    );
    expect(
      [for (final e in mark.history) (e.runtimeType, e.by)],
      [(Answered, 'Owner'), (Reopened, 'Rae')],
    );
  });

  test('events that do not fold are refused, naming the history and why', () {
    expect(
      () => markOfRow(markRow('m1'), [eventRow0('verified', by: 'Rae')], 'mark'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'mark.history: mark m1, event 0: is open, and cannot be verified now',
        ),
      ),
    );
  });
}
