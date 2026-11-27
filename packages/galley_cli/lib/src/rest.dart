import 'dart:convert';
import 'dart:io';
import 'dart:math';

// One request to a PocketBase's REST API, over dart:io: what `galley host` sets its server up
// with, and what the server's tests speak. galley_server's client, which the canvas needs on
// the web as well, replaces both when it is written; until then this is the one place a
// request is made.

/// What PocketBase answered: its status and its JSON body (null when empty).
typedef Answer = ({int status, Object? body});

/// The message PocketBase gave with a refusal, or null when [a] is not one.
String? messageOf(Answer a) =>
    a.status >= 400 && a.body is Map ? (a.body as Map)['message'] as String? : null;

/// A `multipart/form-data` body: [fields] as text parts, and [files] by field name, each with
/// the file name it is uploaded under. What PocketBase takes a file field in.
final class Multipart {
  /// The parts [fields] and [files].
  const Multipart(this.fields, this.files);

  /// Text fields, by name.
  final Map<String, String> fields;

  /// File fields, by name.
  final Map<String, ({String name, List<int> bytes})> files;

  static final _random = Random.secure();

  /// Writes the parts to [request] as UTF-8, between a random boundary.
  ///
  /// The boundary is 32 random hex digits. Rejected: scanning every part for it first. A file
  /// holding those 32 digits by chance is not a case worth a pass over every byte uploaded.
  void writeTo(HttpClientRequest request) {
    final hex = [
      for (var i = 0; i < 16; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ];
    final boundary = 'galley-${hex.join()}';
    request.headers.contentType = ContentType(
      'multipart',
      'form-data',
      parameters: {'boundary': boundary},
    );
    // Encoded here, not by request.write: with no charset in the content type, write would
    // encode as Latin-1 and throw on a path with any other letter in it.
    void text(String s) => request.add(utf8.encode(s));
    String quoted(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    for (final MapEntry(:key, :value) in fields.entries) {
      text(
        '--$boundary\r\nContent-Disposition: form-data; name="${quoted(key)}"\r\n\r\n$value\r\n',
      );
    }
    for (final MapEntry(:key, value: (:name, :bytes)) in files.entries) {
      text(
        '--$boundary\r\nContent-Disposition: form-data; name="${quoted(key)}"; '
        'filename="${quoted(name)}"\r\nContent-Type: application/octet-stream\r\n\r\n',
      );
      request.add(bytes);
      text('\r\n');
    }
    text('--$boundary--\r\n');
  }
}

/// Sends [method] [path] to [base] with [body] as JSON, or as parts when it is a [Multipart],
/// and [token] as its `Authorization`.
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
      switch (body) {
        case null:
          break;
        case final Multipart parts:
          parts.writeTo(request);
        default:
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
