import 'package:galley_core/galley_core.dart';

/// One choice a reviewer is offered under a click: every widget at the point that fills the
/// same box, which on screen is one thing.
///
/// Observed on the first adopter's search field: `TextField`, `Column`, `Semantics` and
/// `MergeSemantics` at one point, all 320 × 89 with one label. Four rows that look alike are one
/// choice to a designer, who cannot tell which to pick and gains nothing by picking. Rejected:
/// dropping the framework's wrappers by name (`Semantics`, `Padding`, …), which would make a
/// list of names to keep current and still leave an app's own wrappers in.
///
/// Pure, so the composer draws it and a test reads it.
final class WidgetChoice {
  WidgetChoice._(this.nodes);

  /// [candidates], deepest first as [FrameTree.allAt] gives them, as choices: those with the
  /// same box made one, in the order their deepest comes.
  static List<WidgetChoice> of(List<WidgetNode> candidates) {
    final byRect = <LogicalRect, List<WidgetNode>>{};
    for (final n in candidates) {
      (byRect[n.rect] ??= []).add(n);
    }
    return [for (final nodes in byRect.values) WidgetChoice._(List.unmodifiable(nodes))];
  }

  /// The widgets it stands for, deepest first.
  final List<WidgetNode> nodes;

  /// The widget a mark on it is pinned to: the deepest, the most particular thing in the box,
  /// as a click on one widget alone was before. Its anchor, not its siblings', is what the
  /// next round looks for (DESIGN D6).
  WidgetNode get node => nodes.first;

  /// What a designer sees of it: its label, quoted, or else its key, then what kind of thing it
  /// is, such as `"Search brews" · text field`. Lead with what is on screen; the types are the
  /// [detail].
  String get title {
    final label = nodes.map((n) => n.semanticsLabel).nonNulls.firstOrNull;
    final key = nodes.map((n) => n.key).nonNulls.firstOrNull;
    final kind = nodes.map((n) => kindOf(n.type)).nonNulls.firstOrNull;
    return [
      if (label != null) '"$label"' else if (key != null) 'key $key',
      kind ?? (label == null && key == null ? node.type : null),
    ].nonNulls.join(' · ');
  }

  /// Its widgets' types, then its size: `TextField · Column · Semantics · 320 × 89`.
  String get detail => [
    ...nodes.map((n) => n.type),
    '${_px(node.rect.width)} × ${_px(node.rect.height)}',
  ].join(' · ');

  /// What a designer calls a widget of [type], or null when it is not one of these. Matched on
  /// the type's name, so an app's own `SearchField` or `PrimaryButton` is a field or a button.
  static String? kindOf(String type) {
    final t = type.toLowerCase();
    for (final (word, kind) in _kinds) {
      if (t.endsWith(word)) return kind;
    }
    return null;
  }

  // Longer words first: `IconButton` is a button, not an icon.
  static const _kinds = [
    ('textfield', 'text field'),
    ('textformfield', 'text field'),
    ('searchbar', 'search field'),
    ('field', 'field'),
    ('button', 'button'),
    ('checkbox', 'checkbox'),
    ('switch', 'switch'),
    ('slider', 'slider'),
    ('chip', 'chip'),
    ('listtile', 'list row'),
    ('appbar', 'top bar'),
    ('navigationbar', 'navigation bar'),
    ('tabbar', 'tabs'),
    ('card', 'card'),
    ('dialog', 'dialog'),
    ('image', 'image'),
    ('icon', 'icon'),
    ('richtext', 'text'),
    ('text', 'text'),
  ];

  static String _px(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
}
