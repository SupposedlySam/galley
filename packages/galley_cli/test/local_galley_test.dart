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
    final WorkItems(:items, :damaged) = await workItems(local());
    expect(damaged, isEmpty, reason: 'a local galley that reads has no mark that does not');
    expect([for (final i in items) i['id']], ['m1', 'm2']);
    final image = items[0]['image']! as String;
    expect(image, isNot(contains('/./')));
    expect(image, endsWith('/galley/rounds/1/frames/drawn.png'));
    expect(File(image).isAbsolute, isTrue);
    expect(items[1]['image'], isNull);
  });

  group('a visit', () {
    test('is kept per reviewer: a first visit has nothing before it, a newer round the one '
        'opened before, and a reload the same', () async {
      writeRoundAt(g.roundPath(2));
      writeRoundAt(g.roundPath(3));
      final galley = local();
      expect(await galley.opened(1, by: 'Rae'), isNull);
      expect(await galley.opened(1, by: 'Rae'), isNull, reason: 'a reload of the first');
      expect(await galley.opened(3, by: ' Rae '), 1, reason: 'by the name, trimmed');
      expect(await galley.opened(3, by: 'Rae'), 1, reason: 'a reload');
      expect(await galley.opened(2, by: 'Rae'), 1, reason: 'an older round moves nothing');
      // Another reviewer's visits are their own.
      expect(await galley.opened(3, by: 'Kit'), isNull);
      expect(await galley.opened(3, by: 'Rae'), 1);
      expect(
        {for (final MapEntry(:key, :value) in g.visits().entries) key: value.toJson()},
        {
          'Rae': {'latest': 3, 'before': 1},
          'Kit': {'latest': 3},
        },
      );
    });

    test('a reload writes nothing', () async {
      final galley = local();
      await galley.opened(1, by: 'Rae');
      final file = File('${g.path}/visits.json');
      final written = file.lastModifiedSync();
      file.setLastModifiedSync(DateTime(2001));
      await galley.opened(1, by: 'Rae');
      expect(file.lastModifiedSync(), DateTime(2001));
      expect(written, isNot(DateTime(2001)));
    });

    test('is refused for nobody, and for a round that has not finished, and writes '
        'nothing', () async {
      await expectLater(
        local().opened(1, by: '  '),
        throwsA(isA<Refused>().having((e) => e.kind, 'kind', RefusalKind.invalid)),
      );
      await expectLater(
        local().opened(2, by: 'Rae'),
        throwsA(
          isA<Refused>()
              .having((e) => e.kind, 'kind', RefusalKind.missing)
              .having((e) => e.message, 'message', contains('no finished round 2')),
        ),
      );
      expect(File('${g.path}/visits.json').existsSync(), isFalse);
      expect(await local().opened(1, by: 'Rae'), isNull, reason: 'the control: it does write');
      expect(File('${g.path}/visits.json').existsSync(), isTrue);
    });

    test('a visits file that does not read is refused as damaged, naming it', () async {
      File('${g.path}/visits.json').writeAsStringSync('{"Rae": {"latest": 2, "before": 2}}');
      await expectLater(
        local().opened(1, by: 'Kit'),
        throwsA(
          isA<Refused>()
              .having((e) => e.kind, 'kind', RefusalKind.damaged)
              .having((e) => e.message, 'message', contains('visits.json.Rae')),
        ),
      );
    });
  });
}
