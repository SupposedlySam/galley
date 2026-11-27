import 'package:flutter_test/flutter_test.dart';
import 'package:galley_core/galley_core.dart';
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

  Future<(CanvasModel, FakeGalley)> loaded({String reviewer = 'Owner'}) async {
    final api = FakeGalley(roundsList: [1, 2]);
    final model = CanvasModel(api, reviewer: reviewer, now: () => t);
    await model.load();
    return (model, api);
  }

  group('load', () {
    test('shows the latest round, with its board and every mark', () async {
      final api = FakeGalley(roundsList: [1, 2])..seed(byStatus[MarkStatus.open]!, round: 2);
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
      final model = CanvasModel(FakeGalley(roundsList: const []));
      await model.load();
      expect((model.state as Unavailable).message, contains('galley pack'));
    });

    test("a refusal is shown in the backend's words", () async {
      final model = CanvasModel(FakeGalley(refuse: const Refused.damaged('damaged')));
      await model.load();
      expect((model.state as Unavailable).message, 'damaged');
    });

    test('a round it cannot read is said so, not shown empty', () async {
      final model = CanvasModel(FakeGalley(files: {'index.json': 'not a manifest'}));
      await model.load();
      expect((model.state as Unavailable).message, startsWith('The galley sent something'));
    });
  });

  group('offers', () {
    /// What [reviewer] is offered on each status, as `status: [reviews]`.
    Map<MarkStatus, List<Review>> offered(String reviewer) {
      final model = CanvasModel(FakeGalley(), reviewer: reviewer, now: () => t);
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
          PlacedMark(2, Carried.raised(m), raisedIn: 2),
          PlacedMark(
            null,
            Carried(buttonMark('none', home), const Unplaced('no round'), anchor),
            raisedIn: 1,
          ),
          PlacedMark(1, Carried(buttonMark('older', home), const Raised(), anchor), raisedIn: 1),
          PlacedMark(
            2,
            Carried(buttonMark('unplaced', home), const Unplaced('no tree'), anchor),
            raisedIn: 1,
          ),
          PlacedMark(
            2,
            Carried(buttonMark('lost', home), Reanchored(Lost(const [])), anchor),
            raisedIn: 1,
          ),
          PlacedMark(2, Carried(buttonMark('retired', home), const Retired(), anchor), raisedIn: 1),
        ];
        final shown = Shown(2, round, Board.of(round.frames), GalleyMarks(marks));

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

  group('the queue', () {
    Answered answeredAt(int hour) => Answered(
      Answer.wontFix(note: 'by design'),
      by: 'Claude',
      at: DateTime.utc(2026, 11, 26, hour),
    );

    // Rae's marks in each status, two of them answered at different times, and an answered
    // mark of someone else's.
    Future<(CanvasModel, FakeGalley)> population({String reviewer = 'Rae'}) async {
      final (model, api) = await loaded(reviewer: reviewer);
      for (final m in [
        buttonMark('later', home, by: 'Rae', history: [answeredAt(11)]),
        buttonMark('earlier', home, by: 'Rae', history: [answeredAt(10)]),
        buttonMark('theirs', home, by: 'Sam', history: [answeredAt(9)]),
        buttonMark('open', home, by: 'Rae'),
        buttonMark(
          'done',
          home,
          by: 'Rae',
          history: [
            answeredAt(8),
            Verified(by: 'Rae', at: t),
          ],
        ),
        // Hand-written, naming nobody: the core refuses to raise one, not to read one.
        buttonMark('nobody', home, by: '', history: [answeredAt(7)]),
      ]) {
        api.seed(m, round: 2);
      }
      await model.load();
      return (model, api);
    }

    List<String> ids(CanvasModel model) => [for (final m in model.queue) m.mark.id];

    test("is the reviewer's own answered marks, the longest waiting first", () async {
      final (model, _) = await population();
      expect(ids(model), ['earlier', 'later']);
      expect((model.state as Shown).marks, hasLength(6), reason: 'of six marks');
    });

    test(
      'is empty for someone who has said nothing yet, or whose marks are not answered',
      () async {
        expect(ids((await population(reviewer: '')).$1), isEmpty);
        expect(ids((await population(reviewer: 'Sam')).$1), ['theirs'], reason: 'the control');
        expect(ids((await population(reviewer: 'Owner')).$1), isEmpty);
      },
    );

    test('a mark taken from it opens the next, and the last opens the list', () async {
      final (model, _) = await population();
      final queue = model.queue;
      model.select('earlier');
      expect(await model.record(queue.first.mark, model.verified()), isNull);
      expect(
        [model.selected, ...ids(model)],
        ['later', 'later'],
        reason: 'selected, then the queue',
      );

      expect(await model.record(queue.last.mark, model.reopened('still tight')), isNull);
      expect([model.selected, ...ids(model)], [null], reason: 'nothing selected, and no queue');
    });

    test('a mark not in it leaves the thread open', () async {
      final (model, _) = await population(reviewer: 'Sam');
      final rae = (model.state as Shown).marks.firstWhere((m) => m.mark.id == 'later');
      model.select('later');
      expect(await model.record(rae.mark, model.verified()), isNull);
      expect(
        [model.selected, ...ids(model)],
        ['later', 'theirs'],
        reason: 'selected, then the queue',
      );
    });
  });

  group('before', () {
    final other = keyOf('other', pixel7);

    Future<(CanvasModel, FakeGalley)> galley() async {
      final api = FakeGalley(
        roundsList: [1, 2],
        files: roundFiles([home]),
        byRound: {
          1: roundFiles([home, other], images: true),
        },
      );
      final model = CanvasModel(api, reviewer: 'Rae', now: () => t);
      await model.load();
      return (model, api);
    }

    PlacedMark placed(String id, {required int? raisedIn, FrameKey? on}) =>
        PlacedMark(2, Carried.raised(buttonMark(id, on ?? home)), raisedIn: raisedIn);

    test('is the frame in the round it was raised on, each round read once', () async {
      final (model, api) = await galley();
      expect(api.roundReads, [2], reason: 'the load');

      final a = await model.before(placed('a', raisedIn: 1));
      final b = await model.before(placed('b', raisedIn: 1, on: other));
      expect([a, b].map((x) => ((x as BeforeIn).n, x.record.key, x.record.image)), [
        (1, home, 'frames/0.png'),
        (1, other, 'frames/1.png'),
      ]);
      expect(api.roundReads, [2, 1]);

      final shown = await model.before(placed('c', raisedIn: 2));
      expect(((shown as BeforeIn).n, shown.record.image), (2, null));
      expect(api.roundReads, [2, 1], reason: 'the round shown is not read again');
    });

    test('says why when it cannot be shown, and reads a refused round again', () async {
      final (model, api) = await galley();
      String? why(Before b) => switch (b) {
        BeforeUnknown(:final why) => why,
        BeforeIn() => null,
      };

      expect(why(await model.before(placed('a', raisedIn: null))), contains('not recorded'));
      expect(why(await model.before(placed('a', raisedIn: 2, on: other))), contains('no frame'));

      api.refuseRound[1] = const Refused.environment('connection refused');
      expect(why(await model.before(placed('a', raisedIn: 1))), contains('connection refused'));
      api.refuseRound.clear();
      expect(await model.before(placed('a', raisedIn: 1)), isA<BeforeIn>());
      expect(api.roundReads, [2, 1, 1]);
    });
  });
}
