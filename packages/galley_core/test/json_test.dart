import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

void main() {
  Matcher failsNaming(String field) =>
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(field)));

  test('a missing required field names its full path', () {
    final json = {
      'bounds': {'left': 0, 'top': 0, 'width': 10, 'height': 10},
      'nodes': [
        {
          'path': <int>[],
          'type': 'App',
          'rect': {'left': 0, 'top': 0, 'width': 10},
        },
      ],
    };
    expect(() => FrameTree.fromJson(json, 'tree'), failsNaming('tree.nodes[0].rect.height'));
  });

  test('a mistyped field says what it got', () {
    expect(
      () => LogicalRect.fromJson({'left': '0', 'top': 0, 'width': 1, 'height': 1}, 'r'),
      failsNaming('r.left: expected a number, got a string'),
    );
  });

  test('a non-object is refused', () {
    expect(() => JsonReader([1], 'x'), failsNaming('x: expected an object, got a list'));
  });

  test('optional fields read null as absent, but not a wrong type', () {
    final r = JsonReader({'a': null, 'b': 3}, 'x');
    expect(r.optionalString('a'), isNull);
    expect(r.optionalString('missing'), isNull);
    expect(() => r.optionalString('b'), failsNaming('x.b'));
  });

  test('integers are not doubles', () {
    expect(
      () => JsonReader({
        'p': [1, 2.5],
      }, 'x').integers('p'),
      failsNaming('x.p[1]'),
    );
    expect(JsonReader({'n': 3}, 'x').number('n'), 3.0);
  });
}
