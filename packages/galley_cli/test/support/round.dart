import 'dart:convert';
import 'dart:io';

import 'package:galley_cli/galley_cli.dart';
import 'package:galley_core/galley_core.dart';

/// A frame with an image and a tree.
final drawn = FrameKey({'screen': 'drawn'});

/// A frame with a tree and no image.
final blank = FrameKey({'screen': 'blank'});

/// The first bytes of a PNG, as `drawn`'s image.
const png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/// Round 1: `drawn` has an image and a tree, `blank` has a tree and no image.
void writeRound(GalleyDirectory g) => writeRoundAt(g.roundPath(1));

/// The round [writeRound] writes, rendered at [root]: what a renderer writes for a push.
void writeRoundAt(String root) {
  void write(String path, Object? json) =>
      (File('$root/$path')..createSync(recursive: true)).writeAsStringSync(jsonEncode(json));
  final tree = FrameTree(
    bounds: const LogicalRect(0, 0, 400, 800),
    nodes: [
      WidgetNode(indexPath: const [], type: 'App', rect: const LogicalRect(0, 0, 400, 800)),
      WidgetNode(indexPath: const [0], type: 'Card', rect: const LogicalRect(0, 0, 200, 100)),
    ],
  );
  for (final (key, image) in [(drawn, 'frames/drawn.png'), (blank, null)]) {
    final name = '${key.values['screen']}';
    write('trees/$name.json', tree.toJson());
    write(
      'records/$name.json',
      FrameRecord(
        key: key,
        scenario: 'base',
        uri: Uri.parse('/$name'),
        landing: LandedAt(Uri.parse('/$name')),
        status: FrameStatus.rendered,
        device: DeviceProfile.pixel7,
        essential: true,
        errors: const [],
        image: image,
        tree: 'trees/$name.json',
      ).toJson(),
    );
  }
  File('$root/frames/drawn.png')
    ..createSync(recursive: true)
    ..writeAsBytesSync(png);
  write(
    'index.json',
    RoundManifest(frames: ['records/drawn.json', 'records/blank.json'], planned: 2).toJson(),
  );
}
