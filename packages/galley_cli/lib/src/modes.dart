import 'dart:io';

/// Sets [path]'s Unix mode to [mode], as `chmod`. Nothing on Windows, which keeps no such
/// mode: a file there is the user's own by the directory it is in.
///
/// dart:io writes a file but cannot set its mode, so this runs `chmod`, which POSIX requires
/// every system to have. Rejected: an FFI call to chmod(2), a native binding for what one
/// short-lived process does as well.
void setMode(String path, int mode) {
  if (Platform.isWindows) return;
  final r = Process.runSync('chmod', [mode.toRadixString(8), path]);
  if (r.exitCode != 0) {
    throw FileSystemException(
      'chmod ${mode.toRadixString(8)} failed: ${'${r.stderr}'.trim()}',
      path,
    );
  }
}
