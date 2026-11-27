import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import 'src/served_galley.dart';
import 'src/app.dart';
import 'src/canvas_model.dart';

/// The canvas, served by `galley serve` from the same origin as its API: so the API is wherever
/// the page is, and `?by=<name>` names the reviewer.
void main() {
  runApp(
    GalleyCanvasApp(
      model: CanvasModel(
        ServedGalley(http.Client(), Uri.base),
        reviewer: Uri.base.queryParameters['by'] ?? '',
      ),
    ),
  );
}
