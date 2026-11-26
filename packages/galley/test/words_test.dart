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

/// How many lines the only paragraph has, from where each character's caret sits: independent of
/// line height, so it holds when lines are tighter than their glyphs.
int _lineCount(WidgetTester tester) {
  final p = tester.renderObject<RenderParagraph>(find.byType(RichText));
  final n = p.text.toPlainText().length;
  return {for (var i = 0; i < n; i++) p.getOffsetForCaret(TextPosition(offset: i), Rect.zero).dy}
      .length;
}

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

  // Observed in the first adopting app: a display face whose glyph boxes are taller than its
  // line, so boxes on adjacent lines overlap. A check of top against bottom missed every break.
  for (final height in [0.5, 0.8, 1.0, 1.1]) {
    testWidgets('a word broken across lines tighter than its glyphs (height $height) is found', (
      tester,
    ) async {
      final root = await _layout(tester, 4 * 14, [
        Text('PLACED', style: _style.copyWith(height: height)),
      ]);
      expect(_lineCount(tester), 2, reason: 'the positive control: it did break');
      expect(brokenWordsIn(root).single.message, contains('"PLAC|ED"'));
    });

    testWidgets('a sentence wrapped at spaces at height $height is not a finding', (tester) async {
      final root = await _layout(tester, 4 * 14, [
        Text('GO NOW OR NOT', style: _style.copyWith(height: height)),
      ]);
      expect(_lineCount(tester), greaterThan(1));
      expect(brokenWordsIn(root), isEmpty);
    });
  }

  testWidgets('mixed sizes on one line are one line, not a break', (tester) async {
    final root = await _layout(tester, 400, [
      const Text.rich(
        TextSpan(
          style: _style,
          children: [
            TextSpan(text: 'SM'),
            TextSpan(text: 'BIG', style: TextStyle(fontSize: 40)),
            TextSpan(text: 'ALL'),
          ],
        ),
      ),
    ]);
    expect(brokenWordsIn(root), isEmpty);
  });

  for (final align in [TextAlign.center, TextAlign.right]) {
    testWidgets('a break in ${align.name}-aligned text is found', (tester) async {
      final root = await _layout(tester, 4 * 14, [
        SizedBox(
          width: 4 * 14,
          child: Text('PLACED', style: _style, textAlign: align),
        ),
      ]);
      expect(_lines(tester), 2);
      expect(brokenWordsIn(root).single.message, contains('"PLAC|ED"'));
    });
  }

  testWidgets('a break in right-to-left text is found', (tester) async {
    final root = await _layout(tester, 4 * 14, [
      const Text('PLACED', style: _style, textDirection: TextDirection.rtl),
    ]);
    expect(_lines(tester), 2);
    expect(brokenWordsIn(root).single.message, contains('"PLAC|ED"'));
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

  // The test view is 800 × 600. Rows 100 tall: rows 0-5 are on screen, and the list lays out
  // more below the fold, in its cache extent.
  Future<RenderObject> list(WidgetTester tester, {required double height}) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 4 * 14,
            height: height,
            child: ListView(
              children: [
                for (var i = 0; i < 12; i++)
                  SizedBox(height: 100, child: Text(i == 0 ? 'PLACED' : 'FILLED$i', style: _style)),
              ],
            ),
          ),
        ),
      ),
    );
    return tester.binding.renderViews.single;
  }

  testWidgets('a break laid out below the fold is reported apart, as not in the picture', (
    tester,
  ) async {
    final root = await list(tester, height: 600);
    // The positive control: a row below the fold really is laid out, so it is in the tree.
    expect(find.text('FILLED7', skipOffstage: false), findsOneWidget);
    expect(find.text('FILLED7'), findsNothing, reason: 'and it is offstage');

    final byKind = {for (final f in brokenWordsIn(root)) f.kind: f.message};
    expect(byKind.keys, unorderedEquals(['broken-word', 'broken-word-unseen']));
    // On screen: rows 0-5. PLACED and FILLED1..5.
    expect(byKind['broken-word'], startsWith('6 line break(s)'));
    expect(byKind['broken-word'], contains('"PLAC|ED"'));
    expect(byKind['broken-word'], isNot(contains('FILLED7')));
    expect(byKind['broken-word-unseen'], contains('"FILL|ED7"'));
    expect(byKind['broken-word-unseen'], contains('outside the frame'));
  });

  testWidgets('a break clipped by a short list is not in the picture, though on the screen', (
    tester,
  ) async {
    // A list 150 tall. Row 1's break is at y 100 to 128, inside the list's clip. Row 2's is at
    // 200 to 228: inside the 600-tall view, outside the clip.
    final root = await list(tester, height: 150);
    final byKind = {for (final f in brokenWordsIn(root)) f.kind: f.message};
    expect(byKind['broken-word'], startsWith('2 line break(s)'));
    expect(byKind['broken-word'], allOf(contains('"PLAC|ED"'), contains('"FILL|ED1"')));
    expect(byKind['broken-word-unseen'], contains('"FILL|ED2"'));
    expect(byKind['broken-word-unseen'], isNot(contains('"FILL|ED1"')));
  });

  testWidgets('a single-line frame has no finding', (tester) async {
    final root = await _layout(tester, 400, [const Text('PLACED', style: _style)]);
    expect(brokenWordsIn(root), isEmpty);
  });
}
