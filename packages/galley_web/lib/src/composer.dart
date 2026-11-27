import 'package:galley_core/galley_core.dart';
import 'package:material_ui/material_ui.dart';

import 'canvas_model.dart';

/// Asks which widget under a click a mark is for, and what the mark says, then raises it.
///
/// Every widget containing the point is offered, deepest first, with the deepest chosen: a
/// click usually means the smallest thing under it, but a reviewer commenting on a card's
/// padding means the card, not the text in it. Rejected: pinning the deepest with no choice,
/// which makes a container unmarkable wherever it has a child; and a hierarchy browser, which
/// shows a reviewer the app's structure when they asked about one spot on the screen.
Future<void> showComposer(
  BuildContext context, {
  required CanvasModel model,
  required FrameKey frame,
  required List<WidgetNode> candidates,
  required ({double x, double y}) at,
}) async {
  if (candidates.isEmpty) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('No widget was captured at that point.')));
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => Composer(model: model, frame: frame, candidates: candidates, at: at),
  );
}

/// The dialog [showComposer] shows.
class Composer extends StatefulWidget {
  /// A composer for a mark on one of [candidates], deepest first, pinned at [at].
  const Composer({
    super.key,
    required this.model,
    required this.frame,
    required this.candidates,
    required this.at,
  });

  /// Raises the mark.
  final CanvasModel model;

  /// The frame clicked.
  final FrameKey frame;

  /// Every widget at the point, deepest first.
  final List<WidgetNode> candidates;

  /// The point, in the frame's logical pixels.
  final ({double x, double y}) at;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  late WidgetNode _node = widget.candidates.first;
  final _note = TextEditingController();
  String? _error;
  bool _sending = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _raise() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final error = await widget.model.raise(
      frame: widget.frame,
      node: _node,
      at: widget.at,
      note: _note.text,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _sending = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Raise a mark'),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('On', style: Theme.of(context).textTheme.labelLarge),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: RadioGroup<WidgetNode>(
              groupValue: _node,
              onChanged: (n) => setState(() => _node = n ?? _node),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final n in widget.candidates)
                    RadioListTile<WidgetNode>(
                      value: n,
                      dense: true,
                      title: Text(n.type),
                      subtitle: Text(describeNode(n)),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            autofocus: true,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'What is wrong, or what should change',
              border: OutlineInputBorder(),
            ),
          ),
          if (widget.model.reviewer.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Say who you are in the panel first.'),
            ),
          if (_error case final e?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(e, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      FilledButton(
        onPressed: _sending ? null : _raise,
        child: Text('Raise as ${widget.model.reviewer.isEmpty ? '…' : widget.model.reviewer}'),
      ),
    ],
  );
}

/// What tells [n] apart from the other widgets at a point: its key, its semantics label and its
/// size, those it has.
String describeNode(WidgetNode n) => [
  if (n.key case final k?) 'key $k',
  if (n.semanticsLabel case final s?) '"$s"',
  '${_px(n.rect.width)} × ${_px(n.rect.height)}',
].join(' · ');

String _px(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
