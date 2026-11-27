import 'json.dart';

/// Where a widget was constructed: the call site in the app's source.
///
/// Flutter records it at compile time when widget-creation tracking is on, which `flutter test`
/// does by default (docs/BOUNDARY.md § Creation locations). It is the constructor call site, not
/// the widget class's definition. Some widgets have none, because the transform skips
/// constructors with optional positional parameters. So an anchor never requires one.
final class SourceLocation {
  /// A location from its parts. [line] and [column] are 1-based.
  const SourceLocation(this.file, this.line, this.column)
    : assert(line >= 1, 'line is 1-based'),
      assert(column >= 1, 'column is 1-based');

  /// Reads the form [toJson] writes.
  factory SourceLocation.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    final line = r.integer('line');
    final column = r.integer('column');
    if (line < 1 || column < 1) {
      throw FormatException('$context: line and column are 1-based, got $line:$column');
    }
    return SourceLocation(r.string('file'), line, column);
  }

  /// The source file: a path inside the app's package (`lib/screens/home.dart`), which every
  /// round since 0.3.9 records. An older round recorded the URI the compiler did, an absolute
  /// `file:///…`, and the anchors of marks raised on it keep that form, since nothing is erased.
  final String file;

  /// 1-based line.
  final int line;

  /// 1-based column.
  final int column;

  /// The JSON form [SourceLocation.fromJson] reads.
  JsonMap toJson() => {'file': file, 'line': line, 'column': column};

  /// Whether [other] is the same call site: the same line and column, in [sameFile].
  bool sameSite(SourceLocation other) =>
      line == other.line && column == other.column && sameFile(other);

  /// Whether [other] names the same file as this.
  ///
  /// Equal files are the same. So is an absolute file (an older round's `file:///…`, or a
  /// path) and a relative one when the absolute path ends in `/` and the relative path: the
  /// package root it was recorded under is not known, but whatever it was, the relative path
  /// is that file inside it. A mark raised on a round before 0.3.9 is then still carried by its
  /// location into a round that records relative paths. Two absolute files that differ are
  /// different: nothing says where either package root was.
  ///
  /// Not caught: an older round's widget under `<root>/x/lib/a.dart` reads as the same file as
  /// `lib/a.dart`. The recorder keeps only widgets under the app's source roots, so that is a
  /// source root nested in another, which no app has been seen to declare.
  ///
  /// Rejected: rewriting older anchors as relative paths. An anchor is part of a mark, which is
  /// never changed, and the package root of an older round was never recorded.
  bool sameFile(SourceLocation other) {
    if (file == other.file) return true;
    final (absolute, relative) = _isAbsolute(file) ? (file, other.file) : (other.file, file);
    // A second absolute file, or a `package:` URI, never follows a `/` at the end of a path,
    // so the test below refuses both. Rejected: checking them here as well, a clause that no
    // input reaches (mutated, the suite stayed green).
    if (!_isAbsolute(absolute)) return false;
    final path = absolute.startsWith('file:')
        ? '/${Uri.parse(absolute).pathSegments.join('/')}'
        : absolute.replaceAll(r'\', '/');
    return path.endsWith('/$relative');
  }

  static bool _isAbsolute(String file) =>
      file.startsWith('file:') || file.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(file);

  @override
  bool operator ==(Object other) =>
      other is SourceLocation && other.file == file && other.line == line && other.column == column;

  @override
  int get hashCode => Object.hash(file, line, column);

  @override
  String toString() => '$file:$line:$column';
}
