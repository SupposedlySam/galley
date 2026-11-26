/// Whether [source] is a git commit SHA as Galley stores one: 7 to 40 lowercase hex digits.
///
/// A branch name or `HEAD` is refused. It names a different commit tomorrow, and a fix or a
/// round has to keep naming the one it was made at.
bool isCommitSha(String source) => _sha.hasMatch(source);

final _sha = RegExp(r'^[0-9a-f]{7,40}$');
