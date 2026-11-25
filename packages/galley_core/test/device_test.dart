import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

void main() {
  test('the Pixel 7 is 411.43 × 914.29 logical, not the rounded 412 × 915', () {
    final d = DeviceProfile.pixel7;
    expect(d.logicalWidth, closeTo(411.43, 0.005));
    expect(d.logicalHeight, closeTo(914.29, 0.005));
  });

  test('the small phone is 360 wide', () {
    expect(DeviceProfile.smallPhone.logicalWidth, 360);
  });

  test('every preset says its numbers are assumed until measured, and where they came from', () {
    for (final d in [DeviceProfile.pixel7, DeviceProfile.smallPhone]) {
      expect(d.provenance, Provenance.assumed, reason: d.id);
      expect(d.source, isNotEmpty, reason: d.id);
    }
  });

  test('round-trips through json, every field', () {
    final d = DeviceProfile.pixel7;
    final back = DeviceProfile.fromJson(d.toJson(), 'device');
    expect(back.toJson(), d.toJson());
    expect(back.gestureInsets.left, d.gestureInsets.left);
    expect(back.padding.top, 136);
  });

  test('refuses a broken device', () {
    final json = DeviceProfile.smallPhone.toJson();
    expect(() => DeviceProfile.fromJson({...json, 'ratio': 0}, 'd'), throwsFormatException);
    expect(
      () => DeviceProfile.fromJson({...json, 'provenance': 'guessed'}, 'd'),
      throwsFormatException,
    );
    expect(
      () => DeviceProfile.fromJson({
        ...json,
        'padding': {'left': -1, 'top': 0, 'right': 0, 'bottom': 0},
      }, 'd'),
      throwsFormatException,
    );
    expect(() => DeviceProfile.fromJson({...json, 'id': 'a b'}, 'd'), throwsFormatException);
  });
}
