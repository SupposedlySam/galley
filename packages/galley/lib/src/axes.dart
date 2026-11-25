import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:galley_core/galley_core.dart';

/// The built-in axes, and the values an app declares for each. The first value of each is its
/// reference (DESIGN D9).
///
/// Galley applies all of them through Flutter's own test hooks, never through the app's code
/// ([BuiltInAxes.apply]).
final class GalleyAxes {
  /// The axes. The defaults are Galley's opinion of a minimum review: a gesture phone and a
  /// 360-wide phone, text at 1.0× and 2.0×, light and dark, Android, English.
  GalleyAxes({
    List<DeviceProfile>? devices,
    this.textScales = const [1.0, 2.0],
    this.brightness = const [Brightness.light, Brightness.dark],
    this.platforms = const [TargetPlatform.android],
    this.locales = const [Locale('en')],
  }) : devices = devices ?? [DeviceProfile.pixel7, DeviceProfile.smallPhone];

  /// The devices.
  final List<DeviceProfile> devices;

  /// Text scales, such as 1.0 and 2.0.
  final List<double> textScales;

  /// Platform brightness values. An app with one look (dark only, say) declares one.
  final List<Brightness> brightness;

  /// Target platforms: scroll physics, page transitions, adaptive widgets.
  final List<TargetPlatform> platforms;

  /// Locales.
  final List<Locale> locales;
}

/// The built-in axes of one app: the [FrameAxis] list the planner crosses, and how to apply a
/// frame's value on each.
final class BuiltInAxes {
  /// The axes for [declared]. Throws an [ArgumentError] if an axis has no values or two values
  /// spell the same id ([FrameAxis] refuses both).
  BuiltInAxes(GalleyAxes declared)
    : _devices = _index('device', [for (final d in declared.devices) (d.id, d)]),
      _scales = _index('text-scale', [for (final s in declared.textScales) (_scaleId(s), s)]),
      _brightness = _index('brightness', [for (final b in declared.brightness) (b.name, b)]),
      _platforms = _index('platform', [for (final p in declared.platforms) (p.name, p)]),
      _locales = _index('locale', [for (final l in declared.locales) (l.toLanguageTag(), l)]);

  final _Indexed<DeviceProfile> _devices;
  final _Indexed<double> _scales;
  final _Indexed<Brightness> _brightness;
  final _Indexed<TargetPlatform> _platforms;
  final _Indexed<Locale> _locales;

  /// The axes, in the order the planner crosses them.
  List<FrameAxis> get frameAxes => [
    for (final a in [_devices, _scales, _brightness, _platforms, _locales]) a.axis,
  ];

  /// The device a frame with [key] is rendered on.
  DeviceProfile deviceOf(FrameKey key) => _devices.of(key);

  /// Puts [tester]'s view and platform into [key]'s values, and returns what puts them back.
  ///
  /// The undo must run before the test body ends. flutter_test checks after the body that
  /// [debugDefaultTargetPlatformOverride] is unset, before any tearDown would run. So the
  /// packer calls it in a `finally`, not through `addTearDown`.
  VoidCallback apply(WidgetTester tester, FrameKey key) {
    final device = _devices.of(key);
    final view = tester.view;
    final dpr = device.pixelRatio;
    view.physicalSize = Size(device.physicalWidth.toDouble(), device.physicalHeight.toDouble());
    view.devicePixelRatio = dpr;
    final padding = _fake(device.padding);
    view.padding = padding;
    view.viewPadding = padding;
    view.systemGestureInsets = _fake(device.gestureInsets);

    final dispatcher = tester.platformDispatcher;
    dispatcher.textScaleFactorTestValue = _scales.of(key);
    dispatcher.platformBrightnessTestValue = _brightness.of(key);
    final locale = _locales.of(key);
    dispatcher.localeTestValue = locale;
    dispatcher.localesTestValue = [locale];
    debugDefaultTargetPlatformOverride = _platforms.of(key);

    return () {
      debugDefaultTargetPlatformOverride = null;
      dispatcher.clearAllTestValues();
      view.reset();
    };
  }

  static FakeViewPadding _fake(EdgeInsetsPx e) =>
      FakeViewPadding(left: e.left, top: e.top, right: e.right, bottom: e.bottom);

  /// `1.0`, `1.3`, `2.0`: one decimal at least, so 1 and 1.0 are the same id.
  static String _scaleId(double s) {
    final text = s.toString();
    return text.contains('.') ? text : '$text.0';
  }

  static _Indexed<T> _index<T>(String id, List<(String, T)> values) => _Indexed(
    FrameAxis(id, [for (final (v, _) in values) v]),
    {for (final (v, t) in values) v: t},
  );
}

final class _Indexed<T> {
  _Indexed(this.axis, this._byValue);

  final FrameAxis axis;
  final Map<String, T> _byValue;

  String get id => axis.id;
  List<String> get values => axis.values;

  T of(FrameKey key) {
    final value = key[axis.id];
    final found = value == null ? null : _byValue[value];
    if (found == null) {
      throw StateError('frame $key has no known "${axis.id}" value (declared: ${axis.values})');
    }
    return found;
  }
}
