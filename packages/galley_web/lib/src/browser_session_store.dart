import 'dart:convert';

import 'package:galley_server/galley_server.dart';
import 'package:web/web.dart' as web;

import 'session_store.dart';

/// A member's sign-in kept in the browser's `localStorage`, under this page's origin: the
/// server's, since the canvas is served from it.
///
/// `localStorage`, so a reviewer who comes back tomorrow is still signed in. Rejected:
/// `sessionStorage`, which forgets the sign-in with the tab, so every visit would mail another
/// code. Rejected too: an HTTP-only cookie, which no script could read. The canvas sends the
/// token as `Authorization` (PocketBase.send), so a script holds it whichever way it is kept.
/// The page runs no script but its own: the canvas loads nothing from outside the server it is
/// served from (DESIGN D14).
///
/// Storage that cannot be read (blocked, or a private window) is no session, and the member
/// signs in again; what cannot be written is not kept, and the canvas still works for this
/// visit.
final class BrowserSessionStore implements SessionStore {
  /// The store under [key].
  const BrowserSessionStore({this.key = 'galley.session'});

  /// The `localStorage` key.
  final String key;

  @override
  Session? read() {
    try {
      final kept = web.window.localStorage.getItem(key);
      return kept == null ? null : Session.fromJson(jsonDecode(kept), 'the kept sign-in');
    } on Object {
      // Unreadable storage, or a value this canvas did not write: no session, not an error
      // page. The member signs in again, and that write replaces it.
      return null;
    }
  }

  @override
  void write(Session session) {
    try {
      web.window.localStorage.setItem(key, jsonEncode(session.toJson()));
    } on Object {
      // Not kept: the session still serves this visit.
    }
  }

  @override
  void clear() {
    try {
      web.window.localStorage.removeItem(key);
    } on Object {
      // Nothing that could be read is left to forget.
    }
  }
}
