import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math';

import 'package:galley_core/galley_core.dart';

import 'modes.dart';
import 'pinned.dart';
import 'pocketbase.dart';
import 'rest.dart';
import 'server_source.dart';

// A Galley server on this machine (docs/DESIGN.md D15): the pinned PocketBase, run with
// galley_server's schema and hooks and the validator they call, compiled from the source this
// CLI was resolved with. It is for the step 6 check and for working on the server, and it is
// what the server's tests start. It is not hosting (ROADMAP step 8): it listens on loopback
// only, and its sign-in codes are written to a directory, not mailed.

/// Where a galley keeps what it must not lose, from [environment]: `galley` under the
/// platform's user data directory. Null when it cannot be told.
///
/// `~/Library/Application Support` on macOS, `%APPDATA%` on Windows, and `$XDG_DATA_HOME`,
/// else `~/.local/share`, elsewhere (the XDG base directory specification). Rejected: the
/// cache directory ([cacheDirectory]), which a user, or the system, may empty. A server's data
/// is its galleys, and nothing is erased (DESIGN principles).
String? dataDirectory(Map<String, String> environment, {String? os}) {
  String? set(String name) => switch (environment[name]) {
    final v? when v.isNotEmpty => v,
    _ => null,
  };
  final home = set('HOME');
  final platform = switch (os ?? Platform.operatingSystem) {
    'macos' => home == null ? null : '$home/Library/Application Support',
    'windows' => set('APPDATA'),
    _ => set('XDG_DATA_HOME') ?? (home == null ? null : '$home/.local/share'),
  };
  return platform == null ? null : '$platform/galley';
}

/// A running PocketBase with Galley's schema, started by [LocalServer.start].
final class LocalServer {
  LocalServer._(this.url, this.data, this._process, this._superuser, this.exitCode);

  /// Where it answers: loopback, at the port it was started on.
  final Uri url;

  /// Its data directory: PocketBase's database and files, and the sign-in codes.
  final String data;

  /// Where a sign-in code is written, as `<otpDirectory>/<email>`, in place of mail.
  String get otpDirectory => '$data/otp';

  final Process _process;
  final ({String email, String password}) _superuser;

  /// Completes with PocketBase's exit code when it stops, for any reason.
  final Future<int> exitCode;

  /// Starts PocketBase on [port] (a free one when 0) with its data in [data], fetching it
  /// and compiling the validator into [cache] when they are not there yet. [log] gets each
  /// line PocketBase writes. [canvas], a built canvas, is served at `/`, from the same origin
  /// as the API (DESIGN D15); without one, `/` serves the empty `public` in [data].
  ///
  /// [environment] is added to what PocketBase runs with: an operator's settings, which the
  /// hooks apply on every start (DESIGN D18), as GALLEY_OWNERS or GALLEY_SMTP_HOST. A hosted
  /// server reads the same variables, so a test of one here tests the other.
  ///
  /// Throws [Refused] saying why it could not.
  static Future<LocalServer> start({
    required String data,
    required ArchiveCache cache,
    int port = 8090,
    String? canvas,
    Map<String, String> environment = const {},
    void Function(String line)? log,
  }) async {
    final pin = PinnedPocketBase.forAbi();
    if (pin == null) {
      throw Refused.environment(
        'PocketBase is pinned for ${PinnedPocketBase.platforms.join(', ')}, and not for this '
        'machine (${Abi.current()})',
      );
    }
    final source = GalleySource.resolve();
    final pocketbase = switch (await cache.unpacked(pin)) {
      UnpackedAt(:final directory) => '$directory/${pin.executable}',
      NotUnpacked(:final why) => throw Refused.environment('no PocketBase: $why'),
    };
    final validate = await source.validator(cache.root);

    Directory(data).createSync(recursive: true);
    setMode(data, 0x1c0); // 0o700: its galleys' marks, and its users' emails.
    for (final dir in ['otp', 'public']) {
      Directory('$data/$dir').createSync();
    }
    setMode('$data/otp', 0x1c0);
    final superuser = _superuserOf(data);

    final flags = serveFlags(
      data: data,
      schema: source.pocketbase,
      public: canvas ?? '$data/public',
    );
    // The password after `--`, which ends the flags (cobra, as PocketBase reads its command
    // line): a base64url password starts with "-" one time in 32, and was read as a flag
    // ("unknown shorthand flag"). Rejected: a password alphabet without "-". It would leave
    // every superuser.json already written with one unable to start.
    final upsert = await Process.run(pocketbase, [
      'superuser',
      'upsert',
      ...flags,
      '--',
      superuser.email,
      superuser.password,
    ]);
    if (upsert.exitCode != 0) {
      throw Refused.environment(
        'PocketBase would not set up its superuser: ${'${upsert.stderr}${upsert.stdout}'.trim()}',
      );
    }

    final at = port == 0 ? await _freePort() : port;
    final process = await Process.start(
      pocketbase,
      ['serve', '--http=127.0.0.1:$at', ...flags],
      environment: {...environment, 'GALLEY_VALIDATE': validate, 'GALLEY_OTP_LOG': '$data/otp'},
    );
    final tail = <String>[];
    for (final stream in [process.stdout, process.stderr]) {
      stream.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        tail.add(line);
        if (tail.length > 20) tail.removeAt(0);
        log?.call(line);
      });
    }
    final exited = process.exitCode;

    final url = Uri.parse('http://127.0.0.1:$at');
    final server = LocalServer._(url, data, process, superuser, exited);
    final up = await Future.any([_healthy(url).then((_) => true), exited.then((_) => false)])
        .timeout(const Duration(seconds: 30), onTimeout: () => false);
    if (!up) {
      await server.close();
      throw Refused.environment(
        'PocketBase did not start on $url. It said:\n  ${tail.join('\n  ')}',
      );
    }
    return server;
  }

  /// A superuser's token, for setting the server up: making a user an invite has not made.
  ///
  /// Signed in for once per start and kept: a superuser's requests pass PocketBase's rate
  /// limiter, and its sign-in does not.
  Future<String> superuserToken() async => _token ??= await _signIn();
  String? _token;

  Future<String> _signIn() async {
    final body = await _json('POST', '/api/collections/_superusers/auth-with-password', {
      'identity': _superuser.email,
      'password': _superuser.password,
    });
    return (body as Map)['token'] as String;
  }

  /// Makes a user for [email], lower-cased, unless there is one: the owner of a galley, who
  /// no invite names. Returns their id.
  Future<String> ensureUser(String email) async {
    final lower = email.toLowerCase();
    final token = await superuserToken();
    final found = await _json(
      'GET',
      '/api/collections/users/records?filter=${Uri.encodeQueryComponent('email = "${lower.replaceAll('"', '')}"')}',
      null,
      token,
    );
    final items = (found as Map)['items'] as List;
    if (items.isNotEmpty) return (items.first as Map)['id'] as String;
    final password = _secret();
    final made = await _json('POST', '/api/collections/users/records', {
      'email': lower,
      'password': password,
      'passwordConfirm': password,
      'verified': true,
    }, token);
    return (made as Map)['id'] as String;
  }

  /// Stops PocketBase, and returns its exit code.
  Future<int> close() async {
    _process.kill();
    return exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return exitCode;
      },
    );
  }

  Future<Object?> _json(String method, String path, Object? body, [String? token]) async {
    final a = await send(url, method, path, body: body, token: token);
    if (a.status != 200) {
      throw Refused.environment('$method $path answered ${a.status}: ${messageOf(a) ?? a.body}');
    }
    return a.body;
  }
}

/// The superuser `galley host` sets its server up with: made on the first start, with a
/// random password kept in [data], readable by its owner only, and the same on every start.
({String email, String password}) _superuserOf(String data) {
  final file = File('$data/superuser.json');
  if (file.existsSync()) {
    final j = jsonDecode(file.readAsStringSync()) as Map;
    return (email: j['email'] as String, password: j['password'] as String);
  }
  // `.invalid` is reserved (RFC 2606): nothing is ever mailed to it.
  final made = (email: 'galley-host@galley.invalid', password: _secret());
  file.writeAsStringSync(jsonEncode({'email': made.email, 'password': made.password}));
  setMode(file.path, 0x180); // 0o600
  return made;
}

String _secret() {
  final r = Random.secure();
  return base64Url.encode([for (var i = 0; i < 24; i++) r.nextInt(256)]);
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _healthy(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
  try {
    while (true) {
      try {
        final response = await (await client.getUrl(url.resolve('/api/health'))).close();
        await response.drain<void>();
        if (response.statusCode == 200) return;
      } on IOException {
        // Not listening yet.
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  } finally {
    client.close(force: true);
  }
}
