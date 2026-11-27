import 'package:galley_core/galley_core.dart';

import 'pocketbase.dart';

/// Who is signed in to a Galley server: their user id, their email, and the token every
/// request they make carries.
final class Session {
  /// [userId], signed in as [email] with [token].
  const Session({required this.userId, required this.email, required this.token});

  /// Reads the form [toJson] writes.
  factory Session.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    return Session(userId: r.string('user'), email: r.string('email'), token: r.string('token'));
  }

  /// The user's record id.
  final String userId;

  /// The email they signed in with, lower-cased as the server keeps it.
  final String email;

  /// What their requests carry as `Authorization`. A secret: kept where only its owner can
  /// read it, never in `.galley/` (D15).
  final String token;

  /// The form [Session.fromJson] reads.
  JsonMap toJson() => {'user': userId, 'email': email, 'token': token};
}

/// Signing in to a Galley server by the code it mails (docs/DESIGN.md D15): there are no
/// passwords and no sign-up. An invite made the user.
final class SignIn {
  /// Signing in to [server].
  const SignIn(this.server);

  /// The server.
  final PocketBase server;

  /// Asks the server to mail a code to [email], and returns the id the code is checked
  /// against.
  ///
  /// The server answers the same for an email it has no user for, so nobody learns from it
  /// who is invited; that user just never receives a code.
  Future<String> requestCode(String email) async {
    final reply = await server.send(
      'POST',
      server.api(['collections', 'users', 'request-otp']),
      body: {'email': email.trim().toLowerCase()},
    );
    return JsonReader(reply, 'request-otp').string('otpId');
  }

  /// Signs in with the [code] that was mailed for [otpId].
  Future<Session> withCode(String otpId, String code) async {
    final reply = await server.send(
      'POST',
      server.api(['collections', 'users', 'auth-with-otp']),
      body: {'otpId': otpId, 'password': code.trim()},
    );
    return _session(reply, 'auth-with-otp');
  }

  /// [session] with a new token, which is good for as long as a new sign-in's would be.
  /// Refused once the old one has run out: then the user signs in again.
  Future<Session> refresh(Session session) async {
    final reply = await server.send(
      'POST',
      server.api(['collections', 'users', 'auth-refresh']),
      token: session.token,
    );
    return _session(reply, 'auth-refresh');
  }

  static Session _session(Object? reply, String context) {
    final r = JsonReader(reply, context);
    final record = r.read('record', JsonReader.new);
    return Session(
      userId: record.string('id'),
      email: record.string('email'),
      token: r.string('token'),
    );
  }
}
