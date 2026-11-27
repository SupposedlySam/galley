import 'dart:io';

import 'package:galley_cli/galley_cli.dart';
import 'package:galley_core/galley_core.dart';
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

  test('a mark pinned by node and point is where it was dropped, on the edge too', () async {
    // Card is (0, 0, 200, 100). Its right edge is on it; one pixel past is not.
    for (final (x, y, dx, dy) in [(50.0, 25.0, 0.25, 0.25), (200.0, 100.0, 1.0, 1.0)]) {
      final raised = await local().raise(
        frame: drawn,
        target: AtNode(const [0], at: (x: x, y: y)),
        note: 'here',
        by: 'r',
      );
      expect(raised.node.type, 'Card');
      expect(raised.mark.pin.dx, dx, reason: '$x,$y');
      expect(raised.mark.pin.dy, dy, reason: '$x,$y');
    }
    // Past each edge in turn: right, then bottom.
    for (final (x, y) in [(201.0, 50.0), (100.0, 101.0)]) {
      await expectLater(
        local().raise(
          frame: drawn,
          target: AtNode(const [0], at: (x: x, y: y)),
          note: 'n',
          by: 'r',
        ),
        throwsA(
          isA<Refused>()
              .having((r) => r.kind, 'kind', RefusalKind.invalid)
              .having((r) => r.message, 'message', '0 at $x,$y is outside Card in frame $drawn'),
        ),
      );
    }
    expect([for (final m in g.marks()) m.id], ['m1', 'm2']);
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

  test('a note past the limit is refused, on a mark or an event, and nothing is written', () async {
    final long = 'x' * (maxNoteLength + 1);
    await expectLater(
      local().raise(frame: drawn, target: const AtNode([0]), note: long, by: 'r'),
      throwsA(isA<Refused>().having((r) => r.message, 'message', contains('4001 characters'))),
    );
    expect(g.marks(), isEmpty);

    final raised = await local().raise(frame: drawn, target: const AtNode([0]), note: 'n', by: 'r');
    await expectLater(
      local().record(raised.mark.id, (at) => Withdrawn(long, by: 'r', at: at)),
      throwsA(
        isA<Refused>()
            .having((r) => r.kind, 'kind', RefusalKind.invalid)
            .having((r) => r.message, 'message', contains("a withdrawal's note")),
      ),
    );
    expect(g.mark(raised.mark.id)!.history, isEmpty);
    // The same event with a note within the limit is recorded: the limit, not the event, refused.
    await local().record(raised.mark.id, (at) => Withdrawn('dupe', by: 'r', at: at));
    expect(g.mark(raised.mark.id)!.status, MarkStatus.withdrawn);
  });

  test('a work item names its image by a clean absolute path, or null when it has none', () async {
    await local().raise(frame: drawn, target: const AtNode([0]), note: 'a', by: 'r');
    await local().raise(frame: blank, target: const AtNode([0]), note: 'b', by: 'r');
    final items = await workItems(local());
    expect([for (final i in items) i['id']], ['m1', 'm2']);
    final image = items[0]['image']! as String;
    expect(image, isNot(contains('/./')));
    expect(image, endsWith('/galley/rounds/1/frames/drawn.png'));
    expect(File(image).isAbsolute, isTrue);
    expect(items[1]['image'], isNull);
  });
}
