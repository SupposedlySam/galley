import 'package:flutter_test/flutter_test.dart';
import 'package:galley_core/galley_core.dart';
import 'package:galley_web/src/api.dart';
import 'package:galley_web/src/board.dart';
import 'package:galley_web/src/canvas_model.dart';

import 'support.dart';

void main() {
  final home = keyOf('home', pixel7);
  final t = DateTime.utc(2026, 11, 26, 10);
  final answered = Answered(
    Answer.fixed(commit: 'abc1234'),
    by: 'Claude',
    at: t,
  );

  /// A mark raised by Tester in each status, by the events that lead there.
  final byStatus = {
    MarkStatus.open: buttonMark('open', home),
    MarkStatus.answered: buttonMark('answered', home, history: [answered]),
    MarkStatus.verified: buttonMark(
      'verified',
      home,
      history: [
        answered,
        Verified(by: 'Owner', at: t),
      ],
    ),
    MarkStatus.reopened: buttonMark(
      'reopened',
      home,
      history: [
        answered,
        Reopened('still small', by: 'Owner', at: t),
      ],
    ),
    MarkStatus.withdrawn: buttonMark(
      'withdrawn',
      home,
      history: [Withdrawn('duplicate', by: 'Tester', at: t)],
    ),
  };

  test('the marks cover every status', () {
    expect(
      {for (final MapEntry(:key, :value) in byStatus.entries) key: value.status},
      {for (final s in MarkStatus.values) s: s},
    );
  });

  Future<(CanvasModel, FakeGalleyApi)> loaded({String reviewer = 'Owner'}) async {
    final api = FakeGalleyApi(roundsList: [1, 2]);
    final model = CanvasModel(api, reviewer: reviewer, now: () => t);
    await model.load();
    return (model, api);
  }

  group('load', () {
    test('shows the latest round, with its board and every mark', () async {
      final api = FakeGalleyApi(roundsList: [1, 2])..seed(byStatus[MarkStatus.open]!, round: 2);
      final model = CanvasModel(api);
      final states = <CanvasState>[];
      model.addListener(() => states.add(model.state));

      await model.load();

      expect(states.map((s) => s.runtimeType), [Loading, Shown]);
      final shown = model.state as Shown;
      expect(shown.n, 2);
      expect(shown.board.tiles.map((t) => t.frame.record.key), [home]);
      expect(shown.marks.map((m) => m.mark.id), ['open']);
    });

    test('a galley with no rounds says how to make one', () async {
      final model = CanvasModel(FakeGalleyApi(roundsList: const []));
      await model.load();
      expect((model.state as Refused).message, contains('galley pack'));
    });

    test("a refusal is shown in the backend's words", () async {
      final model = CanvasModel(FakeGalleyApi(refuse: const GalleyRefusal(500, 'damaged')));
      await model.load();
      expect((model.state as Refused).message, 'damaged');
    });

    test('a round it cannot read is said so, not shown empty', () async {
      final model = CanvasModel(FakeGalleyApi(files: {'index.json': 'not a manifest'}));
      await model.load();
      expect((model.state as Refused).message, startsWith('The galley sent something'));
    });
  });

  group('offers', () {
    /// What [reviewer] is offered on each status, as `status: [reviews]`.
    Map<MarkStatus, List<Review>> offered(String reviewer) {
      final model = CanvasModel(FakeGalleyApi(), reviewer: reviewer, now: () => t);
      return {
        for (final MapEntry(key: status, value: mark) in byStatus.entries)
          status: [
            for (final r in Review.values)
              if (model.offers(mark, r)) r,
          ],
      };
    }

    test('anyone verifies or reopens an answer, and nothing else', () {
      expect(offered('Owner'), {
        MarkStatus.open: <Review>[],
        MarkStatus.answered: [Review.verify, Review.reopen],
        MarkStatus.verified: <Review>[],
        MarkStatus.reopened: <Review>[],
        MarkStatus.withdrawn: <Review>[],
      });
    });

    test('whoever raised it may also withdraw it, until it is final', () {
      expect(offered('Tester'), {
        MarkStatus.open: [Review.withdraw],
        MarkStatus.answered: [Review.verify, Review.reopen, Review.withdraw],
        MarkStatus.verified: <Review>[],
        MarkStatus.reopened: [Review.withdraw],
        MarkStatus.withdrawn: <Review>[],
      });
    });

    test('nobody is offered anything before they say who they are', () {
      expect(offered('  '), {for (final s in MarkStatus.values) s: <Review>[]});
    });
  });

  group('raise', () {
    test('raises as the reviewer, trimmed, opens its thread and shows it', () async {
      final (model, api) = await loaded(reviewer: '  Owner ');

      final why = await model.raise(
        frame: home,
        node: treeWithButton(pixel7).nodes[1],
        at: (x: 205, y: 326),
        note: 'make it primary',
      );

      expect(why, isNull);
      expect(model.selected, 'm1');
      expect(model.selectedMark?.mark.by, 'Owner');
      expect((model.state as Shown).marks.map((m) => m.mark.id), ['m1']);
    });

    test('asks who is reviewing before raising anything', () async {
      final (model, api) = await loaded(reviewer: '');

      final why = await model.raise(
        frame: home,
        node: treeWithButton(pixel7).nodes[1],
        at: (x: 0, y: 0),
        note: 'x',
      );

      expect(why, startsWith('Say who you are first'));
      expect(api.raised, 0);
      expect(model.selected, isNull);
    });
  });

  group('record', () {
    test(
      'sends the event without a time, which the backend stamps, and shows the result',
      () async {
        final (model, api) = await loaded();
        api.seed(byStatus[MarkStatus.answered]!, round: 2);
        final mark = api.marksById['answered']!.$1;

        expect(await model.record(mark, model.reopened('still small')), isNull);

        // Apart, not as one record: a record compares a map by identity.
        expect(api.recorded.map((r) => r.$1), ['answered']);
        expect(api.recorded.single.$2, {'event': 'reopened', 'by': 'Owner', 'note': 'still small'});
        expect((model.state as Shown).marks.single.mark.status, MarkStatus.reopened);
      },
    );

    test("a refusal comes back in the backend's words, and the marks stay as they were", () async {
      final (model, api) = await loaded();
      api.seed(byStatus[MarkStatus.open]!, round: 2);
      await model.load();
      final before = (model.state as Shown).marks;

      final why = await model.record(before.single.mark, model.verified());

      expect(why, contains('verif'));
      expect((model.state as Shown).marks.single.mark.status, MarkStatus.open);
    });
  });

  group('Shown', () {
    test(
      'draws a mark placed on a widget of this round, and says why it does not draw the rest',
      () async {
        final round = await StoredRound.read(MemoryRoundFiles(roundFiles([home])));
        final m = buttonMark('m', home);
        final anchor = m.anchor;
        final marks = [
          PlacedMark(2, Carried.raised(m)),
          PlacedMark(null, Carried(buttonMark('none', home), const Unplaced('no round'), anchor)),
          PlacedMark(1, Carried(buttonMark('older', home), const Raised(), anchor)),
          PlacedMark(2, Carried(buttonMark('unplaced', home), const Unplaced('no tree'), anchor)),
          PlacedMark(2, Carried(buttonMark('lost', home), Reanchored(Lost(const [])), anchor)),
          PlacedMark(2, Carried(buttonMark('retired', home), const Retired(), anchor)),
        ];
        final shown = Shown(2, round, Board.of(round.frames), marks);

        expect(shown.pinnedOn(home).map((p) => p.mark.id), ['m']);
        expect(shown.pinnedOn(keyOf('other', pixel7)), isEmpty);
        expect(
          {for (final p in marks) p.mark.id: shown.notDrawn(p)},
          {
            'm': null,
            'none': 'not placed in any round yet',
            'older': 'last placed in round 1, not this one',
            'unplaced': 'unplaced: no tree',
            'lost': 'lost: its widget was not found in this round',
            'retired': 'retired: this round has no such frame',
          },
        );
      },
    );
  });
}
