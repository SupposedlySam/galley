import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:galley_core/galley_core.dart';

// What a Galley server is made of, wherever it runs (docs/DESIGN.md D15, D18): galley_server's
// schema and hooks, the validator they call, and the flags PocketBase is started with. Said
// once, here, for `galley host`, which runs it on this machine, and `galley bundle`, which
// writes it out for a machine elsewhere: a hosted server started with other flags would be a
// server nobody tested.

/// The flags PocketBase is started with, by `galley host` and by a bundle's `run`: its data in
/// [data], the schema and hooks in [schema] (a directory with `pb_migrations` and `pb_hooks`),
/// and [public] served at `/`.
List<String> serveFlags({required String data, required String schema, required String public}) => [
  '--dir=$data/pb_data',
  // Said, not defaulted. PocketBase takes itself for `go run`, and so for a developer's build,
  // when it runs from under the user cache directory (tools/osutils/run.go, v0.40.6), which is
  // where the galley cache is. Then it logs every SQL statement, users' emails and password
  // hashes among them.
  '--dev=false',
  '--migrationsDir=$schema/pb_migrations',
  '--hooksDir=$schema/pb_hooks',
  // The schema and hooks are package source, maybe in a read-only pub cache. Automigrate would
  // write a migration there for each change made in the dashboard; a change to the schema is
  // a migration written by hand (pb_migrations/1795800000_galley.js).
  '--automigrate=false',
  // A change to the hooks is a new CLI, so a new start; and watching restarts PocketBase
  // underneath the process that holds it.
  '--hooksWatch=false',
  // Its default is beside the binary. `galley host` serves the canvas's build from where it
  // is, and does not copy it into the data directory: the pinned one is kept in the cache by
  // version, so a copy would be a second one to keep in step. A relative path is read against
  // the working directory, which PocketBase inherits.
  '--publicDir=$public',
];

/// The machine a validator is compiled for, as `dart compile exe` names it.
final class Target {
  /// [os] and [arch], as `linux` and `x64`.
  const Target(this.os, this.arch);

  /// The machine this runs on.
  static final Target current = Target(Platform.operatingSystem, _arch());

  /// The operating system, as `linux`.
  final String os;

  /// The architecture, as `x64` or `arm64`.
  final String arch;

  @override
  bool operator ==(Object other) => other is Target && other.os == os && other.arch == arch;

  @override
  int get hashCode => Object.hash(os, arch);

  @override
  String toString() => '${os}_$arch';
}

String _arch() {
  // `Platform.version` ends with the platform, as `"macos_arm64"`.
  final platform = RegExp(r'"(\w+)_(\w+)"').firstMatch(Platform.version);
  return platform?.group(2) ?? 'x64';
}

/// galley_server and galley_core where this CLI was resolved: the schema and hooks, and the
/// validator's source. Found through the package config, so they are always the versions this
/// CLI runs with (DESIGN D15: the schema ships with the client).
final class GalleySource {
  const GalleySource._(this.server, this.core, this.packageConfig);

  /// galley_server's root, and galley_core's.
  final String server, core;

  /// The package config the validator is compiled with.
  final String packageConfig;

  /// The directory with `pb_migrations` and `pb_hooks`.
  String get pocketbase => '$server/lib/pocketbase';

  /// The source this CLI runs with. Throws [Refused] when it is a compiled executable, which
  /// has no source to find.
  static GalleySource resolve() {
    String root(String library) {
      final uri = Isolate.resolvePackageUriSync(Uri.parse(library));
      if (uri == null || uri.scheme != 'file') {
        throw Refused.environment(
          'a Galley server needs galley_server\'s source, and could not find $library: run '
          'galley with `dart run`, not as a compiled executable',
        );
      }
      return File.fromUri(uri).parent.parent.path;
    }

    final config = Isolate.packageConfigSync;
    if (config == null || config.scheme != 'file') {
      throw const Refused.environment(
        'a Galley server needs the package config galley was run with',
      );
    }
    return GalleySource._(
      root('package:galley_server/judge.dart'),
      root('package:galley_core/galley_core.dart'),
      File.fromUri(config).path,
    );
  }

  /// The validator compiled from this source for [target] (this machine by default), in the
  /// cache under [root]: compiled once per version of the source, of Dart, and of the target,
  /// by the Dart that runs this CLI.
  ///
  /// Keyed by a hash of every file it is compiled from, not by the package's version: a
  /// checkout between releases has the version of the last one, and a validator compiled from
  /// other source would judge by other rules.
  ///
  /// Another target is cross-compiled (`dart compile exe --target-os`, Dart 3.8 and later),
  /// so a bundle for a Linux server is written on a Mac with no Linux in reach. Observed: a
  /// build for linux/x64 on macOS arm64 is an x86-64 ELF executable, linked against glibc.
  Future<String> validator(String root, {Target? target}) async {
    final to = target ?? Target.current;
    final input = BytesBuilder(copy: false)
      ..add(utf8.encode(Platform.version))
      ..add(utf8.encode('\u0000$to'));
    for (final dir in ['$server/bin', '$server/lib', '$core/lib']) {
      final files = [
        for (final f in Directory(dir).listSync(recursive: true))
          if (f is File && f.path.endsWith('.dart')) f,
      ]..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        input
          ..add(utf8.encode('\u0000${f.path.substring(dir.length)}\u0000'))
          ..add(f.readAsBytesSync());
      }
    }
    final hash = sha256.convert(input.takeBytes());
    final suffix = to.os == 'windows' ? '.exe' : '';
    final exe = '$root/validate/galley_validate-${'$hash'.substring(0, 16)}$suffix';
    if (File(exe).existsSync()) return exe;

    Directory('$root/validate').createSync(recursive: true);
    // Compiled into a directory of its own, then renamed into place: two starts at once, in
    // two processes or in one, each compile their own. Observed: a name made of the pid alone
    // was shared by two test files in one process, and the first rename took the other's file
    // ("Cannot rename file ... No such file or directory"). Rejected: a lock. The loser of the
    // race costs one compile, and a lock left by a killed start would stop every start.
    final staging = Directory('$root/validate').createTempSync('partial-');
    final partial = '${staging.path}/galley_validate$suffix';
    try {
      final built = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        '--packages=$packageConfig',
        if (to != Target.current) ...['--target-os=${to.os}', '--target-arch=${to.arch}'],
        '-o',
        partial,
        '$server/bin/galley_validate.dart',
      ]);
      if (built.exitCode != 0) {
        throw Refused.environment(
          'could not compile the validator for $to with ${Platform.resolvedExecutable}: '
          '${'${built.stderr}${built.stdout}'.trim()}',
        );
      }
      try {
        File(partial).renameSync(exe);
      } on FileSystemException {
        // Windows will not rename onto a file: another start put the same build there first.
        if (!File(exe).existsSync()) rethrow;
      }
      return exe;
    } finally {
      staging.deleteSync(recursive: true);
    }
  }
}

/// The validator `galley host` runs, compiled into the cache under [root] when it is not there
/// yet; its path. Here for its test: two compiles at once each finish.
Future<String> compiledValidator(String root) => GalleySource.resolve().validator(root);
