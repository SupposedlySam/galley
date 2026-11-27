import 'json.dart';

/// Where one reviewer was in a galley: the newest round they opened, [latest], and the newest
/// they had opened before it, [before] (docs/DESIGN.md D17).
///
/// Two rounds, not one: a reviewer who opens round 3 after round 2 is shown what changed since
/// round 2, and is shown the same again when they reload, or open the canvas in a second tab,
/// before round 4 is pushed. Rejected: keeping only the round last opened, which compares round
/// 3 with itself on the first reload and so tells the reviewer that nothing changed; and a
/// time of the last visit, which reads the rounds by a clock that the packer's and the
/// server's need not share.
final class Visit {
  /// Opened [latest] last, and [before] before it; null when [latest] is the first opened.
  Visit(this.latest, {this.before}) {
    if (latest < 1) throw ArgumentError.value(latest, 'latest', 'is not a round');
    if (before case final b? when b < 1 || b >= latest) {
      throw ArgumentError.value(b, 'before', 'is not a round before $latest');
    }
  }

  /// Reads the JSON [toJson] writes.
  factory Visit.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    try {
      return Visit(r.integer('latest'), before: r.optionalInteger('before'));
    } on ArgumentError catch (e) {
      throw FormatException('$context: ${e.message}');
    }
  }

  /// The first visit, to round [n].
  factory Visit.first(int n) => Visit(n);

  /// The newest round opened.
  final int latest;

  /// The newest round opened before [latest], or null.
  final int? before;

  /// This visit after round [n] is opened: [n] the latest, and [latest] before it, when [n] is
  /// newer; unchanged otherwise.
  ///
  /// Opening a round no newer leaves it as it was, so a reload, or an older round opened to
  /// look back, does not move what the next visit is compared with.
  Visit opened(int n) => n > latest ? Visit(n, before: latest) : this;

  /// `{"latest", "before"}`, `before` left out when null.
  JsonMap toJson() => {'latest': latest, 'before': ?before};

  @override
  bool operator ==(Object other) =>
      other is Visit && other.latest == latest && other.before == before;

  @override
  int get hashCode => Object.hash(latest, before);

  @override
  String toString() => 'Visit($latest, before: $before)';
}

/// [kept], the visit recorded for a reviewer (null before their first), after they open round
/// [n]: what every [Galley.opened] stores. Its [Visit.before] is what the reviewer is shown the
/// changes since.
Visit visitTo(int n, Visit? kept) => kept?.opened(n) ?? Visit.first(n);
