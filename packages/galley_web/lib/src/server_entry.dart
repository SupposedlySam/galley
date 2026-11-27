import 'package:galley_core/galley_core.dart';
import 'package:galley_server/galley_server.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import 'canvas_model.dart';
import 'session_store.dart';

// The way into a galley on a server (docs/DESIGN.md D15): sign in by a mailed code, be a
// member of the galley, then the canvas. Who may read what is the server's rule; this only
// asks, and says what it answered.

/// What the entry asks the server, through galley_server. An interface so the entry's steps
/// are tested without one; [ServerDoor] is the real one, and galley_server's parts of it are
/// tested against a real server (galley_cli test/linked_test.dart).
abstract interface class Door {
  /// See [SignIn.requestCode].
  Future<String> requestCode(String email);

  /// See [SignIn.withCode].
  Future<Session> withCode(String otpId, String code);

  /// See [SignIn.refresh].
  Future<Session> refresh(Session session);

  /// See [ServerAccount.standingIn].
  Future<Standing> standing(Session session);

  /// See [ServerAccount.join].
  Future<Member> join(Session session, {required String alias});

  /// The galley, read as [session]'s user.
  Galley galley(Session session);
}

/// The [Door] of galley [galleyId] on [server].
final class ServerDoor implements Door {
  /// [galleyId] on [server].
  ServerDoor(this.server, this.galleyId);

  /// The server at [base], through [client].
  ServerDoor.at(http.Client client, Uri base, String galleyId)
    : this(PocketBase(client, base), galleyId);

  /// The server.
  final PocketBase server;

  /// The galley's record id.
  final String galleyId;

  @override
  Future<String> requestCode(String email) => SignIn(server).requestCode(email);

  @override
  Future<Session> withCode(String otpId, String code) => SignIn(server).withCode(otpId, code);

  @override
  Future<Session> refresh(Session session) => SignIn(server).refresh(session);

  @override
  Future<Standing> standing(Session session) => ServerAccount(server, session).standingIn(galleyId);

  @override
  Future<Member> join(Session session, {required String alias}) =>
      ServerAccount(server, session).join(galleyId, alias: alias);

  @override
  Galley galley(Session session) => ServerGalley(server, galleyId: galleyId, session: session);
}

/// Where the entry is.
sealed class EntryStep {
  const EntryStep();
}

/// Reading the sign-in kept on this browser.
final class Checking extends EntryStep {
  /// Checking.
  const Checking();
}

/// Asking for the email to mail a code to, with [why] the last try did not get further.
final class AskingEmail extends EntryStep {
  /// Asking, after [why].
  const AskingEmail([this.why]);

  /// Why the member is here again, or null on a first visit.
  final String? why;
}

/// Asking for the code mailed to [email].
final class AskingCode extends EntryStep {
  /// Asking for [email]'s code, after [why].
  const AskingCode(this.email, this._otpId, [this.why]);

  /// Where the code went.
  final String email;

  final String _otpId;

  /// Why the last code was not taken, or null.
  final String? why;
}

/// Invited, and asking for the alias to join as.
final class AskingAlias extends EntryStep {
  /// Asking [email] for their alias, after [why].
  const AskingAlias(this.email, [this.why]);

  /// Who was invited.
  final String email;

  /// Why the last alias was not taken, or null.
  final String? why;
}

/// Signed in, and not let in: [message] says why.
final class Barred extends EntryStep {
  /// Barred because of [message].
  const Barred(this.message);

  /// Why, in a sentence the member can act on.
  final String message;
}

/// In: the [canvas] of the galley, as the member.
final class Entered extends EntryStep {
  /// In, on [canvas].
  const Entered(this.canvas);

  /// The galley, as the member signed in.
  final CanvasModel canvas;
}

/// The steps into a galley on a server, from a kept sign-in or a new one, to its canvas.
final class ServerEntry extends ChangeNotifier {
  /// The entry through [door], keeping the sign-in in [store].
  ServerEntry(this.door, this.store, {this.now});

  /// What it asks.
  final Door door;

  /// Where the sign-in is kept between visits.
  final SessionStore store;

  /// The clock of the canvas it opens; the system's when null.
  final DateTime Function()? now;

  /// Where it is.
  EntryStep get step => _step;
  EntryStep _step = const Checking();

  /// Whether a request is out: the form waits for it.
  bool get busy => _busy;
  bool _busy = false;

  Session? _session;

  /// From the sign-in kept on this browser, renewed, or to the email form.
  ///
  /// A kept sign-in that cannot be renewed is not forgotten: the next sign-in replaces it.
  /// Rejected: clearing it on any refusal, since the server unreachable for a moment would
  /// then sign the member out.
  Future<void> start() => _run(() async {
    final kept = store.read();
    if (kept == null) return _go(const AskingEmail());
    final Session renewed;
    try {
      renewed = await door.refresh(kept);
    } on Refused catch (e) {
      return _go(
        AskingEmail(
          'The sign-in kept on this browser, as ${kept.email}, was not renewed: ${e.message}. '
          'Sign in again.',
        ),
      );
    }
    store.write(renewed);
    await _open(renewed);
  });

  /// Mails a code to [email].
  Future<void> sendCode(String email) => _run(() async {
    final address = email.trim();
    if (!address.contains('@')) return _go(const AskingEmail('That is not an email address.'));
    try {
      _go(AskingCode(address, await door.requestCode(address)));
    } on Refused catch (e) {
      _go(AskingEmail(e.message));
    }
  });

  /// Signs in with [code], the one mailed for the step now asked.
  Future<void> signIn(String code) => _run(() async {
    final asking = _step;
    if (asking is! AskingCode) throw StateError('no code was asked for');
    final Session session;
    try {
      session = await door.withCode(asking._otpId, code);
    } on Refused catch (e) {
      return _go(AskingCode(asking.email, asking._otpId, e.message));
    }
    store.write(session);
    await _open(session);
  });

  /// Joins the galley as [alias], by the open invite.
  Future<void> join(String alias) => _run(() async {
    final session = _session;
    final asking = _step;
    if (session == null || asking is! AskingAlias) throw StateError('no invite is being taken');
    final name = alias.trim();
    if (name.isEmpty) return _go(AskingAlias(asking.email, 'Say what to sign your marks with.'));
    try {
      await door.join(session, alias: name);
    } on Refused catch (e) {
      return _go(AskingAlias(asking.email, e.message));
    }
    await _open(session);
  });

  /// Back to the email form, from asking for a code.
  void back() => _go(const AskingEmail());

  /// Forgets the sign-in on this browser.
  void signOut() {
    store.clear();
    _session = null;
    _go(const AskingEmail());
  }

  /// Tries the galley again as the member signed in, or from the start when nobody is.
  Future<void> retry() => switch (_session) {
    final s? => _run(() => _open(s)),
    null => start(),
  };

  Future<void> _open(Session session) async {
    _session = session;
    final Standing standing;
    try {
      standing = await door.standing(session);
    } on Refused catch (e) {
      return _go(
        Barred(
          'The server did not say whether ${session.email} is in this galley: '
          '${e.message}',
        ),
      );
    }
    _go(switch (standing) {
      Joined(:final member) => Entered(
        CanvasModel.signedIn(
          door.galley(session),
          SignedIn(email: session.email, alias: member.alias, signOut: signOut),
          now: now,
        ),
      ),
      RevokedFrom() => Barred(
        '${session.email}\'s access to this galley was revoked by its owner. What they wrote '
        'is kept.',
      ),
      InvitedTo() => AskingAlias(session.email),
      Outside() => Barred(
        '${session.email} is not a member of this galley, and has no invite to it. Ask its '
        'owner to invite you: `galley invite ${session.email}`.',
      ),
    });
  }

  Future<void> _run(Future<void> Function() step) async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      await step();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // A canvas left behind is not disposed: a load it began may still finish and notify, which a
  // disposed ChangeNotifier refuses. It holds no resource but its listeners, which go with
  // its page.
  void _go(EntryStep next) {
    _step = next;
    notifyListeners();
  }
}
