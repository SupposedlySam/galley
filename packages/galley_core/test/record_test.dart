import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

FrameRecord _record({
  FrameStatus status = FrameStatus.rendered,
  List<String> errors = const [],
  Landing? landing,
}) => FrameRecord(
  key: FrameKey({'screen': 'home', 'device': 'pixel-7'}),
  scenario: 'base',
  uri: Uri.parse('/home?tab=a'),
  landing: landing ?? LandedAt(Uri.parse('/home?tab=a')),
  status: status,
  device: DeviceProfile.pixel7,
  essential: true,
  errors: errors,
  findings: [
    Finding(kind: 'frozen', message: 'still animating', rect: const LogicalRect(1, 2, 3, 4)),
  ],
  image: 'frames/x.png',
  pixels: _digest,
  tree: 'trees/x.json',
);

final _digest = 'ab' * 32;

void main() {
  group('FrameRecord', () {
    test('round-trips through JSON, every field', () {
      final r = _record(
        status: FrameStatus.error,
        errors: ['boom'],
        landing: const LandingUnknown('no router'),
      );
      final back = FrameRecord.fromJson(r.toJson(), 'r');
      expect(back.toJson(), r.toJson());
      expect(back.key, r.key);
      expect(back.landing, isA<LandingUnknown>());
      expect(back.findings.single.rect, const LogicalRect(1, 2, 3, 4));
      expect(back.device.provenance, Provenance.assumed);
      expect(back.pixels, _digest);
    });

    test('a digest of pixels is read when there is none, and refused when it cannot be one', () {
      final older = _record().toJson()..remove('pixels');
      expect(FrameRecord.fromJson(older, 'r').pixels, isNull, reason: 'packed before 0.3.10');
      expect(FrameRecord.fromJson(older, 'r').image, 'frames/x.png');
      for (final bad in ['AB' * 32, 'ab' * 31, 'zz' * 32, '']) {
        expect(
          () => FrameRecord.fromJson(_record().toJson()..['pixels'] = bad, 'r'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('SHA-256'))),
          reason: bad,
        );
      }
      expect(
        () => FrameRecord.fromJson(_record().toJson()..remove('image'), 'r'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('no image'))),
      );
    });

    test('an error needs an error, and only an error may have one', () {
      expect(() => _record(status: FrameStatus.error), throwsArgumentError);
      expect(() => _record(errors: ['x']), throwsArgumentError);
      expect(() => _record(status: FrameStatus.frozen, errors: ['x']), throwsArgumentError);
      expect(_record(status: FrameStatus.frozen).errors, isEmpty);
    });

    test('a stored record that breaks the rule is a FormatException', () {
      final json = _record().toJson()..['errors'] = ['x'];
      expect(() => FrameRecord.fromJson(json, 'r'), throwsFormatException);
    });

    test('an unknown status or a missing field is refused, never defaulted', () {
      expect(
        () => FrameRecord.fromJson(_record().toJson()..['status'] = 'fine', 'r'),
        throwsFormatException,
      );
      for (final field in ['landing', 'essential', 'device', 'errors', 'findings']) {
        expect(
          () => FrameRecord.fromJson(_record().toJson()..remove(field), 'r'),
          throwsFormatException,
          reason: field,
        );
      }
    });
  });

  group('Landing', () {
    test('needs exactly one of uri and unknown', () {
      expect(() => Landing.fromJson(<String, Object?>{}, 'l'), throwsFormatException);
      expect(() => Landing.fromJson({'uri': '/', 'unknown': 'x'}, 'l'), throwsFormatException);
    });

    test('isAt: same path and query, in any order; trailing slash and fragment ignored', () {
      final at = LandedAt(Uri.parse('/a/b?x=1&y=2#frag'));
      expect(at.isAt(Uri.parse('/a/b?y=2&x=1')), isTrue);
      expect(at.isAt(Uri.parse('/a/b/?x=1&y=2')), isTrue);
      expect(at.isAt(Uri.parse('/a/b?x=1')), isFalse);
      expect(at.isAt(Uri.parse('/a/b?x=1&y=3')), isFalse);
      expect(at.isAt(Uri.parse('/a')), isFalse);
      expect(LandedAt(Uri.parse('')).isAt(Uri.parse('/')), isTrue);
      expect(
        LandedAt(Uri.parse('/a?x=1&x=2')).isAt(Uri.parse('/a?x=2&x=1')),
        isFalse,
        reason: 'repeated parameters keep their order',
      );
    });
  });

  test('Finding refuses a kind that is not an id', () {
    expect(() => Finding(kind: 'two words', message: 'm'), throwsArgumentError);
  });
}
