import 'package:flutter_test/flutter_test.dart';
import 'package:galley_core/galley_core.dart';
import 'package:galley_web/src/board.dart';

import 'support.dart';

void main() {
  // `me` first, as the app's plan lists it: rows follow the round's order, not the alphabet.
  final frames = [
    frameOf('me', pixel7),
    frameOf('coffees', pixel7),
    frameOf('coffees', small),
    frameOf('coffees.detail', pixel7),
  ];

  group('Board.of', () {
    final board = Board.of(frames);

    test('rows are flows and columns are states, in the round order', () {
      expect(board.rows.map((r) => r.flow), ['me', 'coffees']);
      expect(
        [
          for (final r in board.rows) [for (final c in r.columns) c.state],
        ],
        [
          ['me · base'],
          ['coffees · base', 'coffees.detail · base'],
        ],
      );
    });

    test('every frame has a tile, at its logical size, with the gaps between', () {
      // Worked by hand from the constants: row label 72, column label 40, tile label 28,
      // bezel 10, tile gap 24, column gap 96, row gap 160. A row is as tall as its tallest
      // tile, the 914-pixel Pixel 7: 72 + 40 + 28 + 2 × 10 + 914 = 1074.
      expect(
        [for (final t in board.tiles) (t.frame.record.key, t.screen)],
        [
          (frames[0].record.key, const LogicalRect(10, 150, 411, 914)),
          (frames[1].record.key, const LogicalRect(10, 1384, 411, 914)),
          (frames[2].record.key, const LogicalRect(465, 1384, 360, 640)),
          (frames[3].record.key, const LogicalRect(941, 1384, 411, 914)),
        ],
      );
      expect(board.rows.map((r) => r.rect), const [
        LogicalRect(0, 0, 431, 1074),
        LogicalRect(0, 1234, 1362, 1074),
      ]);
      expect((board.width, board.height), (1362.0, 2308.0));
    });

    test("a caption is the device's name, never its id beside it", () {
      expect(board.varying, ['device']);
      expect(board.tiles.map((t) => t.caption), ['Pixel 7', 'Pixel 7', 'Small phone', 'Pixel 7']);
    });

    test('tileOf finds each frame, and nothing for a frame the round lacks', () {
      for (final f in frames) {
        expect(board.tileOf(f.record.key)?.frame, same(f));
      }
      expect(board.tileOf(keyOf('gone', pixel7)), isNull);
    });
  });

  test(
    'the other axes that vary follow the device in a caption; one that does not is left out',
    () {
      final board = Board.of([
        frameOf('home', pixel7, more: {'text-scale': '1.0', 'locale': 'en'}),
        frameOf('home', pixel7, more: {'text-scale': '2.0', 'locale': 'en'}),
      ]);
      expect(board.varying, ['text-scale']);
      expect(board.tiles.map((t) => t.caption), ['Pixel 7 · 1.0', 'Pixel 7 · 2.0']);
    },
  );

  test('an empty round is an empty board', () {
    final board = Board.of(const []);
    expect(board.rows, isEmpty);
    expect((board.width, board.height), (0.0, 0.0));
  });

  group('names', () {
    final board = Board.of([
      frameOf('root', pixel7, uri: Uri.parse('/')),
      frameOf('bloom', pixel7, screenName: 'The Batch'),
      frameOf('bloom', pixel7, scenario: 'empty', screenName: 'The Batch'),
      frameOf('bloom.staff', pixel7),
      frameOf('bloom.tins', pixel7, screenName: 'The Batch'),
      frameOf('root', pixel7, scenario: 'routed'),
    ]);

    test('a row is named by its root screen, a column by its screen, and `/` is home', () {
      expect(board.rows.map((r) => (r.flow, r.name)), [('root', 'home'), ('bloom', 'The Batch')]);
      expect(
        [
          for (final r in board.rows) [for (final c in r.columns) c.state],
        ],
        [
          // The second is a route `/root`, not the app's root: it keeps its id.
          ['home · base', 'root · routed'],
          ['The Batch · base', 'The Batch · empty', 'bloom.staff · base', 'The Batch · base'],
        ],
      );
    });

    test('columns are grouped by id, so two screens with one name stay apart', () {
      expect(board.rows[1].columns, hasLength(4));
      expect(board.tiles, hasLength(6));
    });

    test("nameOf says a frame's name, and a frame the board lacks by its id", () {
      expect(board.nameOf(keyOf('bloom', pixel7)), 'The Batch · base · pixel-7');
      expect(board.nameOf(keyOf('root', pixel7)), 'home · base · pixel-7');
      expect(board.nameOf(keyOf('gone', pixel7)), 'gone · base · pixel-7');
    });
  });

  test('a flow is the first segment of the screen, or says there is no screen', () {
    expect(Board.flowOf(FrameKey({'screen': 'bloom.staff.packing'})), 'bloom');
    expect(Board.flowOf(FrameKey({'screen': 'bloom'})), 'bloom');
    expect(Board.flowOf(FrameKey({'device': 'pixel-7'})), '(no screen)');
  });
}
