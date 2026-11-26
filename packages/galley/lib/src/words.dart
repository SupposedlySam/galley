import 'package:flutter/rendering.dart';
import 'package:galley_core/galley_core.dart';

/// One `broken-word` finding when text under [root] wraps inside a word, or none.
///
/// A line that ends between two letters or digits was broken there because the word did not fit
/// the width: the line breaker breaks a word only when it has no space to break at. That is what
/// a narrow device at a large text scale does to a label ("PLAC" over "ED"). Observed in the
/// first adopting app's round at 2.0× text: several labels broken mid-word, and no finding.
///
/// It reads the laid-out paragraph's carets, so it judges
/// what was drawn, not what a width estimate predicts. A break after a soft hyphen (U+00AD) is
/// the author's choice, and its last character is not a letter, so it is not reported.
///
/// Rejected: reporting it as an overflow error. The frame drew everything; whether a broken
/// word is acceptable is the reviewer's call, so it is a finding on the card.
List<Finding> brokenWordsIn(RenderObject root, {int examples = 5}) {
  final broken = <String>[];

  void visit(RenderObject r) {
    if (r is RenderParagraph && r.hasSize) broken.addAll(_brokenIn(r));
    r.visitChildren(visit);
  }

  visit(root);
  if (broken.isEmpty) return const [];
  final shown = broken.take(examples).map((t) => '"$t"').join(', ');
  final more = broken.length > examples ? ', and ${broken.length - examples} more' : '';
  return [
    Finding(
      kind: 'broken-word',
      message: '${broken.length} line break(s) fall inside a word: $shown$more',
    ),
  ];
}

/// Each break inside a word in [p], as the word with `|` where its line ends.
///
/// `RenderParagraph` has no line-boundary query in Flutter 3.50 (BOUNDARY § Line breaks). It
/// does place a caret with an affinity. At a soft line break, offset `i` has two carets: the
/// upstream one ends the line above and the downstream one starts the line below, so they are at
/// different x in any alignment and direction (a line has width). Anywhere else they share x.
/// Their y is no test: where a run changes font size on one line, the two carets take their
/// height from different runs and sit at different y, though nothing broke (observed).
///
/// Rejected, after it failed on a real app (0.2.0): comparing the boxes of the two characters,
/// a break being where the second box starts below the first one ends. A display face whose
/// ascent plus descent exceeds its line height draws boxes that overlap from line to line, so
/// that missed every break. Comparing box tops fails on a line that mixes font sizes. The carets'
/// x depends on neither.
Iterable<String> _brokenIn(RenderParagraph p) sync* {
  final text = p.text.toPlainText(includeSemanticsLabels: false);
  double caretX(int i, TextAffinity a) =>
      p.getOffsetForCaret(TextPosition(offset: i, affinity: a), Rect.zero).dx;

  for (var end = 1; end < text.length; end++) {
    if (!_isWordChar(text, end - 1) || !_isWordChar(text, end)) continue;
    if ((caretX(end, TextAffinity.upstream) - caretX(end, TextAffinity.downstream)).abs() < 0.5) {
      continue;
    }
    var from = end - 1, to = end;
    while (from > 0 && _isWordChar(text, from - 1)) {
      from--;
    }
    while (to < text.length && _isWordChar(text, to)) {
      to++;
    }
    yield '${text.substring(from, end)}|${text.substring(end, to)}';
  }
}

final _word = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// Whether the UTF-16 unit at [i] is a letter or digit. A letter outside the Basic Multilingual
/// Plane is two units, neither of which matches, so a break inside one goes unreported: a miss,
/// never a false report.
bool _isWordChar(String text, int i) => _word.hasMatch(text[i]);
