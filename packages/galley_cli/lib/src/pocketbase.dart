import 'dart:ffi' show Abi;

import 'pinned.dart';

// The PocketBase `galley host` runs (docs/DESIGN.md D15): one release, pinned here by version
// and by each platform's archive SHA-256, fetched into the galley cache like the canvas.
//
// The hashes were taken from the release's own checksums.txt and checked against each zip as
// downloaded. Pinning them here, not reading checksums.txt at run time, is the point: a
// checksum fetched from where the archive is fetched says only that the two agree.
//
// The schema (galley_server's pb_migrations) and hooks (pb_hooks) are written against this
// version's API: its rule modifiers, its hook names and its JavaScript VM. A new pin is a
// change to read them against, and to run the server's tests on.

/// The PocketBase release `galley host` runs.
const pocketBaseVersion = '0.40.6';

/// Each platform's archive SHA-256, by PocketBase's name for it.
const _sha256 = {
  'darwin_amd64': '970464cfdb8faf0ad57e0b6b806fd85e81f99cb78000a1c9f78cdcb1b36d4b7a',
  'darwin_arm64': '7f2f7544e9ee5994ab69f84b22a4ab9a3bcfed58c1dad7206d05ebeb753f968b',
  'linux_amd64': '0e1f609158ed945f809f8a02ae012aa0427129c66ebb63c1aee76f2c0309373f',
  'linux_arm64': 'd22c66ceb67ca92b7d767f36d826e848a276bcfa3c197ead20bf87c42208984f',
  'windows_amd64': '33a2a1d255cadded77346fc7f5de37dca21ba4bad0d9cae0235a50b3b703d6d9',
  'windows_arm64': '7ca50a72b768965f0da194b907d2a1e8865e614cdbebb27fa64ca7ff1d7f5182',
};

/// PocketBase's names for the platforms it is built for, by Dart's.
const _platforms = {
  Abi.macosX64: 'darwin_amd64',
  Abi.macosArm64: 'darwin_arm64',
  Abi.linuxX64: 'linux_amd64',
  Abi.linuxArm64: 'linux_arm64',
  Abi.windowsX64: 'windows_amd64',
  Abi.windowsArm64: 'windows_arm64',
};

/// A PocketBase release's archive for one platform.
final class PinnedPocketBase implements PinnedArchive {
  /// [version]'s archive for [platform] (PocketBase's name, as `darwin_arm64`), whose SHA-256
  /// is [sha256].
  const PinnedPocketBase({required this.version, required this.platform, required this.sha256});

  /// The pinned release for [abi], this machine's by default; null when PocketBase is not
  /// pinned for it.
  static PinnedPocketBase? forAbi([Abi? abi]) {
    final platform = _platforms[abi ?? Abi.current()];
    return platform == null ? null : forPlatform(platform);
  }

  /// The pinned release for [platform], PocketBase's name for it (as `linux_amd64`); null
  /// when PocketBase is not pinned for it.
  static PinnedPocketBase? forPlatform(String platform) => switch (_sha256[platform]) {
    final sha256? => PinnedPocketBase(
      version: pocketBaseVersion,
      platform: platform,
      sha256: sha256,
    ),
    null => null,
  };

  /// The platforms there is a pin for, by PocketBase's name: for saying which, when there is
  /// none for this one.
  static Iterable<String> get platforms => _platforms.values;

  /// The release, without the `v`.
  final String version;

  /// PocketBase's name for the platform, as `darwin_arm64`.
  final String platform;

  @override
  final String sha256;

  @override
  String get kind => 'pocketbase';

  @override
  String get asset => 'pocketbase_${version}_$platform.zip';

  @override
  Uri get url =>
      Uri.https('github.com', '/pocketbase/pocketbase/releases/download/v$version/$asset');

  @override
  String get marker => executable;

  /// The program's file name in the archive.
  String get executable => platform.startsWith('windows') ? 'pocketbase.exe' : 'pocketbase';
}
