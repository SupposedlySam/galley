// Not a `_test.dart` file: `flutter test` does not pick it up on its own. packer_test.dart runs
// it as a child process with GALLEY_OUT set, and reads what it wrote.
import 'package:material_ui/material_ui.dart';
import 'package:galley/galley.dart';

import '../support/toy_app.dart';

class ToyRoundHost extends GalleyHost {
  const ToyRoundHost();

  @override
  List<GalleyScenario> get scenarios => [
    GalleyScenario('base', screens: [Uri.parse('/home'), Uri.parse('/img')]),
    GalleyScenario('drifty', screens: [Uri.parse('/drift')]),
  ];

  @override
  Map<Uri, String> get screenNames => {Uri.parse('/home'): 'Home'};

  @override
  GalleyAxes get axes => GalleyAxes(textScales: [1.0], brightness: [Brightness.light]);

  @override
  List<String> get sourceRoots => const ['test/support'];

  @override
  Future<Widget> mount(GalleyFrame frame) async => ToyApp(
    opening: frame.uri,
    screens: {
      '/img': (_) => Image.network('https://example.invalid/bean.jpg', width: 80, height: 80),
      '/drift': (_) => const DriftingLabel(),
    },
  );
}

void main() => galley(const ToyRoundHost());
