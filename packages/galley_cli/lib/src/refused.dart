/// What was asked cannot be done, and [message] says why. The CLI prints it and exits 1; the
/// server answers with the status its [kind] names.
///
/// Every refusal names its kind. Rejected: one kind for all, which is what 0.3.5 had. Its
/// server answered 409 to a blank note, and a client could not tell "fix your input" from "the
/// mark moved on". Rejected too: a default kind, which would be a guess wearing a label.
final class Refused implements Exception {
  /// The request is well formed and means something that cannot be: a blank note, a frame the
  /// round does not have, a commit that is not one.
  const Refused.invalid(this.message) : kind = RefusalKind.invalid;

  /// What the request is addressed to is not there: no such mark.
  const Refused.missing(this.message) : kind = RefusalKind.missing;

  /// The galley's state does not allow it now: a mark that is not answered cannot be verified,
  /// and a galley with no rounds has nothing to mark.
  const Refused.conflict(this.message) : kind = RefusalKind.conflict;

  /// Something on this machine failed: a flutter that cannot run, a port that is taken.
  const Refused.environment(this.message) : kind = RefusalKind.environment;

  /// A file the galley keeps does not read, or names what is not there: a mark file deleted
  /// by hand while a round's placements still name it. [message] names the file. Nothing a
  /// request sends can fix it, so the server answers 500, not 400.
  const Refused.damaged(this.message) : kind = RefusalKind.damaged;

  /// Why.
  final String message;

  /// Which kind of refusal it is.
  final RefusalKind kind;

  @override
  String toString() => 'Refused: $message';
}

/// The kinds of [Refused], as the server tells them apart.
enum RefusalKind {
  /// See [Refused.invalid].
  invalid,

  /// See [Refused.missing].
  missing,

  /// See [Refused.conflict].
  conflict,

  /// See [Refused.environment].
  environment,

  /// See [Refused.damaged].
  damaged,
}
