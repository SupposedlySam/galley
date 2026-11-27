import 'package:material_ui/material_ui.dart';

import 'board_view.dart';
import 'canvas_model.dart';
import 'side_panel.dart';

/// The canvas: the latest round on a board, and a panel for marks and their threads.
class GalleyCanvasApp extends StatelessWidget {
  /// The canvas of [model].
  const GalleyCanvasApp({super.key, required this.model});

  /// What it shows.
  final CanvasModel model;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Galley',
    debugShowCheckedModeBanner: false,
    // Roboto is bundled (fonts/), not fetched: the canvas loads nothing from outside the
    // machine it is served from (DESIGN D14), and on the web Flutter otherwise fetches Roboto
    // from Google's font CDN when a page first draws text.
    theme: ThemeData(
      colorSchemeSeed: const Color(0xFF3D5A80),
      brightness: Brightness.dark,
      fontFamily: 'Roboto',
    ),
    home: CanvasPage(model: model),
  );
}

/// The board beside the panel, or why there is nothing to show.
class CanvasPage extends StatefulWidget {
  /// The page for [model].
  const CanvasPage({super.key, required this.model});

  /// What it shows.
  final CanvasModel model;

  @override
  State<CanvasPage> createState() => _CanvasPageState();
}

class _CanvasPageState extends State<CanvasPage> {
  final _board = GlobalKey<BoardViewState>();

  @override
  void initState() {
    super.initState();
    widget.model.load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) => switch (widget.model.state) {
        Loading() => const Center(child: CircularProgressIndicator()),
        Unavailable(:final message) => _Unavailable(message, onRetry: widget.model.load),
        final Shown shown => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: BoardView(key: _board, model: widget.model, shown: shown),
            ),
            const VerticalDivider(width: 1),
            SizedBox(
              width: 380,
              child: SidePanel(
                model: widget.model,
                shown: shown,
                onShow: (frame) => _board.currentState?.showFrame(frame),
              ),
            ),
          ],
        ),
      },
    ),
  );
}

class _Unavailable extends StatelessWidget {
  const _Unavailable(this.message, {required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Nothing to show', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          SelectableText(message, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}
