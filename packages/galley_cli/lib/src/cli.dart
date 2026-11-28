import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:galley_core/galley_core.dart';
import 'package:galley_server/galley_server.dart';
import 'package:http/http.dart' as http;

import 'bundle.dart';
import 'canvas.dart';
import 'pinned.dart';
import 'galley_directory.dart';
import 'galley_server.dart';
import 'host.dart';
import 'linked.dart';
import 'local_galley.dart';
import 'pocketbase.dart';
import 'server_source.dart';
import 'renderer.dart';

part 'cli_server.dart';

/// What the commands need from the world, so a test can supply all of it.
final class GalleyContext {
  /// The real world: stdout, stderr, the clock, random ids and `flutter test`.
  GalleyContext({
    StringSink? out,
    StringSink? err,
    DateTime Function()? now,
    String Function()? newId,
    MakeRenderer? renderer,
    Map<String, String>? environment,
    Future<void> Function()? untilStopped,
    Fetch? fetch,
    PinnedCanvas? canvas,
    this._client,
    String? Function()? readLine,
  }) : out = out ?? stdout,
       err = err ?? stderr,
       now = now ?? DateTime.now,
       newId = newId ?? _randomId,
       renderer = renderer ?? FlutterTestRenderer.new,
       environment = environment ?? Platform.environment,
       untilStopped = untilStopped ?? _untilSignalled,
       fetch = fetch ?? httpFetch,
       canvas = canvas ?? pinnedCanvas,
       readLine = readLine ?? stdin.readLineSync;

  /// Where results go.
  final StringSink out;

  /// Where problems go.
  final StringSink err;

  /// The time an event is recorded at.
  final DateTime Function() now;

  /// A new mark's id.
  final String Function() newId;

  /// What renders a round for `pack`.
  final MakeRenderer renderer;

  /// Read for `GALLEY_BY`, and for where the canvas is cached (`GALLEY_CACHE`, `HOME`, ...).
  final Map<String, String> environment;

  /// Completes when `serve` should stop: on Ctrl-C, or on SIGTERM where there is one.
  final Future<void> Function() untilStopped;

  /// How `serve` downloads the canvas it has not cached.
  final Fetch fetch;

  /// The canvas `serve` serves when it is not given `--web`.
  final PinnedCanvas canvas;

  /// What a galley linked to a server speaks to it through. Made when first needed: a command
  /// on a galley kept here opens no connection.
  http.Client get client => _client ??= http.Client();
  http.Client? _client;

  /// A line the user types: the sign-in code `login` asks for. Null at the end of input.
  final String? Function() readLine;

  static Future<void> _untilSignalled() => Future.any([
    ProcessSignal.sigint.watch().first,
    if (!Platform.isWindows) ProcessSignal.sigterm.watch().first,
  ]);

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
    ..addCommand(_Reopen(c))
    ..addCommand(_Withdraw(c))
    ..addCommand(_Serve(c))
    ..addCommand(_Host(c))
    ..addCommand(_Bundle(c))
    ..addCommand(_Login(c))
    ..addCommand(_Link(c))
    ..addCommand(_Unlink(c))
    ..addCommand(_Push(c))
    ..addCommand(_Invite(c))
    ..addCommand(_Members(c))
    ..addCommand(_Revoke(c));
  try {
    return await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    c.err.writeln(e);
    return 64;
  } on Refused catch (e) {
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

  void addWeb() => argParser.addOption(
    'web',
    help:
        'A built canvas to serve at /, in place of the release\'s. For working on the canvas '
        'itself.',
    valueHelp: 'dir',
  );

  /// `--web`'s build, else the pinned release's, from the cache or fetched into it.
  Future<CanvasSource> canvasToServe() async {
    if (_args.option('web') case final web?) {
      if (!File('$web/index.html').existsSync()) {
        throw Refused.invalid('$web has no index.html: give the canvas\'s build directory');
      }
      return CanvasAt(web);
    }
    final root = cacheDirectory(c.environment);
    if (root == null) {
      return const NoCanvas('there is nowhere to cache it: set GALLEY_CACHE, or HOME');
    }
    final (pin, cache) = (c.canvas, CanvasCache(root, fetch: c.fetch));
    if (!File('${cache.directoryOf(pin)}/index.html').existsSync()) {
      c.out.writeln('Fetching the canvas, ${pin.asset}, into $root (once)');
    }
    return cache.canvas(pin);
  }

  /// Who is doing this, in a galley kept here.
  String get by {
    final by = _args.option('by') ?? c.environment['GALLEY_BY'];
    if (by == null || by.trim().isEmpty) {
      throw UsageException('say who: --by <name>, or set GALLEY_BY', usage);
    }
    return by;
  }

  String? get note => _args.option('note');

  LocalGalley get local => LocalGalley(galley, repository: app, now: c.now, newId: c.newId);

  /// The one positional argument: a mark's id.
  String get markArg {
    final rest = _args.rest;
    if (rest.isEmpty) throw UsageException('which mark?', usage);
    return rest.first;
  }

  /// The server and galley `.galley/server.json` names, or null when the galley is kept here.
  ServerLink? get link => ServerLink.read(galley.path);

  Future<_Linked>? _linked;

  /// The galley the commands act on, and who acts: the directory and `--by` (or GALLEY_BY),
  /// or, when it is linked to a server, the server's galley as the signed-in member, who acts
  /// as their alias there.
  ///
  /// `--by` is refused in a linked galley: the alias is the server's, and a name given here
  /// that differed from it would sign nothing. GALLEY_BY is ignored there, since it is set
  /// for the shell, not for one galley. [needsBy] is false for a command that writes nothing.
  Future<({Galley galley, String by})> acting({bool needsBy = true}) async {
    final l = link;
    if (l == null) return (galley: local as Galley, by: needsBy ? by : '');
    if (argParser.options.containsKey('by') && _args.wasParsed('by')) {
      throw UsageException(
        '--by is not given in a galley linked to ${l.url}: you act as your alias there',
        usage,
      );
    }
    final linked = await (_linked ??= _Linked.open(c, l));
    return (galley: linked.galley as Galley, by: linked.member.alias);
  }

  /// Appends the event [build] makes to the mark [id], and says what the mark is now.
  ///
  /// An event the core refuses to construct (a reopen with no note) is a usage error.
  Future<int> record(String id, MarkEvent Function(String by, DateTime at) build) async {
    final (:galley, :by) = await acting();
    final Mark next;
    try {
      next = await galley.record(id, (at) => build(by, at));
    } on ArgumentError catch (e) {
      throw UsageException('${e.message}', usage);
    }
    c.out.writeln('${next.id}: ${next.status.name}');
    return 0;
  }
}

final class _Pack extends _GalleyCommand {
  _Pack(super.c) {
    argParser
      ..addOption('test', defaultsTo: 'test/galley_test.dart', help: 'The app\'s galley test.')
      ..addOption(
        'flutter',
        defaultsTo: 'flutter',
        help: 'The flutter executable (one path, not a command).',
      );
  }

  @override
  String get name => 'pack';

  @override
  String get invocation => 'galley pack [options] [-- <flutter test args>]';

  @override
  String get description => 'Render a new round, and carry every mark into it.';

  @override
  Future<int> run() async {
    if (link case final l?) {
      throw Refused.invalid(
        'this galley is linked to ${l.url}: `galley push` renders a round and pushes it there',
      );
    }
    final g = galley;
    final n = g.nextRound();
    final exit = await c
        .renderer(
          app: app,
          test: _args.option('test')!,
          flutter: _args.option('flutter')!,
          testArgs: _args.rest,
        )
        .render(g.roundPath(n));
    if (!g.rounds().contains(n)) {
      throw Refused.environment(
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
      c.out.writeln('  ${p.mark.id}  ${p.placement.name}  ${p.mark.frame}');
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
      counts.update(c.placement.name, (v) => v + 1, ifAbsent: () => 1);
    }
    return 'Marks: ${carried.length} carried. '
        '${counts.entries.map((e) => '${e.value} ${e.key}').join(', ')}.';
  }
}

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
    final key = FrameKey.parse(_required('frame'));
    final at = _args.option('at'), path = _args.option('node');
    if ((at == null) == (path == null)) throw UsageException('give one of --at and --node', usage);
    final PinTarget target;
    if (at != null) {
      final xy = at.split(',').map(double.tryParse).toList();
      if (xy.length != 2 || xy.contains(null)) throw UsageException('--at is x,y', usage);
      target = AtPoint(xy[0]!, xy[1]!);
    } else {
      final indexPath = path!.split('.').map(int.tryParse).toList();
      if (indexPath.contains(null)) throw UsageException('--node is an index path, 0.2.1', usage);
      target = AtNode([...indexPath.nonNulls]);
    }
    final (:galley, :by) = await acting();
    final raised = await galley.raise(frame: key, target: target, note: _required('note'), by: by);
    c.out.writeln('${raised.mark.id}: raised on ${raised.node} in round ${raised.round}');
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
    final (galley: target, by: _) = await acting(needsBy: false);
    final all = _args.flag('all');
    final work = await workItems(target, all: all);
    if (_args.flag('json')) {
      c.out.writeln(const JsonEncoder.withIndent('  ').convert(work.toJson()));
      return 0;
    }
    final WorkItems(:items, :damaged) = work;
    if (items.isEmpty && damaged.isEmpty) {
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
    // Whatever its status: a mark that does not read has no status anyone knows.
    for (final d in damaged) {
      c.out.writeln('${d.id}  does not read: ${d.why}');
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
    final id = markArg;
    final rest = _args.rest;
    if (rest.length != 2) throw UsageException('give the mark and how it was answered', usage);
    final Answer answer;
    try {
      answer = switch (rest[1]) {
        'fixed' => Answer.fixed(commit: local.fullCommit(_commit()), note: note),
        'wont-fix' => Answer.wontFix(note: note ?? ''),
        'question' => Answer.question(note: note ?? ''),
        final other => throw UsageException('"$other" is not fixed, wont-fix or question', usage),
      };
    } on ArgumentError catch (e) {
      throw UsageException('${e.name}: ${e.message}', usage);
    }
    return record(id, (by, at) => Answered(answer, by: by, at: at));
  }

  String _commit() =>
      _args.option('commit') ?? (throw UsageException('fixed needs --commit <sha>', usage));
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
  Future<int> run() async => record(markArg, (by, at) => Verified(by: by, at: at));
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
    return record(markArg, (by, at) => Reopened(note ?? '', by: by, at: at));
  }
}

final class _Withdraw extends _GalleyCommand {
  _Withdraw(super.c) {
    argParser.addOption('note', help: 'Why: a duplicate of another mark, or a test.');
    addBy();
  }

  @override
  String get name => 'withdraw';

  @override
  String get invocation => 'galley withdraw <mark> --note <why> --by <name>';

  @override
  String get description =>
      'Take back a mark you raised. It is kept, with its history, and waits on no one.';

  @override
  Future<int> run() async => record(markArg, (by, at) => Withdrawn(note ?? '', by: by, at: at));
}

final class _Serve extends _GalleyCommand {
  _Serve(super.c) {
    argParser.addOption(
      'port',
      defaultsTo: '$defaultPort',
      help: 'The loopback port. 0 picks a free one.',
      valueHelp: 'n',
    );
    addWeb();
  }

  /// Fixed, so the canvas's address is the same every time and can be bookmarked. Rejected:
  /// a free port by default. Every run would print a new address to open.
  static const defaultPort = 7340;

  @override
  String get name => 'serve';

  @override
  String get description =>
      'Serve the galley on this machine for the canvas: its rounds, its marks, and new marks '
      'and events. Loopback only. Stops on Ctrl-C.';

  @override
  Future<int> run() async {
    if (link case final l?) {
      // Rejected: serving the directory anyway. Its marks are not the server's, and the canvas
      // would show a galley that looks whole and is not.
      throw Refused.invalid(
        'this galley is linked to ${l.url}, and `serve` shows a galley kept here. Its canvas is '
        'on the server: ${canvasLink(l.url, l.galley)}. `galley unlink` serves this directory '
        'again',
      );
    }
    final port = int.tryParse(_args.option('port')!);
    if (port == null || port < 0 || port > 65535) {
      throw UsageException('--port is 0 to 65535', usage);
    }
    final canvas = await canvasToServe();
    final GalleyServer server;
    try {
      server = await GalleyServer.start(local, port: port, canvas: canvas);
    } on SocketException catch (e) {
      throw Refused.environment(
        'could not listen on port $port (${e.osError?.message ?? e.message})',
      );
    }
    c.out.writeln('Serving ${galley.path} at ${server.url}  (Ctrl-C stops it)');
    if (canvas case NoCanvas(:final why)) {
      // Said, not hidden (DESIGN D14): the API still answers, and the address alone would
      // look like a canvas that failed to load.
      c.err.writeln(
        'galley: no canvas at ${server.url}: $why. The API is served; '
        '`--web <dir>` serves a built canvas.',
      );
    }
    await c.untilStopped();
    await server.close();
    return 0;
  }
}

final class _Host extends _GalleyCommand {
  _Host(super.c) {
    argParser
      ..addOption(
        'port',
        defaultsTo: '$defaultPort',
        help: 'The loopback port. 0 picks a free one.',
        valueHelp: 'n',
      )
      ..addOption(
        'data',
        help: 'Where its galleys are kept. Defaults to galley/host under the user data directory.',
        valueHelp: 'dir',
      )
      ..addOption(
        'owner',
        help: 'Make a user for this email, who can then make a galley and invite to it.',
        valueHelp: 'email',
      );
    addWeb();
  }

  /// PocketBase's own default, and not `serve`'s, so the two can run at once.
  static const defaultPort = 8090;

  @override
  String get name => 'host';

  @override
  String get description =>
      'Run a Galley server on this machine: PocketBase with Galley\'s schema, on loopback. '
      'Sign-in codes are written to its data directory, not mailed. Stops on Ctrl-C.';

  @override
  Future<int> run() async {
    final port = int.tryParse(_args.option('port')!);
    if (port == null || port < 0 || port > 65535) {
      throw UsageException('--port is 0 to 65535', usage);
    }
    final cache = cacheDirectory(c.environment);
    if (cache == null) {
      throw const Refused.environment(
        'there is nowhere to cache PocketBase: set GALLEY_CACHE, or HOME',
      );
    }
    final data =
        _args.option('data') ??
        switch (dataDirectory(c.environment)) {
          final d? => '$d/host',
          null => throw const Refused.environment(
            'there is nowhere to keep its data: give --data <dir>',
          ),
        };
    c.out.writeln(
      'Starting PocketBase with Galley\'s schema (the first start fetches it into $cache)',
    );
    final canvas = await canvasToServe();
    final server = await LocalServer.start(
      data: data,
      cache: ArchiveCache(cache, fetch: c.fetch),
      port: port,
      canvas: switch (canvas) {
        CanvasAt(:final directory) => directory,
        NoCanvas() => null,
      },
      // The operator's setting a hosted server reads (DESIGN D18), so `--owner` here is
      // GALLEY_OWNERS there, made by the same hook.
      environment: {'GALLEY_OWNERS': ?_args.option('owner')},
    );
    try {
      if (_args.option('owner') case final owner?) {
        c.out.writeln('${owner.toLowerCase()} can sign in');
      }
      c.out
        ..writeln('Hosting $data at ${server.url}  (Ctrl-C stops it)')
        ..writeln('Sign-in codes are written to ${server.otpDirectory}');
      if (canvas case NoCanvas(:final why)) {
        // Said, as `serve` says it (DESIGN D14): the API answers, and the CLI works; a
        // reviewer's link would open nothing.
        c.err.writeln(
          'galley: no canvas at ${server.url}: $why. The API is served; `--web <dir>` serves '
          'a built canvas.',
        );
      } else {
        c.out.writeln(
          'The canvas is at ${server.url}; each galley\'s link is printed by '
          '`galley link` and `galley invite`.',
        );
      }
      final stopped = await Future.any([
        c.untilStopped().then((_) => null),
        server.exitCode.then<int?>((code) => code),
      ]);
      if (stopped != null) {
        throw Refused.environment('PocketBase stopped by itself, with exit code $stopped');
      }
      return 0;
    } finally {
      await server.close();
    }
  }
}

final class _Bundle extends _GalleyCommand {
  _Bundle(super.c) {
    argParser.addOption(
      'platform',
      defaultsTo: 'linux_amd64',
      help:
          'The machine it runs on: linux_amd64, linux_arm64, or this one '
          '(${PinnedPocketBase.forAbi()?.platform ?? 'none'}).',
      valueHelp: 'name',
    );
    addWeb();
  }

  @override
  String get name => 'bundle';

  @override
  String get invocation => 'galley bundle <dir>';

  @override
  String get description =>
      'Write a Galley server to <dir>, for a machine elsewhere: PocketBase, the validator '
      'compiled for it, the schema, the canvas, a run script and a Dockerfile (docs/HOSTING.md).';

  @override
  Future<int> run() async {
    final rest = _args.rest;
    if (rest.length != 1) throw UsageException('give the directory to write it to', usage);
    final platform = _args.option('platform')!;
    final pin = PinnedPocketBase.forPlatform(platform);
    if (pin == null || targetOf(platform) == null) {
      throw UsageException(
        '--platform is linux_amd64, linux_arm64 or ${PinnedPocketBase.forAbi()?.platform}, '
        'not $platform',
        usage,
      );
    }
    final cache = cacheDirectory(c.environment);
    if (cache == null) {
      throw const Refused.environment(
        'there is nowhere to cache PocketBase: set GALLEY_CACHE, or HOME',
      );
    }
    final canvas = switch (await canvasToServe()) {
      CanvasAt(:final directory) => directory,
      // Refused, where `host` serves the API alone: a hosted server is for reviewers, and
      // their link would open nothing.
      NoCanvas(:final why) => throw Refused.environment(
        'no canvas to serve: $why. `--web <dir>` bundles a built one.',
      ),
    };
    final pocketbase = switch (await ArchiveCache(cache, fetch: c.fetch).unpacked(pin)) {
      UnpackedAt(:final directory) => '$directory/${pin.executable}',
      NotUnpacked(:final why) => throw Refused.environment('no PocketBase: $why'),
    };
    c.out.writeln('Writing a Galley server for $platform to ${rest.single}');
    await writeBundle(
      to: rest.single,
      platform: platform,
      pocketbase: pocketbase,
      source: GalleySource.resolve(),
      cache: cache,
      canvas: canvas,
      canvasNamed: _args.option('web') == null ? 'release ${c.canvas.version}' : 'a build',
      made: c.now(),
    );
    c.out.writeln(
      'Written. `fly deploy ${rest.single} --config <fly.toml> --ha=false` deploys it '
      '(docs/HOSTING.md).',
    );
    return 0;
  }
}
