import 'dart:io';

import 'package:galley_cli/galley_cli.dart';
import 'package:galley_cli/src/rest.dart';

export 'package:galley_cli/src/rest.dart' show Answer, Multipart, messageOf;

// A user of a LocalServer, signed in by the code it writes in place of mail, speaking
// PocketBase's REST API directly. For the server's tests only: what these tests prove is the
// schema's rules and hooks, so they send exactly the requests a client could, not what one
// particular client chooses to.

/// A signed-in user of [server].
final class As {
  As._(this.server, this.email, this.id, this._token);

  final LocalServer server;
  final String email;

  /// Their user id.
  final String id;
  final String _token;

  /// Signs [email] in by the code the server writes for it. The user must exist: an invite,
  /// or [LocalServer.ensureUser], makes it.
  static Future<As> signIn(LocalServer server, String email) async {
    late Answer requested;
    final code = await codeAfter(server.otpDirectory, email, () async {
      requested = await _send(server, 'POST', '/api/collections/users/request-otp', {
        'email': email,
      });
    });
    if (code == null) throw StateError('no code was written for $email');
    final otpId = (requested.body as Map)['otpId'] as String;
    final signed = await _send(server, 'POST', '/api/collections/users/auth-with-otp', {
      'otpId': otpId,
      'password': code,
    });
    if (signed.status != 200) throw StateError('$email did not sign in: ${signed.body}');
    final body = signed.body as Map;
    return As._(server, email, (body['record'] as Map)['id'] as String, body['token'] as String);
  }

  Future<Answer> create(String collection, Map<String, Object?> body) =>
      _send(server, 'POST', '/api/collections/$collection/records', body, _token);

  Future<Answer> update(String collection, String id, Map<String, Object?> body) =>
      _send(server, 'PATCH', '/api/collections/$collection/records/$id', body, _token);

  Future<Answer> view(String collection, String id) =>
      _send(server, 'GET', '/api/collections/$collection/records/$id', null, _token);

  /// A [collection] record with [fields] and [files], sent as parts, as a file field must be.
  Future<Answer> upload(
    String collection,
    Map<String, String> fields,
    Map<String, ({String name, List<int> bytes})> files,
  ) => _send(
    server,
    'POST',
    '/api/collections/$collection/records',
    Multipart(fields, files),
    _token,
  );

  /// The [collection] records this user may list, matching PocketBase's [filter] when given,
  /// sorted by [sort].
  Future<List<Map<String, Object?>>> records(
    String collection, {
    String? filter,
    String sort = 'created',
  }) async {
    final query = Uri(queryParameters: {'perPage': '500', 'sort': sort, 'filter': ?filter}).query;
    final a = await _send(
      server,
      'GET',
      '/api/collections/$collection/records?$query',
      null,
      _token,
    );
    if (a.status != 200) throw StateError('listing $collection answered ${a.status}: ${a.body}');
    return ((a.body as Map)['items'] as List).cast<Map<String, Object?>>();
  }

  /// The ids of the [collection] records this user may list.
  Future<List<String>> ids(String collection) async => [
    for (final r in await records(collection)) r['id'] as String,
  ];

  /// A galley named [name], with this user as its owner under [alias], made the one way it
  /// can be: the galley and the owner's membership in one batch.
  Future<String> makeGalley(String name, {String alias = 'Owner'}) async {
    final id = _id();
    final a = await _send(server, 'POST', '/api/batch', {
      'requests': [
        {
          'method': 'POST',
          'url': '/api/collections/galleys/records',
          'body': {'id': id, 'name': name, 'owner': this.id},
        },
        {
          'method': 'POST',
          'url': '/api/collections/members/records',
          'body': {'galley': id, 'user': this.id, 'role': 'owner', 'alias': alias},
        },
      ],
    }, _token);
    if (a.status != 200) throw StateError('the galley was not made: ${a.body}');
    return id;
  }
}

/// The sign-in code written for [email] into [otpDirectory] once [request] asks for one, or
/// null when none is written in five seconds.
///
/// Waited for: PocketBase answers the request first and sends the code after
/// (apis/record_auth_otp_request.go, `routine.FireAndForget`, v0.40.6), so the file is not
/// there yet when the answer is. An earlier code is removed first, so it is never read as this
/// one.
Future<String?> codeAfter(
  String otpDirectory,
  String email,
  Future<void> Function() request,
) async {
  final file = File('$otpDirectory/$email');
  if (file.existsSync()) file.deleteSync();
  await request();
  for (var i = 0; i < 50; i++) {
    // Written by one call, but read only once it ends in the newline it is written with.
    if (file.existsSync()) {
      final text = file.readAsStringSync();
      if (text.endsWith('\n')) return text.trim();
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return null;
}

var _ids = 0;

/// A record id of PocketBase's form, 15 of [a-z0-9], unique in this run.
String _id() => 'galley${'${_ids++}'.padLeft(9, '0')}';

Future<Answer> _send(
  LocalServer server,
  String method,
  String path,
  Object? body, [
  String? token,
]) => send(server.url, method, path, body: body, token: token);
