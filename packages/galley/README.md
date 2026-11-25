# galley

Renders every screen × state × device of a Flutter app as a reviewable frame, inside the app's
own `flutter test`.

An app's whole integration is a `GalleyHost` in its `test/` and one line:

```dart
void main() => galley(MyAppHost());
```

The host declares the app's scenarios and the uris each one shows, and mounts the app on fresh
fakes for a frame. Galley derives the frames (screens × devices × text scales × brightness ×
platform × locale, by pairwise cover), sets each one up through Flutter's test hooks, renders
it twice, and checks where the app landed.

```sh
flutter test test/galley_test.dart --dart-define=GALLEY_OUT=build/galley/round-1
```

The full host example, what a round contains and the findings a frame can carry are in the
[repository README](https://github.com/SupposedlySam/galley#readme). The decisions behind them
are in [DESIGN.md](https://github.com/SupposedlySam/galley/blob/main/docs/DESIGN.md).

Requires Flutter 3.50 or later. `galley` is a dev dependency: it depends on `flutter_test` and
runs only in tests.
