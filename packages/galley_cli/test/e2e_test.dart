@Tags(['e2e'])
library;

import 'dart:io';

import 'package:galley_cli/galley_cli.dart';
import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

/// `galley pack` with the real [FlutterTestRenderer], against the galley package's toy round:
/// the only test that runs `flutter test` from the CLI and reads back what the packer wrote.
/// Slow (two child `flutter test` runs). cli_test.dart covers the commands with a fake renderer.
void main() {
  late Directory dir;
  late StringBuffer out, err;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('galley_e2e_');
    out = StringBuffer();
    err = StringBuffer();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  final app = Directory('../galley').absolute.path;
  final root = Platform.environment['FLUTTER_ROOT'];
  final flutter = root == null ? 'flutter' : '$root/bin/flutter';

  Future<int> galley(List<String> args) {
    out.clear();
    err.clear();
    return runGalley([
      '--app',
      app,
      '--galley',
      '${dir.path}/.galley',
      ...args,
    ], GalleyContext(out: out, err: err, environment: const {'GALLEY_BY': 'e2e'}));
  }

  test('pack, mark, pack again: the mark is found exactly where it was', () async {
    final pack = ['pack', '--test', 'test/e2e/toy_round.dart', '--flutter', flutter];
    expect(await galley(pack), 0, reason: '$err');
    expect('$out', contains('Round 1: 6 of 6 planned frames'));
    expect('$out', contains('Rendered from '), reason: 'round.json was read');

    final g = GalleyDirectory('${dir.path}/.galley');
    final frame = (await g.readRound(1)).frames.firstWhere(
      (f) => f.record.status == FrameStatus.rendered && (f.tree?.nodes.length ?? 0) > 1,
    );
    final node = frame.tree!.nodes.last;
    final key = frame.record.key;
    expect(
      await galley(['mark', '--frame', '$key', '--node', node.indexPath.join('.'), '--note', 'x']),
      0,
      reason: '$err',
    );

    expect(await galley(pack), 0, reason: '$err');
    expect('$out', contains('Round 2: 6 of 6 planned frames'));
    expect('$out', contains('Marks: 1 carried. 1 exact, 0 moved'));
    final image = File(
      '${g.roundPath(2)}/${(await g.readRound(2)).round.frame(key)!.record.image}',
    );
    expect(image.lengthSync(), greaterThan(100), reason: 'a real png: ${image.path}');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
