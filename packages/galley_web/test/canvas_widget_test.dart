import 'package:flutter_test/flutter_test.dart';
import 'package:galley_core/galley_core.dart';
import 'package:galley_web/src/app.dart';
import 'package:galley_web/src/board.dart';
import 'package:galley_web/src/board_view.dart';
import 'package:galley_web/src/canvas_model.dart';
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
      for (final label in ['Verify', 'Reopen', 'Withdraw'])
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
      expect(buttons(tester), ['Verify', 'Reopen']);
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

      await tester.tap(find.text('Reopen'));
      await tester.pump();
      expect(find.text('a reopen must say what is still wrong'), findsOneWidget);
      expect(api.recorded, isEmpty);

      await tester.enterText(
        find.widgetWithText(TextField, 'Why (for a reopen or a withdrawal)'),
        'still small',
      );
      await tester.tap(find.text('Reopen'));
      await tester.pump();
      await tester.pump();

      expect(api.recorded.map((r) => r.$2['note']), ['still small']);
      expect(api.marksById['a']!.$1.status, MarkStatus.reopened);
      expect(find.text('reopened'), findsWidgets);
    });
  });
}
