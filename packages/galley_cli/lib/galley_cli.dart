/// The `galley` command: packs an app's rounds, carries every mark into each one, and records
/// answers (docs/DESIGN.md D12).
library;

export 'src/cli.dart' show GalleyContext, runGalley;
export 'src/galley_directory.dart' show GalleyDirectory;
export 'src/renderer.dart';
