// Where a galley's canvas is on a server, said once for the CLI that prints the link and the
// canvas that reads it (docs/DESIGN.md D15).
//
// The server serves the canvas's build at its root (`galley host`), so the page and the API
// share an origin and a root: the API is `<root>api/`, and the link names the galley by a
// query parameter. Rejected: a path (`<root>g/<id>`). The server would have to answer it with
// the canvas's page, and the canvas would have to tell its own root from the path; a query
// leaves the page at the root, where its assets are.

/// The query parameter that names the galley on its canvas's link.
const galleyParameter = 'galley';

/// The canvas of galley [galleyId] on the server at [root].
Uri canvasLink(Uri root, String galleyId) => root.replace(
  path: root.path.endsWith('/') ? root.path : '${root.path}/',
  queryParameters: {galleyParameter: galleyId},
);

/// The galley [page] names, or null when it names none.
String? galleyOf(Uri page) => switch (page.queryParameters[galleyParameter]?.trim()) {
  final id? when id.isNotEmpty => id,
  _ => null,
};

/// The server's root, for the canvas at [page]: the directory the page is in, with no query
/// or fragment. PocketBase.api keeps its base's query on every request it builds, and the
/// galley named in the page's is not the API's.
Uri serverOf(Uri page) {
  final path = page.path;
  return Uri(
    scheme: page.scheme,
    host: page.host,
    port: page.port,
    path: path.substring(0, path.lastIndexOf('/') + 1),
  );
}
