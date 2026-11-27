import 'package:galley_server/galley_server.dart';

/// Where the canvas keeps a member's sign-in between visits.
///
/// An interface so the canvas is tested without a browser: [MemorySessionStore] in tests, the
/// browser's storage in the built canvas (browser_session_store.dart, imported only by
/// main.dart).
abstract interface class SessionStore {
  /// The session kept, or null when there is none or it could not be read.
  Session? read();

  /// Keeps [session], replacing any other.
  void write(Session session);

  /// Forgets the session kept.
  void clear();
}

/// A [SessionStore] that lasts as long as the page.
final class MemorySessionStore implements SessionStore {
  /// A store holding [session], if one is given.
  MemorySessionStore([this._session]);

  Session? _session;

  @override
  Session? read() => _session;

  @override
  void write(Session session) => _session = session;

  @override
  void clear() => _session = null;
}
