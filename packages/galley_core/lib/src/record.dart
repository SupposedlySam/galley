import 'device.dart';
import 'frame_key.dart';
import 'geometry.dart';
import 'json.dart';

/// How a frame's render ended.
enum FrameStatus {
  /// It settled, it was captured, and the two renders agreed.
  rendered,

  /// It was still animating when the settle budget ran out. Galley stopped every ticker and
  /// captured that state. The picture is real but not one a user waits to see, so the card says
  /// so.
  frozen,

  /// It threw, landed on another screen, or rendered differently twice. The frame is an error
  /// card, never a missing frame (DESIGN.md, "An unknown is never nothing").
  error,
}

/// Where the app was when the frame was captured.
///
/// This is a sealed type and not a nullable uri. "Galley could not read it" must never be
/// stored in the same shape as "it matched".
sealed class Landing {
  const Landing();

  /// Reads the form [toJson] writes.
  factory Landing.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    final uri = r.optionalString('uri');
    final unknown = r.optionalString('unknown');
    return switch ((uri, unknown)) {
      (final String u, null) => LandedAt(Uri.parse(u)),
      (null, final String why) => LandingUnknown(why),
      _ => throw FormatException('$context: exactly one of "uri" and "unknown" is required'),
    };
  }

  /// The JSON form [Landing.fromJson] reads.
  JsonMap toJson();
}

/// The app's router reported [uri].
final class LandedAt extends Landing {
  /// Landed at [uri].
  const LandedAt(this.uri);

  /// What the router reported, as its parser would restore it.
  final Uri uri;

  /// Whether this is the screen [expected] names. The paths must match, ignoring a trailing
  /// `/`. The query parameters must match too, in any order. The fragment is ignored, because
  /// a router does not navigate on it.
  bool isAt(Uri expected) => _path(uri) == _path(expected) && _sameQuery(uri, expected);

  static String _path(Uri u) {
    final p = u.path;
    return p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : (p.isEmpty ? '/' : p);
  }

  static bool _sameQuery(Uri a, Uri b) {
    final qa = a.queryParametersAll, qb = b.queryParametersAll;
    if (qa.length != qb.length) return false;
    for (final MapEntry(:key, :value) in qa.entries) {
      final other = qb[key];
      if (other == null || other.length != value.length) return false;
      for (var i = 0; i < value.length; i++) {
        if (other[i] != value[i]) return false;
      }
    }
    return true;
  }

  @override
  JsonMap toJson() => {'uri': uri.toString()};

  @override
  String toString() => '$uri';
}

/// Galley could not tell where the app was, for [reason]. For example, the app has no `Router`.
/// A frame with this landing is never reported as having reached its screen.
final class LandingUnknown extends Landing {
  /// Unknown, for [reason].
  const LandingUnknown(this.reason);

  /// Why Galley could not tell.
  final String reason;

  @override
  JsonMap toJson() => {'unknown': reason};

  @override
  String toString() => 'unknown ($reason)';
}

/// Something Galley noticed about a frame that a reviewer should know, short of an error.
final class Finding {
  /// A finding of [kind], explained by [message], optionally at [rect].
  Finding({required this.kind, required this.message, this.rect}) {
    if (!FrameKey.isValidId(kind)) throw ArgumentError.value(kind, 'kind', 'not a valid id');
  }

  /// Reads the form [toJson] writes.
  factory Finding.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    try {
      return Finding(
        kind: r.string('kind'),
        message: r.string('message'),
        rect: r.readOptional('rect', LogicalRect.fromJson),
      );
    } on ArgumentError catch (e) {
      throw FormatException('$context: ${e.message}');
    }
  }

  /// A short id: `missing-font`, `network-image`, `frozen`.
  final String kind;

  /// What was observed, in a sentence.
  final String message;

  /// Where on the frame, in logical pixels, when it has a place.
  final LogicalRect? rect;

  /// The JSON form [Finding.fromJson] reads.
  JsonMap toJson() => {'kind': kind, 'message': message, if (rect != null) 'rect': rect!.toJson()};

  @override
  String toString() => '$kind: $message';
}

/// Everything a round keeps about one frame, apart from its pixels and its tree, which are
/// files of their own named here.
final class FrameRecord {
  /// A record. An [FrameStatus.error] record must carry at least one error, and the other
  /// statuses carry none. That way the status and the errors can never disagree.
  FrameRecord({
    required this.key,
    required this.scenario,
    required this.uri,
    required this.landing,
    required this.status,
    required this.device,
    required this.essential,
    List<String> errors = const [],
    List<Finding> findings = const [],
    this.image,
    this.tree,
  }) : errors = List.unmodifiable(errors),
       findings = List.unmodifiable(findings) {
    if ((status == FrameStatus.error) != errors.isNotEmpty) {
      throw ArgumentError(
        'frame $key: status ${status.name} with ${errors.length} error(s); an error record '
        'needs an error, and only an error record may have one',
      );
    }
  }

  /// Reads the form [toJson] writes.
  factory FrameRecord.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    final statusName = r.string('status');
    final key = r.string('key');
    try {
      return FrameRecord(
        key: FrameKey.parse(key),
        scenario: r.string('scenario'),
        uri: Uri.parse(r.string('uri')),
        landing: r.read('landing', Landing.fromJson),
        status: FrameStatus.values.firstWhere(
          (s) => s.name == statusName,
          orElse: () => throw FormatException('$context.status: unknown "$statusName"'),
        ),
        device: r.read('device', DeviceProfile.fromJson),
        essential: r.boolean('essential'),
        errors: [
          for (final (i, e) in r.list('errors').indexed)
            e is String ? e : throw FormatException('$context.errors[$i]: expected a string'),
        ],
        findings: r.readList('findings', Finding.fromJson),
        image: r.optionalString('image'),
        tree: r.optionalString('tree'),
      );
    } on ArgumentError catch (e) {
      throw FormatException('$context: ${e.message}');
    }
  }

  /// The frame's identity.
  final FrameKey key;

  /// The scenario it shows.
  final String scenario;

  /// The screen it was meant to show.
  final Uri uri;

  /// Where it actually was.
  final Landing landing;

  /// How the render ended.
  final FrameStatus status;

  /// The device it was rendered on, with the provenance of its numbers.
  final DeviceProfile device;

  /// Whether it is in the essential set (DESIGN D9).
  final bool essential;

  /// What went wrong, one message each. Empty unless [status] is [FrameStatus.error].
  final List<String> errors;

  /// What a reviewer should know.
  final List<Finding> findings;

  /// The PNG, relative to the round directory. Null when nothing could be captured.
  final String? image;

  /// The tree JSON, relative to the round directory. Null when nothing could be recorded.
  final String? tree;

  /// The JSON form [FrameRecord.fromJson] reads.
  JsonMap toJson() => {
    'key': key.toString(),
    'scenario': scenario,
    'uri': uri.toString(),
    'landing': landing.toJson(),
    'status': status.name,
    'device': device.toJson(),
    'essential': essential,
    'errors': errors,
    'findings': [for (final f in findings) f.toJson()],
    if (image != null) 'image': image,
    if (tree != null) 'tree': tree,
  };
}
