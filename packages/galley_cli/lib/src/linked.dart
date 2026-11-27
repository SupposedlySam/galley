import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:galley_core/galley_core.dart';
import 'package:galley_server/galley_server.dart';

import 'modes.dart';

// A galley linked to a server (docs/DESIGN.md D15, "The commands follow the galley"): which
// server and galley `.galley/server.json` names, who is signed in to it, and a rendered round
// as the files a push sends.

/// The server and galley an app's `.galley/` is linked to, kept in `.galley/server.json`.
///
/// Only where, never who: the sign-in is the user's, kept in their own [SessionStore], so a
/// `.galley/` that is copied, or committed by mistake, carries no secret.
final class ServerLink {
  /// The galley [galley] on the server at [url].
  const ServerLink(this.url, this.galley);

  /// The server's root.
  final Uri url;

  /// The galley's record id.
  final String galley;

  static String _file(String galleyPath) => '$galleyPath/server.json';

  /// The link of the galley at [galleyPath], or null when it is not linked: then every
  /// command works on the directory itself.
  static ServerLink? read(String galleyPath) {
    final f = File(_file(galleyPath));
    if (!f.existsSync()) return null;
    try {
      final r = JsonReader(jsonDecode(f.readAsStringSync()), f.path);
      return ServerLink(serverUrl(r.string('url')), r.string('galley'));
    } on FormatException catch (e) {
      throw Refused.damaged('${f.path} does not read: ${e.message}. `galley unlink` removes it');
    }
  }

  /// Links the galley at [galleyPath] to this.
  void write(String galleyPath) {
    final f = File(_file(galleyPath))..parent.createSync(recursive: true);
    f.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(toJson())}\n');
  }

  /// Unlinks the galley at [galleyPath], and says whether it was linked. Nothing on the
  /// server changes.
  static bool remove(String galleyPath) {
    final f = File(_file(galleyPath));
    if (!f.existsSync()) return false;
    f.deleteSync();
    return true;
  }

  /// The form [read] reads.
  JsonMap toJson() => {'url': '$url', 'galley': galley};
}

/// [given] as a server's root URL: http or https, with a host, and no query or fragment.
/// A path is kept, for a server behind a proxy under one, and ends in `/`.
Uri serverUrl(String given) {
  final url = Uri.tryParse(given.trim());
  if (url == null || !url.isScheme('http') && !url.isScheme('https') || url.host.isEmpty) {
    throw Refused.invalid('"$given" is not a server\'s URL: give http://host:port or https://host');
  }
  if (url.hasQuery || url.hasFragment) {
    throw Refused.invalid('$given has a query or fragment; give the server\'s root');
  }
  final path = url.path.endsWith('/') ? url.path : '${url.path}/';
  return url.replace(path: path);
}

/// The sessions this user is signed in with, one per server, kept under [root] where only
/// they can read them (the directory 700, each file 600).
///
/// A session's token lets anyone holding it act as the user until it runs out, so it is
/// never written into `.galley/` (D15). Kept in the user cache: losing it costs a sign-in,
/// nothing more.
final class SessionStore {
  /// Sessions kept in [root].
  const SessionStore(this.root);

  /// The directory they are kept in.
  final String root;

  /// The file for [server]: named by a hash of its URL, since a URL is not a file name.
  String fileFor(Uri server) =>
      '$root/${sha256.convert(utf8.encode('$server')).toString().substring(0, 32)}.json';

  /// The session for [server], or null when the user has not signed in to it here.
  Session? read(Uri server) {
    final f = File(fileFor(server));
    if (!f.existsSync()) return null;
    try {
      final r = JsonReader(jsonDecode(f.readAsStringSync()), f.path);
      if (r.string('server') != '$server') {
        throw FormatException('${f.path} is the session for ${r.string('server')}, not $server');
      }
      return r.read('session', Session.fromJson);
    } on FormatException catch (e) {
      throw Refused.damaged(
        'the saved sign-in ${f.path} does not read: ${e.message}. `galley login` again',
      );
    }
  }

  /// Keeps [session] for [server], replacing the one before.
  void write(Uri server, Session session) {
    final dir = Directory(root)..createSync(recursive: true);
    setMode(dir.path, 448); // 0700: listing the directory says which servers one uses.
    final f = File(fileFor(server));
    // Made empty and closed to others before the token is in it.
    f.writeAsStringSync('');
    setMode(f.path, 384); // 0600
    f.writeAsStringSync(
      '${jsonEncode({'server': '$server', 'session': session.toJson()})}\n',
      flush: true,
    );
  }
}

/// Every file of the round rendered at [dir], for a push: each one's path inside the round,
/// size and SHA-256, read again only when it is sent.
///
/// `placements.json` is left out: a local pack writes it, and on a server the placements are
/// the round's own field, set as it is finished. The files are listed in path order, so two
/// pushes of one render make one manifest, and a push that stopped can be finished.
Future<List<PushFile>> pushFilesOf(String dir) async {
  final root = Directory(dir);
  final prefix = root.absolute.path.length + 1;
  final files = [
    for (final e in root.absolute.listSync(recursive: true, followLinks: false))
      if (e is File) e,
  ];
  final pushed = <PushFile>[];
  for (final f in files) {
    final path = f.path.substring(prefix).replaceAll(r'\', '/');
    if (path == 'placements.json') continue;
    final digest = await sha256.bind(f.openRead()).first;
    pushed.add(PushFile(path: path, sha256: '$digest', size: f.lengthSync(), read: f.readAsBytes));
  }
  pushed.sort((a, b) => a.path.compareTo(b.path));
  return pushed;
}
