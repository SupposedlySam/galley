import 'package:galley_server/galley_server.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import 'src/app.dart';
import 'src/browser_session_store.dart';
import 'src/canvas_model.dart';
import 'src/entry_page.dart';
import 'src/served_galley.dart';
import 'src/server_entry.dart';

/// The canvas, served from the same origin as its API, so the API is wherever the page is.
///
/// `?galley=<id>` is a galley on a Galley server, which serves the canvas from its public
/// directory (`galley host`): the member signs in, and the canvas reads the galley as them.
/// Without it, the page is `galley serve`'s, on this machine, and `?by=<name>` names the
/// reviewer.
///
/// Said by the link, not guessed from what answers: `galley serve` and the server both answer
/// under `/api`, and a canvas that probed would read an outage of one as the other.
void main() {
  final client = http.Client();
  final galley = galleyOf(Uri.base);
  runApp(
    galley == null
        ? GalleyCanvasApp(
            model: CanvasModel(
              ServedGalley(client, Uri.base),
              reviewer: Uri.base.queryParameters['by'] ?? '',
            ),
          )
        : ServerCanvasApp(
            entry: ServerEntry(
              ServerDoor.at(client, serverOf(Uri.base), galley),
              const BrowserSessionStore(),
            ),
          ),
  );
}
