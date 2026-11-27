import 'dart:convert';
import 'dart:io';

import 'package:galley_cli/galley_cli.dart';
import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

final _drawn = FrameKey({'screen': 'drawn'});
final _blank = FrameKey({'screen': 'blank'});

/// LocalGalley called directly, as `galley serve` calls it: what the CLI checks before it ever
/// gets here (a blank `--by`) is still checked here, because the server does not have the CLI.
void main() {
  late Directory dir;
  late GalleyDirectory g;
  final at = DateTime.utc(2026, 11, 26, 9, 30);
  var ids = 0;

  LocalGalley local() => LocalGalley(g, now: () => at, newId: () => 'm${++ids}');

  /// Round 1: `drawn` has an image and a tree, `blank` has a tree and no image.
  void writeRound() {
    final root = g.roundPath(1);
    void write(String path, Object? json) =>
        (File('$root/$path')..createSync(recursive: true)).writeAsStringSync(jsonEncode(json));
    final tree = FrameTree(
      bounds: const LogicalRect(0, 0, 400, 800),
      nodes: [
        WidgetNode(indexPath: const [], type: 'App', rect: const LogicalRect(0, 0, 400, 800)),
        WidgetNode(indexPath: const [0], type: 'Card', rect: const LogicalRect(0, 0, 200, 100)),
      ],
    );
    for (final (key, image) in [(_drawn, 'frames/drawn.png'), (_blank, null)]) {
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
    write(
      'index.json',
      RoundManifest(frames: ['records/drawn.json', 'records/blank.json'], planned: 2).toJson(),
    );
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('local_galley_');
    // A `.` in the galley's path, as `--app .` gives: work items must not carry it.
    g = GalleyDirectory('${dir.path}/./galley');
    ids = 0;
    writeRound();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a mark pinned by node is at its centre, stamped with the clock', () async {
    final raised = await local().raise(
      frame: _drawn,
      target: const AtNode([0]),
      note: 'too tight',
      by: 'r',
    );
    expect(raised.node.type, 'Card');
    expect((raised.mark.pin.dx, raised.mark.pin.dy), (0.5, 0.5));
    expect(raised.mark.at, at);
    expect(g.mark('m1')!.at, at);
  });

  test('a blank author is refused here too, and takes no id', () async {
    for (final by in ['', '  ']) {
      await expectLater(
        local().raise(frame: _drawn, target: const AtNode([0]), note: 'x', by: by),
        throwsA(isA<Refused>().having((r) => r.message, 'message', 'a mark says who raised it')),
      );
    }
    expect(ids, 0);
    expect(g.marks(), isEmpty);
  });

  test('a work item names its image by a clean absolute path, or null when it has none', () async {
    await local().raise(frame: _drawn, target: const AtNode([0]), note: 'a', by: 'r');
    await local().raise(frame: _blank, target: const AtNode([0]), note: 'b', by: 'r');
    final items = await local().workItems();
    expect([for (final i in items) i['id']], ['m1', 'm2']);
    final image = items[0]['image']! as String;
    expect(image, isNot(contains('/./')));
    expect(image, endsWith('/galley/rounds/1/frames/drawn.png'));
    expect(File(image).isAbsolute, isTrue);
    expect(items[1]['image'], isNull);
  });
}
