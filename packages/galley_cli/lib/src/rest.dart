import 'dart:convert';
import 'dart:io';

// One request to a PocketBase's REST API, over dart:io: what `galley host` sets its server up
// with, and what the server's tests speak. galley_server's client, which the canvas needs on
// the web as well, replaces both when it is written; until then this is the one place a
// request is made.

/// What PocketBase answered: its status and its JSON body (null when empty).
typedef Answer = ({int status, Object? body});

/// The message PocketBase gave with a refusal, or null when [a] is not one.
String? messageOf(Answer a) =>
    a.status >= 400 && a.body is Map ? (a.body as Map)['message'] as String? : null;

/// Sends [method] [path] to [base] with [body] as JSON and [token] as its `Authorization`.
///
/// A 429 is waited out and the request sent again, up to [tries] in all. Galley turns
/// PocketBase's rate limiter on (pb_migrations), and it counts by client IP: two sign-ins in
/// three seconds from one address, which is every reviewer behind one router. Rejected:
/// turning the limit off, or up. It is what keeps an eight-digit sign-in code from being
/// guessed.
Future<Answer> send(
  Uri base,
  String method,
  String path, {
  Object? body,
  String? token,
  int tries = 8,
}) async {
  for (var attempt = 1; ; attempt++) {
    final client = HttpClient();
    final Answer answer;
    try {
      final request = await client.openUrl(method, base.resolve(path));
      if (token != null) request.headers.set('Authorization', token);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      answer = (status: response.statusCode, body: text.isEmpty ? null : jsonDecode(text));
    } finally {
      client.close();
    }
    if (answer.status != 429 || attempt >= tries) return answer;
    // PocketBase's shortest window is one second, and the auth window three.
    await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
  }
}
