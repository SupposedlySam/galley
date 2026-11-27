import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:galley_core/galley_core.dart';
import 'package:galley_web/src/served_galley.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

/// A `galley serve` stand-in that answers [routes] by path, and logs every request.
(ServedGalley, List<http.Request>) serve(
  Map<String, (int, Object)> routes, {
  String page = 'http://localhost:7399/?by=Owner',
}) {
  final asked = <http.Request>[];
  final client = MockClient((request) async {
    asked.add(request);
    final (status, body) = routes[request.url.path] ?? (404, {'error': 'no such route'});
    return http.Response(
      body is String ? body : jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );
  });
  return (ServedGalley(client, Uri.parse(page)), asked);
}

void main() {
  final home = keyOf('home', pixel7);

  test("every call goes to the page's server under /api, without the page's ?by=", () async {
    final (api, asked) = serve({
      '/api/galley': (
        200,
        {
          'rounds': [1, 2],
        },
      ),
      '/api/marks': (200, {'items': <Object>[], 'damaged': <Object>[]}),
    });

    expect(await api.rounds(), [1, 2]);
    final marks = await api.marks();
    expect(marks.placed, isEmpty);
    expect(marks.damaged, isEmpty);

    expect(asked.map((r) => '${r.method} ${r.url}'), [
      'GET http://localhost:7399/api/galley',
      'GET http://localhost:7399/api/marks',
    ]);
  });

  test("a frame's file name, with its = and ;, reaches the server as written", () async {
    final name = 'records/${home.toString().replaceAll(';', ',')};x.json';
    final url = ServedGalley(
      MockClient((_) async => http.Response('', 200)),
      Uri.parse('http://localhost:7399/?by=Owner'),
    ).file(3, name);

    expect(url.query, isEmpty);
    expect(url.pathSegments, ['api', 'rounds', '3', ...name.split('/')]);
    expect(Uri.parse('$url').pathSegments, url.pathSegments, reason: 'it survives printing');
  });

  test('a round is read file by file, and a 404 is a file that is not there', () async {
    final files = roundFiles([home]);
    final (api, asked) = serve({
      for (final MapEntry(:key, :value) in files.entries) '/api/rounds/1/$key': (200, value!),
    });

    final round = await api.round(1);

    expect(round.frames.map((f) => f.record.key), [home]);
    expect(round.frames.single.tree?.nodes.map((n) => n.type), ['App', 'FilledButton']);
    expect(round.provenance, isA<Unrecorded<RoundProvenance>>(), reason: 'round.json was 404');
    expect(asked.map((r) => r.url.path), containsAll(files.keys.map((k) => '/api/rounds/1/$k')));
  });

  test('a round file that fails for any other reason is a refusal, not a missing file', () async {
    final (api, _) = serve({
      '/api/rounds/1/index.json': (200, roundFiles([home])['index.json']!),
      '/api/rounds/1/round.json': (500, {'error': 'the galley is damaged: round.json'}),
    });
    await expectLater(
      api.round(1),
      throwsA(
        isA<Refused>()
            .having((e) => e.kind, 'kind', RefusalKind.damaged)
            .having((e) => e.message, 'message', 'the galley is damaged: round.json'),
      ),
    );
  });

  test('raising posts the frame, the widget, the point, the note and who', () async {
    final mark = buttonMark('m1', home, by: 'Owner');
    final button = treeWithButton(pixel7).nodes[1];
    final (api, asked) = serve({
      '/api/marks': (201, {'mark': mark.toJson(), 'node': button.toJson(), 'round': 3}),
    });

    final raised = await api.raise(
      frame: home,
      target: const AtNode([0], at: (x: 205, y: 326)),
      note: 'make it primary',
      by: 'Owner',
    );

    expect((raised.mark.id, raised.node.type, raised.round), ('m1', 'FilledButton', 3));
    expect(asked.single.method, 'POST');
    expect(asked.single.headers['Content-Type'], startsWith('application/json'));
    expect(jsonDecode(asked.single.body), {
      'frame': '$home',
      'node': [0],
      'at': [205, 326],
      'note': 'make it primary',
      'by': 'Owner',
    });
  });

  test("recording posts the event to the mark's events", () async {
    final mark = buttonMark('m 1', home);
    final (api, asked) = serve({
      // The path as it is sent: the id's space is encoded.
      '/api/marks/m%201/events': (200, {'mark': mark.toJson()}),
    });

    await api.record('m 1', (at) => Verified(by: 'Owner', at: at));

    expect(asked.single.url.path, '/api/marks/m%201/events');
    expect(jsonDecode(asked.single.body), {
      'event': 'verified',
      'by': 'Owner',
    }, reason: 'the time is the server\'s, so none is sent');
  });

  test('a visit posts the round and who, and reads the round opened before, or none', () async {
    var before = <String, Object?>{'before': 2};
    final asked = <http.Request>[];
    final api = ServedGalley(
      MockClient((request) async {
        asked.add(request);
        return http.Response(jsonEncode(before), 200);
      }),
      Uri.parse('http://localhost:7399/?by=Owner'),
    );
    expect(await api.opened(3, by: 'Rae'), 2);
    before = {'before': null};
    expect(await api.opened(3, by: 'Rae'), isNull);
    before = {'before': 'two'};
    await expectLater(api.opened(3, by: 'Rae'), throwsFormatException);
    expect(asked.map((r) => '${r.method} ${r.url.path} ${r.body}'), [
      for (var i = 0; i < 3; i++) 'POST /api/visits {"round":3,"by":"Rae"}',
    ]);
  });

  group('a reply that is not a success', () {
    test("is a refusal in the backend's words", () async {
      final (api, _) = serve({
        '/api/marks': (
          409,
          {'error': 'mark m1 is open, and only an answered mark can be verified'},
        ),
      });
      await expectLater(
        api.marks(),
        throwsA(
          isA<Refused>()
              .having((e) => e.kind, 'kind', RefusalKind.conflict)
              .having((e) => e.message, 'message', contains('only an answered mark')),
        ),
      );
    });

    test('is still a refusal, naming the URL, when it says nothing', () async {
      final (api, _) = serve({
        '/api/marks': (503, {'busy': true}),
      });
      await expectLater(
        api.marks(),
        throwsA(
          isA<Refused>()
              .having((e) => e.kind, 'kind', RefusalKind.environment)
              .having((e) => e.message, 'message', 'http://localhost:7399/api/marks answered 503'),
        ),
      );
    });

    test('is a refusal naming the URL when it is not JSON, whatever its status', () async {
      for (final status in [200, 502]) {
        final (api, _) = serve({'/api/galley': (status, '<html>Bad gateway</html>')});
        await expectLater(
          api.rounds(),
          throwsA(
            isA<Refused>().having(
              (e) => e.message,
              'message',
              'http://localhost:7399/api/galley answered $status, not JSON',
            ),
          ),
          reason: 'status $status',
        );
      }
    });
  });
}
