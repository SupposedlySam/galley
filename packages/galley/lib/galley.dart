/// Galley: every screen × state × device of a Flutter app, rendered as a frame for review.
///
/// An app's whole integration is a [GalleyHost] in its `test/`, and one line:
///
/// ```dart
/// void main() => galley(MyAppHost());
/// ```
library;

export 'package:galley_core/galley_core.dart' show DeviceProfile, EdgeInsetsPx, Provenance;

export 'src/axes.dart' show GalleyAxes;
export 'src/host.dart';
export 'src/packer.dart' show galley;
