import 'dart:collection';

/// The identity of one frame across rounds: the value it takes on every axis.
///
/// For example `device=android-gesture;scenario=offSeason;screen=find-us;text-scale=2.0`.
/// The key holds no hash of the pixels. The same frame in round 5 is the same frame as in
/// round 4 even when its pixels changed, and that is what lets a mark carry forward
/// (docs/DESIGN.md D5).
///
/// The canonical form sorts axes by id, so two keys built in different orders are equal and
/// print the same.
final class FrameKey {
  /// A key from axis id → value id. Ids are checked by [isValidId]; it must not be empty.
  factory FrameKey(Map<String, String> values) {
    if (values.isEmpty) {
      throw ArgumentError.value(values, 'values', 'a frame key needs at least one axis');
    }
    for (final MapEntry(:key, :value) in values.entries) {
      if (!isValidId(key)) throw ArgumentError.value(key, 'axis id', _idRule);
      if (!isValidId(value)) {
        throw ArgumentError.value(value, 'value of axis "$key"', _idRule);
      }
    }
    final sorted = SplayTreeMap<String, String>.of(values);
    return FrameKey._(UnmodifiableMapView(sorted), _canonical(sorted));
  }

  /// Reads the canonical form [toString] writes.
  factory FrameKey.parse(String source) {
    if (source.isEmpty) throw const FormatException('empty frame key');
    final values = <String, String>{};
    for (final part in source.split(_pairSeparator)) {
      final eq = part.indexOf(_valueSeparator);
      if (eq <= 0 || eq == part.length - 1) {
        throw FormatException('frame key part "$part" is not axis=value', source);
      }
      final axis = part.substring(0, eq);
      if (values.containsKey(axis)) {
        throw FormatException('frame key repeats axis "$axis"', source);
      }
      values[axis] = part.substring(eq + 1);
    }
    try {
      final key = FrameKey(values);
      // A key that parses but is not canonical (axes out of order) would compare equal to the
      // canonical one but hash differently as a string wherever it was stored as one. Refuse it,
      // so every stored key is the canonical spelling.
      if (key._canonicalForm != source) {
        throw FormatException(
          'frame key is not canonical; expected "${key._canonicalForm}"',
          source,
        );
      }
      return key;
    } on ArgumentError catch (e) {
      throw FormatException('${e.message}: ${e.invalidValue}', source);
    }
  }

  const FrameKey._(this.values, this._canonicalForm);

  /// Axis id → value id, sorted by axis id.
  final Map<String, String> values;

  final String _canonicalForm;

  /// Whether [id] may be an axis id or a value id: letters, digits, `_`, `-` and `.`.
  ///
  /// `=` and `;` are the canonical form's separators, so they are excluded. So is
  /// whitespace, which reads ambiguously in a URL or a log line.
  static bool isValidId(String id) => _id.hasMatch(id);

  /// The value on [axis], or null when this key does not have that axis.
  String? operator [](String axis) => values[axis];

  /// A copy with [axis] set to [value].
  FrameKey withValue(String axis, String value) => FrameKey({...values, axis: value});

  @override
  bool operator ==(Object other) => other is FrameKey && other._canonicalForm == _canonicalForm;

  @override
  int get hashCode => _canonicalForm.hashCode;

  /// The canonical form [FrameKey.parse] reads.
  @override
  String toString() => _canonicalForm;

  static final _id = RegExp(r'^[A-Za-z0-9_.\-]+$');
  static const _idRule = 'must be letters, digits, "_", "-" or "."';
  static const _pairSeparator = ';';
  static const _valueSeparator = '=';

  static String _canonical(SplayTreeMap<String, String> sorted) =>
      [for (final MapEntry(:key, :value) in sorted.entries) '$key$_valueSeparator$value']
          .join(_pairSeparator);
}
