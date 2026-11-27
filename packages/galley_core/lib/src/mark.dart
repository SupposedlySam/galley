import 'anchor.dart';
import 'commit.dart';
import 'frame_key.dart';
import 'json.dart';

/// Where a mark is in its review: who it is waiting on.
enum MarkStatus {
  /// A reviewer raised it; it waits for an answer.
  open,

  /// It was answered; it waits for a reviewer to verify or reopen it.
  answered,

  /// A reviewer accepted the answer. Final.
  verified,

  /// A reviewer did not accept the answer; it waits for another.
  reopened,

  /// Whoever raised it took it back: a duplicate, or a test. Final, and kept with its history.
  withdrawn;

  /// Whether this status waits on an answer.
  bool get awaitsAnswer => this == open || this == reopened;

  /// Whether nothing more happens to it: verified or withdrawn. Every other status waits on
  /// someone, the app or the reviewer.
  bool get isFinal => this == verified || this == withdrawn;
}

/// How a mark was answered.
enum AnswerKind {
  /// The change was made. Names the commit.
  fixed,

  /// It will not be changed. Says why.
  wontFix,

  /// It needs the reviewer to say more. Asks what.
  question,
}

/// The answer to a mark.
final class Answer {
  /// A fix, made in [commit]. [note] is optional.
  Answer.fixed({required String this.commit, this.note}) : kind = AnswerKind.fixed {
    if (!isCommitSha(commit!)) {
      throw ArgumentError.value(commit, 'commit', 'must be a 7 to 40 character hex SHA');
    }
  }

  /// A decision not to change it, explained by [note].
  Answer.wontFix({required String this.note}) : kind = AnswerKind.wontFix, commit = null {
    _requireNote(note!);
  }

  /// A question back to the reviewer, asked in [note].
  Answer.question({required String this.note}) : kind = AnswerKind.question, commit = null {
    _requireNote(note!);
  }

  /// Reads the form [toJson] writes.
  factory Answer.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    final kind = r.string('kind');
    try {
      return switch (kind) {
        'fixed' => Answer.fixed(commit: r.string('commit'), note: r.optionalString('note')),
        'wont_fix' => Answer.wontFix(note: r.string('note')),
        'question' => Answer.question(note: r.string('note')),
        _ => throw FormatException('$context.kind: unknown answer kind "$kind"'),
      };
    } on ArgumentError catch (e) {
      throw FormatException('$context.${e.name}: ${e.message}');
    }
  }

  /// How it was answered.
  final AnswerKind kind;

  /// The commit that fixed it, for [AnswerKind.fixed]; otherwise null.
  final String? commit;

  /// What the answerer said. Required unless [kind] is [AnswerKind.fixed].
  final String? note;

  /// The JSON form [Answer.fromJson] reads.
  JsonMap toJson() => {
    'kind': _kindNames[kind],
    if (commit != null) 'commit': commit,
    if (note != null) 'note': note,
  };

  static void _requireNote(String note) {
    if (note.trim().isEmpty) {
      throw ArgumentError.value(note, 'note', 'must say why, or ask what');
    }
  }

  static const _kindNames = {
    AnswerKind.fixed: 'fixed',
    AnswerKind.wontFix: 'wont_fix',
    AnswerKind.question: 'question',
  };
}

/// Something that happened to a mark. A mark's history is a list of these, only ever appended
/// to; its status is what they add up to (DESIGN.md, "nothing is erased").
sealed class MarkEvent {
  const MarkEvent({required this.by, required this.at});

  /// Reads the form [toJson] writes.
  factory MarkEvent.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    final by = r.string('by');
    final at = r.utcTime('at');
    return switch (r.string('event')) {
      'answered' => Answered(r.read('answer', Answer.fromJson), by: by, at: at),
      'verified' => Verified(by: by, at: at),
      'reopened' => Reopened(r.string('note'), by: by, at: at),
      'withdrawn' => Withdrawn(r.string('note'), by: by, at: at),
      final other => throw FormatException('$context.event: unknown event "$other"'),
    };
  }

  /// Who did it.
  final String by;

  /// When, in UTC.
  final DateTime at;

  /// The status a mark in [from], raised by [raisedBy], moves to; or null when this event is
  /// not allowed on it.
  MarkStatus? apply(MarkStatus from, {required String raisedBy});

  /// What a person reads for this event: "answered", "withdrawn".
  String get verb;

  /// Why this event is not allowed on a mark in [from] raised by [raisedBy], when [apply] says
  /// it is not.
  String refusal(MarkStatus from, {required String raisedBy}) =>
      'is ${from.name}, and cannot be $verb now';

  /// The JSON form [MarkEvent.fromJson] reads.
  JsonMap toJson();

  JsonMap _base(String event) => {'event': event, 'by': by, 'at': at.toIso8601String()};
}

/// The mark was answered.
final class Answered extends MarkEvent {
  /// [answer], given by [by] at [at].
  const Answered(this.answer, {required super.by, required super.at});

  /// The answer.
  final Answer answer;

  @override
  MarkStatus? apply(MarkStatus from, {required String raisedBy}) =>
      from.awaitsAnswer ? MarkStatus.answered : null;

  @override
  String get verb => 'answered';

  @override
  JsonMap toJson() => {..._base('answered'), 'answer': answer.toJson()};
}

/// A reviewer accepted the answer.
final class Verified extends MarkEvent {
  /// Verified by [by] at [at].
  const Verified({required super.by, required super.at});

  @override
  MarkStatus? apply(MarkStatus from, {required String raisedBy}) =>
      from == MarkStatus.answered ? MarkStatus.verified : null;

  @override
  String get verb => 'verified';

  @override
  JsonMap toJson() => _base('verified');
}

/// A reviewer did not accept the answer, and said why.
final class Reopened extends MarkEvent {
  /// Reopened by [by] at [at], because of [note].
  Reopened(this.note, {required super.by, required super.at}) {
    if (note.trim().isEmpty) {
      throw ArgumentError.value(note, 'note', 'a reopen must say what is still wrong');
    }
  }

  /// What is still wrong.
  final String note;

  @override
  MarkStatus? apply(MarkStatus from, {required String raisedBy}) =>
      from == MarkStatus.answered ? MarkStatus.reopened : null;

  @override
  String get verb => 'reopened';

  @override
  JsonMap toJson() => {..._base('reopened'), 'note': note};
}

/// Whoever raised the mark took it back, and said why: a duplicate of another mark, or a mark
/// raised to try the tool.
///
/// It is an event, not a deletion, because nothing is erased: a withdrawn mark keeps its note
/// and its history, and is still carried into every round. Only the person who raised it may
/// withdraw it. Rejected: letting anyone withdraw, which would let an answerer close a mark
/// without the reviewer's say; the app's owner who disagrees with a mark answers it `wont-fix`,
/// and the reviewer verifies or reopens that. Allowed from every status but the final ones, so
/// a duplicate that was already answered can still be taken back.
final class Withdrawn extends MarkEvent {
  /// Withdrawn by [by] at [at], because of [note].
  Withdrawn(this.note, {required super.by, required super.at}) {
    if (note.trim().isEmpty) {
      throw ArgumentError.value(note, 'note', 'a withdrawal must say why');
    }
  }

  /// Why it was taken back.
  final String note;

  @override
  MarkStatus? apply(MarkStatus from, {required String raisedBy}) =>
      by == raisedBy && !from.isFinal ? MarkStatus.withdrawn : null;

  @override
  String get verb => 'withdrawn';

  @override
  String refusal(MarkStatus from, {required String raisedBy}) => by == raisedBy
      ? super.refusal(from, raisedBy: raisedBy)
      : 'was raised by $raisedBy, and only they can withdraw it';

  @override
  JsonMap toJson() => {..._base('withdrawn'), 'note': note};
}

/// A reviewer's comment, pinned to a widget in one frame, and everything that happened to it.
final class Mark {
  /// A mark with its history. Throws a [StateError] if [history] is not a legal sequence.
  Mark({
    required this.id,
    required this.frame,
    required this.anchor,
    required this.pin,
    required this.note,
    required this.by,
    required this.at,
    List<MarkEvent> history = const [],
  }) : history = List.unmodifiable(history),
       status = _fold(id, by, history);

  /// Reads the form [toJson] writes.
  factory Mark.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    final frameSource = r.string('frame');
    final FrameKey frame;
    try {
      frame = FrameKey.parse(frameSource);
    } on FormatException catch (e) {
      throw FormatException('$context.frame: ${e.message}');
    }
    final id = r.string('id');
    try {
      return Mark(
        id: id,
        frame: frame,
        anchor: r.read('anchor', Anchor.fromJson),
        pin: r.read('pin', PinOffset.fromJson),
        note: r.string('note'),
        by: r.string('by'),
        at: r.utcTime('at'),
        history: r.readList('history', MarkEvent.fromJson),
      );
    } on StateError catch (e) {
      throw FormatException('$context.history: ${e.message}');
    }
  }

  /// Stable id, assigned by the server.
  final String id;

  /// The frame the mark was raised on.
  final FrameKey frame;

  /// The widget it was pinned to, as captured.
  final Anchor anchor;

  /// Where on that widget.
  final PinOffset pin;

  /// What the reviewer said.
  final String note;

  /// Who raised it.
  final String by;

  /// When, in UTC.
  final DateTime at;

  /// Everything that happened to it since, oldest first.
  final List<MarkEvent> history;

  /// What [history] adds up to.
  final MarkStatus status;

  /// A copy with [event] appended. Throws a [StateError] saying why when [event] is not
  /// allowed on this mark, such as verifying a mark nobody answered.
  Mark record(MarkEvent event) {
    if (event.apply(status, raisedBy: by) == null) {
      throw StateError('mark $id ${event.refusal(status, raisedBy: by)}');
    }
    return _with(event);
  }

  Mark _with(MarkEvent event) => Mark(
    id: id,
    frame: frame,
    anchor: anchor,
    pin: pin,
    note: note,
    by: by,
    at: at,
    history: [...history, event],
  );

  /// The JSON form [Mark.fromJson] reads.
  JsonMap toJson() => {
    'id': id,
    'frame': frame.toString(),
    'anchor': anchor.toJson(),
    'pin': pin.toJson(),
    'note': note,
    'by': by,
    'at': at.toIso8601String(),
    'history': [for (final e in history) e.toJson()],
  };

  static MarkStatus _fold(String id, String by, List<MarkEvent> history) {
    var status = MarkStatus.open;
    for (final (i, event) in history.indexed) {
      final next = event.apply(status, raisedBy: by);
      if (next == null) {
        throw StateError('mark $id, event $i: ${event.refusal(status, raisedBy: by)}');
      }
      status = next;
    }
    return status;
  }
}
