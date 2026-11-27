import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

import 'rounds.dart';
import 'trees.dart';

final _home = FrameKey({'screen': 'home', 'device': 'pixel-7'});
final _menu = FrameKey({'screen': 'menu', 'device': 'pixel-7'});
final _cart = FrameKey({'screen': 'cart', 'device': 'pixel-7'});
final _gone = FrameKey({'screen': 'promo', 'device': 'pixel-7'});

Located _located(Carried c) => (c.placement as Reanchored).result as Located;

void main() {
  group('carry', () {
    test('a widget where it was is Exact, and the mark keeps its pin and history', () {
      final answered = Answered(
        Answer.question(note: 'which edge?'),
        by: 'claude',
        at: DateTime.utc(2026, 11, 26, 1),
      );
      final mark = markOn('m1', _home, history: [answered]);
      final round = Round([RoundFrame(frameRecord(_home), withBuy(buyRect))]);

      final carried = round.carry(Carried.raised(mark));

      expect(_located(carried).isExact, isTrue);
      expect(_located(carried).decidedBy, Evidence.key);
      expect(carried.mark, same(mark), reason: 'the mark itself is never rewritten');
      expect(carried.mark.status, MarkStatus.answered);
    });

    test('a widget found elsewhere is Moved, and its new box is the anchor from now on', () {
      final round2 = Round([
        RoundFrame(frameRecord(_home), withBuy(const LogicalRect(10, 300, 100, 40))),
      ]);
      final moved = round2.carry(Carried.raised(markOn('m1', _home)));
      expect(_located(moved).isExact, isFalse);
      expect(moved.anchor.rect, const LogicalRect(10, 300, 100, 40));
      expect(moved.anchor.key, 'buy');

      // The next round compares with where it was last seen, not where it was raised: the same
      // place again is Exact. Re-anchoring from the raised box would call it Moved forever.
      final again = round2.carry(moved);
      expect(_located(again).isExact, isTrue);
      expect(again.mark.anchor.rect, buyRect, reason: 'the anchor as raised is kept on the mark');
    });

    test('a widget that is gone is Lost, and the last anchor is kept for the next round', () {
      final moved = Round([
        RoundFrame(frameRecord(_home), withBuy(const LogicalRect(10, 300, 100, 40))),
      ]).carry(Carried.raised(markOn('m1', _home)));
      final lost = Round([
        RoundFrame(
          frameRecord(_home),
          tree([
            root,
            node([0], 'Text'),
          ]),
        ),
      ]).carry(moved);

      expect((lost.placement as Reanchored).result, isA<Lost>());
      expect(lost.anchor, same(moved.anchor));
    });

    test('a frame missing from the round retires the mark, which returns with its frame', () {
      final raised = Carried.raised(markOn('m1', _gone));
      final retired = Round([RoundFrame(frameRecord(_home), withBuy(buyRect))]).carry(raised);
      expect(retired.placement, isA<Retired>());
      expect(retired.anchor, same(raised.anchor));

      final back = Round([RoundFrame(frameRecord(_gone), withBuy(buyRect))]).carry(retired);
      expect(_located(back).isExact, isTrue);
    });

    test('a mark not placed this round keeps the anchor it was last found at, not as raised', () {
      const below = LogicalRect(10, 300, 100, 40);
      final moved = Round([RoundFrame(frameRecord(_home), withBuy(below))])
          .carry(Carried.raised(markOn('m1', _home)));
      expect(moved.anchor.rect, below, reason: 'the positive control: it did move');

      final notPlaced = [
        Round([RoundFrame(frameRecord(_menu), withBuy(buyRect))]),
        Round([
          RoundFrame(frameRecord(_home, status: FrameStatus.error, errors: ['threw']), null),
        ]),
        Round([RoundFrame(frameRecord(_home), null)]),
      ];
      for (final round in notPlaced) {
        final kept = round.carry(moved);
        expect(kept.placement, isNot(isA<Reanchored>()));
        expect(kept.anchor.rect, below, reason: '${kept.placement.runtimeType}');
      }
    });

    test('an error frame is Unplaced, never Lost, though its tree would place it', () {
      // The positive control: the same tree in a rendered frame does place the mark.
      final ok = Round([RoundFrame(frameRecord(_home), withBuy(buyRect))]);
      expect(_located(ok.carry(Carried.raised(markOn('m1', _home)))).isExact, isTrue);

      final errored = Round([
        RoundFrame(
          frameRecord(_home, status: FrameStatus.error, errors: ['landed on /login']),
          withBuy(buyRect),
        ),
      ]).carry(Carried.raised(markOn('m1', _home)));
      final unplaced = errored.placement as Unplaced;
      expect(unplaced.reason, contains('landed on /login'));
      expect(errored.anchor, same(errored.mark.anchor));
    });

    test('a frozen frame is placed: its picture and tree are real', () {
      final round = Round([
        RoundFrame(frameRecord(_home, status: FrameStatus.frozen), withBuy(buyRect)),
      ]);
      expect(_located(round.carry(Carried.raised(markOn('m1', _home)))).isExact, isTrue);
    });

    test('a frame with no tree is Unplaced, and says whether it was recorded or not read', () {
      final none = Round([RoundFrame(frameRecord(_home, tree: null), null)]);
      expect(
        (none.carry(Carried.raised(markOn('m1', _home))).placement as Unplaced).reason,
        contains('no tree was recorded'),
      );
      final unread = Round([RoundFrame(frameRecord(_home), null)]);
      expect(
        (unread.carry(Carried.raised(markOn('m1', _home))).placement as Unplaced).reason,
        contains('trees/x.json was not read'),
      );
    });
  });

  test('every mark is carried, once, in order, each to its own outcome', () {
    final round = Round([
      RoundFrame(frameRecord(_home), withBuy(buyRect)),
      RoundFrame(frameRecord(_menu), withBuy(const LogicalRect(200, 500, 100, 40))),
      RoundFrame(frameRecord(_cart), tree([root])),
      RoundFrame(
        frameRecord(
          FrameKey({'screen': 'pay', 'device': 'pixel-7'}),
          status: FrameStatus.error,
          errors: ['threw'],
        ),
        null,
      ),
    ]);
    final marks = [
      markOn('exact', _home),
      markOn('moved', _menu),
      markOn('lost', _cart),
      markOn('unplaced', FrameKey({'screen': 'pay', 'device': 'pixel-7'})),
      markOn('retired', _gone),
      markOn(
        'verified',
        _home,
        history: [
          Answered(
            Answer.fixed(commit: 'abc1234'),
            by: 'claude',
            at: DateTime.utc(2026, 11, 26, 1),
          ),
          Verified(by: 'reviewer', at: DateTime.utc(2026, 11, 26, 2)),
        ],
      ),
    ];

    final carried = round.carryAll([for (final m in marks) Carried.raised(m)]);

    expect([for (final c in carried) c.mark.id], [for (final m in marks) m.id]);
    String outcome(Carried c) => switch (c.placement) {
      Reanchored(result: Located(isExact: true)) => 'exact',
      Reanchored(result: Located()) => 'moved',
      Reanchored(result: Lost()) => 'lost',
      Unplaced() => 'unplaced',
      Retired() => 'retired',
      Raised() => 'raised',
    };
    expect(carried.map(outcome), ['exact', 'moved', 'lost', 'unplaced', 'retired', 'exact']);
    expect(carried.last.mark.status, MarkStatus.verified, reason: 'a verified mark still carries');
  });

  test('a newly raised mark is Raised, at its own anchor', () {
    final mark = markOn('m1', _home);
    final raised = Carried.raised(mark);
    expect(raised.placement, isA<Raised>());
    expect(raised.anchor, same(mark.anchor));
  });

  group('Round', () {
    test('refuses two frames with one key', () {
      expect(
        () => Round([
          RoundFrame(frameRecord(_home), withBuy(buyRect)),
          RoundFrame(frameRecord(_home), withBuy(buyRect)),
        ]),
        throwsArgumentError,
      );
    });

    test('refuses a tree for a record that says none was recorded', () {
      expect(
        () => RoundFrame(frameRecord(_home, tree: null), withBuy(buyRect)),
        throwsArgumentError,
      );
    });
  });

  group('Carried JSON', () {
    // One of every placement, from a real carry, so the JSON is tested on what carry makes.
    List<Carried> everyPlacement() {
      final round = Round([
        RoundFrame(frameRecord(_home), withBuy(buyRect)),
        RoundFrame(frameRecord(_menu), withBuy(const LogicalRect(200, 500, 100, 40))),
        RoundFrame(
          frameRecord(_cart),
          tree([
            root,
            node([0], 'Text', label: 'Buy'),
            node([1], 'Text', label: 'Buy'),
          ]),
        ),
        RoundFrame(frameRecord(_gone, status: FrameStatus.error, errors: ['threw']), null),
      ]);
      final cartMark = Mark(
        id: 'lost',
        frame: _cart,
        anchor: Anchor(type: 'Text', indexPath: [2], rect: buyRect, semanticsLabel: 'Buy'),
        pin: const PinOffset(0, 0),
        note: 'n',
        by: 'r',
        at: DateTime.utc(2026),
      );
      return [
        Carried.raised(markOn('raised', _home)),
        ...round.carryAll([
          Carried.raised(markOn('exact', _home)),
          Carried.raised(markOn('moved', _menu)),
          Carried.raised(cartMark),
          Carried.raised(markOn('unplaced', _gone)),
          Carried.raised(markOn('retired', FrameKey({'screen': 'x'}))),
        ]),
      ];
    }

    test('each placement has the word a person reads, one per kind', () {
      expect(
        [for (final c in everyPlacement()) (c.mark.id, c.placement.name)],
        [
          ('raised', 'raised'),
          ('exact', 'exact'),
          ('moved', 'moved'),
          ('lost', 'lost'),
          ('unplaced', 'unplaced'),
          ('retired', 'retired'),
        ],
      );
    });

    test('a pin is drawn where the widget is in this round, and only when it is on one', () {
      final pins = {for (final c in everyPlacement()) c.mark.id: c.pin};
      // Every placement, so a pin that a Lost, Unplaced or Retired mark claims is seen, and so is
      // a Moved mark drawn where it was raised rather than where it was found.
      expect(pins, {
        'raised': (60.0, 30.0),
        'exact': (60.0, 30.0),
        'moved': (250.0, 520.0),
        'lost': null,
        'unplaced': null,
        'retired': null,
      });
      expect(everyPlacement()[2].box, const LogicalRect(200, 500, 100, 40));
      // Off centre, so the mark's own offset is seen to be used: every mark above is at 0.5, 0.5.
      final corner = Mark(
        id: 'c',
        frame: _home,
        anchor: Anchor.of(withBuy(buyRect).nodes[1]),
        pin: const PinOffset(0.25, 1),
        note: 'n',
        by: 'r',
        at: DateTime.utc(2026),
      );
      expect(Carried.raised(corner).pin, (35.0, 50.0));
    });

    test('every placement round-trips, joined to its mark by id', () {
      final carried = everyPlacement();
      final marks = {for (final c in carried) c.mark.id: c.mark};
      expect(carried.map((c) => c.placement.runtimeType).toSet(), {
        Raised,
        Reanchored,
        Unplaced,
        Retired,
      });
      final lost = (carried[3].placement as Reanchored).result as Lost;
      expect(lost.candidates, hasLength(2), reason: 'the positive control: Lost has candidates');

      // Read back, each placement says what the original said. JSON against JSON alone passes a
      // writer and a reader that are wrong the same way.
      String describe(Placement p) => switch (p) {
        Raised() => 'raised',
        Reanchored(
          result: Located(:final node, :final decidedBy, :final considered, :final overlap),
        ) =>
          'located $node by ${decidedBy.name} of $considered at $overlap',
        Reanchored(result: Lost(:final candidates)) => 'lost among $candidates',
        Unplaced(:final reason) => 'unplaced: $reason',
        Retired() => 'retired',
      };
      final byLocation = Carried(
        markOn('by-location', _home),
        Reanchored(
          Located(
            node: node([0, 1], 'Text', at: loc(12)),
            decidedBy: Evidence.location,
            considered: 3,
            overlap: 0.25,
          ),
        ),
        markOn('by-location', _home).anchor,
      );
      for (final c in [...carried, byLocation]) {
        final back = Carried.fromJson(c.toJson(), 'p', (_) => c.mark);
        expect(describe(back.placement), describe(c.placement));
      }

      for (final c in carried) {
        final json = c.toJson();
        expect(json['mark'], c.mark.id, reason: 'the mark is stored once, not per round');
        final back = Carried.fromJson(json, 'p', (id) => marks[id]);
        expect(back.toJson(), json);
        expect(back.mark, same(c.mark));
      }
      final moved = Carried.fromJson(carried[2].toJson(), 'p', (id) => marks[id]);
      final located = (moved.placement as Reanchored).result as Located;
      expect(located.isExact, isFalse);
      expect(located.decidedBy, Evidence.key);
      expect(located.node.rect, const LogicalRect(200, 500, 100, 40));
      final lostBack =
          (Carried.fromJson(carried[3].toJson(), 'p', (id) => marks[id]).placement as Reanchored)
                  .result
              as Lost;
      expect(lostBack.candidates.map((n) => n.indexPath), [
        [0],
        [1],
      ]);
    });

    test('a placement for a mark nobody has, or of an unknown kind, is refused', () {
      final c = everyPlacement().first;
      expect(() => Carried.fromJson(c.toJson(), 'p', (_) => null), throwsFormatException);
      expect(
        () =>
            Carried.fromJson(c.toJson()..['placement'] = {'kind': 'misplaced'}, 'p', (_) => c.mark),
        throwsFormatException,
      );
      expect(
        () => Carried.fromJson(c.toJson()..remove('anchor'), 'p', (_) => c.mark),
        throwsFormatException,
      );
    });
  });

  group('RoundManifest', () {
    test('reads the index the packer has written since 0.1.0', () {
      final m = RoundManifest.fromJson({
        'frames': ['records/a.json', 'records/b.json'],
        'planned': 3,
      }, 'index');
      expect(m.frames, ['records/a.json', 'records/b.json']);
      expect(m.planned, 3);
      expect(m.toJson(), {
        'frames': ['records/a.json', 'records/b.json'],
        'planned': 3,
      });
    });

    test('says how many planned frames are missing', () {
      expect(RoundManifest(frames: ['records/a.json'], planned: 3).missing, 2);
      expect(RoundManifest(frames: ['records/a.json'], planned: 1).missing, 0);
    });

    test('refuses more frames than planned, a repeat, or a missing field', () {
      expect(() => RoundManifest(frames: ['a', 'b'], planned: 1), throwsArgumentError);
      expect(() => RoundManifest(frames: ['a', 'a'], planned: 2), throwsArgumentError);
      expect(
        () => RoundManifest.fromJson({
          'frames': ['a', 'b'],
          'planned': 1,
        }, 'index'),
        throwsFormatException,
      );
      expect(() => RoundManifest.fromJson({'frames': <String>[]}, 'index'), throwsFormatException);
      expect(() => RoundManifest.fromJson({'planned': 0}, 'index'), throwsFormatException);
      expect(
        () => RoundManifest.fromJson({
          'frames': [1],
          'planned': 1,
        }, 'index'),
        throwsFormatException,
      );
    });
  });
}
