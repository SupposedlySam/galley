import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

import 'rounds.dart';

/// A galley held in memory: two rounds, where round 2's frame `a` has an image and round 1's
/// frame `b` has none, and the marks given, each placed in the round given (null: none).
final class MemoryGalley implements Galley {
  MemoryGalley(this.placed, {this.base = 'file:///g/rounds'});

  final List<PlacedMark> placed;
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
  Future<List<PlacedMark>> marks() async => placed;

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
  PlacedMark placed(int? round, Mark m) => PlacedMark(round, Carried.raised(m));

  // m1 and m2 in round 2, on the frame with an image; m3 placed in no round; m4 in round 1, on
  // the frame without one. m2 is answered, so it waits on a reviewer, not on an answer.
  List<PlacedMark> population() => [
    placed(2, markOn('m1', MemoryGalley.a)),
    placed(2, markOn('m2', MemoryGalley.a, history: answered)),
    placed(null, markOn('m3', MemoryGalley.a)),
    placed(1, markOn('m4', MemoryGalley.b)),
  ];

  group('workItems', () {
    test('lists the marks waiting on an answer, or with all, every mark', () async {
      final g = MemoryGalley(population());
      expect([for (final i in await workItems(g)) i['id']], ['m1', 'm3', 'm4']);
      expect([for (final i in await workItems(g, all: true)) i['id']], ['m1', 'm2', 'm3', 'm4']);
    });

    test('names the image by the galley: a path for a file, the URL otherwise', () async {
      Future<List<Object?>> images(MemoryGalley g) async => [
        for (final i in await workItems(g, all: true)) i['image'],
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
      final items = await workItems(
        MemoryGalley(population()),
        imageAt: (n, image) => 'round $n: $image',
      );
      expect(items.map((i) => i['image']), ['round 2: frames/a.png', null, null]);
    });

    test('reads each round once, however many of its marks are listed', () async {
      final g = MemoryGalley(population());
      await workItems(g, all: true);
      expect(g.reads, {2: 1, 1: 1});
    });

    test('is what PlacedMark.fromJson reads back', () async {
      final items = await workItems(MemoryGalley(population()), all: true);
      final back = [for (final (i, item) in items.indexed) PlacedMark.fromJson(item, 'item $i')];
      expect(
        [for (final p in back) (p.round, p.mark.id, p.mark.status, p.carried.placement.name)],
        [
          (2, 'm1', MarkStatus.open, 'raised'),
          (2, 'm2', MarkStatus.answered, 'raised'),
          (null, 'm3', MarkStatus.open, 'raised'),
          (1, 'm4', MarkStatus.open, 'raised'),
        ],
      );
      expect(items.first.keys, [
        'id',
        'status',
        'round',
        'placement',
        'where',
        'anchor',
        'image',
        'mark',
      ]);
    });
  });
}
