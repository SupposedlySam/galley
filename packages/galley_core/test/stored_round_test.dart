import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

import 'rounds.dart';

final _home = FrameKey({'screen': 'home', 'device': 'pixel-7'});
final _menu = FrameKey({'screen': 'menu', 'device': 'pixel-7'});

/// Stands for a file that is there and is not JSON.
const _notJson = Object();

/// A round held in memory, as [RoundFiles] sees one.
final class _Files implements RoundFiles {
  _Files(this.files);
  final Map<String, Object?> files;
  final read = <String>[];

  @override
  Future<Object?> json(String path) async {
    read.add(path);
    if (!files.containsKey(path)) throw RoundFileMissing(path);
    if (files[path] == _notJson) throw FormatException('$path: not JSON');
    return files[path];
  }
}

Map<String, Object?> _round({bool withProvenance = true, bool withMenuTree = true}) => {
  'index.json': RoundManifest(
    frames: ['records/home.json', 'records/menu.json'],
    planned: 3,
  ).toJson(),
  if (withProvenance)
    'round.json': RoundProvenance(
      commit: const Known('d9a9f85'),
      dirty: const Known(true),
      flutter: const Known('3.50.0'),
      at: DateTime.utc(2026, 11, 26),
    ).toJson(),
  'records/home.json': frameRecord(_home, tree: 'trees/home.json').toJson(),
  'records/menu.json': frameRecord(_menu, tree: 'trees/menu.json').toJson(),
  'trees/home.json': withBuy(buyRect).toJson(),
  if (withMenuTree) 'trees/menu.json': withBuy(const LogicalRect(0, 0, 50, 50)).toJson(),
};

void main() {
  group('StoredRound.read', () {
    test('reads the provenance, the index, every record and every tree', () async {
      final files = _Files(_round());
      final stored = await StoredRound.read(files);

      expect((stored.provenance as Known<RoundProvenance>).value.dirty, isA<Known<bool>>());
      expect(stored.manifest.missing, 1);
      expect(stored.frames.map((f) => f.record.key), [_home, _menu]);
      expect(stored.frames.map((f) => f.tree?.nodes.length), [2, 2]);
      expect(stored.round.frame(_menu)?.tree?.nodes[1].rect, const LogicalRect(0, 0, 50, 50));
      expect(files.read, containsAll(_round().keys), reason: 'every file was read');
    });

    test('a round packed before round.json still reads, its provenance unknown', () async {
      final stored = await StoredRound.read(_Files(_round(withProvenance: false)));
      expect((stored.provenance as Unrecorded).reason, contains('before 0.3.2'));
      expect(stored.frames, hasLength(2));
    });

    test('a missing tree leaves its frame treeless, so its marks are Unplaced', () async {
      final stored = await StoredRound.read(_Files(_round(withMenuTree: false)));
      expect(stored.round.frame(_home)?.tree, isNotNull, reason: 'the control');
      expect(stored.round.frame(_menu)?.tree, isNull);
      final carried = stored.round.carry(Carried.raised(markOn('m', _menu)));
      expect((carried.placement as Unplaced).reason, contains('trees/menu.json'));
    });

    test('no index, a missing or malformed record, or a malformed tree is refused', () async {
      Future<void> refused(Map<String, Object?> files, Matcher error) =>
          expectLater(StoredRound.read(_Files(files)), throwsA(error));

      await refused(_round()..remove('index.json'), isA<RoundFileMissing>());
      await refused(_round()..remove('records/menu.json'), isA<RoundFileMissing>());
      await refused(_round()..['records/menu.json'] = {'key': 'x'}, isFormatException);
      await refused(_round()..['trees/menu.json'] = {'nodes': 'x'}, isFormatException);
      await refused(_round()..['round.json'] = {'commit': 'x'}, isFormatException);
      await refused(_round()..['trees/menu.json'] = _notJson, isFormatException);
      await refused(_round()..['round.json'] = _notJson, isFormatException);
    });
  });

  group('Placements', () {
    final a = markOn('a', _home), b = markOn('b', _menu);
    Mark? markOf(String id) => {'a': a, 'b': b}[id];

    test('round-trips, and finds each mark\'s placement by id', () {
      final placements = Placements([
        Carried.raised(a),
        Carried(b, const Unplaced('the frame is an error: boom'), b.anchor),
      ]);
      final back = Placements.fromJson(placements.toJson(), 'p', markOf);
      expect(back.carried.map((c) => c.mark.id), ['a', 'b']);
      expect(back.of('a')?.placement, isA<Raised>());
      expect((back.of('b')?.placement as Unplaced).reason, 'the frame is an error: boom');
      expect(back.of('c'), isNull);
    });

    test('a mark placed twice is refused, in code and in a file', () {
      expect(() => Placements([Carried.raised(a), Carried.raised(a)]), throwsArgumentError);
      expect(() => Placements([Carried.raised(a)]).plus([Carried.raised(a)]), throwsArgumentError);
      expect(Placements([Carried.raised(a)]).plus([Carried.raised(b)]).carried, hasLength(2));
      final twice = {
        'placements': [Carried.raised(a).toJson(), Carried.raised(a).toJson()],
      };
      expect(() => Placements.fromJson(twice, 'p', markOf), throwsFormatException);
    });
  });
}
