import 'package:galley_core/galley_core.dart';

import 'axes.dart';
import 'host.dart';

/// The frames a round of [host] renders: its scenarios × screens as subjects, planned across the
/// built-in axes and the variant axis (DESIGN D2′, D9).
List<GalleyFrame> deriveFrames(GalleyHost host, BuiltInAxes builtIn) {
  final bySubject = <FrameKey, (GalleyScenario, Uri)>{};
  final idsSeen = <String, Uri>{};
  final subjects = <Map<String, String>>[];
  for (final scenario in host.scenarios) {
    for (final uri in scenario.screens) {
      final screen = screenId(uri);
      // Two uris can spell one id ("/a/b" and "/a.b"). Say which two, here, instead of letting
      // the planner refuse a "repeated subject" that names neither.
      final clash = idsSeen[screen];
      if (clash != null && clash != uri) {
        throw ArgumentError('screens $clash and $uri both have the frame id "$screen"');
      }
      idsSeen[screen] = uri;
      final subject = {'scenario': scenario.name, 'screen': screen};
      subjects.add(subject);
      bySubject[FrameKey(subject)] = (scenario, uri);
    }
  }

  final names = host.screenNames;
  for (final MapEntry(key: uri, value: name) in names.entries) {
    if (!idsSeen.containsValue(uri)) {
      throw ArgumentError('screenNames names $uri, which no scenario shows');
    }
    if (name.trim().isEmpty) throw ArgumentError('screenNames gives $uri a blank name');
  }

  final axes = [
    ...builtIn.frameAxes,
    if (host.variants.isNotEmpty) FrameAxis('variant', host.variants),
  ];
  final frames = <GalleyFrame>[];
  for (final planned in const FramePlanner().plan(subjects: subjects, axes: axes)) {
    final key = planned.key;
    final (scenario, uri) =
        bySubject[FrameKey({'scenario': key['scenario']!, 'screen': key['screen']!})]!;
    frames.add(
      GalleyFrame(
        key: key,
        scenario: scenario,
        uri: uri,
        variant: key['variant'],
        essential: planned.essential,
        screenName: names[uri],
      ),
    );
  }
  return frames;
}

/// The `screen` id of [uri]: its path segments joined by `.`, then its query, sorted, as
/// `.name-value`. Any character a [FrameKey] id cannot hold becomes `_`.
///
/// `/` is `root`. For example `/orders/new` is `orders.new`, and `/feed?tab=saved` is
/// `feed.tab-saved`.
///
/// Readable, not reversible: the frame record keeps the uri itself. A collision between two uris
/// is refused by [deriveFrames], so it can never merge two screens into one frame.
String screenId(Uri uri) {
  final parts = [
    ...uri.pathSegments.where((s) => s.isNotEmpty),
    for (final e in (uri.queryParameters.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
      '${e.key}-${e.value}',
  ];
  if (parts.isEmpty) return 'root';
  return parts.join('.').replaceAll(_notAnId, '_');
}

final _notAnId = RegExp(r'[^A-Za-z0-9_.\-]');
