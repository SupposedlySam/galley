/// The `galley` command: packs an app's rounds, carries every mark into each one, and records
/// answers (docs/DESIGN.md D12).
library;

export 'src/archive.dart';
export 'src/canvas.dart';
export 'src/cli.dart' show GalleyContext, runGalley;
export 'src/galley_directory.dart' show GalleyDirectory;
export 'src/galley_server.dart';
export 'src/local_galley.dart';
export 'src/pinned.dart';
export 'src/pocketbase.dart';
export 'src/renderer.dart';
