/// Strict readers for the JSON Galley writes and reads back.
///
/// Every format Galley stores (a frame tree, a mark, an answer) is read through these. A missing
/// or mistyped field throws a [FormatException] that names the field. It is never defaulted: a
/// tree read with a defaulted rect would re-anchor a mark onto the wrong widget and report it as
/// Exact. That failure looks like success, which is the worst kind (CLAUDE.md, "An unknown is
/// never nothing").
library;

/// A JSON object.
typedef JsonMap = Map<String, Object?>;

/// Reads typed fields out of one JSON object, naming [context] in every error.
extension type const JsonReader._(({JsonMap map, String context}) _r) {
  /// Reads [value] as an object, or throws naming [context].
  factory JsonReader(Object? value, String context) {
    if (value is! Map<String, Object?>) {
      throw FormatException('$context: expected an object, got ${_kind(value)}');
    }
    return JsonReader._((map: value, context: context));
  }

  /// The required string at [key].
  String string(String key) => _required<String>(key, 'a string');

  /// The string at [key], or null when the key is absent or null.
  String? optionalString(String key) => _optional<String>(key, 'a string');

  /// The required integer at [key].
  int integer(String key) => _required<int>(key, 'an integer');

  /// The required number at [key], as a double.
  double number(String key) => _required<num>(key, 'a number').toDouble();

  /// The required nested value at [key], parsed by [parse] with this field's context.
  ///
  /// [parse] is a type's own `fromJson(Object? json, String context)`, so a nested type reads
  /// the same way standalone and inside another.
  T read<T>(String key, T Function(Object? json, String context) parse) {
    if (!_r.map.containsKey(key) || _r.map[key] == null) {
      throw FormatException('${_r.context}.$key: missing');
    }
    return parse(_r.map[key], '${_r.context}.$key');
  }

  /// The nested value at [key] parsed by [parse], or null when the key is absent or null.
  T? readOptional<T>(String key, T Function(Object? json, String context) parse) {
    final value = _r.map[key];
    return value == null ? null : parse(value, '${_r.context}.$key');
  }

  /// The required list at [key], each element parsed by [parse] with its own context.
  List<T> readList<T>(String key, T Function(Object? json, String context) parse) => [
    for (final (i, v) in list(key).indexed) parse(v, '${_r.context}.$key[$i]'),
  ];

  /// The required list at [key].
  List<Object?> list(String key) => _required<List<Object?>>(key, 'a list');

  /// The required list of integers at [key].
  List<int> integers(String key) {
    final values = list(key);
    return [
      for (final (i, v) in values.indexed)
        if (v is int)
          v
        else
          throw FormatException('${_r.context}.$key[$i]: expected an integer, got ${_kind(v)}'),
    ];
  }

  /// The context this reader names in its errors, such as `tree.nodes[3]`.
  String get context => _r.context;

  T _required<T>(String key, String expected) {
    if (!_r.map.containsKey(key)) {
      throw FormatException('${_r.context}.$key: missing, expected $expected');
    }
    final value = _r.map[key];
    if (value is! T) {
      throw FormatException('${_r.context}.$key: expected $expected, got ${_kind(value)}');
    }
    return value;
  }

  T? _optional<T>(String key, String expected) {
    final value = _r.map[key];
    if (value == null) return null;
    if (value is! T) {
      throw FormatException('${_r.context}.$key: expected $expected or null, got ${_kind(value)}');
    }
    return value as T;
  }
}

String _kind(Object? value) => switch (value) {
  null => 'null',
  String() => 'a string',
  int() => 'an integer',
  num() => 'a number',
  bool() => 'a boolean',
  List<Object?>() => 'a list',
  Map<Object?, Object?>() => 'an object',
  _ => value.runtimeType.toString(),
};
