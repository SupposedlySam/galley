import 'dart:io';

import 'package:galley_cli/galley_cli.dart';
import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late GalleyDirectory g;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('galley_dir_');
    g = GalleyDirectory('${dir.path}/.galley');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Mark mark(String id, DateTime at) => Mark(
    id: id,
    frame: FrameKey({'screen': 'home'}),
    anchor: Anchor.of(
      WidgetNode(indexPath: const [], type: 'App', rect: const LogicalRect(0, 0, 1, 1)),
    ),
    pin: const PinOffset(0.5, 0.5),
    note: 'n',
    by: 'r',
    at: at,
  );

  test('marks are oldest first, then by id, whatever their ids sort as', () {
    g
      ..saveMark(mark('b', DateTime.utc(2026, 1, 1)))
      ..saveMark(mark('c', DateTime.utc(2026, 1, 2)))
      ..saveMark(mark('a', DateTime.utc(2026, 1, 2)));
    expect(g.marks().map((m) => m.id), ['b', 'a', 'c']);
  });

  test('a mark id that is not a plain file name is refused, and nothing is written', () {
    for (final id in ['../x', 'a/b', '']) {
      expect(() => g.saveMark(mark(id, DateTime.utc(2026))), throwsArgumentError, reason: id);
    }
    expect(Directory('${dir.path}/.galley').existsSync(), isFalse);
    g.saveMark(mark('ok', DateTime.utc(2026)));
    expect(g.mark('ok'), isNotNull, reason: 'the control');
  });

  test('a round never carried has no placements, not empty ones', () {
    Directory(g.roundPath(1)).createSync(recursive: true);
    expect(g.placements(1), isNull);
    g.savePlacements(1, Placements(const []));
    expect(g.placements(1)?.carried, isEmpty);
  });
}
