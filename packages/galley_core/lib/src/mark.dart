import 'anchor.dart';
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
  reopened;

  /// Whether this status waits on an answer.
  bool get awaitsAnswer => this == open || this == reopened;
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
    if (!_sha.hasMatch(commit!)) {
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

  static final _sha = RegExp(r'^[0-9a-f]{7,40}$');
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
    final at = _readTime(r, 'at');
    return switch (r.string('event')) {
      'answered' => Answered(r.read('answer', Answer.fromJson), by: by, at: at),
      'verified' => Verified(by: by, at: at),
      'reopened' => Reopened(r.string('note'), by: by, at: at),
      final other => throw FormatException('$context.event: unknown event "$other"'),
    };
  }

  /// Who did it.
  final String by;

  /// When, in UTC.
  final DateTime at;

  /// The status a mark in [from] moves to, or null when this event is not allowed from it.
  MarkStatus? apply(MarkStatus from);

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
  MarkStatus? apply(MarkStatus from) => from.awaitsAnswer ? MarkStatus.answered : null;

  @override
  JsonMap toJson() => {..._base('answered'), 'answer': answer.toJson()};
}

/// A reviewer accepted the answer.
final class Verified extends MarkEvent {
  /// Verified by [by] at [at].
  const Verified({required super.by, required super.at});

  @override
  MarkStatus? apply(MarkStatus from) => from == MarkStatus.answered ? MarkStatus.verified : null;

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
  MarkStatus? apply(MarkStatus from) => from == MarkStatus.answered ? MarkStatus.reopened : null;

  @override
  JsonMap toJson() => {..._base('reopened'), 'note': note};
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
       status = _fold(id, history);

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
        at: _readTime(r, 'at'),
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

  /// A copy with [event] appended. Throws a [StateError] when [event] is not allowed in
  /// [status], such as verifying a mark nobody answered.
  Mark record(MarkEvent event) => Mark(
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

  static MarkStatus _fold(String id, List<MarkEvent> history) {
    var status = MarkStatus.open;
    for (final (i, event) in history.indexed) {
      final next = event.apply(status);
      if (next == null) {
        throw StateError('mark $id: event $i (${event.runtimeType}) is not allowed when $status');
      }
      status = next;
    }
    return status;
  }
}

/// Reads a UTC timestamp. A time without a zone is refused: read as local, it would sort a
/// designer's mark before Claude's answer to it.
DateTime _readTime(JsonReader r, String key) {
  final source = r.string(key);
  final time = DateTime.tryParse(source);
  if (time == null || !time.isUtc) {
    throw FormatException('${r.context}.$key: expected a UTC ISO 8601 time, got "$source"');
  }
  return time;
}
