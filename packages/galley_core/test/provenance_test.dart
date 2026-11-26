import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

RoundProvenance _full() => RoundProvenance(
  commit: const Known('d9a9f852efd81f114e96ef0c335ba8ddf7ec4c8a'),
  dirty: const Known(false),
  flutter: const Known('3.50.0'),
  at: DateTime.utc(2026, 11, 26, 12),
);

void main() {
  test('round-trips through JSON, known and unrecorded alike', () {
    final known = _full();
    final back = RoundProvenance.fromJson(known.toJson(), 'round');
    expect(back.toJson(), known.toJson());
    expect((back.commit as Known<String>).value, 'd9a9f852efd81f114e96ef0c335ba8ddf7ec4c8a');
    expect((back.dirty as Known<bool>).value, isFalse);

    final unknown = RoundProvenance(
      commit: Unrecorded('not a git checkout'),
      dirty: Unrecorded('not a git checkout'),
      flutter: Unrecorded('FLUTTER_ROOT is not set'),
      at: DateTime.utc(2026, 11, 26, 12),
    );
    final back2 = RoundProvenance.fromJson(unknown.toJson(), 'round');
    expect(back2.toJson(), unknown.toJson());
    expect((back2.commit as Unrecorded).reason, 'not a git checkout');
    expect(back2.dirty, isA<Unrecorded<bool>>());
  });

  test('a missing or empty field is refused, never read as unknown', () {
    for (final field in ['commit', 'dirty', 'flutter', 'at']) {
      expect(
        () => RoundProvenance.fromJson(_full().toJson()..remove(field), 'round'),
        throwsFormatException,
        reason: field,
      );
    }
    expect(
      () => RoundProvenance.fromJson(_full().toJson()..['commit'] = <String, Object?>{}, 'round'),
      throwsFormatException,
    );
    expect(
      () => RoundProvenance.fromJson(
        _full().toJson()..['commit'] = {'value': 'abc1234', 'unknown': 'both'},
        'round',
      ),
      throwsFormatException,
    );
  });

  test('a known value of the wrong type, or a commit that is not a sha, is refused', () {
    expect(
      () => RoundProvenance.fromJson(_full().toJson()..['dirty'] = {'value': 'no'}, 'round'),
      throwsFormatException,
    );
    expect(
      () => RoundProvenance.fromJson(_full().toJson()..['commit'] = {'value': 'main'}, 'round'),
      throwsFormatException,
    );
    expect(
      () => RoundProvenance(
        commit: const Known('main'),
        dirty: const Known(false),
        flutter: const Known('3.50.0'),
        at: DateTime.utc(2026),
      ),
      throwsArgumentError,
    );
  });

  test('a time without a zone is refused', () {
    expect(
      () => RoundProvenance.fromJson(_full().toJson()..['at'] = '2026-11-26T12:00:00', 'round'),
      throwsFormatException,
    );
    expect(
      () => RoundProvenance(
        commit: Unrecorded('x'),
        dirty: Unrecorded('x'),
        flutter: Unrecorded('x'),
        at: DateTime(2026),
      ),
      throwsArgumentError,
    );
  });

  test('an unrecorded value must say why', () {
    expect(() => Unrecorded<String>(' '), throwsArgumentError);
  });
}
