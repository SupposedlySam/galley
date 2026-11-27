import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

import 'rounds.dart';

/// A galley held in memory: two rounds, where round 2's frame `a` has an image and round 1's
/// frame `b` has none, and the marks given, each placed in the round given (null: none).
final class MemoryGalley implements Galley {
  MemoryGalley(this.placed, {this.base = 'file:///g/rounds', this.damaged = const []});

  final List<PlacedMark> placed;
  final List<DamagedMark> damaged;
  final String base;

  /// How many times each round was read.
  final reads = <int, int>{};

  static final a = FrameKey({'screen': 'a'}), b = FrameKey({'screen': 'b'});

  @override
  Future<List<int>> rounds() async => [1, 2];

  @override
  Future<StoredRound> round(int n) {
    reads.update(n, (r) => r + 1, ifAbsent: () => 1);
    final record = n == 2 ? frameRecord(a, tree: null) : frameRecord(b, tree: null);
    final files = {
      'index.json': RoundManifest(frames: ['records/0.json'], planned: 1).toJson(),
      'records/0.json': n == 2 ? (record.toJson()..['image'] = 'frames/a.png') : record.toJson(),
    };
    return StoredRound.read(_Files(files));
  }

  @override
  Uri file(int n, String path) => Uri.parse('$base/$n/$path');

  @override
  Future<GalleyMarks> marks() async => GalleyMarks(placed, damaged: damaged);

  @override
  Future<({Mark mark, WidgetNode node, int round})> raise({
    required FrameKey frame,
    required PinTarget target,
    required String note,
    required String by,
  }) => throw UnimplementedError();

  @override
  Future<Mark> record(String id, MarkEvent Function(DateTime at) event) =>
      throw UnimplementedError();

  @override
  Future<int?> opened(int n, {required String by}) => throw UnimplementedError();
}

final class _Files implements RoundFiles {
  _Files(this.files);
  final Map<String, Object?> files;

  @override
  Future<Object?> json(String path) async =>
      files.containsKey(path) ? files[path] : throw RoundFileMissing(path);
}

void main() {
  final at = DateTime.utc(2026, 11, 27);
  final answered = [
    Answered(
      Answer.wontFix(note: 'by design'),
      by: 'owner',
      at: at,
    ),
  ];
  PlacedMark placed(int? round, Mark m, {required int? raisedIn}) =>
      PlacedMark(round, Carried.raised(m), raisedIn: raisedIn);

  // m1 and m2 in round 2, on the frame with an image; m3 placed in no round; m4 in round 1, on
  // the frame without one. m2 is answered, so it waits on a reviewer, not on an answer. m1 was
  // raised on round 1, so where it was raised is not where it was last placed.
  List<PlacedMark> population() => [
    placed(2, markOn('m1', MemoryGalley.a), raisedIn: 1),
    placed(2, markOn('m2', MemoryGalley.a, history: answered), raisedIn: 2),
    placed(null, markOn('m3', MemoryGalley.a), raisedIn: null),
    placed(1, markOn('m4', MemoryGalley.b), raisedIn: 1),
  ];

  group('workItems', () {
    test('lists the marks waiting on an answer, or with all, every mark', () async {
      final g = MemoryGalley(population());
      expect([for (final i in (await workItems(g)).items) i['id']], ['m1', 'm3', 'm4']);
      expect(
        [for (final i in (await workItems(g, all: true)).items) i['id']],
        ['m1', 'm2', 'm3', 'm4'],
      );
    });

    test('names the image by the galley: a path for a file, the URL otherwise', () async {
      Future<List<Object?>> images(MemoryGalley g) async => [
        for (final i in (await workItems(g, all: true)).items) i['image'],
      ];
      // m3 has no round to look in, and m4's frame has no image: null, not a guess.
      expect(await images(MemoryGalley(population())), [
        '/g/rounds/2/frames/a.png',
        '/g/rounds/2/frames/a.png',
        null,
        null,
      ]);
      expect(await images(MemoryGalley(population(), base: 'https://galley.test/r')), [
        'https://galley.test/r/2/frames/a.png',
        'https://galley.test/r/2/frames/a.png',
        null,
        null,
      ]);
    });

    test('names it by imageAt when given', () async {
      final items = (await workItems(
        MemoryGalley(population()),
        imageAt: (n, image) => 'round $n: $image',
      )).items;
      expect(items.map((i) => i['image']), ['round 2: frames/a.png', null, null]);
    });

    test('reads each round once, however many of its marks are listed', () async {
      final g = MemoryGalley(population());
      await workItems(g, all: true);
      expect(g.reads, {2: 1, 1: 1});
    });

    test('is what PlacedMark.fromJson reads back', () async {
      final items = (await workItems(MemoryGalley(population()), all: true)).items;
      final back = [for (final (i, item) in items.indexed) PlacedMark.fromJson(item, 'item $i')];
      expect(
        [
          for (final p in back)
            (p.round, p.raisedIn, p.mark.id, p.mark.status, p.carried.placement.name),
        ],
        [
          (2, 1, 'm1', MarkStatus.open, 'raised'),
          (2, 2, 'm2', MarkStatus.answered, 'raised'),
          (null, null, 'm3', MarkStatus.open, 'raised'),
          (1, 1, 'm4', MarkStatus.open, 'raised'),
        ],
      );
      expect(items.first.keys, [
        'id',
        'status',
        'round',
        'raised_in',
        'placement',
        'where',
        'anchor',
        'image',
        'mark',
      ]);
    });
  });

  test('PlacedMark.fromJson reads work items printed before raised_in as raised on no known '
      'round', () async {
    final item = (await workItems(MemoryGalley(population()))).items.first..remove('raised_in');
    final back = PlacedMark.fromJson(item, 'item');
    expect((back.round, back.raisedIn, back.mark.id), (2, null, 'm1'));
  });

  group('a mark that does not read', () {
    final damaged = [
      const DamagedMark('m8', 'u9, who wrote to mark m8, is not a member'),
      const DamagedMark('m9', 'it does not read'),
    ];

    test('is listed apart, with all or without, beside the marks that read', () async {
      final g = MemoryGalley(population(), damaged: damaged);
      for (final all in [false, true]) {
        final work = await workItems(g, all: all);
        expect(work.toJson().keys, ['latest_round', 'items', 'damaged']);
        expect(work.toJson()['damaged'], [
          {'id': 'm8', 'why': 'u9, who wrote to mark m8, is not a member'},
          {'id': 'm9', 'why': 'it does not read'},
        ]);
        expect(work.items, hasLength(all ? 4 : 3), reason: 'the rest are read');
      }
      expect((await workItems(MemoryGalley(population()))).toJson()['damaged'], isEmpty);
    });

    test('is read back by GalleyMarks.fromJson, with every mark that reads', () async {
      final work = await workItems(MemoryGalley(population(), damaged: damaged), all: true);
      final back = GalleyMarks.fromJson(work.toJson(), 'marks');
      expect([for (final p in back.placed) p.mark.id], ['m1', 'm2', 'm3', 'm4']);
      expect(
        [for (final d in back.damaged) (d.id, d.why)],
        [('m8', 'u9, who wrote to mark m8, is not a member'), ('m9', 'it does not read')],
      );
      final old = work.toJson()..remove('damaged');
      expect(() => GalleyMarks.fromJson(old, 'marks'), throwsFormatException);
    });

    test('refuses the whole of them to a writer that carries every mark, naming it', () {
      final placed = population();
      expect(GalleyMarks(placed).whole, hasLength(4));
      Object? refusal(List<DamagedMark> d) {
        try {
          GalleyMarks(placed, damaged: d).whole;
        } on Refused catch (e) {
          return (e.kind, e.message);
        }
        return null;
      }

      expect(refusal(damaged), (
        RefusalKind.damaged,
        'mark m8 does not read (u9, who wrote to mark m8, is not a member), nor 1 more; every '
            'mark must be carried, so this is refused until it is mended',
      ));
      expect(refusal(damaged.sublist(1)), (
        RefusalKind.damaged,
        'mark m9 does not read (it does not read); every mark must be carried, so this is '
            'refused until it is mended',
      ));
    });
  });
}
