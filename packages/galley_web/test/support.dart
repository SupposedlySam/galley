import 'dart:async';

import 'package:galley_core/galley_core.dart';

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

/// A rendered frame's record, with a tree, an image and its [pixels] digest when named.
FrameRecord recordOf(
  FrameKey key,
  DeviceProfile on, {
  String? tree,
  String? image,
  String? pixels,
}) => FrameRecord(
  key: key,
  scenario: key.values['scenario']!,
  uri: Uri.parse('/${key.values['screen']}'),
  landing: LandedAt(Uri.parse('/${key.values['screen']}')),
  status: FrameStatus.rendered,
  device: on,
  essential: true,
  tree: tree,
  image: image,
  pixels: pixels,
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

/// The files of a round of [keys], each on [pixel7] with [treeWithButton], and an image
/// `frames/<i>.png` of each with [images], or of each frame [pixels] gives a digest of.
Map<String, Object?> roundFiles(
  List<FrameKey> keys, {
  bool images = false,
  Map<FrameKey, String> pixels = const {},
}) {
  final records = [for (final (i, _) in keys.indexed) 'records/$i.json'];
  return {
    'index.json': RoundManifest(frames: records, planned: keys.length).toJson(),
    for (final (i, k) in keys.indexed) ...{
      records[i]: recordOf(
        k,
        pixel7,
        tree: 'trees/$i.json',
        image: images || pixels.containsKey(k) ? 'frames/$i.png' : null,
        pixels: pixels[k],
      ).toJson(),
      'trees/$i.json': treeWithButton(pixel7).toJson(),
    },
  };
}

/// A galley in memory that keeps marks by the core's rules, as `galley serve` does, and
/// remembers what it was asked.
final class FakeGalley implements Galley {
  FakeGalley({
    this.roundsList = const [1],
    Map<String, Object?>? files,
    this.refuse,
    this.byRound = const {},
  }) : files = files ?? roundFiles([keyOf('home', pixel7)]);

  final List<int> roundsList;

  /// The files of every round not in [byRound].
  final Map<String, Object?> files;

  /// The files of a round, by its number, where it differs from [files].
  final Map<int, Map<String, Object?>> byRound;

  /// The rounds read, in order.
  final roundReads = <int>[];

  /// Rounds whose reading is refused with this, by number.
  final refuseRound = <int, Refused>{};

  /// When set, every call is refused with it.
  Refused? refuse;

  /// Every mark, by id, and the round each was placed in (null: none).
  final marksById = <String, (Mark, int?)>{};

  /// The marks the galley holds and cannot read.
  final damaged = <DamagedMark>[];

  /// The round each mark was raised on, by id; the round it was placed in when absent.
  final raisedIn = <String, int?>{};

  /// The events recorded, as sent: without a time, which the galley gives.
  final recorded = <(String, JsonMap)>[];

  /// Each reviewer's visit, by name, kept as the core keeps it ([visitTo]).
  final visits = <String, Visit>{};

  /// The rounds opened, in order, with who opened them.
  final opens = <(int, String)>[];

  /// When set, every [opened] is refused with it.
  Refused? refuseOpened;

  /// When set, every [opened] waits for it.
  Completer<void>? holdOpened;

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
    roundReads.add(n);
    if (refuseRound[n] case final r?) throw r;
    return StoredRound.read(MemoryRoundFiles(byRound[n] ?? files));
  }

  @override
  Uri file(int n, String path) => Uri.parse('http://galley.test/api/rounds/$n/$path');

  @override
  Future<GalleyMarks> marks() async {
    _check();
    return GalleyMarks([
      for (final (m, round) in marksById.values)
        PlacedMark(
          round,
          Carried(m, round == null ? const Unplaced('no round') : const Raised(), m.anchor),
          raisedIn: raisedIn.containsKey(m.id) ? raisedIn[m.id] : round,
        ),
    ], damaged: damaged);
  }

  @override
  Future<({Mark mark, WidgetNode node, int round})> raise({
    required FrameKey frame,
    required PinTarget target,
    required String note,
    required String by,
  }) async {
    _check();
    final (:node, :pin) = target.resolve(treeWithButton(pixel7));
    raised++;
    final mark = Mark(
      id: 'm$raised',
      frame: frame,
      anchor: Anchor.of(node),
      pin: pin,
      note: note,
      by: by,
      at: now,
    );
    marksById[mark.id] = (mark, roundsList.last);
    return (mark: mark, node: node, round: roundsList.last);
  }

  @override
  Future<Mark> record(String id, MarkEvent Function(DateTime at) event) async {
    _check();
    final e = event(now);
    recorded.add((id, e.toJson()..remove('at')));
    final (mark, round) = marksById[id]!;
    try {
      final next = mark.record(e);
      marksById[id] = (next, round);
      return next;
    } on StateError catch (x) {
      throw Refused.conflict(x.message);
    }
  }

  @override
  Future<int?> opened(int n, {required String by}) async {
    _check();
    opens.add((n, by));
    await holdOpened?.future;
    if (refuseOpened case final r?) throw r;
    return (visits[by] = visitTo(n, visits[by])).before;
  }

  /// Puts [mark] in, placed in [round], raised on [raisedOn] (on [round] when not given). A
  /// mark raised on no known round is put in with this, then `raisedIn[id] = null`.
  void seed(Mark mark, {int? round = 1, int? raisedOn}) {
    marksById[mark.id] = (mark, round);
    raisedIn[mark.id] = raisedOn ?? round;
  }
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
