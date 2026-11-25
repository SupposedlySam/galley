import 'frame_key.dart';
import 'json.dart';

/// Space the system takes from one edge of the screen, in physical pixels.
final class EdgeInsetsPx {
  /// Insets from their sides. None may be negative.
  const EdgeInsetsPx({this.left = 0, this.top = 0, this.right = 0, this.bottom = 0})
    : assert(left >= 0 && top >= 0 && right >= 0 && bottom >= 0, 'insets are never negative');

  /// Reads the form [toJson] writes.
  factory EdgeInsetsPx.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    final sides = [
      for (final s in const ['left', 'top', 'right', 'bottom']) r.number(s),
    ];
    if (sides.any((s) => s < 0)) throw FormatException('$context: insets are never negative');
    return EdgeInsetsPx(left: sides[0], top: sides[1], right: sides[2], bottom: sides[3]);
  }

  /// No insets.
  static const zero = EdgeInsetsPx();

  /// Left, in physical pixels.
  final double left;

  /// Top, in physical pixels.
  final double top;

  /// Right, in physical pixels.
  final double right;

  /// Bottom, in physical pixels.
  final double bottom;

  /// The JSON form [EdgeInsetsPx.fromJson] reads.
  JsonMap toJson() => {'left': left, 'top': top, 'right': right, 'bottom': bottom};
}

/// Whether a device's numbers were measured on the device or taken from somewhere weaker.
enum Provenance {
  /// Read from the device or its emulator image (`MediaQuery` logged once).
  measured,

  /// From a spec sheet or the platform's defaults. Shown on the frame, so a reviewer who sees a
  /// status bar overlap knows the inset itself may be the thing that is wrong.
  assumed,
}

/// A device a frame is rendered on: its screen, its pixel ratio, and what the system draws over
/// it.
///
/// Physical pixels, not logical ones, because that is how devices are specified, and a logical
/// size is a rounded quotient. The Pixel 7 is 1080 × 2400 at 2.625, which is 411.43 × 914.29,
/// not the 412 × 915 that device databases print.
final class DeviceProfile {
  /// A device from its parts. [source] says where each number came from.
  DeviceProfile({
    required this.id,
    required this.name,
    required this.physicalWidth,
    required this.physicalHeight,
    required this.pixelRatio,
    required this.provenance,
    required this.source,
    this.padding = EdgeInsetsPx.zero,
    this.gestureInsets = EdgeInsetsPx.zero,
  }) {
    if (!FrameKey.isValidId(id)) throw ArgumentError.value(id, 'id', 'not a valid value id');
    if (physicalWidth <= 0 || physicalHeight <= 0 || pixelRatio <= 0) {
      throw ArgumentError('device "$id": size and pixel ratio must be positive');
    }
  }

  /// Reads the form [toJson] writes.
  factory DeviceProfile.fromJson(Object? json, String context) {
    final r = JsonReader(json, context);
    final provenance = r.string('provenance');
    try {
      return DeviceProfile(
        id: r.string('id'),
        name: r.string('name'),
        physicalWidth: r.integer('width'),
        physicalHeight: r.integer('height'),
        pixelRatio: r.number('ratio'),
        provenance: Provenance.values.firstWhere(
          (p) => p.name == provenance,
          orElse: () => throw FormatException('$context.provenance: unknown "$provenance"'),
        ),
        source: r.string('source'),
        padding: r.read('padding', EdgeInsetsPx.fromJson),
        gestureInsets: r.read('gesture_insets', EdgeInsetsPx.fromJson),
      );
    } on ArgumentError catch (e) {
      throw FormatException('$context: ${e.message}');
    }
  }

  /// The id on the `device` axis, such as `pixel-7`.
  final String id;

  /// What a person calls it, such as `Pixel 7`.
  final String name;

  /// Screen width, in physical pixels.
  final int physicalWidth;

  /// Screen height, in physical pixels.
  final int physicalHeight;

  /// Physical pixels per logical pixel.
  final double pixelRatio;

  /// What the status bar, cutout and navigation bar cover (`MediaQuery.padding` before the
  /// keyboard), in physical pixels.
  final EdgeInsetsPx padding;

  /// Where a swipe is the system's, not the app's (`MediaQuery.systemGestureInsets`).
  final EdgeInsetsPx gestureInsets;

  /// Whether the numbers were measured.
  final Provenance provenance;

  /// Where they came from, with a link or a file path.
  final String source;

  /// Width in logical pixels.
  double get logicalWidth => physicalWidth / pixelRatio;

  /// Height in logical pixels.
  double get logicalHeight => physicalHeight / pixelRatio;

  /// The JSON form [DeviceProfile.fromJson] reads.
  JsonMap toJson() => {
    'id': id,
    'name': name,
    'width': physicalWidth,
    'height': physicalHeight,
    'ratio': pixelRatio,
    'padding': padding.toJson(),
    'gesture_insets': gestureInsets.toJson(),
    'provenance': provenance.name,
    'source': source,
  };

  /// A Pixel 7: a 412 × 915 gesture-navigation phone, Galley's default reference device.
  ///
  /// The size and ratio are confirmed. The insets are AOSP's and are **assumed** until someone
  /// logs them from the device:
  /// - top: 136 px, the panther overlay's `status_bar_height_portrait` on AOSP main, which
  ///   includes the punch hole. A 2022 commit had 118 px.
  /// - bottom: the gestural overlay's 24 dp `navigation_bar_height`.
  /// - gestures: the gestural overlay's 30 dp `config_backGestureInset` at the sides and 32 dp
  ///   `navigation_bar_gesture_height` at the bottom.
  static final pixel7 = DeviceProfile(
    id: 'pixel-7',
    name: 'Pixel 7',
    physicalWidth: 1080,
    physicalHeight: 2400,
    pixelRatio: 2.625,
    padding: const EdgeInsetsPx(top: 136, bottom: 24 * 2.625),
    gestureInsets: const EdgeInsetsPx(left: 30 * 2.625, right: 30 * 2.625, bottom: 32 * 2.625),
    provenance: Provenance.assumed,
    source:
        'size: blisk.io/devices/details/google-pixel-7; insets: AOSP device/google/pantah '
        'panther overlay dimens.xml (main) and NavigationBarModeGesturalOverlay',
  );

  /// A 360-dp-wide phone (720 × 1600 at 2.0, the Galaxy A06 class), with 3-button navigation.
  ///
  /// 360 dp is the narrowest width with usage data behind it (StatCounter, October 2026). Only
  /// the resolution is confirmed. The ratio is inferred, and the insets are AOSP's defaults
  /// (24 dp status bar, 48 dp 3-button bar), not Samsung's. A 3-button bar takes no gestures.
  static final smallPhone = DeviceProfile(
    id: 'small-phone',
    name: 'Small phone (360 dp)',
    physicalWidth: 720,
    physicalHeight: 1600,
    pixelRatio: 2,
    padding: const EdgeInsetsPx(top: 24 * 2, bottom: 48 * 2),
    provenance: Provenance.assumed,
    source:
        'resolution: Galaxy A06 spec; ratio inferred (720 px / 360 dp); insets: AOSP '
        'core/res/values/dimens.xml defaults',
  );
}
