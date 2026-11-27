import 'frame_tree.dart';
import 'provenance.dart';
import 'record.dart';
import 'round.dart';

/// The files of one round, wherever they are kept: a directory for the CLI, object storage for
/// the server, HTTP for the viewer. Paths are the ones the packer writes, relative to the round.
abstract interface class RoundFiles {
  /// The decoded JSON at [path]. Throws [RoundFileMissing] when there is no file there, and a
  /// [FormatException] when there is one that is not JSON.
  Future<Object?> json(String path);
}

/// [RoundFiles.json] found no file at [path].
///
/// An exception rather than a null, because `null` is a JSON value: a reader returning it for
/// "no file" would let an empty file pass as a missing one, or the reverse.
final class RoundFileMissing implements Exception {
  /// No file at [path].
  const RoundFileMissing(this.path);

  /// The path, relative to the round.
  final String path;

  @override
  String toString() => 'RoundFileMissing: $path';
}

/// A round as stored: where it came from, its index, and its frames, read once.
final class StoredRound {
  StoredRound._(this.provenance, this.manifest, this.frames);

  /// Reads `round.json`, `index.json`, every record the index lists, and each record's tree.
  ///
  /// - A round with no `index.json` did not finish, and is refused.
  /// - A round with no `round.json` was packed before 0.3.2: its [provenance] is [Unrecorded],
  ///   and it is still read.
  /// - A record that is missing or malformed is refused. Carrying a round without it would
  ///   retire the marks on a frame that is in the round.
  /// - A tree that is missing leaves the frame with no tree, so its marks are Unplaced, not
  ///   Lost: the app's widgets were not judged. A tree that is malformed is refused, because a
  ///   packer bug should not be read as an app with no widgets.
  static Future<StoredRound> read(RoundFiles files) async {
    final manifest = RoundManifest.fromJson(await files.json(_index), _index);
    Recorded<RoundProvenance> provenance;
    try {
      provenance = Known(RoundProvenance.fromJson(await files.json(_provenance), _provenance));
    } on RoundFileMissing {
      provenance = Unrecorded('the round has no $_provenance: it was packed before 0.3.2');
    }
    final frames = <RoundFrame>[];
    for (final path in manifest.frames) {
      final record = FrameRecord.fromJson(await files.json(path), path);
      final treePath = record.tree;
      Object? tree;
      if (treePath != null) {
        try {
          tree = await files.json(treePath);
        } on RoundFileMissing {
          tree = null;
        }
      }
      frames.add(RoundFrame(record, tree == null ? null : FrameTree.fromJson(tree, treePath!)));
    }
    return StoredRound._(provenance, manifest, List.unmodifiable(frames));
  }

  /// Where the round came from, or why that is not known.
  final Recorded<RoundProvenance> provenance;

  /// Its `index.json`.
  final RoundManifest manifest;

  /// Its frames, in the index's order.
  final List<RoundFrame> frames;

  /// The frames, ready to carry marks into.
  Round get round => Round(frames);

  static const _index = 'index.json';
  static const _provenance = 'round.json';
}
