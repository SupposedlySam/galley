import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

// The built canvas, as `galley serve` finds it (docs/DESIGN.md D14): a release asset, pinned by
// tag and SHA-256 here, fetched once into a cache outside the app, checked before anything is
// unpacked, and unpacked whole or not at all.

/// The canvas build this `galley_cli` serves: its release, and its archive's SHA-256.
///
/// A release that does not change the canvas keeps the old pin, so [version] is the release
/// the canvas was last built in, not necessarily this package's.
const pinnedCanvas = PinnedCanvas(
  version: '0.3.8',
  sha256: '767edff05cc1e9a590b781d78e020b9287f2194825bda367514fcecc3357db2c',
);

/// A canvas build, by the release it is attached to and its archive's SHA-256.
final class PinnedCanvas {
  /// The build attached to `v<version>`, whose archive hashes to [sha256].
  const PinnedCanvas({required this.version, required this.sha256});

  /// The release it is attached to, without the `v`.
  final String version;

  /// The archive's SHA-256, as lowercase hex.
  final String sha256;

  /// The archive's file name, on the release and in the cache.
  String get asset => 'galley_web-$version.tar.gz';

  /// Where it is downloaded from.
  Uri get url =>
      Uri.https('github.com', '/SupposedlySam/galley/releases/download/v$version/$asset');
}

/// Where the canvas is, or why there is none.
sealed class CanvasSource {
  const CanvasSource();
}

/// A built canvas, in [directory]: it has an `index.html`.
final class CanvasAt extends CanvasSource {
  /// The canvas in [directory].
  const CanvasAt(this.directory);

  /// The build's root.
  final String directory;
}

/// No canvas, and [why]. The API is still served.
final class NoCanvas extends CanvasSource {
  /// No canvas, because of [why].
  const NoCanvas(this.why);

  /// What went wrong, in a sentence a person can act on.
  final String why;
}

/// Gets [url]'s body, or throws saying why.
typedef Fetch = Future<Uint8List> Function(Uri url);

/// Where a galley keeps what it fetched, from [environment]: `GALLEY_CACHE` as given, else
/// `galley` under the platform's user cache directory. Null when neither can be told.
///
/// The platform's directory is the one its own tools use: `~/Library/Caches` on macOS,
/// `%LOCALAPPDATA%` on Windows, and `$XDG_CACHE_HOME`, else `~/.cache`, elsewhere (the XDG base
/// directory specification). Rejected: the app's `.galley`. The build is the same for every
/// app, 40 MB unpacked, and would be one more thing for each app to keep out of git.
String? cacheDirectory(Map<String, String> environment, {String? os}) {
  String? set(String name) => switch (environment[name]) {
    final v? when v.isNotEmpty => v,
    _ => null,
  };
  if (set('GALLEY_CACHE') case final dir?) return dir;
  final home = set('HOME');
  final platform = switch (os ?? Platform.operatingSystem) {
    'macos' => home == null ? null : '$home/Library/Caches',
    'windows' => set('LOCALAPPDATA'),
    _ => set('XDG_CACHE_HOME') ?? (home == null ? null : '$home/.cache'),
  };
  return platform == null ? null : '$platform/galley';
}

/// The canvas cache under [root], filled by [fetch].
final class CanvasCache {
  /// The cache in [root].
  CanvasCache(this.root, {required this.fetch});

  /// The galley cache directory ([cacheDirectory]); canvases are under `canvas/`.
  final String root;

  /// How an archive is downloaded.
  final Fetch fetch;

  /// The most an archive may be: the 0.3.8 build is 14 MB. A body larger than this is not the
  /// canvas, and is not held in memory to find that out.
  static const maxArchive = 64 << 20;

  /// [pin]'s directory, keyed by its hash as well as its version: a re-pinned build of the same
  /// version is a different directory, never a stale one.
  String directoryOf(PinnedCanvas pin) =>
      '$root/canvas/galley_web-${pin.version}-${pin.sha256.substring(0, 16)}';

  /// The canvas [pin] names: from the cache, or fetched, checked and unpacked into it.
  ///
  /// The archive is checked against [PinnedCanvas.sha256] before anything is written, then
  /// unpacked beside its directory and renamed into it, so the directory is whole or absent.
  /// Rejected: unpacking in place. An interrupted unpack would leave an `index.html` and a
  /// partial build, which the next start would take for whole.
  Future<CanvasSource> canvas(PinnedCanvas pin) async {
    final dir = directoryOf(pin);
    if (File('$dir/index.html').existsSync()) return CanvasAt(dir);

    final Uint8List archive;
    try {
      archive = await fetch(pin.url);
    } on Object catch (e) {
      return NoCanvas('could not fetch ${pin.url}: $e');
    }
    final got = sha256.convert(archive).toString();
    if (got != pin.sha256) {
      return NoCanvas(
        '${pin.url} is not the pinned build: its SHA-256 is $got, not ${pin.sha256}. '
        'Nothing was kept',
      );
    }

    final staging = Directory('$dir.partial-$pid-${DateTime.now().microsecondsSinceEpoch}');
    try {
      final entries = readTarGz(archive);
      if (!entries.any((e) => e.path == 'index.html' && e.bytes != null)) {
        return NoCanvas('${pin.asset} has no index.html at its root');
      }
      for (final e in entries) {
        final at = '${staging.path}/${e.path}';
        if (e.bytes case final bytes?) {
          File(at)
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(bytes);
        } else {
          Directory(at).createSync(recursive: true);
        }
      }
      try {
        staging.renameSync(dir);
      } on FileSystemException {
        // Another `serve` unpacked it first: the same bytes, by the hash, so take that one.
        if (!File('$dir/index.html').existsSync()) rethrow;
      }
      return CanvasAt(dir);
    } on FormatException catch (e) {
      return NoCanvas('${pin.asset} does not unpack: ${e.message}');
    } on FileSystemException catch (e) {
      return NoCanvas('could not unpack ${pin.asset} into $root: ${e.message} (${e.path})');
    } finally {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    }
  }
}

/// Downloads [url] with dart:io, following redirects (a release asset redirects to its
/// storage), refusing anything but a 200 and any body over [max] bytes.
Future<Uint8List> httpFetch(Uri url, {int max = CanvasCache.maxArchive}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final response = await (await client.getUrl(url)).close();
    if (response.statusCode != 200) {
      throw HttpException('answered ${response.statusCode}', uri: url);
    }
    final body = BytesBuilder(copy: false);
    await for (final chunk in response) {
      body.add(chunk);
      if (body.length > max) {
        throw HttpException('larger than $max bytes', uri: url);
      }
    }
    return body.takeBytes();
  } finally {
    client.close(force: true);
  }
}

/// One entry of a tar archive: a file with its [bytes], or a directory (null).
typedef TarEntry = ({String path, Uint8List? bytes});

/// The entries of the gzipped tar [archive], with every path checked to stay inside the
/// directory it is unpacked into.
///
/// Only what a canvas build is made of is read: regular files and directories, in ustar
/// headers, with pax headers for long names. Anything else, a link, a device or a FIFO above
/// all, is refused, so nothing in the archive can write outside its directory or point out of
/// it. Rejected: `package:archive`, which reads every kind of entry and would leave the same
/// refusals to be written here, and brings in an FFI dependency for file modes this does not
/// keep. Rejected too: running `tar`, whose handling of `..` and links differs between the
/// implementations a reviewer's machine might have.
///
/// Throws [FormatException] naming the entry when the archive is not that.
List<TarEntry> readTarGz(Uint8List archive) {
  final Uint8List tar;
  try {
    tar = Uint8List.fromList(gzip.decode(archive));
  } on FormatException catch (e) {
    throw FormatException('not gzip (${e.message})');
  }
  return readTar(tar);
}

/// The entries of the tar [tar]: see [readTarGz].
List<TarEntry> readTar(Uint8List tar) {
  const block = 512;
  final entries = <TarEntry>[];
  String? paxPath;
  var at = 0;
  while (true) {
    if (at + block > tar.length) throw const FormatException('it ends inside a header');
    final header = Uint8List.sublistView(tar, at, at + block);
    if (header.every((b) => b == 0)) return entries;
    _checksum(header, at);
    final type = header[156];
    final size = _octal(header, 124, 12, 'size');
    final start = at + block;
    if (start + size > tar.length) throw const FormatException('it ends inside an entry');
    final data = Uint8List.sublistView(tar, start, start + size);
    at = start + (size + block - 1) ~/ block * block;

    switch (type) {
      case 0x78: // 'x': a pax header for the next entry. Only its path is kept.
        paxPath = _paxPath(data);
      case 0x67: // 'g': a pax header for the whole archive, of nothing a build needs.
        break;
      case 0x30 || 0x00 || 0x35: // '0' or NUL: a file. '5': a directory.
        final named = paxPath ?? _name(header);
        paxPath = null;
        final path = _safePath(named);
        if (path == null) continue; // `./`, the archive's own root.
        entries.add((path: path, bytes: type == 0x35 ? null : Uint8List.fromList(data)));
      default:
        throw FormatException(
          '${paxPath ?? _name(header)} is a "${String.fromCharCode(type)}" entry: '
          'only files and directories are unpacked',
        );
    }
  }
}

void _checksum(Uint8List header, int at) {
  var sum = 0;
  for (var i = 0; i < header.length; i++) {
    sum += i >= 148 && i < 156 ? 0x20 : header[i];
  }
  if (_octal(header, 148, 8, 'checksum') != sum) {
    throw FormatException('the header at byte $at does not match its checksum');
  }
}

int _octal(Uint8List header, int offset, int length, String field) {
  final text = _string(header, offset, length).trim();
  final n = int.tryParse(text.isEmpty ? '0' : text, radix: 8);
  if (n == null) throw FormatException('a header\'s $field is not octal: "$text"');
  return n;
}

String _string(Uint8List bytes, int offset, int length) {
  final field = Uint8List.sublistView(bytes, offset, offset + length);
  final end = field.indexOf(0);
  return _utf8(end < 0 ? field : field.sublist(0, end));
}

String _name(Uint8List header) {
  final name = _string(header, 0, 100);
  final prefix = _string(header, 345, 155);
  return prefix.isEmpty ? name : '$prefix/$name';
}

/// The `path` record of a pax header: lines of `<length> <key>=<value>\n`.
String? _paxPath(Uint8List data) {
  // A record's length counts bytes, so it is walked over the bytes, not the decoded text: a
  // name with a character outside ASCII would otherwise put every later record off.
  String? path;
  var i = 0;
  while (i < data.length) {
    final space = data.indexOf(0x20, i);
    final length = space < 0 ? null : int.tryParse(String.fromCharCodes(data, i, space));
    if (length == null || space + 1 > i + length - 1 || i + length > data.length) {
      throw const FormatException('a pax header does not read');
    }
    // Only the path is decoded. Observed: macOS tar writes extended attributes as pax
    // records whose values are not UTF-8, and decoding every record refused its archives.
    final record = Uint8List.sublistView(data, space + 1, i + length - 1);
    if (record.length >= 5 && String.fromCharCodes(record, 0, 5) == 'path=') {
      path = _utf8(Uint8List.sublistView(record, 5));
    }
    i += length;
  }
  return path;
}

String _utf8(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const FormatException('a name is not UTF-8');
  }
}

/// [name] relative to the directory it is unpacked into, or null for that directory itself.
/// Throws when it would leave it: absolute, a `..`, a drive, or a backslash, which Windows
/// reads as a separator.
String? _safePath(String name) {
  final segments = name.split('/').where((s) => s.isNotEmpty && s != '.').toList();
  if (segments.isEmpty) return null;
  if (name.startsWith('/') ||
      segments.any((s) => s == '..' || s.contains(r'\') || s.contains(':'))) {
    throw FormatException('$name would be unpacked outside its directory');
  }
  return segments.join('/');
}
