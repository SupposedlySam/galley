import 'package:galley_core/galley_core.dart';
import 'package:galley_server/judge.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// What [judge] said: null for ok, else the reason.
String? said(JsonMap request) => switch (judge(request)) {
  {'ok': true} => null,
  {'refused': final String why} => why,
  final other => throw StateError('neither ok nor refused: $other'),
};

final sha = 'a' * 64;
JsonMap entry(String path, [int size = 10]) => {'path': path, 'sha256': sha, 'size': size};

void main() {
  group('a new mark', () {
    JsonMap raise({
      JsonMap? mark,
      int number = 4,
      bool finished = true,
      int? newest = 4,
      List<String>? frames,
    }) => {
      'write': 'mark',
      'mark': mark ?? {...markRow('m1')}
        ..remove('id'),
      'round': {
        'number': number,
        'finished': finished,
        'frames': frames ?? ['$home'],
      },
      'newest': newest,
    };

    test('on a frame of the newest finished round is taken', () {
      expect(said(raise()), isNull);
    });

    test('is refused, saying why, on any other round, frame or note', () {
      expect(
        [
          said(raise(number: 3)),
          said(raise(finished: false, newest: 3)),
          said(raise(frames: ['screen=settings'])),
          said(raise(mark: {...markRow('m1'), 'note': ' '})),
          said(raise(mark: {...markRow('m1'), 'note': 'x' * (maxNoteLength + 1)})),
        ],
        [
          'round 3 is out: round 4 is the newest; reload',
          'round 4 is still being pushed',
          'round 4 has no frame $home',
          'a mark says what is wrong',
          "a mark's note is 4001 characters, more than 4000",
        ],
      );
    });

    test('is refused, naming the field, when its anchor, pin or frame does not read', () {
      expect(
        [
          said(
            raise(
              mark: {
                ...markRow('m1'),
                'pin': {'dx': 1.5, 'dy': 0},
              },
            ),
          ),
          said(
            raise(
              mark: {
                ...markRow('m1'),
                'anchor': {'type': 'X'},
              },
            ),
          ),
          said(raise(mark: {...markRow('m1'), 'frame': 'nope'})),
        ],
        [
          startsWith('request.mark.pin: dx and dy are fractions in 0..1'),
          startsWith('request.mark.anchor.path: missing'),
          startsWith('request.mark.frame: frame key part "nope"'),
        ],
      );
    });
  });

  group('an event', () {
    JsonMap record(
      JsonMap event, {
      String role = 'reviewer',
      String by = 'Rae',
      List<JsonMap> history = const [],
    }) => {
      'write': 'event',
      'mark': markRow('m1'),
      'history': history,
      'event': event,
      'role': role,
      'by': by,
    };
    final answered = [eventRow0('answered', answer: 'wont_fix', note: 'by design')];
    final wontFix = {'kind': 'answered', 'answer': 'wont_fix', 'note': 'by design', 'commit': ''};

    test("the mark's history allows is taken, from whoever it allows", () {
      expect(
        [
          said(record(wontFix, role: 'owner', by: 'Owner')),
          said(record({'kind': 'verified'}, history: answered)),
          // The owner may verify their own answer (DESIGN D15).
          said(record({'kind': 'verified'}, role: 'owner', by: 'Owner', history: answered)),
          said(record({'kind': 'reopened', 'note': 'it is not'}, history: answered)),
          said(record({'kind': 'withdrawn', 'note': 'dupe'})),
        ],
        [null, null, null, null, null],
      );
    });

    test('is refused, in the core\'s words, when the history does not allow it', () {
      expect(
        [
          said(record({'kind': 'verified'})),
          said(record(wontFix, role: 'owner', by: 'Owner', history: answered)),
          said(record({'kind': 'withdrawn', 'note': 'mine now'}, by: 'Owner', role: 'owner')),
          said(record({'kind': 'reopened', 'note': ''}, history: answered)),
        ],
        [
          'mark m1 is open, and cannot be verified now',
          'mark m1 is answered, and cannot be answered now',
          'mark m1 was raised by Rae, and only they can withdraw it',
          'request.event.note: missing, expected a string',
        ],
      );
    });

    test('an answer is refused from a reviewer, and one past the limit from anyone', () {
      expect(said(record(wontFix)), "only the galley's owner answers a mark");
      expect(
        said(record({...wontFix, 'note': 'x' * (maxNoteLength + 1)}, role: 'owner', by: 'O')),
        "an answer's note is 4001 characters, more than 4000",
      );
      expect(
        said(record({'kind': 'answered', 'answer': 'fixed', 'commit': 'nothex'}, role: 'owner')),
        contains('commit'),
      );
    });

    test("the writer's by is the request's, never the event's own", () {
      // The columns claim Rae, who raised the mark; the hook says the writer is Owner.
      expect(
        said(record({'kind': 'withdrawn', 'note': 'dupe', 'by': 'Rae'}, by: 'Owner')),
        'mark m1 was raised by Rae, and only they can withdraw it',
      );
    });

    test('on a mark whose stored history does not fold is refused, naming it', () {
      expect(
        said(record({'kind': 'withdrawn', 'note': 'x'}, history: [eventRow0('verified')])),
        'request.mark.history: mark m1, event 0: is open, and cannot be verified now',
      );
    });
  });

  group('a round', () {
    JsonMap push(int number, int? newest, [List<JsonMap>? manifest]) => {
      'write': 'round',
      'round': {
        'number': number,
        'frames': ['$home'],
        'manifest': manifest ?? [entry('index.json')],
      },
      'newest': newest,
    };

    test('is the next number, from 1', () {
      expect([said(push(1, null)), said(push(5, 4))], [null, null]);
      expect(
        [said(push(2, null)), said(push(4, 4)), said(push(7, 4))],
        [
          'round 2 is not next: the next round is 1',
          'round 4 is not next: the next round is 5',
          'round 7 is not next: the next round is 5',
        ],
      );
    });

    test('lists only safe relative paths, each once, with a SHA-256 and a size in the limit', () {
      final refusals = [
        for (final m in [
          [entry('../escape.png')],
          [entry('/abs.png')],
          [entry('frames//a.png')],
          [entry('frames/./a.png')],
          [entry(r'frames\a.png')],
          [entry('')],
          [entry('a.png'), entry('a.png')],
          [
            {...entry('a.png'), 'sha256': 'A' * 64},
          ],
          [entry('a.png', -1)],
          [entry('a.png', maxFileBytes + 1)],
          [for (var i = 0; i <= maxManifestFiles; i++) entry('f$i')],
        ])
          said(push(1, null, m)),
      ];
      expect(refusals, [
        'request.round.manifest[0].path: "../escape.png" is not a relative path inside the round',
        'request.round.manifest[0].path: "/abs.png" is not a relative path inside the round',
        'request.round.manifest[0].path: "frames//a.png" is not a relative path inside the round',
        'request.round.manifest[0].path: "frames/./a.png" is not a relative path inside the round',
        'request.round.manifest[0].path: "frames\\a.png" is not a relative path inside the round',
        'request.round.manifest[0].path: "" is not a relative path inside the round',
        'request.round.manifest[1].path: a.png is listed twice',
        'request.round.manifest[0].sha256: expected 64 lower-case hex digits',
        'request.round.manifest[0].size: -1 bytes, outside 0 to $maxFileBytes',
        'request.round.manifest[0].size: ${maxFileBytes + 1} bytes, outside 0 to $maxFileBytes',
        'request.round.manifest: ${maxManifestFiles + 1} files, more than $maxManifestFiles',
      ]);
      // At the limits, taken.
      expect(
        said(
          push(1, null, [
            entry('frames/a b.png', maxFileBytes),
            for (var i = 1; i < maxManifestFiles; i++) entry('f$i', 0),
          ]),
        ),
        isNull,
      );
    });
  });

  group('a file', () {
    JsonMap upload(
      String path,
      int size, {
      bool finished = false,
      List<String> existing = const [],
    }) => {
      'write': 'file',
      'round': {
        'finished': finished,
        'manifest': [entry('index.json', 10), entry('frames/a.png', 99)],
      },
      'path': path,
      'size': size,
      'existing': existing,
    };

    test('is one the manifest lists, at its size, not yet uploaded, before the finish', () {
      expect(said(upload('frames/a.png', 99, existing: ['index.json'])), isNull);
      expect(
        [
          said(upload('frames/b.png', 99)),
          said(upload('frames/a.png', 98)),
          said(upload('frames/a.png', 99, existing: ['frames/a.png'])),
          said(upload('frames/a.png', 99, finished: true)),
        ],
        [
          "the round's manifest does not list frames/b.png",
          'frames/a.png is 98 bytes, and the manifest says 99',
          'the round already has frames/a.png',
          'the round is finished, and a finished round is not changed',
        ],
      );
    });
  });

  group('the finish', () {
    // Any placement but Raised: which one is the carry's business, not the finish's.
    final retired = {'kind': 'retired'};
    JsonMap finish({
      List<String> files = const ['index.json', 'frames/a.png'],
      List<JsonMap>? placements,
      List<String> marks = const ['m1', 'm2'],
      bool finished = false,
    }) => {
      'write': 'finish',
      'round': {
        'number': 5,
        'finished': finished,
        'manifest': [entry('index.json'), entry('frames/a.png')],
      },
      'files': files,
      'marks': [for (final id in marks) markRow(id)],
      // In the form the round stores them, Placements.toJson's.
      'placements': {
        'placements':
            placements ??
            [
              for (final id in marks) {'mark': id, 'placement': retired, 'anchor': anchor},
            ],
      },
    };

    test('is taken with every file uploaded and every earlier mark placed', () {
      expect(said(finish()), isNull);
      expect(said(finish(marks: const [])), isNull, reason: 'a first round places nothing');
    });

    test('is refused, saying what is missing, when a file or a mark is', () {
      expect(
        [
          said(finish(files: ['index.json'])),
          said(
            finish(
              placements: [
                {'mark': 'm1', 'placement': retired, 'anchor': anchor},
              ],
            ),
          ),
          said(finish(finished: true)),
        ],
        [
          'round 5 is missing 1 of its files: frames/a.png',
          'round 5 does not place m2; carry every mark again',
          'round 5 is already finished',
        ],
      );
    });

    test('is refused when a placement names no earlier mark, or says one was raised here', () {
      expect(
        [
          said(
            finish(
              placements: [
                {'mark': 'm1', 'placement': retired, 'anchor': anchor},
                {'mark': 'm2', 'placement': retired, 'anchor': anchor},
                {'mark': 'm9', 'placement': retired, 'anchor': anchor},
              ],
            ),
          ),
          said(
            finish(
              placements: [
                {
                  'mark': 'm1',
                  'placement': {'kind': 'raised'},
                  'anchor': anchor,
                },
                {'mark': 'm2', 'placement': retired, 'anchor': anchor},
              ],
            ),
          ),
        ],
        [
          'request.placements.placements[2].mark: no mark "m9"',
          'mark m1 was raised on an earlier round, not 5',
        ],
      );
    });

    test('is refused when a placement places a mark twice', () {
      expect(
        said(
          finish(
            placements: [
              {'mark': 'm1', 'placement': retired, 'anchor': anchor},
              {'mark': 'm2', 'placement': retired, 'anchor': anchor},
              {'mark': 'm1', 'placement': retired, 'anchor': anchor},
            ],
          ),
        ),
        'request.placements.placements: mark "m1" places this mark twice',
      );
    });

    test('names at most three missing files, and how many there are', () {
      String? missing(int count) => said(
        finish(files: const [])
          ..['round'] = {
            'number': 5,
            'finished': false,
            'manifest': [for (var i = 0; i < count; i++) entry('f$i.png')],
          },
      );
      expect(
        [missing(3), missing(4), missing(5)],
        [
          'round 5 is missing 3 of its files: f0.png, f1.png, f2.png',
          'round 5 is missing 4 of its files: f0.png, f1.png, f2.png, ...',
          'round 5 is missing 5 of its files: f0.png, f1.png, f2.png, ...',
        ],
      );
    });
  });

  group('an alias', () {
    String? accept(String alias, [List<String> aliases = const ['Owner', 'Sam  Lee']]) =>
        said({'write': 'member', 'alias': alias, 'aliases': aliases});

    test("is letters, digits, spaces, '.', '-' or \"'\", 1 to 40 of them", () {
      expect(
        [
          for (final a in ['Rae', 'Zoë', "D'Arcy-Lee Jr.", '王小明', 'a' * 40, 'R2']) accept(a),
        ],
        [null, null, null, null, null, null],
      );
      expect(
        [
          for (final a in [
            '',
            'a' * 41,
            'Rae\n',
            'Rae\u0007',
            '<b>Rae</b>',
            'Rae@x',
            ' Rae',
            'Rae ',
          ])
            accept(a),
        ],
        [
          for (final a in ['', 'a' * 41, 'Rae\n', 'Rae\u0007', '<b>Rae</b>', 'Rae@x'])
            'an alias is 1 to 40 letters, digits, spaces, ".", "-" or "\'": "$a" is not',
          'an alias does not start or end with a space',
          'an alias does not start or end with a space',
        ],
      );
    });

    test("is not another member's, ignoring case and runs of spaces", () {
      expect(
        [accept('owner'), accept('sam lee'), accept('SAM   LEE'), accept('Sam Lees')],
        [
          'a member of this galley is already "owner"',
          'a member of this galley is already "sam lee"',
          'a member of this galley is already "SAM   LEE"',
          null,
        ],
      );
    });
  });

  group('a visit', () {
    String? visit(JsonMap visit, {JsonMap? kept, List<int> finished = const [1, 2, 3]}) =>
        said({'write': 'visit', 'visit': visit, 'kept': kept, 'finished': finished});

    test('is a first visit, or the round opened after the one kept, to a finished round', () {
      expect(
        [
          visit({'latest': 1}),
          visit({'latest': 3, 'before': 1}, kept: {'latest': 1}),
          visit({'latest': 3, 'before': 2}, kept: {'latest': 2, 'before': 1}),
        ],
        [null, null, null],
      );
    });

    test('is refused, saying why, out of order, to a round not finished, or not newer', () {
      expect(
        [
          visit({'latest': 4}),
          visit({'latest': 2, 'before': 1}),
          visit({'latest': 3}, kept: {'latest': 2}),
          visit({'latest': 3, 'before': 1}, kept: {'latest': 2, 'before': 1}),
          visit({'latest': 2, 'before': 1}, kept: {'latest': 2, 'before': 1}),
          visit({'latest': 2}, kept: {'latest': 3, 'before': 1}),
          visit({'latest': 3, 'before': 3}),
        ],
        [
          'the galley has no finished round 4',
          'a visit to round 2 after none is before none, not 1',
          'a visit to round 3 after round 2 is before 2, not none',
          'a visit to round 3 after round 2 is before 2, not 1',
          'round 2 is no newer than round 2, opened already',
          'round 2 is no newer than round 3, opened already',
          startsWith('request.visit: '),
        ],
      );
    });
  });

  test('a request it does not read is refused, never passed', () {
    expect(
      [
        said({'write': 'delete'}),
        said({'mark': markRow('m1')}),
        said({'write': 'event', 'mark': markRow('m1')}),
      ],
      [
        'request.write: no write "delete"',
        'request.write: missing, expected a string',
        startsWith('request.history: missing'),
      ],
    );
    expect(judge('not an object'), {'refused': 'request: expected an object, got a string'});
  });
}
