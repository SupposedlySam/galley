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

  /// The source file, as the URI the compiler recorded (`file:///…` or `package:…`).
  final String file;

  /// 1-based line.
  final int line;

  /// 1-based column.
  final int column;

  /// The JSON form [SourceLocation.fromJson] reads.
  JsonMap toJson() => {'file': file, 'line': line, 'column': column};

  @override
  bool operator ==(Object other) =>
      other is SourceLocation && other.file == file && other.line == line && other.column == column;

  @override
  int get hashCode => Object.hash(file, line, column);

  @override
  String toString() => '$file:$line:$column';
}
