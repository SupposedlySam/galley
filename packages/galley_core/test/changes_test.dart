import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

import 'rounds.dart';

FrameKey _key(String screen) => FrameKey({'screen': screen, 'device': 'pixel-7'});

/// A frame of [screen] whose pixels digest to [pixels], with an image unless [image] is false.
RoundFrame _frame(String screen, String? pixels, {bool image = true}) {
  final r = frameRecord(_key(screen), tree: null);
  return RoundFrame(
    FrameRecord.fromJson({
      ...r.toJson(),
      if (image) 'image': 'frames/$screen.png',
      'pixels': ?pixels,
    }, screen),
    null,
  );
}

String _d(String c) => c * 64;

void main() {
  group('changesSince', () {
    test('says of every frame whether it is new, changed, the same or gone, in order', () {
      final since = [
        _frame('home', _d('a')),
        _frame('cart', _d('b')),
        _frame('old', _d('c')),
        _frame('menu', _d('d')),
      ];
      final shown = [
        _frame('menu', _d('d')),
        _frame('home', _d('e')),
        _frame('new', _d('f')),
        _frame('cart', _d('b')),
      ];
      expect(changesSince(since, shown, sinceN: 3, shownN: 5).map((c) => '$c'), [
        'FrameSame(${_key('menu')})',
        'FrameChanged(${_key('home')})',
        'FrameAdded(${_key('new')})',
        'FrameSame(${_key('cart')})',
        'FrameGone(${_key('old')})',
      ]);
    });

    test('a frame with no digest on either side is not compared, and says which and why', () {
      final since = [
        _frame('older', null),
        _frame('blank', null, image: false),
        _frame('both', _d('a')),
        _frame('now', _d('a')),
      ];
      final shown = [
        _frame('older', _d('a')),
        _frame('blank', _d('a')),
        _frame('both', _d('a')),
        _frame('now', null, image: false),
      ];
      final changes = changesSince(since, shown, sinceN: 3, shownN: 5);
      expect(
        [
          for (final c in changes)
            if (c case FrameUncompared(:final key, :final why)) (key.values['screen'], why),
        ],
        [
          ('older', 'round 3 did not record a digest of its pixels: it was packed before 0.3.10'),
          ('blank', 'nothing was captured of it in round 3'),
          ('now', 'nothing was captured of it in round 5'),
        ],
      );
      expect(changes[2], isA<FrameSame>(), reason: 'the one with both digests is compared');
      expect(changes, hasLength(4));
    });

    test('against the same round, every frame is the same', () {
      final round = [_frame('home', _d('a')), _frame('cart', _d('b'))];
      final changes = changesSince(round, round, sinceN: 5, shownN: 5);
      expect(changes, hasLength(2));
      expect(changes, everyElement(isA<FrameSame>()));
    });
  });
}
