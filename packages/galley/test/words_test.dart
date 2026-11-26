import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:galley/src/words.dart';

/// Lays out [children] in a column [width] logical pixels wide, in the test font: every glyph is
/// a 14 × 14 square, so a width says exactly how many characters fit on a line.
Future<RenderObject> _layout(WidgetTester tester, double width, List<Widget> children) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
        ),
      ),
    ),
  );
  return tester.binding.renderViews.single;
}

const _style = TextStyle(fontSize: 14);

/// How many lines the only paragraph has, from its height: every line of the test font at 14 is
/// 14 tall.
int _lines(WidgetTester tester) =>
    tester.renderObject<RenderParagraph>(find.byType(RichText)).size.height ~/ 14;

void main() {
  testWidgets('a word wider than its line is a finding, showing where it broke', (tester) async {
    // 4 glyphs fit; "PLACED" is 6.
    final root = await _layout(tester, 4 * 14, [const Text('PLACED', style: _style)]);
    final found = brokenWordsIn(root);
    expect(found, hasLength(1));
    expect(found.single.kind, 'broken-word');
    expect(found.single.message, contains('"PLAC|ED"'));
    expect(found.single.message, startsWith('1 line break(s)'));
  });

  testWidgets('text that wraps at spaces is not a finding, though it does wrap', (tester) async {
    final root = await _layout(tester, 4 * 14, [const Text('GO NOW OR NOT', style: _style)]);
    // The positive control: it really is several lines, so silence is not "nothing wrapped".
    expect(_lines(tester), greaterThan(1));
    expect(brokenWordsIn(root), isEmpty);
  });

  testWidgets('a break after a soft hyphen is the author\'s, and not a finding', (tester) async {
    final root = await _layout(tester, 5 * 14, [const Text('PLAC­ED', style: _style)]);
    expect(_lines(tester), 2);
    expect(brokenWordsIn(root), isEmpty);
  });

  testWidgets('every broken label is counted, and the examples are capped', (tester) async {
    final root = await _layout(tester, 3 * 14, [
      for (final w in ['PICKED', 'ASSORTMENT', 'COMPLIMENTARY', 'WORDS', 'LONGER', 'OK'])
        Text(w, style: _style),
    ]);
    final message = brokenWordsIn(root, examples: 2).single.message;
    // PICKED 1, ASSORTMENT 3, COMPLIMENTARY 4, WORDS 1, LONGER 1; OK fits.
    expect(message, startsWith('10 line break(s)'));
    expect(message, contains('"PIC|KED"'));
    expect(message, endsWith(', and 8 more'));
  });

  testWidgets('a single-line frame has no finding', (tester) async {
    final root = await _layout(tester, 400, [const Text('PLACED', style: _style)]);
    expect(brokenWordsIn(root), isEmpty);
  });
}
