import 'package:flutter/rendering.dart';
import 'package:galley_core/galley_core.dart';

/// The findings for text under [root] that wraps inside a word: `broken-word` for breaks the
/// frame shows, `broken-word-unseen` for breaks laid out where the capture does not show them.
/// Each is there only if it has a break to list.
///
/// A line that ends between two letters or digits was broken there because the word did not fit
/// the width: the line breaker breaks a word only when it has no space to break at. That is what
/// a narrow device at a large text scale does to a label ("PLAC" over "ED"). Observed in the
/// first adopting app's round at 2.0× text: several labels broken mid-word, and no finding.
///
/// It reads the laid-out paragraph's carets, so it judges what was laid out, not what a width
/// estimate predicts. A break after a soft hyphen (U+00AD) is the author's choice, and its last
/// character is not a letter, so it is not reported.
///
/// A lazy list lays out rows past the edge of its viewport (its cache extent): they are in the
/// render tree and not in the picture. Observed in the first adopting app: a card said
/// "cockt|ail" over a frame with no such word, from a row below the fold. Such a break still
/// ships, so it is reported, under its own kind, so that a card can say it is not in the
/// picture. Rejected: dropping it, which would make "no broken words" mean "none on the first
/// screen".
///
/// Rejected: reporting it as an overflow error. The frame drew everything; whether a broken
/// word is acceptable is the reviewer's call, so it is a finding on the card.
List<Finding> brokenWordsIn(RenderObject root, {int examples = 5}) {
  final frame = _frameOf(root);
  final seen = <String>[], unseen = <String>[];

  void visit(RenderObject r) {
    if (r is RenderParagraph && r.hasSize) {
      final visible = _visibleRect(r, frame);
      for (final b in _brokenIn(r)) {
        (visible != null && b.rect.overlaps(visible) ? seen : unseen).add(b.word);
      }
    }
    r.visitChildren(visit);
  }

  visit(root);
  String list(List<String> words) {
    final shown = words.take(examples).map((t) => '"$t"').join(', ');
    return words.length > examples ? '$shown, and ${words.length - examples} more' : shown;
  }

  return [
    if (seen.isNotEmpty)
      Finding(
        kind: 'broken-word',
        message: '${seen.length} line break(s) fall inside a word: ${list(seen)}',
      ),
    if (unseen.isNotEmpty)
      Finding(
        kind: 'broken-word-unseen',
        message:
            '${unseen.length} line break(s) fall inside a word in text laid out outside the '
            'frame, scrolled or clipped out of the picture: ${list(unseen)}',
      ),
  ];
}

/// What the capture shows, in the coordinates `getTransformTo(null)` gives: the view's child,
/// as `capture.dart` takes the widget tree's rects.
Rect? _frameOf(RenderObject root) {
  final box = root is RenderView ? root.child : root;
  if (box is! RenderBox || !box.hasSize) return null;
  return MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
}

/// The part of [frame] where [r] can be seen, or null if none: [frame] cut by every clip an
/// ancestor applies on the way down to [r]. A viewport reports its clip through
/// `describeApproximatePaintClip`, which is what semantics uses to mark a node offscreen.
Rect? _visibleRect(RenderObject r, Rect? frame) {
  if (frame == null) return null;
  var visible = frame;
  RenderObject child = r;
  for (var parent = r.parent; parent != null; child = parent, parent = parent.parent) {
    final clip = parent.describeApproximatePaintClip(child);
    if (clip == null) continue;
    visible = visible.intersect(MatrixUtils.transformRect(parent.getTransformTo(null), clip));
    if (visible.isEmpty) return null;
  }
  return visible;
}

/// Each break inside a word in [p]: the word with `|` where its line ends, and the rect of the
/// two characters either side of it, in the coordinates `getTransformTo(null)` gives.
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
Iterable<({String word, Rect rect})> _brokenIn(RenderParagraph p) sync* {
  final toGlobal = p.getTransformTo(null);
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
    final boxes = p.getBoxesForSelection(TextSelection(baseOffset: end - 1, extentOffset: end + 1));
    final local = boxes.isEmpty
        ? Offset.zero & p.size
        : boxes.map((b) => b.toRect()).reduce((a, b) => a.expandToInclude(b));
    yield (
      word: '${text.substring(from, end)}|${text.substring(end, to)}',
      rect: MatrixUtils.transformRect(toGlobal, local),
    );
  }
}

final _word = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// Whether the UTF-16 unit at [i] is a letter or digit. A letter outside the Basic Multilingual
/// Plane is two units, neither of which matches, so a break inside one goes unreported: a miss,
/// never a false report.
bool _isWordChar(String text, int i) => _word.hasMatch(text[i]);
