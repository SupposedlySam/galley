import 'package:galley_core/galley_core.dart';
import 'package:material_ui/material_ui.dart';

import 'api.dart';
import 'canvas_model.dart';
import 'marks.dart';

/// Beside the board: who is reviewing, every mark, and the open mark's thread.
///
/// Every mark is listed, including those the board cannot draw, each with why it is not drawn
/// (DESIGN: an unknown is never nothing). Rejected: listing only the marks on the board, which
/// would hide exactly the marks a reviewer most needs to see, the ones that lost their widget.
class SidePanel extends StatelessWidget {
  /// The panel for [shown].
  const SidePanel({super.key, required this.model, required this.shown, required this.onShow});

  /// What a reviewer does.
  final CanvasModel model;

  /// The round shown.
  final Shown shown;

  /// Moves the board to a frame.
  final void Function(FrameKey frame) onShow;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: _ReviewerField(model: model),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          'Round ${shown.n} · ${shown.round.frames.length} frames · '
          '${shown.marks.length} ${shown.marks.length == 1 ? 'mark' : 'marks'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      const Divider(height: 24),
      Expanded(
        child: switch (model.selectedMark) {
          final m? => Thread(model: model, shown: shown, mark: m, onShow: onShow),
          null => MarkList(model: model, shown: shown, onShow: onShow),
        },
      ),
    ],
  );
}

class _ReviewerField extends StatefulWidget {
  const _ReviewerField({required this.model});

  final CanvasModel model;

  @override
  State<_ReviewerField> createState() => _ReviewerFieldState();
}

class _ReviewerFieldState extends State<_ReviewerField> {
  late final _name = TextEditingController(text: widget.model.reviewer);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _name,
    decoration: const InputDecoration(
      labelText: 'Reviewing as',
      hintText: 'Your name, on every mark you raise',
      border: OutlineInputBorder(),
      isDense: true,
    ),
    onChanged: (v) => widget.model.reviewer = v,
  );
}

/// Every mark, newest first, with where it is.
class MarkList extends StatelessWidget {
  /// The list of [shown]'s marks.
  const MarkList({super.key, required this.model, required this.shown, required this.onShow});

  /// Opens a thread.
  final CanvasModel model;

  /// The round shown.
  final Shown shown;

  /// Moves the board to a frame.
  final void Function(FrameKey frame) onShow;

  @override
  Widget build(BuildContext context) {
    if (shown.marks.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('No marks yet. Click a widget in a frame to raise one.'),
      );
    }
    final marks = [...shown.marks]..sort((a, b) => b.mark.at.compareTo(a.mark.at));
    return ListView(
      children: [
        for (final m in marks)
          ListTile(
            key: ValueKey(m.mark.id),
            leading: Icon(Icons.circle, size: 14, color: statusColor(m.mark.status)),
            title: Text(m.mark.note, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                '${m.mark.status.name} · ${m.mark.by} · ${m.mark.anchor.type}',
                if (shown.notDrawn(m) case final why?) 'Not on the board: $why',
              ].join('\n'),
            ),
            isThreeLine: shown.notDrawn(m) != null,
            onTap: () {
              model.select(m.mark.id);
              onShow(m.mark.frame);
            },
          ),
      ],
    );
  }
}

/// One mark's thread: what was said, by whom and when, and what the reviewer can do next.
class Thread extends StatefulWidget {
  /// The thread of [mark].
  const Thread({
    super.key,
    required this.model,
    required this.shown,
    required this.mark,
    required this.onShow,
  });

  /// Records an event.
  final CanvasModel model;

  /// The round shown.
  final Shown shown;

  /// The mark.
  final PlacedMark mark;

  /// Moves the board to a frame.
  final void Function(FrameKey frame) onShow;

  @override
  State<Thread> createState() => _ThreadState();
}

class _ThreadState extends State<Thread> {
  final _note = TextEditingController();
  String? _error;
  bool _sending = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Mark get _mark => widget.mark.mark;

  Future<void> _do(Review review) async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final model = widget.model;
    String? error;
    try {
      error = await model.record(_mark, switch (review) {
        Review.verify => model.verified(),
        Review.reopen => model.reopened(_note.text),
        Review.withdraw => model.withdrawn(_note.text),
      });
    } on ArgumentError catch (e) {
      // A reopen or withdrawal with no note, refused by the core as it is built.
      error = '${e.message}';
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      _error = error;
      if (error == null) _note.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final mark = _mark;
    final model = widget.model;
    final text = Theme.of(context).textTheme;
    final offered = [
      for (final r in Review.values)
        if (model.offers(mark, r)) r,
    ];
    final needsNote = offered.any((r) => r != Review.verify);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Every mark',
              onPressed: () => model.select(null),
              icon: const Icon(Icons.arrow_back),
            ),
            Icon(Icons.circle, size: 14, color: statusColor(mark.status)),
            const SizedBox(width: 8),
            // The status gives way, not the buttons: with wide text (a large browser font, or
            // the test font) the row overflowed the 380-pixel panel by 59 pixels.
            Expanded(
              child: Text(
                mark.status.name,
                style: text.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: () => widget.onShow(mark.frame),
              child: const Text('Show on board'),
            ),
          ],
        ),
        if (widget.shown.notDrawn(widget.mark) case final why?)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Not on the board: $why', style: text.bodySmall),
          ),
        _Entry(
          who: mark.by,
          at: mark.at,
          what: 'raised it on ${mark.anchor.type}',
          note: mark.note,
        ),
        for (final e in mark.history) _Entry.of(e),
        const SizedBox(height: 12),
        if (needsNote)
          TextField(
            controller: _note,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Why (for a reopen or a withdrawal)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final r in offered)
              switch (r) {
                Review.verify => FilledButton(
                  onPressed: _sending ? null : () => _do(r),
                  child: const Text('Verify'),
                ),
                Review.reopen => OutlinedButton(
                  onPressed: _sending ? null : () => _do(r),
                  child: const Text('Reopen'),
                ),
                Review.withdraw => TextButton(
                  onPressed: _sending ? null : () => _do(r),
                  child: const Text('Withdraw'),
                ),
              },
          ],
        ),
        if (offered.isEmpty) Text(_nothingToDo(mark, model.reviewer), style: text.bodySmall),
        if (_error case final e?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(e, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        const SizedBox(height: 16),
      ],
    );
  }

  /// Why no button is offered, so an empty row is never left to be guessed at.
  static String _nothingToDo(Mark mark, String reviewer) => switch (mark.status) {
    _ when reviewer.isEmpty => 'Say who you are above to act on this mark.',
    MarkStatus.open ||
    MarkStatus.reopened => 'Waiting on an answer from the app (`galley answer ${mark.id}`).',
    MarkStatus.verified || MarkStatus.withdrawn => 'Closed: ${mark.status.name}.',
    MarkStatus.answered => 'Nothing to do here.',
  };
}

/// One line of a thread.
class _Entry extends StatelessWidget {
  const _Entry({required this.who, required this.at, required this.what, this.note});

  factory _Entry.of(MarkEvent e) => switch (e) {
    Answered(:final answer) => _Entry(
      who: e.by,
      at: e.at,
      what: switch (answer.kind) {
        AnswerKind.fixed => 'answered: fixed in ${answer.commit}',
        AnswerKind.wontFix => "answered: won't fix",
        AnswerKind.question => 'answered with a question',
      },
      note: answer.note,
    ),
    Verified() => _Entry(who: e.by, at: e.at, what: 'verified it'),
    Reopened(:final note) => _Entry(who: e.by, at: e.at, what: 'reopened it', note: note),
    Withdrawn(:final note) => _Entry(who: e.by, at: e.at, what: 'withdrew it', note: note),
  };

  final String who;
  final DateTime at;
  final String what;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$who $what', style: text.labelLarge),
          Text(_when(at), style: text.bodySmall),
          if (note case final n?) Padding(padding: const EdgeInsets.only(top: 4), child: Text(n)),
        ],
      ),
    );
  }

  static String _when(DateTime at) {
    final l = at.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}
