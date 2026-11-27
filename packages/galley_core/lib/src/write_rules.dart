import 'mark.dart';

/// The longest note a mark or an event may carry, in Unicode code points.
///
/// A limit set, not defaulted (DESIGN D15): a server's text field has none of its own, and a
/// note is shown whole in every reviewer's thread and handed whole to the owner's agent by
/// `pull --json`. Applied when a note is written, never when one is read: a note already
/// stored is not made unreadable by a later, lower limit.
const maxNoteLength = 4000;

/// Why a new mark's [note] is refused, or null. It says what is wrong, within [maxNoteLength].
///
/// Here, in the core, because a local galley and a server both take new marks, and the two
/// must refuse the same notes. Rejected: the check in each, which is how one would come to
/// take a note the other refuses.
String? markNoteRefusal(String note) =>
    note.trim().isEmpty ? 'a mark says what is wrong' : _tooLong('a mark', note);

/// Why [event] is refused before it is applied, or null: its note is within [maxNoteLength].
///
/// Whether the event may be recorded on the mark at all, and whether its note may be empty,
/// are [MarkEvent]'s rules, which [Mark.record] applies.
String? eventRefusal(MarkEvent event) => switch (event) {
  Answered(:final answer) => _tooLong('an answer', answer.note),
  Reopened(:final note) => _tooLong('a reopen', note),
  Withdrawn(:final note) => _tooLong('a withdrawal', note),
  Verified() => null,
};

String? _tooLong(String what, String? note) => switch (note?.runes.length) {
  final n? when n > maxNoteLength => '$what\'s note is $n characters, more than $maxNoteLength',
  _ => null,
};
