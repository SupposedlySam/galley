import 'package:galley_core/galley_core.dart';
import 'package:test/test.dart';

import 'trees.dart';

void main() {
  const reanchorer = Reanchorer();

  Located located(Reanchoring r) {
    expect(r, isA<Located>(), reason: 'expected the anchor to be found, got $r');
    return r as Located;
  }

  Lost lost(Reanchoring r) {
    expect(r, isA<Lost>(), reason: 'expected the anchor to be lost, got $r');
    return r as Lost;
  }

  group('key', () {
    test('a unique key decides, even when everything else changed', () {
      final before = node([0, 1], 'ElevatedButton', key: 'order', label: 'Order', at: loc(10));
      final after = tree([
        root,
        node([0], 'Column'),
        // Same label and type elsewhere: the key must win over both.
        node([0, 0], 'ElevatedButton', label: 'Order', at: loc(10)),
        node([0, 1], 'FilledButton', key: 'order', label: 'Buy', at: loc(99)),
      ]);
      final r = located(reanchorer.locate(Anchor.of(before), after));
      expect(r.node.key, 'order');
      expect(r.node.type, 'FilledButton');
      expect(r.decidedBy, Evidence.key);
      expect(r.considered, after.nodes.length);
    });

    test('a key no longer in the tree is skipped, not fatal', () {
      final before = node([0], 'Text', key: 'gone', label: 'Hours');
      final after = tree([
        root,
        node([0], 'Text', label: 'Hours'),
        node([1], 'Text', label: 'Menu'),
      ]);
      final r = located(reanchorer.locate(Anchor.of(before), after));
      expect(r.node.semanticsLabel, 'Hours');
      expect(r.decidedBy, Evidence.semanticsLabel);
    });
  });

  group('narrowing', () {
    test('a shared label plus a call site identifies one of three buttons', () {
      final before = node([2], 'TextButton', label: 'Details', at: loc(40));
      final after = tree([
        root,
        node([0], 'TextButton', label: 'Details', at: loc(20)),
        node([1], 'TextButton', label: 'Details', at: loc(30)),
        node([2], 'TextButton', label: 'Details', at: loc(40)),
        node([3], 'TextButton', label: 'Close', at: loc(40)),
      ]);
      final r = located(reanchorer.locate(Anchor.of(before), after));
      expect(r.node.indexPath, [2]);
      expect(r.decidedBy, Evidence.location);
      // The label left three; the location chose among them. Not the close button, which
      // shares the call site but not the label: narrowing kept the label's verdict.
      expect(r.considered, 3);
    });

    test('identical cards from one call site are told apart by index path', () {
      // A ListView.builder: every card has the same location, type and (no) label.
      final before = node([0, 1], 'Card', at: loc(55));
      final after = tree([
        root,
        node([0], 'ListView'),
        for (var i = 0; i < 3; i++) node([0, i], 'Card', at: loc(55)),
      ]);
      final r = located(reanchorer.locate(Anchor.of(before), after));
      expect(r.node.indexPath, [0, 1]);
      expect(r.decidedBy, Evidence.indexPath);
      expect(r.considered, 3);
    });

    test('a shifted line falls back to the same file and type', () {
      final before = node([1], 'Image', at: loc(12));
      final after = tree([
        root,
        node([0], 'Text', at: loc(14)),
        node([1], 'Image', at: loc(15)), // three lines were added above it
        node([2], 'Image', at: loc(3, 1, 'package:app/other.dart')),
      ]);
      final r = located(reanchorer.locate(Anchor.of(before), after));
      expect(r.node.location, loc(15));
      expect(r.decidedBy, Evidence.fileAndType);
    });
  });

  group('a mark raised on a round before 0.3.9', () {
    // Its anchor keeps the absolute file:// URI the compiler recorded; rounds since record the
    // file inside the package.
    SourceLocation old(int line, [String file = 'lib/screen.dart']) =>
        SourceLocation('file:///home/owner/dev/app/$file', line, 5);
    SourceLocation now(int line, [String file = 'lib/screen.dart']) =>
        SourceLocation(file, line, 5);

    test('is found by its call site in a round that records the file inside the package', () {
      final before = node([2], 'TextButton', label: 'Details', at: old(40));
      final after = tree([
        root,
        node([0], 'TextButton', label: 'Details', at: now(20)),
        node([1], 'TextButton', label: 'Details', at: now(40, 'lib/other.dart')),
        node([2], 'TextButton', label: 'Details', at: now(40)),
      ]);
      final r = located(reanchorer.locate(Anchor.of(before), after));
      expect(r.node.indexPath, [2]);
      expect(r.decidedBy, Evidence.location);
    });

    test('is found by its file and type when the lines shifted', () {
      final before = node([1], 'Image', at: old(12));
      final after = tree([
        root,
        node([0], 'Image', at: now(15, 'lib/xscreen.dart')),
        node([1], 'Image', at: now(15)),
        node([2], 'Image', at: now(3, 'lib/other.dart')),
      ]);
      final r = located(reanchorer.locate(Anchor.of(before), after));
      expect(r.node.indexPath, [1]);
      expect(r.decidedBy, Evidence.fileAndType);
    });

    test('names the same file only where the absolute path ends in the relative one', () {
      final cases = {
        ('file:///home/owner/dev/app/lib/screen.dart', 'lib/screen.dart'): true,
        ('lib/screen.dart', 'file:///home/owner/dev/app/lib/screen.dart'): true,
        ('/home/owner/dev/app/lib/screen.dart', 'lib/screen.dart'): true,
        (r'C:\dev\app\lib\screen.dart', 'lib/screen.dart'): true,
        ('file:///home/my%20dev/app/lib/a%20b.dart', 'lib/a b.dart'): true,
        ('lib/screen.dart', 'lib/screen.dart'): true,
        ('file:///home/owner/dev/app/lib/xscreen.dart', 'lib/screen.dart'): false,
        ('file:///home/owner/dev/app/xlib/screen.dart', 'lib/screen.dart'): false,
        ('file:///a/app/lib/screen.dart', 'file:///b/app/lib/screen.dart'): false,
        ('lib/screen.dart', 'test/screen.dart'): false,
        ('package:app/screen.dart', 'screen.dart'): false,
        ('file:///a/app/lib/screen.dart', 'package:app/screen.dart'): false,
      };
      expect(cases.values.where((same) => same), hasLength(6));
      for (final MapEntry(key: (a, b), value: same) in cases.entries) {
        expect(
          SourceLocation(a, 1, 1).sameFile(SourceLocation(b, 1, 1)),
          same,
          reason: '$a and $b',
        );
      }
      const site = SourceLocation('lib/a.dart', 3, 4);
      expect(site.sameSite(const SourceLocation('file:///app/lib/a.dart', 3, 4)), isTrue);
      expect(site.sameSite(const SourceLocation('file:///app/lib/a.dart', 3, 5)), isFalse);
      expect(site.sameSite(const SourceLocation('file:///app/lib/a.dart', 2, 4)), isFalse);
    });
  });

  group('lost', () {
    test('candidates no evidence can split are Lost with all of them, not the first', () {
      // Two cards from one call site, and the anchor's path no longer exists (a card was
      // removed above it). Picking either would be a guess.
      final before = node([0, 2], 'Card', at: loc(55));
      final after = tree([
        root,
        node([0], 'ListView'),
        node([0, 0], 'Card', at: loc(55)),
        node([0, 1], 'Card', at: loc(55)),
      ]);
      final r = lost(reanchorer.locate(Anchor.of(before), after));
      expect(r.candidates.map((n) => n.indexPath), [
        [0, 0],
        [0, 1],
      ]);
    });

    test('an anchor nothing agrees with is Lost with no candidates', () {
      final before = node([5], 'Slider', key: 'volume', label: 'Volume', at: loc(80));
      final after = tree([
        root,
        node([0], 'Text', label: 'Hours', at: loc(3)),
        node([1], 'Slider', at: loc(2, 1, 'package:app/other.dart')),
      ]);
      expect(lost(reanchorer.locate(Anchor.of(before), after)).candidates, isEmpty);
    });

    test('a path alone never finds a widget of another type', () {
      // Population: the path exists, and a Card exists. Neither is the anchor.
      final before = node([1], 'Card');
      final after = tree([
        root,
        node([0], 'Card'),
        node([1], 'Text'),
      ]);
      expect(after.at([1]), isNotNull);
      expect(after.nodes.where((n) => n.type == 'Card'), isNotEmpty);
      expect(lost(reanchorer.locate(Anchor.of(before), after)).candidates, isEmpty);
    });
  });

  group('exact or moved', () {
    Located findShifted(double dx) {
      const rect = LogicalRect(100, 200, 100, 40);
      final before = node([0], 'Button', key: 'k', rect: rect);
      final after = tree([
        root,
        node([0], 'Button', key: 'k', rect: LogicalRect(rect.left + dx, rect.top, 100, 40)),
      ]);
      return located(reanchorer.locate(Anchor.of(before), after));
    }

    test('in place is Exact', () {
      final r = findShifted(0);
      expect(r.overlap, 1);
      expect(r.isExact, isTrue);
    });

    test('a 5 px nudge is still Exact; 6 px is Moved', () {
      expect(findShifted(5).isExact, isTrue);
      expect(findShifted(6).isExact, isFalse);
    });

    test('elsewhere entirely is Moved, and still found', () {
      final r = findShifted(250);
      expect(r.overlap, 0);
      expect(r.isExact, isFalse);
      expect(r.decidedBy, Evidence.key);
    });
  });

  test('matchers are pluggable and run in the order given', () {
    // With the index path first, the path decides even though a key also matches elsewhere.
    const pathFirst = Reanchorer(matchers: [IndexPathMatcher(), KeyMatcher()]);
    final before = node([0], 'Text', key: 'k');
    final after = tree([
      root,
      node([0], 'Text'),
      node([1], 'Text', key: 'k'),
    ]);
    expect(located(pathFirst.locate(Anchor.of(before), after)).node.indexPath, [0]);
    expect(located(reanchorer.locate(Anchor.of(before), after)).node.indexPath, [1]);
  });
}
