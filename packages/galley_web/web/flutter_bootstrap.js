{{flutter_js}}
{{flutter_build_config}}

// The canvas loads nothing from outside the machine that serves it (docs/DESIGN.md D14).
//
// CanvasKit and Roboto are bundled (`--no-web-resources-cdn`, and fonts/ in pubspec.yaml). What
// is left is the engine's font fallback: a glyph no bundled font has, such as an emoji in a
// reviewer's note, makes it fetch a Noto font from https://fonts.gstatic.com/s/. Observed on
// the first adopter's round, before the tiles stopped drawing '⚠'. Pointing the fallback at a
// path on the canvas's own server, where no fonts are, turns that fetch into a local 404, and
// the glyph is drawn as a box. Rejected: bundling the Noto fallbacks, megabytes for glyphs a
// note rarely has; and leaving the default, which tells a font CDN that someone is reviewing.
//
// No service worker either: Flutter's is deprecated, and a canvas served by `galley serve`
// from this machine has nothing to cache for offline.
_flutter.loader.load({
  config: {
    fontFallbackBaseUrl: 'no-fallback-fonts/',
  },
});
