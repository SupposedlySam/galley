import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'archive.dart';
import 'modes.dart';

// What a galley fetches and keeps (docs/DESIGN.md D14, D15): the canvas build for `serve`, and
// PocketBase for `host`. Each is a release asset pinned by URL and SHA-256 in this package,
// fetched once into a cache outside the app, checked before anything is unpacked, and
// unpacked whole or not at all.

/// An archive this package fetches: where it is, what it hashes to, and how it is kept.
abstract interface class PinnedArchive {
  /// The cache's directory for its kind, as `canvas` or `pocketbase`.
  String get kind;

  /// The archive's file name, ending `.tar.gz` or `.zip`, which says how it is read.
  String get asset;

  /// Where it is downloaded from.
  Uri get url;

  /// Its SHA-256, as lowercase hex.
  String get sha256;

  /// A file every whole unpack has at its root, as `index.html`. It is what says, on the
  /// next start, that the directory holds the archive and not nothing.
  String get marker;
}

/// Gets [url]'s body, or throws saying why.
typedef Fetch = Future<Uint8List> Function(Uri url);

/// Where a galley keeps what it fetched, from [environment]: `GALLEY_CACHE` as given, else
/// `galley` under the platform's user cache directory. Null when neither can be told.
///
/// The platform's directory is the one its own tools use: `~/Library/Caches` on macOS,
/// `%LOCALAPPDATA%` on Windows, and `$XDG_CACHE_HOME`, else `~/.cache`, elsewhere (the XDG base
/// directory specification). Rejected: the app's `.galley`. What is kept is the same for every
/// app, tens of megabytes unpacked, and would be one more thing for each app to keep out of git.
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

/// Where an archive was unpacked, or why it was not.
sealed class Unpacked {
  const Unpacked();
}

/// The archive, whole, in [directory].
final class UnpackedAt extends Unpacked {
  /// The archive in [directory].
  const UnpackedAt(this.directory);

  /// Its root.
  final String directory;
}

/// No archive, and [why].
final class NotUnpacked extends Unpacked {
  /// No archive, because of [why].
  const NotUnpacked(this.why);

  /// What went wrong, in a sentence a person can act on.
  final String why;
}

/// The cache of pinned archives under [root], filled by [fetch].
final class ArchiveCache {
  /// The cache in [root].
  ArchiveCache(this.root, {required this.fetch});

  /// The galley cache directory ([cacheDirectory]).
  final String root;

  /// How an archive is downloaded.
  final Fetch fetch;

  /// The most an archive may be: the 0.3.8 canvas is 14 MB, and PocketBase's zips are 12 to
  /// 13 MB. A body larger than this is not what was pinned, and is not held in memory to find
  /// that out.
  static const maxArchive = 64 << 20;

  /// [pin]'s directory, keyed by its hash as well as its name: a re-pinned archive of the same
  /// name is a different directory, never a stale one.
  String directoryOf(PinnedArchive pin) =>
      '$root/${pin.kind}/${_stem(pin.asset)}-${pin.sha256.substring(0, 16)}';

  /// The archive [pin] names: from the cache, or fetched, checked and unpacked into it.
  ///
  /// The archive is checked against [PinnedArchive.sha256] before anything is written, then
  /// unpacked beside its directory and renamed into it, so the directory is whole or absent.
  /// Rejected: unpacking in place. An interrupted unpack would leave the marker and a partial
  /// archive, which the next start would take for whole.
  Future<Unpacked> unpacked(PinnedArchive pin) async {
    final dir = directoryOf(pin);
    if (File('$dir/${pin.marker}').existsSync()) return UnpackedAt(dir);

    final Uint8List archive;
    try {
      archive = await fetch(pin.url);
    } on Object catch (e) {
      return NotUnpacked('could not fetch ${pin.url}: $e');
    }
    final got = sha256.convert(archive).toString();
    if (got != pin.sha256) {
      return NotUnpacked(
        '${pin.url} is not the pinned build: its SHA-256 is $got, not ${pin.sha256}. '
        'Nothing was kept',
      );
    }

    final staging = Directory('$dir.partial-$pid-${DateTime.now().microsecondsSinceEpoch}');
    try {
      final entries = pin.asset.endsWith('.zip') ? readZip(archive) : readTarGz(archive);
      if (!entries.any((e) => e.path == pin.marker && e.bytes != null)) {
        return NotUnpacked('${pin.asset} has no ${pin.marker} at its root');
      }
      for (final e in entries) {
        final at = '${staging.path}/${e.path}';
        if (e.bytes case final bytes?) {
          File(at)
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(bytes);
          // The owner's alone, as chmod 700. Rejected: the archive's own mode bits. A
          // world-writable mode in an archive would be kept, and the cache is the user's.
          if (e.executable) setMode(at, 0x1c0);
        } else {
          Directory(at).createSync(recursive: true);
        }
      }
      try {
        staging.renameSync(dir);
      } on FileSystemException {
        // Another start unpacked it first: the same bytes, by the hash, so take that one.
        if (!File('$dir/${pin.marker}').existsSync()) rethrow;
      }
      return UnpackedAt(dir);
    } on FormatException catch (e) {
      return NotUnpacked('${pin.asset} does not unpack: ${e.message}');
    } on FileSystemException catch (e) {
      return NotUnpacked('could not unpack ${pin.asset} into $root: ${e.message} (${e.path})');
    } finally {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    }
  }
}

String _stem(String asset) => asset.endsWith('.tar.gz')
    ? asset.substring(0, asset.length - '.tar.gz'.length)
    : asset.endsWith('.zip')
    ? asset.substring(0, asset.length - '.zip'.length)
    : asset;

/// Downloads [url] with dart:io, following redirects (a release asset redirects to its
/// storage), refusing anything but a 200 and any body over [max] bytes.
Future<Uint8List> httpFetch(Uri url, {int max = ArchiveCache.maxArchive}) async {
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
