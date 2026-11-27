import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

void main() {
  final at = DateTime.utc(2026, 11, 27);
  final atLimit = 'é' * maxNoteLength, past = '$atLimit.';

  test('a new mark says what is wrong, within the limit', () {
    expect(
      {
        for (final n in ['make it primary', atLimit, '', '  \n', past])
          n.length: markNoteRefusal(n),
      },
      {
        15: null,
        maxNoteLength: null,
        0: 'a mark says what is wrong',
        3: 'a mark says what is wrong',
        maxNoteLength + 1: "a mark's note is 4001 characters, more than 4000",
      },
    );
  });

  test('the limit counts code points, not UTF-16 units', () {
    // One emoji is two UTF-16 units and one code point: at the limit in code points.
    expect(markNoteRefusal('😀' * maxNoteLength), isNull);
    expect(markNoteRefusal('😀' * (maxNoteLength + 1)), contains('4001 characters'));
  });

  test("an event's note is held to the same limit, whichever event carries it", () {
    expect(
      [
        for (final e in <MarkEvent>[
          Answered(
            Answer.wontFix(note: atLimit),
            by: 'o',
            at: at,
          ),
          Answered(
            Answer.wontFix(note: past),
            by: 'o',
            at: at,
          ),
          Answered(
            Answer.fixed(commit: 'abc1234', note: past),
            by: 'o',
            at: at,
          ),
          Answered(
            Answer.fixed(commit: 'abc1234'),
            by: 'o',
            at: at,
          ),
          Answered(
            Answer.question(note: past),
            by: 'o',
            at: at,
          ),
          Reopened(past, by: 'r', at: at),
          Withdrawn(past, by: 'r', at: at),
          Reopened(atLimit, by: 'r', at: at),
          Verified(by: 'r', at: at),
        ])
          eventRefusal(e),
      ],
      [
        null,
        "an answer's note is 4001 characters, more than 4000",
        "an answer's note is 4001 characters, more than 4000",
        null,
        "an answer's note is 4001 characters, more than 4000",
        "a reopen's note is 4001 characters, more than 4000",
        "a withdrawal's note is 4001 characters, more than 4000",
        null,
        null,
      ],
    );
  });
}
