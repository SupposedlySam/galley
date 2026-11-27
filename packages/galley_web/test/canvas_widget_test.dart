import 'package:flutter_test/flutter_test.dart';
import 'package:galley_core/galley_core.dart';
import 'package:galley_web/src/app.dart';
import 'package:galley_web/src/board.dart';
import 'package:galley_web/src/board_view.dart';
import 'package:galley_web/src/canvas_model.dart';
import 'package:galley_web/src/compare.dart';
import 'package:galley_web/src/frame_tile.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

/// Four flows, one frame each: a board 4,776 pixels tall, which fits the 1,000-pixel window
/// at about 20%, well under [BoardViewState.thumbnailBelow].
final _keys = [
  for (final s in ['home', 'coffees', 'brew', 'me']) keyOf(s, pixel7),
];
final _home = _keys.first;

/// The canvas over [api], as [reviewer], in a [window] of 1600 × 1000 unless said, loaded.
Future<CanvasModel> pumpCanvas(
  WidgetTester tester,
  FakeGalley api, {
  String reviewer = 'Owner',
  Size window = const Size(1600, 1000),
}) async {
  tester.view
    ..physicalSize = window
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final model = CanvasModel(api, reviewer: reviewer, now: () => DateTime.utc(2026, 11, 26));
  await tester.pumpWidget(GalleyCanvasApp(model: model));
  await tester.pump();
  expect(model.state, isA<Shown>(), reason: 'the canvas loaded');
  return model;
}

FakeGalley apiOf([List<Mark> marks = const []]) {
  final api = FakeGalley(files: roundFiles(_keys));
  for (final m in marks) {
    api.seed(m);
  }
  return api;
}

BoardViewState boardOf(WidgetTester tester) => tester.state<BoardViewState>(find.byType(BoardView));

List<FrameTile> tiles(WidgetTester tester) =>
    tester.widgetList<FrameTile>(find.byType(FrameTile)).toList();

/// What [finder] finds on the board's frames, not in the side panel.
Finder onTiles(Finder finder) => find.descendant(of: find.byType(FrameTile), matching: finder);

/// Moves the view to [key] at full size, as "Show on board" does.
Future<void> showFrame(WidgetTester tester, FrameKey key) async {
  boardOf(tester).showFrame(key);
  await tester.pump();
}

void main() {
  final t = DateTime.utc(2026, 11, 26, 10);
  final answered = Answered(
    Answer.fixed(commit: 'abc1234'),
    by: 'Claude',
    at: t,
  );

  group('the board, fitted', () {
    testWidgets('draws every frame as a thumbnail, at the zoom it reports', (tester) async {
      await pumpCanvas(tester, apiOf());

      final board = boardOf(tester);
      final drawn = tiles(tester);
      // The fit: 0.95 of the board's height in the window (its width fits with room).
      expect(board.scale, closeTo(1000 / 4776 * 0.95, 1e-9));
      expect(drawn.map((t) => t.tile.frame.record.key), _keys, reason: 'every frame is in view');
      expect(drawn.map((t) => (t.scale, t.thumbnail)), [
        for (final _ in _keys) (board.scale, true),
      ]);
    });

    testWidgets("names each flow 14 pixels tall on screen, its label's bottom on its line", (
      tester,
    ) async {
      await pumpCanvas(tester, apiOf());
      final scale = boardOf(tester).scale;

      for (final (i, flow) in ['home', 'coffees', 'brew', 'me'].indexed) {
        final label = tester.widget<Text>(find.text(flow));
        expect(label.style!.fontSize! * scale, closeTo(14, 1e-9), reason: flow);
        // Its row's line, on screen: where the row's tiles start, less the column label.
        final tile = find.byType(FrameTile).at(i);
        final tilesTop = tester.getTopLeft(tile).dy;
        final line = tilesTop - Board.columnLabel * scale;
        expect(tester.getBottomLeft(find.text(flow)).dy, closeTo(line, 1), reason: flow);
      }
    });
  });

  testWidgets('a frame shown on the board is at full size, and no longer a thumbnail', (
    tester,
  ) async {
    await pumpCanvas(tester, apiOf());

    await showFrame(tester, _keys[2]);

    expect(boardOf(tester).scale, 1.0, reason: '952 of the 914 pixels fit, so it is not enlarged');
    final shown = tiles(tester).singleWhere((t) => t.tile.frame.record.key == _keys[2]);
    expect((shown.scale, shown.thumbnail), (1.0, false));
  });

  group("a frame's caption and badge", () {
    testWidgets('count the marks still waiting on someone, in red', (tester) async {
      await pumpCanvas(
        tester,
        apiOf([
          buttonMark('open', _home),
          buttonMark('answered', _home, history: [answered]),
          buttonMark(
            'done',
            _home,
            history: [
              answered,
              Verified(by: 'Owner', at: t),
            ],
          ),
        ]),
      );
      final caption = find.ancestor(of: find.text('2'), matching: find.byType(Tooltip));

      expect(tester.widget<Tooltip>(caption).message, '2 waiting, 1 closed');
      expect(onTiles(find.byIcon(Icons.circle)), findsOneWidget);
      expect(find.text('2 waiting'), findsOneWidget, reason: 'the thumbnail badge');
    });

    testWidgets('show closed marks apart, and no badge, when nothing waits', (tester) async {
      await pumpCanvas(
        tester,
        apiOf([
          buttonMark(
            'done',
            _home,
            history: [
              answered,
              Verified(by: 'Owner', at: t),
            ],
          ),
          buttonMark(
            'gone',
            _home,
            history: [Withdrawn('dupe', by: 'Tester', at: t)],
          ),
        ]),
      );

      final caption = find.ancestor(of: find.text('2'), matching: find.byType(Tooltip));
      expect(tester.widget<Tooltip>(caption).message, '0 waiting, 2 closed');
      expect(onTiles(find.byIcon(Icons.check_circle_outline)), findsOneWidget);
      expect(onTiles(find.byIcon(Icons.circle)), findsNothing);
      expect(find.byIcon(Icons.circle), findsNWidgets(2), reason: 'the list still shows both');
      expect(find.textContaining('waiting'), findsNothing, reason: 'no badge');
    });

    // On the badge's size, not where it is drawn: the test font's glyphs are each a full em
    // wide, so its text wraps inside the frame capped or not, and a width check passed both.
    double badgeSize(WidgetTester tester) =>
        tester.widget<Text>(find.text('1 waiting')).style!.fontSize!;

    testWidgets('draw the badge 14 pixels tall on screen while that fits its frame', (
      tester,
    ) async {
      // A window that shows a frame at 30%: (48 + 0.3 × 914) pixels tall.
      await pumpCanvas(
        tester,
        apiOf([buttonMark('open', _home)]),
        window: const Size(1600, 48 + 0.3 * 914),
      );
      await showFrame(tester, _home);

      final shown = tiles(tester).singleWhere((t) => t.tile.frame.record.key == _home);
      expect(boardOf(tester).scale, closeTo(0.3, 1e-9));
      expect(shown.thumbnail, isTrue);
      expect(badgeSize(tester) * 0.3, closeTo(14, 1e-9));
    });

    testWidgets('cap the badge at a sixth of its frame when 14 pixels would not fit', (
      tester,
    ) async {
      await pumpCanvas(tester, apiOf([buttonMark('open', _home)]));

      expect(14 / boardOf(tester).scale, greaterThan(411 / 6), reason: 'the cap applies here');
      expect(badgeSize(tester), 411 / 6);
    });
  });

  testWidgets('a click on a frame offers every widget under it, deepest first, and raises', (
    tester,
  ) async {
    final api = apiOf();
    final model = await pumpCanvas(tester, api);
    await showFrame(tester, _home);

    // The button's middle: the screen is inside the tile's caption and bezel, at 100%.
    final tile = tester.getTopLeft(find.byType(FrameTile).first);
    await tester.tapAt(tile + const Offset(Board.bezel + 205, Board.tileLabel + Board.bezel + 326));
    await tester.pump();

    final radios = tester.widgetList<RadioListTile<WidgetNode>>(
      find.byType(RadioListTile<WidgetNode>),
    );
    expect(radios.map((r) => r.value.type), ['FilledButton', 'App']);

    await tester.enterText(
      find.widgetWithText(TextField, 'What is wrong, or what should change'),
      'make it primary',
    );
    await tester.tap(find.text('Raise as Owner'));
    await tester.pump();
    await tester.pump();

    final raised = api.marksById.values.single.$1;
    expect(
      (raised.anchor.type, raised.note, raised.by),
      ('FilledButton', 'make it primary', 'Owner'),
    );
    expect(model.selected, raised.id, reason: 'its thread is open');
  });

  group('a thread', () {
    Future<FakeGalley> openThread(WidgetTester tester, Mark mark, {String as = 'Owner'}) async {
      final api = apiOf([mark]);
      await pumpCanvas(tester, api, reviewer: as);
      await tester.tap(find.text(mark.note));
      await tester.pump();
      return api;
    }

    List<String> buttons(WidgetTester tester) => [
      for (final label in ['Looks right', 'Not yet', 'Withdraw'])
        // An ancestor of any button type: `find.byType` matches the exact type only.
        if (find
            .ancestor(
              of: find.text(label),
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            )
            .evaluate()
            .isNotEmpty)
          label,
    ];

    testWidgets('of an answer offers its verifying or reopening', (tester) async {
      await openThread(tester, buttonMark('a', _home, history: [answered]));
      expect(buttons(tester), ['Looks right', 'Not yet']);
    });

    testWidgets("of one's own open mark offers only its withdrawal", (tester) async {
      await openThread(tester, buttonMark('a', _home, by: 'Owner'));
      expect(buttons(tester), ['Withdraw']);
    });

    testWidgets('of a mark waiting on the app offers nothing, and says so', (tester) async {
      await openThread(tester, buttonMark('a', _home));
      expect(buttons(tester), isEmpty);
      expect(find.textContaining('galley answer a'), findsOneWidget);
    });

    testWidgets('refuses a reopen with no note, sending nothing, and records one with', (
      tester,
    ) async {
      final api = await openThread(tester, buttonMark('a', _home, history: [answered]));

      await tester.tap(find.text('Not yet'));
      await tester.pump();
      expect(find.text('a reopen must say what is still wrong'), findsOneWidget);
      expect(api.recorded, isEmpty);

      await tester.enterText(
        find.widgetWithText(TextField, 'What is still wrong (for Not yet), or why you withdraw it'),
        'still small',
      );
      await tester.tap(find.text('Not yet'));
      await tester.pump();
      await tester.pump();

      expect(api.recorded.map((r) => r.$2['note']), ['still small']);
      expect(api.marksById['a']!.$1.status, MarkStatus.reopened);
      expect(find.text('reopened'), findsWidgets);
    });
  });

  group('what waits on the reviewer', () {
    List<String> images(WidgetTester tester) => [
      for (final i in tester.widgetList<Image>(
        find.descendant(of: find.byType(Compare), matching: find.byType(Image)),
      ))
        (i.image as NetworkImage).url,
    ];

    Future<CanvasModel> openQueued(
      WidgetTester tester,
      FakeGalley api, {
      void Function()? before,
    }) async {
      final model = await pumpCanvas(tester, api, reviewer: 'Tester');
      before?.call();
      await tester.tap(find.byKey(const ValueKey('queue a')));
      await tester.pump();
      await tester.pump();
      return model;
    }

    testWidgets('is their answered marks, apart from the rest, each one tap from its thread', (
      tester,
    ) async {
      final api = apiOf([
        buttonMark('a', _home, history: [answered]),
        buttonMark('b', _home),
        buttonMark('c', _home, by: 'Sam', history: [answered]),
      ]);
      final model = await openQueued(
        tester,
        api,
        before: () {
          expect(find.text('1 answer waits on you'), findsOneWidget);
          expect(find.byKey(const ValueKey('queue c')), findsNothing, reason: "Sam's");
          expect(find.text('Every mark'), findsOneWidget);
          expect(find.text('Claude: fixed in abc1234'), findsOneWidget);
        },
      );
      expect(model.selected, 'a');
      expect(find.byType(Compare), findsOneWidget);
    });

    testWidgets('shows nothing above the list when nothing waits', (tester) async {
      await pumpCanvas(tester, apiOf([buttonMark('a', _home)]), reviewer: 'Tester');
      expect(find.textContaining('on you'), findsNothing);
      expect(find.text('Every mark'), findsNothing);
      expect(find.text('make it primary'), findsOneWidget, reason: 'the mark is listed');
    });

    testWidgets('names a commit short in the queue, so the note shows, and whole in the thread', (
      tester,
    ) async {
      // Seen in a browser: a whole commit took the queue's two lines and cut the note off.
      const commit = 'e01c053f7fe6896982f6792f6f54f4425fbe77df';
      final api = apiOf([
        buttonMark(
          'a',
          _home,
          history: [
            Answered(
              Answer.fixed(commit: commit, note: 'Padding raised to 16'),
              by: 'Claude',
              at: t,
            ),
          ],
        ),
      ]);
      await openQueued(
        tester,
        api,
        before: () =>
            expect(find.text('Claude: fixed in e01c053 · Padding raised to 16'), findsOneWidget),
      );
      expect(find.text('Claude answered: fixed in $commit'), findsOneWidget);
      expect(find.textContaining('fixed in e01c053 '), findsNothing, reason: 'the thread');
    });

    testWidgets('compares the widget in the round it was raised on with the round shown', (
      tester,
    ) async {
      final api = FakeGalley(
        roundsList: [1, 2],
        files: roundFiles(_keys, images: true),
        byRound: {1: roundFiles(_keys.reversed.toList(), images: true)},
      )..seed(buttonMark('a', _home, history: [answered]), round: 2, raisedOn: 1);
      await openQueued(tester, api);
      expect(find.text('As you marked it, round 1'), findsOneWidget);
      expect(find.text('Now, round 2'), findsOneWidget);
      // Home is the last frame of round 1 and the first of round 2: each side reads its own.
      expect(images(tester), [
        'http://galley.test/api/rounds/1/frames/3.png',
        'http://galley.test/api/rounds/2/frames/0.png',
      ]);
    });

    testWidgets('says what it cannot show: no image, or no record of the round raised on', (
      tester,
    ) async {
      final api = apiOf([
        buttonMark('a', _home, history: [answered]),
      ]);
      api.raisedIn['a'] = null;
      await openQueued(tester, api);
      expect(find.text('As you marked it'), findsOneWidget);
      expect(find.textContaining('is not recorded'), findsOneWidget);
      expect(find.text('Now, round 1'), findsOneWidget);
      expect(find.text('no image was captured of this frame'), findsOneWidget);
      expect(images(tester), isEmpty);
    });
  });

  group('since your last visit', () {
    String digest(String c) => c * 64;
    final coffees = _keys[1];
    final away = keyOf('away', pixel7);

    /// Round 1 has home, coffees and away; round 2 has every [_keys] frame, coffees changed.
    FakeGalley visited() => FakeGalley(
      roundsList: [1, 2],
      byRound: {
        1: roundFiles(
          [_home, coffees, away],
          pixels: {_home: digest('a'), coffees: digest('b'), away: digest('c')},
        ),
        2: roundFiles(_keys, pixels: {for (final k in _keys) k: digest(k == coffees ? 'e' : 'a')}),
      },
    )..visits['Tester'] = Visit(1);

    testWidgets('lists the frames to look at again, counts the rest, and says so on the board', (
      tester,
    ) async {
      final api = visited();
      await pumpCanvas(tester, api, reviewer: 'Tester');
      await tester.pump();
      expect(api.opens, [(2, 'Tester')]);
      expect(find.text('Since your last visit, round 1'), findsOneWidget);
      expect(find.text('1 changed · 2 new · 1 gone · 0 not compared · 1 the same'), findsOneWidget);
      final listed = [
        for (final t in tester.widgetList<ListTile>(
          find.descendant(of: find.byKey(const ValueKey('since')), matching: find.byType(ListTile)),
        ))
          ((t.title! as Text).data, (t.subtitle! as Text).data, t.onTap != null),
      ];
      expect(listed, [
        ('coffees · base · pixel-7', 'changed', true),
        ('brew · base · pixel-7', 'new', true),
        ('me · base · pixel-7', 'new', true),
        ('away · base · pixel-7', 'gone: not in this round', false),
      ]);
      expect(onTiles(find.text('changed')), findsOneWidget);
      expect(onTiles(find.text('new')), findsNWidgets(2));
      expect(find.byKey(ValueKey('since $_home')), findsNothing, reason: 'the same says nothing');

      await tester.tap(find.text('coffees · base · pixel-7'));
      await tester.pump();
      expect(boardOf(tester).scale, closeTo(1, 0.01), reason: 'shown at full size');
    });

    testWidgets('a first visit says so, and a typed name is recorded on Enter, not as typed', (
      tester,
    ) async {
      final api = visited()..visits.clear();
      await pumpCanvas(tester, api, reviewer: '');
      expect(find.textContaining('press Enter'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Reviewing as'), 'Tes');
      await tester.enterText(find.widgetWithText(TextField, 'Reviewing as'), 'Tester');
      await tester.pump();
      expect(api.opens, isEmpty, reason: 'no visit for a name half typed');

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(api.opens, [(2, 'Tester')]);
      expect(find.text('Your first visit: every frame is new to you.'), findsOneWidget);
      expect(
        onTiles(find.text('new')),
        findsNothing,
        reason: 'no frame is badged on a first visit',
      );
    });

    testWidgets('that is not known says why, and shows no frame as changed or the same', (
      tester,
    ) async {
      final api = visited()..refuseOpened = const Refused.environment('connection refused');
      await pumpCanvas(tester, api, reviewer: 'Tester');
      await tester.pump();
      expect(
        find.text('Not known: connection refused. No frame is shown as changed or the same.'),
        findsOneWidget,
      );
      expect(onTiles(find.text('changed')), findsNothing);
    });
  });

  group('a mark that does not read', () {
    const why = 'u7, who wrote to mark m9, is not a member';

    testWidgets('is listed with why, apart from the marks, and counted', (tester) async {
      final api = apiOf([
        buttonMark('a', _home, history: [answered]),
        buttonMark('b', _home),
      ])..damaged.addAll([const DamagedMark('m9', why), const DamagedMark('m10', 'no frame')]);
      await pumpCanvas(tester, api, reviewer: 'Tester');
      expect(find.text('Round 1 · 4 frames · 2 marks · 2 that do not read'), findsOneWidget);
      expect(find.text('2 marks do not read'), findsOneWidget);
      expect(
        [
          for (final d in ['m9', 'm10']) tester.getTopLeft(find.byKey(ValueKey('damaged $d'))).dy,
        ],
        everyElement(
          allOf(
            greaterThan(tester.getTopLeft(find.byKey(const ValueKey('queue a'))).dy),
            lessThan(tester.getTopLeft(find.text('Every mark')).dy),
          ),
        ),
        reason: 'after what waits on the reviewer, before every mark',
      );
      expect(find.text(why), findsOneWidget);
      expect(find.text('no frame'), findsOneWidget);
      expect(find.byKey(const ValueKey('a')), findsOneWidget, reason: 'the marks still listed');
      expect(find.byKey(const ValueKey('b')), findsOneWidget);
    });

    testWidgets('alone, is not "no marks yet", and heads the list without a queue', (tester) async {
      final api = apiOf()..damaged.add(const DamagedMark('m9', why));
      await pumpCanvas(tester, api, reviewer: 'Tester');
      expect(find.textContaining('No marks yet'), findsNothing);
      expect(find.text('1 mark does not read'), findsOneWidget);
      expect(find.text(why), findsOneWidget);
      expect(find.textContaining('on you'), findsNothing);
      expect(find.text('Round 1 · 4 frames · 0 marks · 1 that does not read'), findsOneWidget);
    });

    testWidgets('with marks and nothing waiting, still sets the marks apart under a heading', (
      tester,
    ) async {
      final api = apiOf([buttonMark('b', _home)])..damaged.add(const DamagedMark('m9', why));
      await pumpCanvas(tester, api, reviewer: 'Tester');
      expect(find.textContaining('on you'), findsNothing, reason: 'no queue');
      expect(
        tester.getTopLeft(find.text('Every mark')).dy,
        greaterThan(tester.getTopLeft(find.byKey(const ValueKey('damaged m9'))).dy),
      );
      expect(find.byKey(const ValueKey('b')), findsOneWidget);
    });

    testWidgets('none: no heading, and the count says nothing of them', (tester) async {
      await pumpCanvas(tester, apiOf([buttonMark('b', _home)]), reviewer: 'Tester');
      expect(find.textContaining('not read'), findsNothing);
      expect(find.text('Every mark'), findsNothing, reason: 'nothing above the marks to part');
      expect(find.byKey(const ValueKey('b')), findsOneWidget);
      expect(find.text('Round 1 · 4 frames · 1 mark'), findsOneWidget);
    });
  });

  group('cropAround', () {
    const frame = (width: 400.0, height: 800.0);
    List<double> of(LogicalRect r) => [r.left, r.top, r.width, r.height];

    test('is the box and a margin on every side', () {
      expect(of(cropAround(const LogicalRect(100, 200, 50, 20), frame)), [76, 176, 98, 68]);
    });

    test('stops at the edges of the frame', () {
      expect(of(cropAround(const LogicalRect(10, 790, 380, 10), frame)), [0, 766, 400, 34]);
    });

    test('is the frame for a box larger than it', () {
      expect(of(cropAround(const LogicalRect(-10, -10, 500, 900), frame)), [0, 0, 400, 800]);
    });
  });
}
