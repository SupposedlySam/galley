import 'pinned.dart';

// The built canvas, as `galley serve` finds it (docs/DESIGN.md D14): a release asset, pinned by
// tag and SHA-256 here, and kept in the galley cache like every pinned archive (pinned.dart).

/// The canvas build this `galley_cli` serves: its release, and its archive's SHA-256.
///
/// A release that does not change the canvas keeps the old pin, so [version] is the release
/// the canvas was last built in, not necessarily this package's.
const pinnedCanvas = PinnedCanvas(
  version: '0.3.12',
  sha256: '97b1586dd30a3b10920a3b860e905d57dfdbcd28180786e78c312326a05b13a7',
);

/// A canvas build, by the release it is attached to and its archive's SHA-256.
final class PinnedCanvas implements PinnedArchive {
  /// The build attached to `v<version>`, whose archive hashes to [sha256].
  const PinnedCanvas({required this.version, required this.sha256});

  /// The release it is attached to, without the `v`.
  final String version;

  @override
  final String sha256;

  @override
  String get kind => 'canvas';

  @override
  String get asset => 'galley_web-$version.tar.gz';

  @override
  Uri get url =>
      Uri.https('github.com', '/SupposedlySam/galley/releases/download/v$version/$asset');

  @override
  String get marker => 'index.html';
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

/// The canvas from the galley cache under [root], filled by [fetch].
final class CanvasCache {
  /// The cache in [root].
  CanvasCache(String root, {required Fetch fetch}) : _cache = ArchiveCache(root, fetch: fetch);

  final ArchiveCache _cache;

  /// [pin]'s directory: see [ArchiveCache.directoryOf].
  String directoryOf(PinnedCanvas pin) => _cache.directoryOf(pin);

  /// The canvas [pin] names: see [ArchiveCache.unpacked].
  Future<CanvasSource> canvas(PinnedCanvas pin) async => switch (await _cache.unpacked(pin)) {
    UnpackedAt(:final directory) => CanvasAt(directory),
    NotUnpacked(:final why) => NoCanvas(why),
  };
}
