import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

import 'trees.dart';

void main() {
  group('validation', () {
    for (final (name, nodes) in <(String, List<WidgetNode>)>[
      (
        'no root first',
        [
          node([0], 'A'),
        ],
      ),
      ('a second root', [root, node([], 'B')]),
      (
        'a repeated path',
        [
          root,
          node([0], 'A'),
          node([0], 'B'),
        ],
      ),
      (
        'a child before its parent',
        [
          root,
          node([0, 0], 'A'),
          node([0], 'B'),
        ],
      ),
    ]) {
      test('refuses $name', () => expect(() => tree(nodes), throwsArgumentError));
    }

    test('json turns a broken tree into a FormatException', () {
      final json = tree([root]).toJson()
        ..['nodes'] = [
          root.toJson(),
          node([3, 1], 'Orphan').toJson(),
        ];
      expect(() => FrameTree.fromJson(json, 'tree'), throwsFormatException);
    });
  });

  test('round-trips through json', () {
    final t = tree([
      root,
      node([0], 'Column', rect: const LogicalRect(0, 0, 400, 300)),
      node([0, 0], 'Text', key: 'title', label: 'Title', at: loc(4, 7)),
    ]);
    final back = FrameTree.fromJson(t.toJson(), 'tree');
    expect(back.toJson(), t.toJson());
    expect(back.at([0, 0])?.key, 'title');
    expect(back.at([9]), isNull);
  });

  group('deepestAt', () {
    final t = tree([
      root,
      node([0], 'Card', rect: const LogicalRect(0, 0, 200, 100)),
      node([0, 0], 'Text', rect: const LogicalRect(10, 10, 50, 20)),
      // Painted after [0, 0], overlapping it: it is on top.
      node([0, 1], 'Badge', rect: const LogicalRect(40, 10, 30, 20)),
    ]);

    test('picks the deepest node', () => expect(t.deepestAt(15, 15)?.type, 'Text'));
    test('among equals, the one painted last', () => expect(t.deepestAt(45, 15)?.type, 'Badge'));
    test('falls back to the ancestor', () => expect(t.deepestAt(150, 50)?.type, 'Card'));
    test('right and bottom edges are outside', () {
      expect(t.deepestAt(200, 50)?.type, 'App');
      expect(t.deepestAt(500, 900), isNull);
    });
  });
}
