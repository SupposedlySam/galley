import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'server_entry.dart';

/// The canvas of a galley on a server: the way in, then the galley.
class ServerCanvasApp extends StatefulWidget {
  /// The app over [entry].
  const ServerCanvasApp({super.key, required this.entry});

  /// The steps in.
  final ServerEntry entry;

  @override
  State<ServerCanvasApp> createState() => _ServerCanvasAppState();
}

class _ServerCanvasAppState extends State<ServerCanvasApp> {
  @override
  void initState() {
    super.initState();
    widget.entry.start();
  }

  @override
  Widget build(BuildContext context) => galleyApp(
    Scaffold(
      body: ListenableBuilder(
        listenable: widget.entry,
        builder: (context, _) => switch (widget.entry.step) {
          // Keyed by the model, so a new sign-in is a new page that loads its own galley.
          Entered(:final canvas) => CanvasPage(key: ObjectKey(canvas), model: canvas),
          final step => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: _StepForm(entry: widget.entry, step: step),
              ),
            ),
          ),
        },
      ),
    ),
  );
}

/// One step's form: what it asks, why the last answer was not taken, and the way on.
class _StepForm extends StatelessWidget {
  const _StepForm({required this.entry, required this.step});

  final ServerEntry entry;
  final EntryStep step;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Galley', style: text.headlineSmall),
        const SizedBox(height: 16),
        ...switch (step) {
          Checking() || Entered() => [const Center(child: CircularProgressIndicator())],
          AskingEmail(:final why) => [
            if (why != null) _Why(why),
            _Ask(
              key: const ValueKey('email'),
              label: 'Your email',
              hint: 'The one you were invited by',
              action: 'Mail me a code',
              busy: entry.busy,
              onSubmit: entry.sendCode,
            ),
          ],
          AskingCode(:final email, :final why) => [
            Text('A code was mailed to $email.', style: text.bodyMedium),
            const SizedBox(height: 12),
            if (why != null) _Why(why),
            _Ask(
              key: const ValueKey('code'),
              label: 'The code',
              action: 'Sign in',
              busy: entry.busy,
              onSubmit: entry.signIn,
            ),
            TextButton(
              onPressed: entry.busy ? null : entry.back,
              child: const Text('Another email'),
            ),
          ],
          AskingAlias(:final email, :final why) => [
            Text(
              '$email is invited to this galley. Say what to sign your marks with: the owner and '
              'the other reviewers see it on everything you write.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 12),
            if (why != null) _Why(why),
            _Ask(
              key: const ValueKey('alias'),
              label: 'Your name in this galley',
              action: 'Join',
              busy: entry.busy,
              onSubmit: entry.join,
            ),
            TextButton(onPressed: entry.signOut, child: const Text('Sign out')),
          ],
          Barred(:final message) => [
            SelectableText(message),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: entry.busy ? null : entry.retry,
              child: const Text('Try again'),
            ),
            TextButton(onPressed: entry.signOut, child: const Text('Sign out')),
          ],
        },
      ],
    );
  }
}

/// Why the last answer was not taken.
class _Why extends StatelessWidget {
  const _Why(this.why);

  final String why;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: SelectableText(why, style: TextStyle(color: Theme.of(context).colorScheme.error)),
  );
}

/// One field and its button; Enter submits too.
class _Ask extends StatefulWidget {
  const _Ask({
    super.key,
    required this.label,
    this.hint,
    required this.action,
    required this.busy,
    required this.onSubmit,
  });

  final String label;
  final String? hint;
  final String action;
  final bool busy;
  final Future<void> Function(String value) onSubmit;

  @override
  State<_Ask> createState() => _AskState();
}

class _AskState extends State<_Ask> {
  final _value = TextEditingController();

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  void _submit() {
    if (!widget.busy) widget.onSubmit(_value.text);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _value,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: widget.busy ? null : _submit,
        child: Text(widget.busy ? '…' : widget.action),
      ),
    ],
  );
}
