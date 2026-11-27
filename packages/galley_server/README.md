# galley_server

What speaks a Galley server's language (DESIGN D15). The server is PocketBase with Galley's
schema, and every write is judged by galley_core before it lands. Pure Dart: the CLI and the
canvas share it, and it never imports Flutter.

Built so far:

- **The judge**, `bin/galley_validate.dart`. The server's hooks run it inside each write's
  transaction with the write as one JSON argument, and it answers `{"ok": true}` or
  `{"refused": "<why>"}` on one line. It always exits 0, because PocketBase's `$os.exec`
  throws away a failed command's output. `package:galley_server/judge.dart` is the same
  judgment as a function. It judges what may be written: a mark on the newest finished round
  and on one of its frames; an event the mark's history allows, an answer only from the owner;
  a round with the next number and a manifest of safe paths within the limits; a file the
  manifest lists, at its size; a finish with every file uploaded and every earlier mark
  placed; an alias no other member has. Who may write at all is the collections' API rules.
- **The rows**: a mark and its events as the server stores them (typed columns, `by` read
  through the author's membership, `at` the server's `created`), read as the core's `Mark`
  and `MarkEvent`.

Not built yet: the schema and hooks, and the client that implements the core's `Galley`.
