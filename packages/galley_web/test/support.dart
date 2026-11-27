import 'package:galley_core/galley_core.dart';
import 'package:galley_web/src/api.dart';

// Builders for the canvas tests: frames on named devices, rounds held in memory, and a backend
// that keeps marks the way `galley serve` does, by the core's own rules.

/// A device [width] × [height] logical pixels, at a pixel ratio of 1 so the numbers read as
/// they are drawn.
DeviceProfile device(String id, String name, {int width = 400, int height = 800}) => DeviceProfile(
  id: id,
  name: name,
  physicalWidth: width,
  physicalHeight: height,
  pixelRatio: 1,
  provenance: Provenance.assumed,
  source: 'test',
);

final pixel7 = device('pixel-7', 'Pixel 7', width: 411, height: 914);
final small = device('small-phone', 'Small phone', width: 360, height: 640);

/// The key of [screen] in [scenario] on [on], with any [more] axes.
FrameKey keyOf(
  String screen,
  DeviceProfile on, {
  String scenario = 'base',
  Map<String, String> more = const {},
}) => FrameKey({'screen': screen, 'scenario': scenario, 'device': on.id, ...more});

/// A rendered frame's record, with a tree and no image.
FrameRecord recordOf(FrameKey key, DeviceProfile on, {String? tree}) => FrameRecord(
  key: key,
  scenario: key.values['scenario']!,
  uri: Uri.parse('/${key.values['screen']}'),
  landing: LandedAt(Uri.parse('/${key.values['screen']}')),
  status: FrameStatus.rendered,
  device: on,
  essential: true,
  tree: tree,
);

/// A frame of [screen] on [on], with no tree.
RoundFrame frameOf(
  String screen,
  DeviceProfile on, {
  String scenario = 'base',
  Map<String, String> more = const {},
}) => RoundFrame(recordOf(keyOf(screen, on, scenario: scenario, more: more), on), null);

/// The root and one button, at (20, 300) and 371 × 52, in every frame's tree.
const buttonRect = LogicalRect(20, 300, 371, 52);

FrameTree treeWithButton(DeviceProfile on) => FrameTree(
  bounds: LogicalRect(0, 0, on.logicalWidth, on.logicalHeight),
  nodes: [
    WidgetNode(
      indexPath: const [],
      type: 'App',
      rect: LogicalRect(0, 0, on.logicalWidth, on.logicalHeight),
    ),
    WidgetNode(indexPath: const [0], type: 'FilledButton', rect: buttonRect, key: 'add'),
  ],
);

/// A round's files held in memory: what [StoredRound.read] reads.
final class MemoryRoundFiles implements RoundFiles {
  MemoryRoundFiles(this.files);

  final Map<String, Object?> files;

  @override
  Future<Object?> json(String path) async {
    if (!files.containsKey(path)) throw RoundFileMissing(path);
    return files[path];
  }
}

/// The files of a round of [keys], each on [pixel7] with [treeWithButton].
Map<String, Object?> roundFiles(List<FrameKey> keys) {
  final records = [for (final (i, _) in keys.indexed) 'records/$i.json'];
  return {
    'index.json': RoundManifest(frames: records, planned: keys.length).toJson(),
    for (final (i, k) in keys.indexed) ...{
      records[i]: recordOf(k, pixel7, tree: 'trees/$i.json').toJson(),
      'trees/$i.json': treeWithButton(pixel7).toJson(),
    },
  };
}

/// A backend in memory that keeps marks by the core's rules, as `galley serve` does, and
/// remembers what it was asked.
final class FakeGalleyApi implements GalleyApi {
  FakeGalleyApi({this.roundsList = const [1], Map<String, Object?>? files, this.refuse})
    : files = files ?? roundFiles([keyOf('home', pixel7)]);

  final List<int> roundsList;
  final Map<String, Object?> files;

  /// When set, every call is refused with it.
  GalleyRefusal? refuse;

  /// Every mark, by id, and the round each was placed in (null: none).
  final marksById = <String, (Mark, int?)>{};

  /// The events recorded, as sent.
  final recorded = <(String, JsonMap)>[];

  /// How many marks were raised.
  int raised = 0;

  DateTime now = DateTime.utc(2026, 11, 26, 12);

  void _check() {
    if (refuse case final r?) throw r;
  }

  @override
  Future<List<int>> rounds() async {
    _check();
    return roundsList;
  }

  @override
  Future<StoredRound> round(int n) async {
    _check();
    return StoredRound.read(MemoryRoundFiles(files));
  }

  @override
  Uri file(int n, String path) => Uri.parse('http://galley.test/api/rounds/$n/$path');

  @override
  Future<List<PlacedMark>> marks() async {
    _check();
    return [
      for (final (m, round) in marksById.values)
        PlacedMark(
          round,
          Carried(m, round == null ? const Unplaced('no round') : const Raised(), m.anchor),
        ),
    ];
  }

  @override
  Future<Mark> raise({
    required FrameKey frame,
    required IndexPath node,
    required ({double x, double y}) at,
    required String note,
    required String by,
  }) async {
    _check();
    raised++;
    final tree = treeWithButton(pixel7);
    final widget = tree.nodes.firstWhere((n) => n.indexPath.join() == node.join());
    final mark = Mark(
      id: 'm$raised',
      frame: frame,
      anchor: Anchor.of(widget),
      pin: PinOffset.within(widget.rect, at.x, at.y),
      note: note,
      by: by,
      at: now,
    );
    marksById[mark.id] = (mark, roundsList.last);
    return mark;
  }

  @override
  Future<Mark> record(String id, JsonMap event) async {
    _check();
    recorded.add((id, event));
    final (mark, round) = marksById[id]!;
    final MarkEvent e;
    try {
      e = MarkEvent.fromJson({...event, 'at': now.toIso8601String()}, 'event');
    } on FormatException catch (x) {
      throw GalleyRefusal(400, x.message);
    }
    try {
      final next = mark.record(e);
      marksById[id] = (next, round);
      return next;
    } on StateError catch (x) {
      throw GalleyRefusal(409, x.message);
    }
  }

  /// Puts [mark] in, placed in [round].
  void seed(Mark mark, {int? round = 1}) => marksById[mark.id] = (mark, round);
}

/// A mark on the button of [frame], raised by [by], with [history].
Mark buttonMark(
  String id,
  FrameKey frame, {
  String by = 'Tester',
  List<MarkEvent> history = const [],
}) => Mark(
  id: id,
  frame: frame,
  anchor: Anchor.of(treeWithButton(pixel7).nodes[1]),
  pin: const PinOffset(0.5, 0.5),
  note: 'make it primary',
  by: by,
  at: DateTime.utc(2026, 11, 26, 9),
  history: history,
);
