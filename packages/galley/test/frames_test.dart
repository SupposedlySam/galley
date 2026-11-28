import 'package:flutter_test/flutter_test.dart';
import 'package:galley/galley.dart';
import 'package:galley/src/axes.dart';
import 'package:galley/src/frames.dart';
import 'package:material_ui/material_ui.dart';

class _Host extends GalleyHost {
  _Host(this.screenNames);

  @override
  final Map<Uri, String> screenNames;

  @override
  List<GalleyScenario> get scenarios => [
    GalleyScenario('base', screens: [Uri.parse('/'), Uri.parse('/bloom')]),
    GalleyScenario('empty', screens: [Uri.parse('/bloom')]),
  ];

  @override
  Future<Widget> mount(GalleyFrame frame) async => const SizedBox();
}

List<GalleyFrame> _frames(Map<Uri, String> names) =>
    deriveFrames(_Host(names), BuiltInAxes(GalleyAxes()));

void main() {
  group('screen names', () {
    test('every frame of a named screen carries its name, and only those', () {
      final frames = _frames({Uri.parse('/bloom'): 'The Batch'});
      final named = {for (final f in frames) '${f.key}': f.screenName};
      expect(named.values.where((n) => n != null), isNotEmpty);
      for (final f in frames) {
        expect(f.screenName, f.uri.path == '/bloom' ? 'The Batch' : isNull, reason: '${f.key}');
      }
      // The id is the uri's, named or not: a mark on the screen keeps its frame.
      expect(frames.map((f) => f.key.values['screen']).toSet(), {'root', 'bloom'});
    });

    test('naming a screen changes no frame key', () {
      expect(
        _frames({Uri.parse('/'): 'Home', Uri.parse('/bloom'): 'The Batch'}).map((f) => f.key),
        _frames(const {}).map((f) => f.key),
      );
    });

    test('a name for a screen no scenario shows is refused, naming it', () {
      expect(
        () => _frames({Uri.parse('/blom'): 'The Batch'}),
        throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', contains('/blom'))),
      );
    });

    test('a blank name is refused, naming the screen', () {
      for (final blank in ['', '  ']) {
        expect(
          () => _frames({Uri.parse('/bloom'): blank}),
          throwsA(
            isA<ArgumentError>().having((e) => '${e.message}', 'message', contains('/bloom')),
          ),
          reason: '"$blank"',
        );
      }
    });
  });
}
