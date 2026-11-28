import 'package:galley_core/galley_core.dart';
import 'package:galley_web/src/widget_choice.dart';
import 'package:flutter_test/flutter_test.dart';

WidgetNode _n(String type, LogicalRect rect, {String? key, String? label, int i = 0}) =>
    WidgetNode(indexPath: [i], type: type, rect: rect, key: key, semanticsLabel: label);

void main() {
  const field = LogicalRect(20, 100, 320, 89);
  const page = LogicalRect(0, 0, 360, 800);

  group('of', () {
    // The first adopter's search field, as allAt gave it: four widgets in one box, then the page.
    final candidates = [
      _n('TextField', field, label: 'Search brews', i: 4),
      _n('Column', field, i: 3),
      _n('Semantics', field, label: 'Search brews', i: 2),
      _n('MergeSemantics', field, i: 1),
      _n('Scaffold', page, i: 0),
    ];

    test('widgets with the same box are one choice, in the order their deepest comes', () {
      final choices = WidgetChoice.of(candidates);
      expect(choices.map((c) => c.nodes.map((n) => n.type).toList()), [
        ['TextField', 'Column', 'Semantics', 'MergeSemantics'],
        ['Scaffold'],
      ]);
      expect(choices.map((c) => c.node.type), ['TextField', 'Scaffold'], reason: 'deepest');
    });

    test('widgets with different boxes stay apart', () {
      final choices = WidgetChoice.of([
        _n('Text', const LogicalRect(20, 100, 80, 20)),
        _n('Text', const LogicalRect(20, 100, 80, 21)),
      ]);
      expect(choices, hasLength(2));
    });

    test('leads with what is on screen, and keeps the types as detail', () {
      final choice = WidgetChoice.of(candidates).first;
      expect(choice.title, '"Search brews" · text field');
      expect(choice.detail, 'TextField · Column · Semantics · MergeSemantics · 320 × 89');
    });
  });

  group('title', () {
    String titleOf(List<WidgetNode> nodes) => WidgetChoice.of(nodes).single.title;

    test('a key stands in for a missing label', () {
      expect(titleOf([_n('FilledButton', field, key: 'add')]), 'key add · button');
    });

    test('a label is preferred to a key', () {
      expect(titleOf([_n('FilledButton', field, key: 'add', label: 'Add')]), '"Add" · button');
    });

    test('a widget with neither is named by its type', () {
      expect(titleOf([_n('Padding', field)]), 'Padding');
    });

    test('a kind is taken from the first widget in the box that has one', () {
      expect(titleOf([_n('Padding', field, i: 1), _n('MyPrimaryButton', field)]), 'button');
    });
  });

  group('kindOf', () {
    test('names the kinds a designer would, from the end of the type', () {
      expect(
        {
          for (final t in [
            'TextField',
            'TextFormField',
            'SearchBar',
            'IconButton',
            'ElevatedButton',
            'Checkbox',
            'Switch',
            'ListTile',
            'AppBar',
            'Icon',
            'Image',
            'RichText',
            'Text',
          ])
            t: WidgetChoice.kindOf(t),
        },
        {
          'TextField': 'text field',
          'TextFormField': 'text field',
          'SearchBar': 'search field',
          'IconButton': 'button',
          'ElevatedButton': 'button',
          'Checkbox': 'checkbox',
          'Switch': 'switch',
          'ListTile': 'list row',
          'AppBar': 'top bar',
          'Icon': 'icon',
          'Image': 'image',
          'RichText': 'text',
          'Text': 'text',
        },
      );
    });

    test('is null for a widget that is no kind', () {
      expect(
        [
          for (final t in ['Column', 'Padding', 'Semantics']) WidgetChoice.kindOf(t),
        ],
        [null, null, null],
      );
    });
  });
}
