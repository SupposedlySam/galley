import 'anchor.dart';
import 'frame_tree.dart';

/// One kind of evidence that can tell whether a node in a new tree is the anchor's widget.
///
/// Each is small and knows one thing (docs/DESIGN.md D6). The order they are tried in is the
/// [Reanchorer]'s business, not theirs.
abstract interface class AnchorMatcher {
  /// The evidence this matcher weighs, recorded on the result so a reviewer can see why a
  /// mark landed where it did.
  Evidence get evidence;

  /// Whether [anchor] carries this evidence at all. An anchor captured without a key cannot be
  /// matched by key, and that is not the same as "no node has its key".
  bool appliesTo(Anchor anchor);

  /// Whether [node] agrees with [anchor] on this evidence.
  bool matches(Anchor anchor, WidgetNode node);
}

/// The kinds of evidence, strongest first.
enum Evidence {
  /// The widget's key: written by the app on purpose, so the strongest.
  key,

  /// The semantics label: what a screen reader announces. Survives refactors, but several
  /// widgets can share one, and copy edits change it.
  semanticsLabel,

  /// The exact constructor call site. Survives layout changes, but any edit above it in the
  /// file shifts its line.
  location,

  /// The same source file and widget type: what is left of [location] after the lines shifted.
  fileAndType,

  /// The index path and widget type: the weakest, since inserting a sibling shifts it.
  indexPath,
}

/// Matches by widget key.
final class KeyMatcher implements AnchorMatcher {
  /// The key matcher.
  const KeyMatcher();

  @override
  Evidence get evidence => Evidence.key;

  @override
  bool appliesTo(Anchor anchor) => anchor.key != null;

  @override
  bool matches(Anchor anchor, WidgetNode node) => node.key == anchor.key;
}

/// Matches by semantics label.
final class SemanticsLabelMatcher implements AnchorMatcher {
  /// The semantics label matcher.
  const SemanticsLabelMatcher();

  @override
  Evidence get evidence => Evidence.semanticsLabel;

  @override
  bool appliesTo(Anchor anchor) => anchor.semanticsLabel != null;

  @override
  bool matches(Anchor anchor, WidgetNode node) => node.semanticsLabel == anchor.semanticsLabel;
}

/// Matches by exact creation location.
final class LocationMatcher implements AnchorMatcher {
  /// The location matcher.
  const LocationMatcher();

  @override
  Evidence get evidence => Evidence.location;

  @override
  bool appliesTo(Anchor anchor) => anchor.location != null;

  @override
  bool matches(Anchor anchor, WidgetNode node) => node.location == anchor.location;
}

/// Matches by creation file and widget type, ignoring line and column.
final class FileAndTypeMatcher implements AnchorMatcher {
  /// The file-and-type matcher.
  const FileAndTypeMatcher();

  @override
  Evidence get evidence => Evidence.fileAndType;

  @override
  bool appliesTo(Anchor anchor) => anchor.location != null;

  @override
  bool matches(Anchor anchor, WidgetNode node) =>
      node.type == anchor.type && node.location?.file == anchor.location!.file;
}

/// Matches by index path and widget type.
///
/// The type is required as well as the path. A path alone always names some node in any tree
/// deep enough, so on its own it would "find" an unrelated widget rather than report Lost.
final class IndexPathMatcher implements AnchorMatcher {
  /// The index path matcher.
  const IndexPathMatcher();

  @override
  Evidence get evidence => Evidence.indexPath;

  @override
  bool appliesTo(Anchor anchor) => true;

  @override
  bool matches(Anchor anchor, WidgetNode node) =>
      node.type == anchor.type && _samePath(node.indexPath, anchor.indexPath);

  static bool _samePath(IndexPath a, IndexPath b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Where an anchor ended up in a new tree.
sealed class Reanchoring {
  const Reanchoring();
}

/// The anchor's widget was found.
final class Located extends Reanchoring {
  /// A found anchor.
  const Located({
    required this.node,
    required this.decidedBy,
    required this.considered,
    required this.overlap,
  });

  /// The node the anchor now refers to.
  final WidgetNode node;

  /// The evidence that narrowed the candidates to one.
  final Evidence decidedBy;

  /// How many candidates were still in play when [decidedBy] was applied. One means the
  /// evidence before it had already narrowed to this node; more means [decidedBy] broke a tie.
  final int considered;

  /// How much the node's box overlaps the anchor's old one (intersection over union).
  final double overlap;

  /// Whether the widget is where it was: [overlap] is at least [Reanchorer.exactOverlap].
  ///
  /// When false, the mark is Moved: the widget was found but its box is elsewhere, so the
  /// reviewer should look before trusting that the comment still applies.
  bool get isExact => overlap >= Reanchorer.exactOverlap;
}

/// The anchor's widget could not be decided. The mark keeps its old crop, as a ghost.
final class Lost extends Reanchoring {
  /// A lost anchor, with the nodes that were still in contention.
  Lost(List<WidgetNode> candidates) : candidates = List.unmodifiable(candidates);

  /// The nodes no evidence could tell apart. Empty when no evidence matched any node at all;
  /// otherwise the reviewer can be shown "it may be one of these".
  ///
  /// Several candidates is Lost, not a guess at the first. A mark silently moved onto the
  /// wrong one of three identical cards looks like success and is not (CLAUDE.md, "An unknown
  /// is never nothing").
  final List<WidgetNode> candidates;
}

/// Finds an [Anchor] in a new [FrameTree] by progressive narrowing (docs/DESIGN.md D6).
///
/// Every node starts as a candidate. Each matcher that applies to the anchor filters the
/// candidates:
/// - one left: that node is the answer, decided by this matcher;
/// - several left: they become the candidates, and the next matcher narrows further;
/// - none left: this evidence does not hold in the new tree (a key was removed, a label was
///   reworded), so it is skipped rather than allowed to rule everything out.
///
/// When the matchers run out with more than one candidate, or no evidence matched anything,
/// the result is [Lost].
///
/// Narrowing, rather than "first matcher with a unique hit wins", is what lets weak evidence
/// help. A label shared by three buttons plus the call site of one of them identifies it,
/// although neither does alone.
final class Reanchorer {
  /// A reanchorer with [matchers] tried in order. The default is strongest evidence first.
  const Reanchorer({this.matchers = defaultMatchers});

  /// Key, semantics label, exact location, file and type, index path and type.
  static const defaultMatchers = <AnchorMatcher>[
    KeyMatcher(),
    SemanticsLabelMatcher(),
    LocationMatcher(),
    FileAndTypeMatcher(),
    IndexPathMatcher(),
  ];

  /// The overlap at or above which a found widget counts as Exact rather than Moved.
  ///
  /// 0.9 intersection-over-union lets a 100-wide button shift about 5 logical pixels sideways
  /// ((100 - d) / (100 + d) ≥ 0.9 gives d ≤ 5.3). That absorbs a font's antialiasing and a
  /// padding tweak, and flags a row that was reordered. A stricter 1.0 would call every
  /// sub-pixel re-layout Moved, and reviewers learn to ignore a flag that is always on.
  static const exactOverlap = 0.9;

  /// The matchers, in the order they narrow.
  final List<AnchorMatcher> matchers;

  /// Where [anchor] is in [tree].
  Reanchoring locate(Anchor anchor, FrameTree tree) {
    var candidates = tree.nodes;
    var narrowed = false;
    for (final matcher in matchers) {
      if (!matcher.appliesTo(anchor)) continue;
      final kept = [
        for (final node in candidates)
          if (matcher.matches(anchor, node)) node,
      ];
      if (kept.isEmpty) continue;
      if (kept.length == 1) {
        final node = kept.single;
        return Located(
          node: node,
          decidedBy: matcher.evidence,
          considered: candidates.length,
          overlap: node.rect.overlapWith(anchor.rect),
        );
      }
      candidates = kept;
      narrowed = true;
    }
    return Lost(narrowed ? candidates : const []);
  }
}
