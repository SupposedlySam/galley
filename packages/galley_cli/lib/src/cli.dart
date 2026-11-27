import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:galley_core/galley_core.dart';

import 'galley_directory.dart';
import 'renderer.dart';

/// What the commands need from the world, so a test can supply all of it.
final class GalleyContext {
  /// The real world: stdout, stderr, the clock, random ids and `flutter test`.
  GalleyContext({
    StringSink? out,
    StringSink? err,
    DateTime Function()? now,
    String Function()? newId,
    RoundRenderer Function({required String app, required String test, required String flutter})?
    renderer,
    Map<String, String>? environment,
  }) : out = out ?? stdout,
       err = err ?? stderr,
       now = now ?? DateTime.now,
       newId = newId ?? _randomId,
       renderer = renderer ?? FlutterTestRenderer.new,
       environment = environment ?? Platform.environment;

  /// Where results go.
  final StringSink out;

  /// Where problems go.
  final StringSink err;

  /// The time an event is recorded at.
  final DateTime Function() now;

  /// A new mark's id.
  final String Function() newId;

  /// What renders a round for `pack`.
  final RoundRenderer Function({required String app, required String test, required String flutter})
  renderer;

  /// Read for `GALLEY_BY`.
  final Map<String, String> environment;

  /// 48 random bits as hex: unique enough for one galley's marks, short enough to type.
  /// Rejected: a counter. Two people marking the same galley offline would both make `m3`.
  static String _randomId() {
    final r = Random.secure();
    return 'm${[for (var i = 0; i < 6; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join()}';
  }
}

/// Runs the `galley` command with [args], and returns its exit code.
Future<int> runGalley(List<String> args, [GalleyContext? context]) async {
  final c = context ?? GalleyContext();
  final runner = _Runner(c)
    ..argParser.addOption('app', defaultsTo: '.', help: 'The app\'s root.')
    ..argParser.addOption('galley', help: 'The galley directory.', defaultsTo: null)
    ..addCommand(_Pack(c))
    ..addCommand(_MarkCommand(c))
    ..addCommand(_Pull(c))
    ..addCommand(_AnswerCommand(c))
    ..addCommand(_Verify(c))
    ..addCommand(_Reopen(c));
  try {
    return await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    c.err.writeln(e);
    return 64;
  } on _Refused catch (e) {
    c.err.writeln('galley: ${e.message}');
    return 1;
  } on StateError catch (e) {
    c.err.writeln('galley: ${e.message}');
    return 1;
  } on FormatException catch (e) {
    c.err.writeln('galley: ${e.message}');
    return 1;
  }
}

/// Prints its usage to [GalleyContext.out], not to `print`: what a command says goes where the
/// context says, so a test sees `--help` too.
final class _Runner extends CommandRunner<int> {
  _Runner(this.c)
    : super('galley', 'Rounds of an app\'s frames, and the marks reviewers pin to them.');

  final GalleyContext c;

  @override
  void printUsage() => c.out.writeln(usage);
}

/// A command that cannot do what it was asked, and says why.
final class _Refused implements Exception {
  _Refused(this.message);
  final String message;
}

abstract class _GalleyCommand extends Command<int> {
  _GalleyCommand(this.c);

  final GalleyContext c;

  @override
  void printUsage() => c.out.writeln(usage);

  ArgResults get _args => argResults!;
  ArgResults get _global => globalResults!;

  String get app => _global.option('app')!;

  GalleyDirectory get galley => GalleyDirectory(_global.option('galley') ?? '$app/.galley');

  void addBy() => argParser.addOption(
    'by',
    help: 'Who is doing this. Defaults to GALLEY_BY.',
    valueHelp: 'name',
  );

  String get by {
    final by = _args.option('by') ?? c.environment['GALLEY_BY'];
    if (by == null || by.trim().isEmpty) {
      throw UsageException('say who: --by <name>, or set GALLEY_BY', usage);
    }
    return by;
  }

  String? get note => _args.option('note');

  /// The one positional argument: a mark's id.
  Mark get markArg {
    final rest = _args.rest;
    if (rest.isEmpty) throw UsageException('which mark?', usage);
    final mark = galley.mark(rest.first);
    if (mark == null) throw _Refused('no mark "${rest.first}" in ${galley.path}');
    return mark;
  }

  /// Appends [event] to [mark], and says what it is now.
  int record(Mark mark, MarkEvent event) {
    final Mark next;
    try {
      next = mark.record(event);
    } on StateError {
      throw _Refused('mark ${mark.id} is ${mark.status.name}, and cannot be $name now');
    }
    galley.saveMark(next);
    c.out.writeln('${next.id}: ${next.status.name}');
    return 0;
  }

  int latestRound() {
    final rounds = galley.rounds();
    if (rounds.isEmpty) throw _Refused('${galley.path} has no rounds yet: run `galley pack`');
    return rounds.last;
  }
}

final class _Pack extends _GalleyCommand {
  _Pack(super.c) {
    argParser
      ..addOption('test', defaultsTo: 'test/galley_test.dart', help: 'The app\'s galley test.')
      ..addOption('flutter', defaultsTo: 'flutter', help: 'The flutter command.');
  }

  @override
  String get name => 'pack';

  @override
  String get description => 'Render a new round, and carry every mark into it.';

  @override
  Future<int> run() async {
    final g = galley;
    final n = g.nextRound();
    final exit = await c
        .renderer(app: app, test: _args.option('test')!, flutter: _args.option('flutter')!)
        .render(g.roundPath(n));
    if (!g.rounds().contains(n)) {
      throw _Refused(
        'round $n did not finish: the galley test exited $exit and wrote no index.json. '
        'What it did write is kept in ${g.roundPath(n)}.',
      );
    }
    final stored = await g.readRound(n);
    final carried = stored.round.carryAll(g.lastPlaced().map((p) => p.carried).toList());
    g.savePlacements(n, Placements(carried));

    final errors = stored.frames.where((f) => f.record.status == FrameStatus.error).length;
    c.out
      ..writeln(
        'Round $n: ${stored.frames.length} of ${stored.manifest.planned} planned frames, '
        '$errors errors. ${_provenance(stored.provenance)}',
      )
      ..writeln(_placementCounts(carried));
    for (final p in carried) {
      c.out.writeln('  ${p.mark.id}  ${placementName(p.placement)}  ${p.mark.frame}');
    }
    if (exit != 0) {
      c.out.writeln(
        'The galley test exited $exit: each error frame failed its test. The round is kept, '
        'with those frames as errors.',
      );
    }
    return 0;
  }

  static String _provenance(Recorded<RoundProvenance> recorded) => switch (recorded) {
    Unrecorded(:final reason) => 'Provenance unknown: $reason.',
    Known(value: final p) =>
      'Rendered from ${switch (p.commit) {
            Known(:final value) => value.substring(0, min(7, value.length)),
            Unrecorded(:final reason) => 'an unknown commit ($reason)',
          }}'
          '${switch (p.dirty) {
            Known(value: true) => ' with uncommitted changes',
            Known(value: false) => '',
            Unrecorded(:final reason) => ', tree state unknown ($reason)',
          }}'
          ', on Flutter ${p.flutter}.',
  };

  static String _placementCounts(List<Carried> carried) {
    final counts = <String, int>{
      for (final k in ['exact', 'moved', 'lost', 'unplaced', 'retired']) k: 0,
    };
    for (final c in carried) {
      counts.update(placementName(c.placement), (v) => v + 1, ifAbsent: () => 1);
    }
    return 'Marks: ${carried.length} carried. '
        '${counts.entries.map((e) => '${e.value} ${e.key}').join(', ')}.';
  }
}

/// The word a person reads for [p].
String placementName(Placement p) => switch (p) {
  Raised() => 'raised',
  Reanchored(result: final Located l) => l.isExact ? 'exact' : 'moved',
  Reanchored(result: Lost()) => 'lost',
  Unplaced() => 'unplaced',
  Retired() => 'retired',
};

final class _MarkCommand extends _GalleyCommand {
  _MarkCommand(super.c) {
    argParser
      ..addOption('frame', help: 'The frame\'s key, as in its record.', valueHelp: 'key')
      ..addOption('at', help: 'A point in the frame, in logical pixels.', valueHelp: 'x,y')
      ..addOption('node', help: 'A widget\'s index path in the frame\'s tree.', valueHelp: '0.2.1')
      ..addOption('note', help: 'What is wrong.');
    addBy();
  }

  @override
  String get name => 'mark';

  @override
  String get description =>
      'Pin a note to a widget in the latest round. The canvas does this for reviewers; this is '
      'for an app\'s owner and for tests.';

  @override
  Future<int> run() async {
    final g = galley;
    final n = latestRound();
    final key = FrameKey.parse(_required('frame'));
    final frame = (await g.readRound(n)).round.frame(key);
    if (frame == null) throw _Refused('round $n has no frame $key');
    final tree = frame.tree;
    if (tree == null) throw _Refused('frame $key in round $n has no tree to pin a widget of');

    final at = _args.option('at'), path = _args.option('node');
    if ((at == null) == (path == null)) throw UsageException('give one of --at and --node', usage);
    final WidgetNode? node;
    final PinOffset pin;
    if (at != null) {
      final xy = at.split(',').map(double.tryParse).toList();
      if (xy.length != 2 || xy.contains(null)) throw UsageException('--at is x,y', usage);
      node = tree.deepestAt(xy[0]!, xy[1]!);
      pin = node == null ? const PinOffset(0.5, 0.5) : PinOffset.within(node.rect, xy[0]!, xy[1]!);
    } else {
      final indexPath = path!.split('.').map(int.tryParse).toList();
      if (indexPath.contains(null)) throw UsageException('--node is an index path, 0.2.1', usage);
      node = tree.at([...indexPath.nonNulls]);
      pin = const PinOffset(0.5, 0.5);
    }
    if (node == null) throw _Refused('no widget at ${at ?? path} in frame $key');

    final note = _required('note'), who = by;
    if (note.trim().isEmpty) throw UsageException('a mark says what is wrong', usage);
    final mark = Mark(
      id: c.newId(),
      frame: key,
      anchor: Anchor.of(node),
      pin: pin,
      note: note,
      by: who,
      at: c.now().toUtc(),
    );
    final placements = g.placements(n) ?? Placements(const []);
    g
      ..saveMark(mark)
      ..savePlacements(n, placements.plus([Carried.raised(mark)]));
    c.out.writeln('${mark.id}: raised on $node in round $n');
    return 0;
  }

  String _required(String option) =>
      _args.option(option) ?? (throw UsageException('--$option is required', usage));
}

final class _Pull extends _GalleyCommand {
  _Pull(super.c) {
    argParser
      ..addFlag('json', help: 'One JSON document, for an agent.')
      ..addFlag('all', help: 'Every mark, not only those waiting on an answer.');
  }

  @override
  String get name => 'pull';

  @override
  String get description => 'The marks waiting on an answer, where each one is now.';

  @override
  Future<int> run() async {
    final g = galley;
    final latest = g.rounds().lastOrNull;
    final all = _args.flag('all');
    final placed = g.lastPlaced().where((p) => all || p.carried.mark.status.awaitsAnswer);
    final rounds = <int, StoredRound>{};
    final items = <JsonMap>[];
    for (final p in placed) {
      final n = p.round;
      final stored = n == null ? null : rounds[n] ??= await g.readRound(n);
      final image = stored?.round.frame(p.carried.mark.frame)?.record.image;
      items.add({
        'id': p.carried.mark.id,
        'status': p.carried.mark.status.name,
        'round': n,
        'placement': placementName(p.carried.placement),
        'where': p.carried.placement.toJson(),
        'anchor': p.carried.anchor.toJson(),
        'image': image == null ? null : File('${g.roundPath(n!)}/$image').absolute.path,
        'mark': p.carried.mark.toJson(),
      });
    }
    if (_args.flag('json')) {
      c.out.writeln(
        const JsonEncoder.withIndent('  ').convert({'latest_round': latest, 'items': items}),
      );
      return 0;
    }
    if (items.isEmpty) {
      c.out.writeln(all ? 'No marks.' : 'Nothing is waiting on an answer.');
      return 0;
    }
    for (final i in items) {
      final mark = i['mark']! as JsonMap;
      final at = (i['anchor']! as JsonMap)['location'];
      final location = at == null ? null : SourceLocation.fromJson(at, 'anchor.location');
      c.out.writeln(
        '${i['id']}  ${i['status']}  ${i['placement']} in round ${i['round']}  ${mark['frame']}\n'
        '    "${mark['note']}" (${mark['by']})${location == null ? '' : '\n    $location'}',
      );
    }
    return 0;
  }
}

final class _AnswerCommand extends _GalleyCommand {
  _AnswerCommand(super.c) {
    argParser
      ..addOption('commit', help: 'The commit with the fix (fixed).', valueHelp: 'sha')
      ..addOption('note', help: 'Why not (wont-fix), what to ask (question), or a remark.');
    addBy();
  }

  @override
  String get name => 'answer';

  @override
  String get invocation => 'galley answer <mark> <fixed|wont-fix|question> [options]';

  @override
  String get description => 'Answer a mark: fixed in a commit, won\'t fix, or a question back.';

  @override
  Future<int> run() async {
    final mark = markArg;
    final rest = _args.rest;
    if (rest.length != 2) throw UsageException('give the mark and how it was answered', usage);
    final Answer answer;
    try {
      answer = switch (rest[1]) {
        'fixed' => Answer.fixed(commit: _commit(), note: note),
        'wont-fix' => Answer.wontFix(note: note ?? ''),
        'question' => Answer.question(note: note ?? ''),
        final other => throw UsageException('"$other" is not fixed, wont-fix or question', usage),
      };
    } on ArgumentError catch (e) {
      throw UsageException('${e.name}: ${e.message}', usage);
    }
    return record(mark, Answered(answer, by: by, at: c.now().toUtc()));
  }

  /// The full SHA of `--commit`, which must be a commit in the app's repository.
  ///
  /// Stored in full: a short SHA that is unique today can be ambiguous next year. Checked,
  /// because "fixed in a commit that does not exist" cannot be verified by anyone.
  String _commit() {
    final given = _args.option('commit');
    if (given == null) throw UsageException('fixed needs --commit <sha>', usage);
    final r = Process.runSync('git', [
      'rev-parse',
      '--verify',
      '--quiet',
      '$given^{commit}',
    ], workingDirectory: app);
    if (r.exitCode != 0) throw _Refused('$given is not a commit in the repository at $app');
    return '${r.stdout}'.trim();
  }
}

final class _Verify extends _GalleyCommand {
  _Verify(super.c) {
    addBy();
  }

  @override
  String get name => 'verify';

  @override
  String get invocation => 'galley verify <mark> --by <name>';

  @override
  String get description => 'Accept a mark\'s answer.';

  @override
  Future<int> run() async => record(markArg, Verified(by: by, at: c.now().toUtc()));
}

final class _Reopen extends _GalleyCommand {
  _Reopen(super.c) {
    argParser.addOption('note', help: 'What is still wrong.');
    addBy();
  }

  @override
  String get name => 'reopen';

  @override
  String get invocation => 'galley reopen <mark> --note <what> --by <name>';

  @override
  String get description => 'Refuse a mark\'s answer, saying what is still wrong.';

  @override
  Future<int> run() async {
    final mark = markArg;
    final Reopened event;
    try {
      event = Reopened(note ?? '', by: by, at: c.now().toUtc());
    } on ArgumentError catch (e) {
      throw UsageException('${e.message}', usage);
    }
    return record(mark, event);
  }
}
