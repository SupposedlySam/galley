import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

void main() {
  test('keys built in any order are equal and print canonically', () {
    final a = FrameKey({'screen': 'home', 'device': 'pixel-7', 'text-scale': '2.0'});
    final b = FrameKey({'text-scale': '2.0', 'device': 'pixel-7', 'screen': 'home'});
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a.toString(), 'device=pixel-7;screen=home;text-scale=2.0');
    expect(FrameKey.parse(a.toString()), a);
  });

  test('a different value is a different frame', () {
    final a = FrameKey({'screen': 'home'});
    expect(a.withValue('screen', 'menu'), isNot(a));
    expect(a.withValue('screen', 'menu')['screen'], 'menu');
    expect(a['screen'], 'home', reason: 'withValue copies');
  });

  for (final bad in [
    '',
    'screen',
    'screen=',
    '=home',
    'screen=home;screen=menu',
    'screen=home;device=x', // not canonical
    'screen=ho me',
  ]) {
    test('parse refuses "$bad"', () => expect(() => FrameKey.parse(bad), throwsFormatException));
  }

  test('ids with separators or spaces are refused', () {
    expect(() => FrameKey({}), throwsArgumentError);
    expect(() => FrameKey({'a;b': 'c'}), throwsArgumentError);
    expect(() => FrameKey({'a': 'b=c'}), throwsArgumentError);
    expect(FrameKey.isValidId('text-scale_2.0'), isTrue);
  });
}
