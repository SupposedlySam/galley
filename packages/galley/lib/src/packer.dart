import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:galley_core/galley_core.dart';

import 'axes.dart';
import 'capture.dart';
import 'fonts.dart';
import 'frames.dart';
import 'host.dart';
import 'provenance_reader.dart';
import 'render.dart';

/// Declares one test per frame of [host], and writes the round when `GALLEY_OUT` is set.
///
/// ```sh
/// flutter test test/galley_test.dart --dart-define=GALLEY_OUT=build/galley/round-1
/// ```
///
/// Without `GALLEY_OUT` it writes nothing. It still renders every frame twice and fails the
/// test of each frame that errs, so the same file is a CI check.
///
/// **One test per frame**, so a failure names its frame, and `--plain-name` can rerun one.
///
/// **Twice per frame** (DESIGN D4). A frame that renders differently twice is an error, with
/// the widget that changed named. Otherwise the review would chase a difference between two
/// rounds that is really noise inside one.
void galley(GalleyHost host) {
  final builtIn = BuiltInAxes(host.axes);
  final frames = deriveFrames(host, builtIn);
  final out = _outDir();
  final records = <FrameRecord>[];
  late FrameRenderer renderer;
  late RoundProvenance provenance;

  setUpAll(() async {
    // Before anything is written (see readProvenance).
    provenance = readProvenance(
      dir: Directory.current.path,
      environment: Platform.environment,
      now: DateTime.now(),
    );
    final fonts = await GalleyFonts.load();
    final cwd = Directory.current.path;
    renderer = FrameRenderer(
      host: host,
      recorder: TreeRecorder(packageRoot: cwd, sourceRoots: host.sourceRoots),
      fonts: fonts,
    );
    if (out != null) {
      for (final d in ['frames', 'trees', 'records']) {
        Directory('${out.path}/$d').createSync(recursive: true);
      }
    }
  });

  for (final frame in frames) {
    testWidgets('$frame', (tester) async {
      final device = builtIn.deviceOf(frame.key);
      final undo = builtIn.apply(tester, frame.key);
      final FrameRecord record;
      try {
        record = await _renderTwice(tester, renderer, frame, device, out);
      } finally {
        undo();
      }
      records.add(record);
      if (out != null) {
        _writeJson('${out.path}/records/${fileName(frame.key)}.json', record.toJson());
      }
      if (record.status == FrameStatus.error) fail(headline(record));
    });
  }

  tearDownAll(() {
    // Said either way. A round with no output directory looked like a bug to the first adopting
    // app: 155 renders, "All tests passed!", and no files.
    print(
      summary(
        out: out,
        planned: frames.length,
        rendered: records.length,
        errors: records.where((r) => r.status == FrameStatus.error).length,
      ),
    );
    if (out == null) return;
    _writeJson('${out.path}/round.json', provenance.toJson());
    _writeJson(
      '${out.path}/index.json',
      RoundManifest(
        frames: [for (final r in records) 'records/${fileName(r.key)}.json'],
        planned: frames.length,
      ).toJson(),
    );
  });
}

void _writeJson(String path, JsonMap json) =>
    File(path).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));

Future<FrameRecord> _renderTwice(
  WidgetTester tester,
  FrameRenderer renderer,
  GalleyFrame frame,
  DeviceProfile device,
  Directory? out,
) async {
  final first = await renderer.render(tester, frame);
  await _unmount(tester);
  final second = await renderer.render(tester, frame);
  await _unmount(tester);

  final errors = [...first.errors];
  final mismatch = mismatchOf(first, second, device.pixelRatio);
  if (mismatch != null) errors.add(mismatch);

  final name = fileName(frame.key);
  String? image, tree;
  if (out != null && first.pixels != null) {
    image = 'frames/$name.png';
    File('${out.path}/$image').writeAsBytesSync(first.pixels!.png);
  }
  if (out != null && first.tree != null) {
    tree = 'trees/$name.json';
    File('${out.path}/$tree').writeAsStringSync(jsonEncode(first.tree!.toJson()));
  }
  return FrameRecord(
    key: frame.key,
    scenario: frame.scenario.name,
    uri: frame.uri,
    landing: first.landing,
    status: errors.isNotEmpty
        ? FrameStatus.error
        : (first.frozen ? FrameStatus.frozen : FrameStatus.rendered),
    device: device,
    essential: frame.essential,
    errors: errors,
    findings: first.findings,
    image: image,
    pixels: image == null ? null : first.pixels!.digest,
    tree: tree,
  );
}

/// Takes the app down and forgets its images, so the second render starts where the first did.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
}

/// Why two renders of one frame differ, or null when they do not.
///
/// Pixels first, because a pixel difference has a place, and the place names a culprit: the
/// deepest recorded widget holding the whole changed region. When the pixels agree but the
/// trees differ, the first differing node is named instead.
@visibleForTesting
String? mismatchOf(RenderOutcome a, RenderOutcome b, double pixelRatio) {
  final pa = a.pixels, pb = b.pixels;
  if ((pa == null) != (pb == null)) {
    return 'rendered differently twice: one render captured nothing';
  }
  if (pa != null && pb != null) {
    if (pa.width != pb.width || pa.height != pb.height) {
      return 'rendered differently twice: ${pa.width}×${pa.height} then ${pb.width}×${pb.height}';
    }
    final region = pa.diffBounds(pb, pixelRatio);
    if (region != null) {
      final culprit = a.tree?.deepestContaining(region);
      return 'rendered differently twice in ${_rect(region)}; '
          'culprit: ${culprit == null ? 'no recorded widget holds it' : _node(culprit)}';
    }
  }
  final ta = a.tree, tb = b.tree;
  if (ta != null && tb != null) {
    final na = ta.nodes, nb = tb.nodes;
    for (var i = 0; i < na.length || i < nb.length; i++) {
      if (i >= na.length || i >= nb.length) {
        final extra = i < na.length ? na[i] : nb[i];
        return 'recorded different widgets twice: only one render has node $i, ${_node(extra)}';
      }
      final x = na[i].toJson(), y = nb[i].toJson();
      final fields = {...x.keys, ...y.keys}
          .where((f) => jsonEncode(x[f]) != jsonEncode(y[f]))
          .map((f) => '$f ${jsonEncode(x[f])} then ${jsonEncode(y[f])}')
          .toList();
      if (fields.isNotEmpty) {
        return 'recorded different widgets twice at ${_node(na[i])}: ${fields.join('; ')}';
      }
    }
  }
  return null;
}

/// The line printed at the end of a round: how many frames rendered, and where they went.
///
/// [rendered] can be below [planned] when a run was filtered (`--plain-name`) or cut short.
@visibleForTesting
String summary({
  required Directory? out,
  required int planned,
  required int rendered,
  required int errors,
}) {
  final counts = '$rendered of $planned planned frames ($errors errors)';
  if (out == null) {
    return 'Galley: rendered $counts twice and wrote nothing: GALLEY_OUT is not set. '
        'Add --dart-define=GALLEY_OUT=<dir> to keep the round.';
  }
  return 'Galley: wrote $counts to ${out.path}';
}

/// The failure message of an error frame: every fact a reader needs to find it, in one place.
@visibleForTesting
String headline(FrameRecord r) => [
  'Galley frame ${r.key} is an error',
  '  scenario: ${r.scenario}',
  '  expected: ${r.uri}',
  '  landed:   ${r.landing}',
  '  device:   ${r.device.name} (${r.device.provenance.name})',
  for (final e in r.errors) '  error: ${e.replaceAll('\n', '\n         ')}',
].join('\n');

/// The file name of [key]'s files: its canonical form with `;` as `,`. A `;` is safe in a file
/// name but not in a shell or a uri. Ids never hold a `,`, so this is reversible.
@visibleForTesting
String fileName(FrameKey key) => key.toString().replaceAll(';', ',');

String _rect(LogicalRect r) =>
    '(${r.left.toStringAsFixed(1)}, ${r.top.toStringAsFixed(1)}) '
    '${r.width.toStringAsFixed(1)}×${r.height.toStringAsFixed(1)}';

String _node(WidgetNode n) => '$n${n.location == null ? '' : ' (${n.location})'}';

Directory? _outDir() {
  const path = String.fromEnvironment('GALLEY_OUT');
  return path.isEmpty ? null : Directory(path);
}
