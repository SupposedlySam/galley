import 'commit.dart';
import 'json.dart';

/// A fact about a round that was either recorded or not, never left blank.
///
/// "The packer could not run git" must not be stored in the same shape as "the tree was
/// clean", so an unknown carries its reason (DESIGN.md, "An unknown is never nothing").
sealed class Recorded<T extends Object> {
  const Recorded();

  /// Reads `{"value": v}` or `{"unknown": "why"}`, with [value] reading `v`.
  factory Recorded.fromJson(
    Object? json,
    String context,
    T Function(JsonReader r, String key) value,
  ) {
    final r = JsonReader(json, context);
    final unknown = r.optionalString('unknown');
    final hasValue = (json as Map).containsKey('value');
    return switch ((hasValue, unknown)) {
      (true, null) => Known(value(r, 'value')),
      (false, final String why) => Unrecorded(why),
      _ => throw FormatException('$context: exactly one of "value" and "unknown" is required'),
    };
  }

  /// The JSON form [Recorded.fromJson] reads.
  JsonMap toJson();
}

/// It was recorded: [value].
final class Known<T extends Object> extends Recorded<T> {
  /// Recorded as [value].
  const Known(this.value);

  /// What was recorded.
  final T value;

  @override
  JsonMap toJson() => {'value': value};

  @override
  String toString() => '$value';
}

/// It could not be recorded, for [reason].
final class Unrecorded<T extends Object> extends Recorded<T> {
  /// Not recorded, for [reason]. Throws an [ArgumentError] if [reason] is blank.
  Unrecorded(this.reason) {
    if (reason.trim().isEmpty) throw ArgumentError.value(reason, 'reason', 'must say why');
  }

  /// Why it could not be recorded.
  final String reason;

  @override
  JsonMap toJson() => {'unknown': reason};

  @override
  String toString() => 'unknown ($reason)';
}

/// Where a round came from: the app's commit, whether its tree had uncommitted changes, the
/// Flutter version that rendered it, and when. Written as the round's `round.json`.
///
/// A reviewer's "this is fixed" means "fixed in this commit". Without the commit a round
/// cannot be matched with the answers that say which commit fixed a mark. A dirty tree is
/// recorded because a round rendered from uncommitted changes shows a commit it does not
/// match.
final class RoundProvenance {
  /// Provenance from its parts. Throws an [ArgumentError] if [at] is not UTC or a known commit
  /// is not a SHA.
  RoundProvenance({
    required this.commit,
    required this.dirty,
    required this.flutter,
    required this.at,
  }) {
    if (!at.isUtc) throw ArgumentError.value(at, 'at', 'must be UTC');
    if (commit case Known(:final value) when !isCommitSha(value)) {
      throw ArgumentError.value(value, 'commit', 'must be a 7 to 40 character hex SHA');
    }
  }

  /// Reads the form [toJson] writes.
  factory RoundProvenance.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    try {
      return RoundProvenance(
        commit: r.read('commit', (j, c) => Recorded.fromJson(j, c, (r, k) => r.string(k))),
        dirty: r.read('dirty', (j, c) => Recorded.fromJson(j, c, (r, k) => r.boolean(k))),
        flutter: r.read('flutter', (j, c) => Recorded.fromJson(j, c, (r, k) => r.string(k))),
        at: r.utcTime('at'),
      );
    } on ArgumentError catch (e) {
      throw FormatException('$context.${e.name}: ${e.message}');
    }
  }

  /// The app's commit (`git rev-parse HEAD`).
  final Recorded<String> commit;

  /// Whether the app's working tree had changes not in [commit].
  final Recorded<bool> dirty;

  /// The Flutter version that rendered the round.
  final Recorded<String> flutter;

  /// When the round was packed, in UTC.
  final DateTime at;

  /// The JSON form [RoundProvenance.fromJson] reads.
  JsonMap toJson() => {
    'commit': commit.toJson(),
    'dirty': dirty.toJson(),
    'flutter': flutter.toJson(),
    'at': at.toIso8601String(),
  };
}
