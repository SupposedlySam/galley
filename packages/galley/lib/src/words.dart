import 'package:flutter/rendering.dart';
import 'package:galley_core/galley_core.dart';

/// One `broken-word` finding when text under [root] wraps inside a word, or none.
///
/// A line that ends between two letters or digits was broken there because the word did not fit
/// the width: the line breaker breaks a word only when it has no space to break at. That is what
/// a narrow device at a large text scale does to a label ("PLAC" over "ED"). Observed in the
/// first adopting app's round at 2.0× text: several labels broken mid-word, and no finding.
///
/// It reads the laid-out paragraph's character boxes, so it judges
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
/// `RenderParagraph` has no line-boundary query in Flutter 3.50 (no `getLineBoundary`, no
/// `computeLineMetrics`; BOUNDARY § Line breaks). It does measure the box of any range of text.
/// Two adjacent letters whose boxes are on different lines are a break inside a word.
Iterable<String> _brokenIn(RenderParagraph p) sync* {
  final text = p.text.toPlainText(includeSemanticsLabels: false);
  TextBox? boxOf(int i) {
    final boxes = p.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + 1));
    return boxes.isEmpty ? null : boxes.first;
  }

  for (var end = 1; end < text.length; end++) {
    if (!_isWordChar(text, end - 1) || !_isWordChar(text, end)) continue;
    final before = boxOf(end - 1), after = boxOf(end);
    // A character with no box was not laid out: cut off by maxLines. It is not a break.
    if (before == null || after == null || after.top < before.bottom - 0.5) continue;
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
