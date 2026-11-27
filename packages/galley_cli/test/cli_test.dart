import 'dart:convert';
import 'dart:io';

import 'package:galley_cli/galley_cli.dart';
import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

final _home = FrameKey({'screen': 'home', 'device': 'pixel-7'});
final _menu = FrameKey({'screen': 'menu', 'device': 'pixel-7'});

/// The app as the fake renderer draws it. A test changes it between packs.
final class _App {
  LogicalRect buy = const LogicalRect(10, 10, 100, 40);
  bool hasMenu = true;
  bool homeErrs = false;
  bool finishes = true;
  int exitCode = 0;
  RoundProvenance provenance = RoundProvenance(
    commit: Unrecorded('a fixture'),
    dirty: Unrecorded('a fixture'),
    flutter: Unrecorded('a fixture'),
    at: DateTime.utc(2026, 11, 26),
  );
}

/// Writes a round the way the packer does, from [_App], without Flutter.
final class _FakeRenderer implements RoundRenderer {
  _FakeRenderer(this.fake);
  final _App fake;

  @override
  Future<int> render(String outDir) async {
    void write(String path, Object? json) =>
        (File('$outDir/$path')..createSync(recursive: true)).writeAsStringSync(jsonEncode(json));
    FrameTree tree(String type, LogicalRect rect, {List<WidgetNode> children = const []}) =>
        FrameTree(
          bounds: const LogicalRect(0, 0, 400, 800),
          nodes: [
            WidgetNode(indexPath: const [], type: 'App', rect: const LogicalRect(0, 0, 400, 800)),
            WidgetNode(
              indexPath: const [0],
              type: type,
              key: type == 'FilledButton' ? 'buy' : null,
              rect: rect,
              location: const SourceLocation('package:app/screens.dart', 12, 5),
            ),
            ...children,
          ],
        );
    final frames = <String>[];
    void frame(FrameKey key, FrameTree t, {bool error = false}) {
      final name = '${key.values['screen']}';
      write('trees/$name.json', t.toJson());
      File('$outDir/frames/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync([0x89, 0x50, 0x4e, 0x47]);
      write(
        'records/$name.json',
        FrameRecord(
          key: key,
          scenario: 'base',
          uri: Uri.parse('/$name'),
          landing: LandedAt(Uri.parse('/$name')),
          status: error ? FrameStatus.error : FrameStatus.rendered,
          device: DeviceProfile.pixel7,
          essential: true,
          errors: error ? ['boom'] : const [],
          image: 'frames/$name.png',
          tree: 'trees/$name.json',
        ).toJson(),
      );
      frames.add('records/$name.json');
    }

    frame(_home, tree('FilledButton', fake.buy), error: fake.homeErrs);
    if (fake.hasMenu) {
      // Two children, so that an index path read backwards (1.0 for 0.1) finds nothing.
      frame(
        _menu,
        tree(
          'Row',
          const LogicalRect(20, 100, 200, 20),
          children: [
            WidgetNode(
              indexPath: const [0, 0],
              type: 'Icon',
              rect: const LogicalRect(20, 100, 20, 20),
            ),
            WidgetNode(
              indexPath: const [0, 1],
              type: 'Badge',
              rect: const LogicalRect(50, 100, 20, 20),
            ),
          ],
        ),
      );
    }
    write('round.json', fake.provenance.toJson());
    if (fake.finishes) write('index.json', RoundManifest(frames: frames, planned: 2).toJson());
    return fake.exitCode;
  }
}

void main() {
  late Directory dir;
  late _App fake;
  late StringBuffer out, err;
  late int ids;
  late String commit;

  String git(List<String> args) {
    final r = Process.runSync('git', [
      '-c', 'user.name=galley', '-c', 'user.email=galley@example.invalid',
      '-c', 'commit.gpgsign=false', ...args, //
    ], workingDirectory: dir.path);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return '${r.stdout}'.trim();
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('galley_cli_');
    fake = _App();
    out = StringBuffer();
    err = StringBuffer();
    ids = 0;
    git(['init', '-q']);
    File('${dir.path}/main.dart').writeAsStringSync('void main() {}\n');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'one']);
    commit = git(['rev-parse', 'HEAD']);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<int> galley(List<String> args) {
    out.clear();
    err.clear();
    return runGalley(
      ['--app', dir.path, ...args],
      GalleyContext(
        out: out,
        err: err,
        now: () => DateTime.utc(2026, 11, 27, 0, ids),
        newId: () => 'm${++ids}',
        renderer: ({required app, required test, required flutter}) => _FakeRenderer(fake),
        environment: const {},
      ),
    );
  }

  GalleyDirectory store() => GalleyDirectory('${dir.path}/.galley');

  Future<JsonMap> pull([List<String> more = const []]) async {
    expect(await galley(['pull', '--json', ...more]), 0, reason: '$err');
    return jsonDecode('$out') as JsonMap;
  }

  List<String> placed(JsonMap pulled) => [
    for (final i in (pulled['items']! as List).cast<JsonMap>()) '${i['id']} ${i['placement']}',
  ];

  test('the whole local loop: pack, mark, pack, pull, answer, pack, verify', () async {
    expect(await galley(['pack']), 0, reason: '$err');
    expect(
      '$out',
      contains(
        'Round 1: 2 of 2 planned frames, 0 errors. Rendered from an unknown commit (a fixture), '
        'tree state unknown (a fixture), on Flutter unknown (a fixture).',
      ),
    );
    expect('$out', contains('Marks: 0 carried.'));

    expect(
      await galley(['mark', '--frame', '$_home', '--at', '100,20', '--note', 'tight', '--by', 'r']),
      0,
      reason: '$err',
    );
    expect('$out', contains('m1: raised on FilledButton(buy) at 0 in round 1'));
    final pin = store().mark('m1')!.pin;
    expect((pin.dx, pin.dy), (0.9, 0.25), reason: '100,20 in a button at 10,10 sized 100x40');
    expect(
      await galley(['mark', '--frame', '$_menu', '--node', '0', '--note', 'grey', '--by', 'r']),
      0,
    );
    expect(placed(await pull()), ['m1 raised', 'm2 raised']);

    // Round 2: the button moved, the menu is gone.
    fake
      ..buy = const LogicalRect(10, 300, 100, 40)
      ..hasMenu = false;
    expect(await galley(['pack']), 0, reason: '$err');
    expect('$out', contains('Round 2: 1 of 2 planned frames'));
    expect('$out', contains('Marks: 2 carried. 0 exact, 1 moved, 0 lost, 0 unplaced, 1 retired.'));
    final round2 = await pull();
    expect(round2['latest_round'], 2);
    expect(placed(round2), ['m1 moved', 'm2 retired']);
    final m1 = (round2['items']! as List).cast<JsonMap>().first;
    expect(m1['round'], 2);
    expect(File(m1['image']! as String).existsSync(), isTrue, reason: '${m1['image']}');
    expect((m1['anchor']! as JsonMap)['location'], {
      'file': 'package:app/screens.dart',
      'line': 12,
      'column': 5,
    });
    final m2 = (round2['items']! as List).cast<JsonMap>().last;
    expect(m2['round'], 2, reason: 'a retired mark is placed in the round it is retired in');

    expect(
      await galley(['answer', 'm1', 'fixed', '--commit', commit.substring(0, 7), '--by', 'claude']),
      0,
      reason: '$err',
    );
    expect('$out', contains('m1: answered'));
    final answered = store().mark('m1')!;
    final answer = (answered.history.single as Answered).answer;
    expect(answer.commit, commit, reason: 'stored in full, not as typed');
    expect(placed(await pull()), ['m2 retired'], reason: 'm1 waits on a reviewer, not on us');
    expect(placed(await pull(['--all'])), ['m1 moved', 'm2 retired']);

    // Round 3: the menu is back and nothing moved. m1 is Exact against where it was last seen;
    // m2 is found again from the anchor it was last found at.
    fake.hasMenu = true;
    expect(await galley(['pack']), 0, reason: '$err');
    expect('$out', contains('2 exact, 0 moved'));

    expect(await galley(['verify', 'm1', '--by', 'r']), 0, reason: '$err');
    expect(store().mark('m1')!.status, MarkStatus.verified);
    expect(store().mark('m1')!.history, hasLength(2), reason: 'the answer is kept');
    expect(store().rounds(), [1, 2, 3]);
  });

  test('a round that errs on a mark\'s frame leaves it Unplaced, and the round is kept', () async {
    await galley(['pack']);
    await galley(['mark', '--frame', '$_home', '--node', '0', '--note', 'x', '--by', 'r']);
    fake
      ..homeErrs = true
      ..exitCode = 1
      ..provenance = RoundProvenance(
        commit: Known(commit),
        dirty: const Known(true),
        flutter: const Known('3.50.0'),
        at: DateTime.utc(2026, 11, 26),
      );
    expect(await galley(['pack']), 0, reason: '$err');
    expect(
      '$out',
      contains(
        'Rendered from ${commit.substring(0, 7)} with uncommitted changes, on Flutter 3.50.0.',
      ),
    );
    expect('$out', contains('1 errors'));
    expect('$out', contains('1 unplaced'));
    expect('$out', contains('The galley test exited 1'));
    expect(placed(await pull()), ['m1 unplaced']);
  });

  test(
    'a round that did not finish is refused and kept, and the next one is numbered past it',
    () async {
      fake
        ..finishes = false
        ..exitCode = 1;
      expect(await galley(['pack']), 1);
      expect('$err', contains('round 1 did not finish'));
      expect(Directory('${dir.path}/.galley/rounds/1/records').existsSync(), isTrue);
      expect(store().rounds(), isEmpty);

      fake
        ..finishes = true
        ..exitCode = 0;
      expect(await galley(['pack']), 0, reason: '$err');
      expect('$out', contains('Round 2:'));
      expect(store().rounds(), [2]);
    },
  );

  test('marks are carried from the last round that carried them', () async {
    await galley(['pack']);
    await galley(['mark', '--frame', '$_home', '--node', '0', '--note', 'x', '--by', 'r']);
    fake.buy = const LogicalRect(10, 300, 100, 40);
    await galley(['pack']);
    // A round that rendered but was never carried (a pack killed in between).
    File('${store().roundPath(2)}/placements.json').renameSync('${dir.path}/kept.json');
    expect(store().lastPlaced().single.round, 1);
    final pulled = await pull();
    expect(pulled['latest_round'], 2);
    expect((pulled['items']! as List).cast<JsonMap>().single['round'], 1);
    File('${dir.path}/kept.json').renameSync('${store().roundPath(2)}/placements.json');
    expect(store().lastPlaced().single.round, 2, reason: 'the control');

    expect(
      await galley(['mark', '--frame', '$_home', '--node', '0', '--note', 'y', '--by', 'r']),
      0,
    );
    expect('$out', contains('m2: raised on FilledButton(buy) at 0 in round 2'));
    expect(store().placements(2)!.of('m2'), isNotNull);
    expect(store().placements(1)!.of('m2'), isNull);
  });

  test('a mark is only ever appended to', () async {
    await galley(['pack']);
    await galley(['mark', '--frame', '$_home', '--node', '0', '--note', 'x', '--by', 'r']);
    final m = store().mark('m1')!;
    final rewritten = Mark(
      id: m.id,
      frame: m.frame,
      anchor: m.anchor,
      pin: m.pin,
      note: 'something else',
      by: m.by,
      at: m.at,
    );
    expect(() => store().saveMark(rewritten), throwsStateError);
    final answered = m.record(
      Answered(
        Answer.question(note: 'which?'),
        by: 'c',
        at: DateTime.utc(2026, 11, 27),
      ),
    );
    store().saveMark(answered);
    expect(() => store().saveMark(m), throwsStateError, reason: 'dropping an event');
    expect(store().mark('m1')!.history, hasLength(1));
  });

  test('what is refused, and how', () async {
    expect(await galley(['pull']), 0);
    expect('$out', contains('Nothing is waiting on an answer.'));
    expect(
      await galley(['mark', '--frame', '$_home', '--node', '0', '--note', 'x', '--by', 'r']),
      1,
    );
    expect('$err', contains('has no rounds yet'));

    await galley(['pack']);
    expect(await galley(['mark', '--frame', '$_home', '--node', '0', '--note', 'x']), 64);
    expect('$err', contains('--by'));
    expect(await galley(['mark', '--frame', '$_home', '--note', 'x', '--by', 'r']), 64);
    expect(
      await galley(['mark', '--frame', '$_home', '--node', '0', '--note', ' ', '--by', 'r']),
      64,
    );
    expect(
      await galley(['mark', '--frame', '$_home', '--node', '0', '--note', 'x', '--by', ' ']),
      64,
    );
    expect(store().marks(), isEmpty, reason: 'nothing refused was saved');
    expect(
      await galley(['mark', '--frame', '$_home', '--node', '7', '--note', 'x', '--by', 'r']),
      1,
    );
    expect('$err', contains('no widget at 7'));
    final gone = FrameKey({'screen': 'gone', 'device': 'pixel-7'});
    expect(
      await galley(['mark', '--frame', '$gone', '--node', '0', '--note', 'x', '--by', 'r']),
      1,
    );

    await galley(['mark', '--frame', '$_home', '--node', '0', '--note', 'x', '--by', 'r']);
    expect(await galley(['answer', 'm1', 'fixed', '--commit', 'abcdef1', '--by', 'c']), 1);
    expect('$err', contains('is not a commit'));
    expect(await galley(['answer', 'm1', 'fixed', '--by', 'c']), 64);
    expect(await galley(['answer', 'm1', 'wont-fix', '--by', 'c']), 64, reason: 'needs a note');
    expect(await galley(['answer', 'm9', 'question', '--note', 'q', '--by', 'c']), 1);
    expect(await galley(['verify', 'm1', '--by', 'r']), 1);
    expect('$err', contains('m1 is open'));
    expect(await galley(['reopen', 'm1', '--note', 'still', '--by', 'r']), 1);
    expect(store().mark('m1')!.history, isEmpty, reason: 'nothing refused was recorded');

    expect(await galley(['answer', 'm1', 'question', '--note', 'which edge?', '--by', 'c']), 0);
    expect(await galley(['reopen', 'm1', '--by', 'r']), 64, reason: 'a reopen says why');
    expect(await galley(['reopen', 'm1', '--note', 'the left', '--by', 'r']), 0);
    expect(store().mark('m1')!.status, MarkStatus.reopened);

    expect(await galley(['answer', 'm1', 'wont-fix', '--note', 'by design', '--by', 'c']), 0);
    final last = store().mark('m1')!.history.last as Answered;
    expect((last.answer.kind, last.answer.note), (AnswerKind.wontFix, 'by design'));

    expect(
      await galley(['mark', '--frame', '$_menu', '--node', '0.1', '--note', 'x', '--by', 'r']),
      0,
    );
    expect('$out', contains('raised on Badge'));
  });

  test('--help is an answer, on the context\'s out', () async {
    expect(await galley(['--help']), 0);
    expect('$out', contains('Available commands:'));
    expect(await galley(['pack', '--help']), 0);
    expect('$out', contains('--test'));
  });

  test('GALLEY_BY stands in for --by', () async {
    await galley(['pack']);
    final code = await runGalley(
      ['--app', dir.path, 'mark', '--frame', '$_home', '--node', '0', '--note', 'x'],
      GalleyContext(
        out: out,
        err: err,
        newId: () => 'mb',
        environment: const {'GALLEY_BY': 'owner'},
      ),
    );
    expect(code, 0, reason: '$err');
    expect(store().mark('mb')!.by, 'owner');
  });
}
