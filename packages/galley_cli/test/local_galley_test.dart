import 'dart:io';

import 'package:galley_cli/galley_cli.dart';
import 'package:test/test.dart';

import 'support/round.dart';

/// LocalGalley called directly, as `galley serve` calls it: what the CLI checks before it ever
/// gets here (a blank `--by`) is still checked here, because the server does not have the CLI.
void main() {
  late Directory dir;
  late GalleyDirectory g;
  final at = DateTime.utc(2026, 11, 26, 9, 30);
  var ids = 0;

  LocalGalley local() =>
      LocalGalley(g, repository: dir.path, now: () => at, newId: () => 'm${++ids}');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('local_galley_');
    // A `.` in the galley's path, as `--app .` gives: work items must not carry it.
    g = GalleyDirectory('${dir.path}/./galley');
    ids = 0;
    writeRound(g);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a mark pinned by node is at its centre, stamped with the clock', () async {
    final raised = await local().raise(
      frame: drawn,
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
        local().raise(frame: drawn, target: const AtNode([0]), note: 'x', by: by),
        throwsA(isA<Refused>().having((r) => r.message, 'message', 'a mark says who raised it')),
      );
    }
    expect(ids, 0);
    expect(g.marks(), isEmpty);
  });

  test('a work item names its image by a clean absolute path, or null when it has none', () async {
    await local().raise(frame: drawn, target: const AtNode([0]), note: 'a', by: 'r');
    await local().raise(frame: blank, target: const AtNode([0]), note: 'b', by: 'r');
    final items = await local().workItems();
    expect([for (final i in items) i['id']], ['m1', 'm2']);
    final image = items[0]['image']! as String;
    expect(image, isNot(contains('/./')));
    expect(image, endsWith('/galley/rounds/1/frames/drawn.png'));
    expect(File(image).isAbsolute, isTrue);
    expect(items[1]['image'], isNull);
  });
}
