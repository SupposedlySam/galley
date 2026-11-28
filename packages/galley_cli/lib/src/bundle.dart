import 'dart:convert';
import 'dart:io';

import 'package:galley_core/galley_core.dart';

import 'modes.dart';
import 'pocketbase.dart';
import 'server_source.dart';

// A Galley server for a machine elsewhere (docs/DESIGN.md D18, docs/HOSTING.md): everything
// `galley host` runs, written to one directory that a container is built from. The bundle is
// built here, where the galley's source and Dart are, and the machine that runs it needs
// neither: its validator is compiled for it, and its PocketBase is the pinned release for it.
//
// Rejected: a Dockerfile that builds the validator itself (`FROM dart`, `dart pub get`). It
// would compile whatever source the build fetched, not the source this CLI judges by, and a
// server whose rules differ from its client's refuses writes its client allows.

/// The platforms a bundle is written for: Linux, which a host runs containers on. A bundle for
/// this machine's own platform is written too, so it can be run and checked here.
const linuxPlatforms = {
  'linux_amd64': Target('linux', 'x64'),
  'linux_arm64': Target('linux', 'arm64'),
};

/// What [platform], PocketBase's name, is to `dart compile exe`; null when this machine cannot
/// compile for it. Dart cross-compiles to Linux only, so another platform is this one or none.
Target? targetOf(String platform) =>
    linuxPlatforms[platform] ??
    (PinnedPocketBase.forAbi()?.platform == platform ? Target.current : null);

/// Writes a bundle for [platform] to [to], which must be missing or empty: [pocketbase]'s
/// executable (unpacked from the pinned release for [platform]), the validator compiled for
/// it from [source] into the cache under [cache], the schema and hooks, [canvas]'s build as
/// `public/`, a `run` script, a `Dockerfile`, and `bundle.json` saying what it was made of
/// ([made] says when, and [canvasNamed] which canvas).
Future<void> writeBundle({
  required String to,
  required String platform,
  required String pocketbase,
  required GalleySource source,
  required String cache,
  required String canvas,
  required String canvasNamed,
  required DateTime made,
}) async {
  final target = targetOf(platform);
  if (target == null) {
    throw Refused.invalid(
      'a bundle is for ${[...linuxPlatforms.keys, ?PinnedPocketBase.forAbi()?.platform].join(', ')}, '
      'not $platform',
    );
  }
  final dir = Directory(to);
  if (dir.existsSync() && dir.listSync().isNotEmpty) {
    // Nothing is erased: a bundle is written whole into a directory of its own, and never
    // over another, whose files a deploy would ship beside these.
    throw Refused.invalid('$to is not empty: give a new directory');
  }
  final validate = await source.validator(cache, target: target);

  dir.createSync(recursive: true);
  _copy(File(pocketbase), '$to/pocketbase', mode: 0x1ed); // 0o755
  _copy(File(validate), '$to/galley_validate', mode: 0x1ed);
  for (final part in ['pb_migrations', 'pb_hooks']) {
    _copyTree(Directory('${source.pocketbase}/$part'), '$to/schema/$part');
  }
  _copyTree(Directory(canvas), '$to/public');
  File('$to/run').writeAsStringSync(runScript());
  setMode('$to/run', 0x1ed);
  File('$to/Dockerfile').writeAsStringSync(dockerfile);
  File('$to/bundle.json').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'platform': platform, 'pocketbase': pocketBaseVersion, 'canvas': canvasNamed, 'made': made.toUtc().toIso8601String()})}\n',
  );
}

/// The bundle's `run`: PocketBase, started with the flags `galley host` starts it with
/// ([serveFlags]), its data in `$GALLEY_DATA`, listening on `$GALLEY_HTTP` (every address, on
/// port 8080, by default). The operator's settings are the environment's (DESIGN D18), and
/// reach the hooks as they are.
String runScript() {
  final flags = serveFlags(data: r'$data', schema: r'$here/schema', public: r'$here/public');
  // Each flag is double-quoted, so `$data` and `$here` expand and nothing in them splits.
  // They are this package's own strings, with no quote, backtick or backslash in them.
  assert(flags.every((f) => !RegExp(r'["`\\]').hasMatch(f)));
  return [
    '#!/bin/sh',
    '# A Galley server, written by `galley bundle` (docs/HOSTING.md). Its galleys are kept in',
    r'# $GALLEY_DATA, and it listens on $GALLEY_HTTP (0.0.0.0:8080). Its settings are the',
    '# environment\'s: GALLEY_URL, GALLEY_SMTP_*, GALLEY_MAIL_*, GALLEY_PROXY_HEADER and',
    '# GALLEY_OWNERS, applied on every start.',
    'set -eu',
    // Its data is its galleys' marks and its users' emails: the owner's alone.
    'umask 077',
    r'here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)',
    r'data=${GALLEY_DATA:?set GALLEY_DATA to the directory its galleys are kept in}',
    r'mkdir -p "$data"',
    r'export GALLEY_VALIDATE="$here/galley_validate"',
    [
      r'exec "$here/pocketbase" serve "--http=${GALLEY_HTTP:-0.0.0.0:8080}"',
      for (final f in flags) '"$f"',
    ].join(' \\\n  '),
    '',
  ].join('\n');
}

/// The bundle's `Dockerfile`. Debian, not Alpine: the validator is a Dart executable linked
/// against glibc, which Alpine has not. ca-certificates, so the mailer can check its relay's
/// certificate.
///
/// The base image is pinned by digest, as PocketBase and the canvas are pinned by hash: a tag
/// moves, and a server rebuilt from the same bundle would run on another system. The digest is
/// the multi-platform index, so it serves both [linuxPlatforms]. Observed 2026-11-27 from
/// registry-1.docker.io, `library/debian` `bookworm-slim`: the index lists linux/amd64 and
/// linux/arm64/v8. Rejected: the tag alone, the first bundle's choice.
const debianDigest = 'sha256:e67eeead736ff7bbe258ef088bff683635c561b1fcfefad0806c1df4ab49ce0e';

const dockerfile =
    '''
# A Galley server, written by `galley bundle` (docs/HOSTING.md).
FROM debian:bookworm-slim@$debianDigest
RUN apt-get update \\
 && apt-get install -y --no-install-recommends ca-certificates \\
 && rm -rf /var/lib/apt/lists/*
COPY . /galley
ENV GALLEY_DATA=/data
EXPOSE 8080
CMD ["/galley/run"]
''';

void _copy(File from, String to, {int? mode}) {
  from.copySync(to);
  if (mode != null) setMode(to, mode);
}

void _copyTree(Directory from, String to) {
  Directory(to).createSync(recursive: true);
  for (final e in from.listSync(recursive: true, followLinks: false)) {
    final at = '$to${e.path.substring(from.path.length)}';
    switch (e) {
      case Directory():
        Directory(at).createSync(recursive: true);
      case File():
        Directory(File(at).parent.path).createSync(recursive: true);
        e.copySync(at);
      default:
        // A link in a canvas build or the schema would ship whatever it points to on this
        // machine, or nothing.
        throw Refused.invalid('${e.path} is a link: a bundle is made of files');
    }
  }
}
