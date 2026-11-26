import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

import 'trees.dart';

final _home = FrameKey({'screen': 'home', 'device': 'pixel-7'});
final _menu = FrameKey({'screen': 'menu', 'device': 'pixel-7'});
final _cart = FrameKey({'screen': 'cart', 'device': 'pixel-7'});
final _gone = FrameKey({'screen': 'promo', 'device': 'pixel-7'});

const _buy = LogicalRect(10, 10, 100, 40);

FrameRecord _record(
  FrameKey key, {
  FrameStatus status = FrameStatus.rendered,
  List<String> errors = const [],
  String? tree = 'trees/x.json',
}) => FrameRecord(
  key: key,
  scenario: 'base',
  uri: Uri.parse('/${key.values['screen']}'),
  landing: LandedAt(Uri.parse('/${key.values['screen']}')),
  status: status,
  device: DeviceProfile.pixel7,
  essential: true,
  errors: errors,
  tree: tree,
);

/// A tree with one keyed button at [rect].
FrameTree _withBuy(LogicalRect rect, {String key = 'buy'}) => tree([
  root,
  node([0], 'FilledButton', rect: rect, key: key),
]);

Mark _mark(String id, FrameKey frame, {List<MarkEvent> history = const []}) => Mark(
  id: id,
  frame: frame,
  anchor: Anchor.of(_withBuy(_buy).nodes[1]),
  pin: const PinOffset(0.5, 0.5),
  note: 'too tight',
  by: 'reviewer',
  at: DateTime.utc(2026, 11, 26),
  history: history,
);

Located _located(Carried c) => (c.placement as Reanchored).result as Located;

void main() {
  group('carry', () {
    test('a widget where it was is Exact, and the mark keeps its pin and history', () {
      final answered = Answered(
        Answer.question(note: 'which edge?'),
        by: 'claude',
        at: DateTime.utc(2026, 11, 26, 1),
      );
      final mark = _mark('m1', _home, history: [answered]);
      final round = Round([RoundFrame(_record(_home), _withBuy(_buy))]);

      final carried = round.carry(Carried.raised(mark));

      expect(_located(carried).isExact, isTrue);
      expect(_located(carried).decidedBy, Evidence.key);
      expect(carried.mark, same(mark), reason: 'the mark itself is never rewritten');
      expect(carried.mark.status, MarkStatus.answered);
    });

    test('a widget found elsewhere is Moved, and its new box is the anchor from now on', () {
      final round2 = Round([
        RoundFrame(_record(_home), _withBuy(const LogicalRect(10, 300, 100, 40))),
      ]);
      final moved = round2.carry(Carried.raised(_mark('m1', _home)));
      expect(_located(moved).isExact, isFalse);
      expect(moved.anchor.rect, const LogicalRect(10, 300, 100, 40));
      expect(moved.anchor.key, 'buy');

      // The next round compares with where it was last seen, not where it was raised: the same
      // place again is Exact. Re-anchoring from the raised box would call it Moved forever.
      final again = round2.carry(moved);
      expect(_located(again).isExact, isTrue);
      expect(again.mark.anchor.rect, _buy, reason: 'the anchor as raised is kept on the mark');
    });

    test('a widget that is gone is Lost, and the last anchor is kept for the next round', () {
      final moved = Round([
        RoundFrame(_record(_home), _withBuy(const LogicalRect(10, 300, 100, 40))),
      ]).carry(Carried.raised(_mark('m1', _home)));
      final lost = Round([
        RoundFrame(
          _record(_home),
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
      final raised = Carried.raised(_mark('m1', _gone));
      final retired = Round([RoundFrame(_record(_home), _withBuy(_buy))]).carry(raised);
      expect(retired.placement, isA<Retired>());
      expect(retired.anchor, same(raised.anchor));

      final back = Round([RoundFrame(_record(_gone), _withBuy(_buy))]).carry(retired);
      expect(_located(back).isExact, isTrue);
    });

    test('a mark not placed this round keeps the anchor it was last found at, not as raised', () {
      const below = LogicalRect(10, 300, 100, 40);
      final moved = Round([RoundFrame(_record(_home), _withBuy(below))])
          .carry(Carried.raised(_mark('m1', _home)));
      expect(moved.anchor.rect, below, reason: 'the positive control: it did move');

      final notPlaced = [
        Round([RoundFrame(_record(_menu), _withBuy(_buy))]),
        Round([
          RoundFrame(_record(_home, status: FrameStatus.error, errors: ['threw']), null),
        ]),
        Round([RoundFrame(_record(_home), null)]),
      ];
      for (final round in notPlaced) {
        final kept = round.carry(moved);
        expect(kept.placement, isNot(isA<Reanchored>()));
        expect(kept.anchor.rect, below, reason: '${kept.placement.runtimeType}');
      }
    });

    test('an error frame is Unplaced, never Lost, though its tree would place it', () {
      // The positive control: the same tree in a rendered frame does place the mark.
      final ok = Round([RoundFrame(_record(_home), _withBuy(_buy))]);
      expect(_located(ok.carry(Carried.raised(_mark('m1', _home)))).isExact, isTrue);

      final errored = Round([
        RoundFrame(
          _record(_home, status: FrameStatus.error, errors: ['landed on /login']),
          _withBuy(_buy),
        ),
      ]).carry(Carried.raised(_mark('m1', _home)));
      final unplaced = errored.placement as Unplaced;
      expect(unplaced.reason, contains('landed on /login'));
      expect(errored.anchor, same(errored.mark.anchor));
    });

    test('a frozen frame is placed: its picture and tree are real', () {
      final round = Round([RoundFrame(_record(_home, status: FrameStatus.frozen), _withBuy(_buy))]);
      expect(_located(round.carry(Carried.raised(_mark('m1', _home)))).isExact, isTrue);
    });

    test('a frame with no tree is Unplaced, and says whether it was recorded or not read', () {
      final none = Round([RoundFrame(_record(_home, tree: null), null)]);
      expect(
        (none.carry(Carried.raised(_mark('m1', _home))).placement as Unplaced).reason,
        contains('no tree was recorded'),
      );
      final unread = Round([RoundFrame(_record(_home), null)]);
      expect(
        (unread.carry(Carried.raised(_mark('m1', _home))).placement as Unplaced).reason,
        contains('trees/x.json was not read'),
      );
    });
  });

  test('every mark is carried, once, in order, each to its own outcome', () {
    final round = Round([
      RoundFrame(_record(_home), _withBuy(_buy)),
      RoundFrame(_record(_menu), _withBuy(const LogicalRect(200, 500, 100, 40))),
      RoundFrame(_record(_cart), tree([root])),
      RoundFrame(
        _record(
          FrameKey({'screen': 'pay', 'device': 'pixel-7'}),
          status: FrameStatus.error,
          errors: ['threw'],
        ),
        null,
      ),
    ]);
    final marks = [
      _mark('exact', _home),
      _mark('moved', _menu),
      _mark('lost', _cart),
      _mark('unplaced', FrameKey({'screen': 'pay', 'device': 'pixel-7'})),
      _mark('retired', _gone),
      _mark(
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
    final mark = _mark('m1', _home);
    final raised = Carried.raised(mark);
    expect(raised.placement, isA<Raised>());
    expect(raised.anchor, same(mark.anchor));
  });

  group('Round', () {
    test('refuses two frames with one key', () {
      expect(
        () => Round([
          RoundFrame(_record(_home), _withBuy(_buy)),
          RoundFrame(_record(_home), _withBuy(_buy)),
        ]),
        throwsArgumentError,
      );
    });

    test('refuses a tree for a record that says none was recorded', () {
      expect(() => RoundFrame(_record(_home, tree: null), _withBuy(_buy)), throwsArgumentError);
    });
  });

  group('Carried JSON', () {
    // One of every placement, from a real carry, so the JSON is tested on what carry makes.
    List<Carried> everyPlacement() {
      final round = Round([
        RoundFrame(_record(_home), _withBuy(_buy)),
        RoundFrame(_record(_menu), _withBuy(const LogicalRect(200, 500, 100, 40))),
        RoundFrame(
          _record(_cart),
          tree([
            root,
            node([0], 'Text', label: 'Buy'),
            node([1], 'Text', label: 'Buy'),
          ]),
        ),
        RoundFrame(_record(_gone, status: FrameStatus.error, errors: ['threw']), null),
      ]);
      final cartMark = Mark(
        id: 'lost',
        frame: _cart,
        anchor: Anchor(type: 'Text', indexPath: [2], rect: _buy, semanticsLabel: 'Buy'),
        pin: const PinOffset(0, 0),
        note: 'n',
        by: 'r',
        at: DateTime.utc(2026),
      );
      return [
        Carried.raised(_mark('raised', _home)),
        ...round.carryAll([
          Carried.raised(_mark('exact', _home)),
          Carried.raised(_mark('moved', _menu)),
          Carried.raised(cartMark),
          Carried.raised(_mark('unplaced', _gone)),
          Carried.raised(_mark('retired', FrameKey({'screen': 'x'}))),
        ]),
      ];
    }

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
        _mark('by-location', _home),
        Reanchored(
          Located(
            node: node([0, 1], 'Text', at: loc(12)),
            decidedBy: Evidence.location,
            considered: 3,
            overlap: 0.25,
          ),
        ),
        _mark('by-location', _home).anchor,
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
