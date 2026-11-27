/// What was asked cannot be done, and [message] says why. The CLI prints it and exits 1; a
/// server answers with its [kind]'s [RefusalKind.status], and a client reads it back with
/// [Refused.ofStatus].
///
/// In the core because every [Galley] throws it: the local one, `galley serve`'s client and the
/// server's. Rejected: a refusal type per layer, which the canvas had (`GalleyRefusal`, a bare
/// status): each caller then mapped numbers to meanings again.
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

  /// A refusal a server answered with [status], in its words: the [RefusalKind] whose status it
  /// is, a malformed request (400) as invalid, and anything else (a proxy's 502, a 403) as the
  /// environment. Rejected: a status nobody sends taken as damaged, which tells the reader to
  /// fix a galley that is fine.
  factory Refused.ofStatus(int status, String message) => switch (status) {
    400 || 422 => Refused.invalid(message),
    404 => Refused.missing(message),
    409 => Refused.conflict(message),
    500 => Refused.damaged(message),
    _ => Refused.environment(message),
  };

  /// Why.
  final String message;

  /// Which kind of refusal it is.
  final RefusalKind kind;

  @override
  String toString() => 'Refused: $message';
}

/// The kinds of [Refused], as a server tells them apart.
enum RefusalKind {
  /// See [Refused.invalid].
  invalid(422),

  /// See [Refused.missing].
  missing(404),

  /// See [Refused.conflict].
  conflict(409),

  /// See [Refused.environment].
  environment(500),

  /// See [Refused.damaged].
  damaged(500);

  const RefusalKind(this.status);

  /// The HTTP status a server answers it with.
  final int status;
}
