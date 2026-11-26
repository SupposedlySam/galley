import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:galley/src/packer.dart';
import 'package:galley_core/galley_core.dart';

/// Runs a whole round of the toy host in a child `flutter test`, and reads what it wrote. Slow
/// (one child process), and the only test that exercises `galley()` itself: the setUpAll, the
/// one test per frame, the double render, the files and the index.
void main() {
  late Directory out;
  late ProcessResult run;

  setUpAll(() async {
    out = Directory.systemTemp.createTempSync('galley_round_');
    final flutter = '${Platform.environment['FLUTTER_ROOT']}/bin/flutter';
    run = await Process.run(flutter, [
      'test',
      'test/e2e/toy_round.dart',
      '--dart-define=GALLEY_OUT=${out.path}',
    ]);
  });

  tearDownAll(() => out.deleteSync(recursive: true));

  FrameRecord record(String path) =>
      FrameRecord.fromJson(jsonDecode(File('${out.path}/$path').readAsStringSync()), path);

  test('every planned frame has a record, and the index lists exactly those', () {
    final index = _index(out);
    final listed = index.frames;
    // 3 subjects on 2 devices, the other axes single-valued: 3 essential frames plus pairwise
    // cover of subject × device adds the 3 on the small phone. 6 in all.
    expect(index.planned, 6);
    expect(listed, hasLength(6));
    expect(index.missing, 0);
    final onDisk = Directory('${out.path}/records').listSync().map((f) => f.uri.pathSegments.last);
    expect(onDisk.map((f) => 'records/$f'), unorderedEquals(listed));
  });

  test('a settled frame is rendered, with its png, its tree and its landing', () {
    final paths = _listed(out).where((p) => p.contains('screen=home'));
    expect(paths, hasLength(2));
    for (final p in paths) {
      final r = record(p);
      expect(r.status, FrameStatus.rendered, reason: '$p: ${r.errors}');
      expect((r.landing as LandedAt).uri, Uri.parse('/home'));
      final png = File('${out.path}/${r.image}').readAsBytesSync();
      expect(png.sublist(1, 4), utf8.encode('PNG'));
      final tree = FrameTree.fromJson(
        jsonDecode(File('${out.path}/${r.tree}').readAsStringSync()),
        r.tree!,
      );
      expect(tree.nodes.map((n) => n.type), contains('HomeScreen'));
      expect(r.device.provenance, Provenance.assumed);
    }
  });

  test('an image frame names its placeholder', () {
    final r = record(_listed(out).firstWhere((p) => p.contains('screen=img')));
    expect(r.status, FrameStatus.rendered, reason: '${r.errors}');
    expect(r.findings.map((f) => f.kind), contains('network-image'));
  });

  test('a frame that renders differently twice is an error naming the culprit', () {
    final drift = _listed(out).where((p) => p.contains('screen=drift')).toList();
    expect(drift, hasLength(2));
    for (final p in drift) {
      final r = record(p);
      expect(r.status, FrameStatus.error);
      expect(r.errors.single, contains('rendered differently twice'));
      expect(r.errors.single, contains("culprit: Text([<'drift'>])"));
      expect(r.errors.single, contains('toy_app.dart'));
    }
  });

  test('the child run fails, and its failures are the drifting frames and only those', () {
    expect(run.exitCode, isNot(0));
    final stdout = run.stdout as String;
    final headlines = RegExp(r'Galley frame\s+(\S+)\s+is an error').allMatches(stdout).toList();
    expect(headlines, hasLength(2), reason: stdout);
    expect(headlines.every((m) => m.group(1)!.contains('screen=drift')), isTrue);
  });

  test('the child run says where the round went', () {
    final stdout = run.stdout as String;
    expect(stdout, contains('Galley: wrote 6 of 6 planned frames (2 errors) to ${out.path}'));
  });

  group('summary', () {
    test('without an output directory, it says nothing was kept and how to keep it', () {
      final line = summary(out: null, planned: 155, rendered: 155, errors: 0);
      expect(line, startsWith('Galley: rendered 155 of 155 planned frames (0 errors) twice'));
      expect(line, contains('wrote nothing: GALLEY_OUT is not set'));
      expect(line, contains('--dart-define=GALLEY_OUT='));
    });

    test('with one, it names the directory and the count', () {
      final line = summary(out: Directory('build/r1'), planned: 7, rendered: 5, errors: 2);
      expect(line, 'Galley: wrote 5 of 7 planned frames (2 errors) to build/r1');
    });
  });

  test('fileName is the key with ; as ,', () {
    final key = FrameKey({'screen': 'home', 'device': 'pixel-7'});
    expect(fileName(key), 'device=pixel-7,screen=home');
  });
}

/// The round's index, read the way the CLI and the server read it.
RoundManifest _index(Directory out) => RoundManifest.fromJson(
  jsonDecode(File('${out.path}/index.json').readAsStringSync()),
  'index.json',
);

List<String> _listed(Directory out) => _index(out).frames;
