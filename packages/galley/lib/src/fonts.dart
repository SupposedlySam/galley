import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:galley_core/galley_core.dart';

/// Loads the app's real fonts into the test engine, and says which text did not get one.
///
/// **Why.** Under `flutter test`, a family that was never loaded is drawn in the test font,
/// which draws every glyph as a box. A design review of boxes reviews nothing. So every
/// family in the app's `FontManifest.json` is loaded, and so is Roboto from the SDK. Roboto is
/// Material's Android default (`Typography`), and it is not in an app's manifest.
///
/// **What is still missing is said, not hidden.** [missingIn] lists each family that text on
/// the frame asked for and that was not loaded, as a finding on the card. Text that names no
/// family at all also gets one: on a device it is drawn in the platform's font, here in the
/// test font.
final class GalleyFonts {
  GalleyFonts._(this.loaded, this.notes);

  /// The test engine's own font. Text drawn in it is boxes.
  static const testFont = 'FlutterTest';

  /// Loads every family. Call once, from `setUpAll`.
  static Future<GalleyFonts> load() async {
    final loaded = <String>{};
    final notes = <String>[];
    final manifest = await _manifest();
    for (final entry in manifest) {
      final family = entry.family;
      final loader = FontLoader(family);
      for (final asset in entry.assets) {
        loader.addFont(rootBundle.load(asset));
      }
      await loader.load();
      loaded.add(family);
    }

    final root = Platform.environment['FLUTTER_ROOT'];
    final roboto = root == null ? null : Directory('$root/bin/cache/artifacts/material_fonts');
    if (roboto != null && roboto.existsSync()) {
      final loader = FontLoader('Roboto');
      final files = roboto
          .listSync()
          .whereType<File>()
          .where((f) => f.path.split('/').last.startsWith('Roboto-'))
          .toList();
      for (final file in files) {
        loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
      }
      if (files.isNotEmpty) {
        await loader.load();
        loaded.add('Roboto');
      }
    } else {
      notes.add(
        'Roboto was not loaded: FLUTTER_ROOT is ${root == null ? 'unset' : 'without material_fonts'}',
      );
    }
    return GalleyFonts._(Set.unmodifiable(loaded), List.unmodifiable(notes));
  }

  /// The families that were loaded.
  final Set<String> loaded;

  /// What could not be loaded, and why.
  final List<String> notes;

  /// One finding for each family the text under [root] asked for and did not get.
  List<Finding> missingIn(RenderObject root) {
    final missing = <String, int>{};
    var unnamed = 0;

    void span(InlineSpan s, String? inherited) {
      final family = s.style?.fontFamily ?? inherited;
      if (s is TextSpan && (s.text?.trim().isNotEmpty ?? false)) {
        if (family == null) {
          unnamed++;
        } else if (!loaded.contains(family) && family != testFont) {
          missing[family] = (missing[family] ?? 0) + 1;
        }
      }
      s.visitDirectChildren((child) {
        span(child, family);
        return true;
      });
    }

    void visit(RenderObject r) {
      if (r is RenderParagraph) span(r.text, null);
      r.visitChildren(visit);
    }

    visit(root);
    return [
      for (final MapEntry(key: family, value: count) in missing.entries)
        Finding(
          kind: 'missing-font',
          message:
              '$count text span(s) ask for "$family", which is not in the font manifest; they '
              'are drawn in a fallback',
        ),
      if (unnamed > 0)
        Finding(
          kind: 'default-font',
          message:
              '$unnamed text span(s) name no font family. A device draws them in its own font; '
              'this frame draws them in the test font',
        ),
    ];
  }

  static Future<List<({String family, List<String> assets})>> _manifest() async {
    final String text;
    try {
      text = await rootBundle.loadString('FontManifest.json');
    } on FlutterError {
      // An app with no fonts of its own and no Material icons has no manifest.
      return const [];
    }
    final json = jsonDecode(text);
    if (json is! List<Object?>) throw const FormatException('FontManifest.json: not a list');
    return [
      for (final (i, e) in json.indexed)
        () {
          final r = JsonReader(e, 'FontManifest.json[$i]');
          return (
            family: r.string('family'),
            assets: [
              for (final (j, f) in r.list('fonts').indexed)
                JsonReader(f, 'FontManifest.json[$i].fonts[$j]').string('asset'),
            ],
          );
        }(),
    ];
  }
}
