import 'package:galley_core/galley_core.dart';

/// A mark as the server stores it, with its [events] in `seq` order, read as the core's
/// [Mark].
///
/// A row is the mark's columns with `by` already read through the author's membership (their
/// alias in the galley) and `at` the server's `created` (DESIGN D15). Both readers of the
/// server's records, the validator and the client, read them here, so the two cannot disagree
/// on what a stored mark is. Rejected: the mark's JSON stored as written, whose `by` and `at`
/// the client chose.
///
/// Throws a [FormatException] naming the field when a row does not read, and when the events
/// do not fold, the core's reason as a [FormatException] at `history`.
Mark markOfRow(Object? row, List<Object?> events, String context) {
  final r = JsonReader(row, context);
  return Mark.fromJson({
    'id': r.string('id'),
    'frame': r.string('frame'),
    'anchor': r.read('anchor', (j, _) => j),
    'pin': r.read('pin', (j, _) => j),
    'note': r.string('note'),
    'by': r.string('by'),
    'at': r.string('at'),
    'history': [for (final (i, e) in events.indexed) _eventJson(e, '$context.events[$i]')],
  }, context);
}

/// An event as the server stores it, read as the core's [MarkEvent]: `kind` is the event's
/// name, and `note`, `commit` and `answer` (the answer's kind) are columns of their own.
MarkEvent eventOfRow(Object? row, String context) =>
    MarkEvent.fromJson(_eventJson(row, context), context);

/// The columns that store [event]: what a client writes. `by` and `at` are not among them:
/// the server takes them from who is signed in and when the write lands.
JsonMap eventRow(MarkEvent event) => switch (event) {
  Answered(:final answer) => {
    'kind': 'answered',
    'answer': answer.toJson()['kind'],
    'commit': answer.commit ?? '',
    'note': answer.note ?? '',
  },
  Verified() => {'kind': 'verified', 'answer': '', 'commit': '', 'note': ''},
  Reopened(:final note) => {'kind': 'reopened', 'answer': '', 'commit': '', 'note': note},
  Withdrawn(:final note) => {'kind': 'withdrawn', 'answer': '', 'commit': '', 'note': note},
};

/// The core's JSON for an event row. An empty column is an absent one: PocketBase stores an
/// unset text field as "", and the core reads a note of "" as a note that says nothing, which
/// it refuses where a note is required.
JsonMap _eventJson(Object? row, String context) {
  final r = JsonReader(row, context);
  String? text(String key) => switch (r.optionalString(key)) {
    '' || null => null,
    final s => s,
  };
  final kind = r.string('kind'), note = text('note');
  return {
    'event': kind,
    'by': r.string('by'),
    'at': r.string('at'),
    if (kind == 'answered')
      'answer': {'kind': text('answer'), 'commit': ?text('commit'), 'note': ?note}
    else
      'note': ?note,
  };
}
