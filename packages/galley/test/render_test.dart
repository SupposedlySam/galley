import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:galley/galley.dart';
import 'package:galley/src/axes.dart';
import 'package:galley/src/capture.dart';
import 'package:galley/src/fonts.dart';
import 'package:galley/src/render.dart';
import 'package:galley_core/galley_core.dart';

import 'support/toy_app.dart';

/// A host whose mount is the toy app, with screens a test adds.
class ToyHost extends GalleyHost {
  ToyHost({this.screens = const {}, this.arrival, this.bare});

  final Map<String, WidgetBuilder> screens;
  final Future<void> Function(WidgetTester tester)? arrival;

  /// When set, mount this instead of the router app.
  final Widget? bare;

  int mounts = 0;

  @override
  List<GalleyScenario> get scenarios => [
    GalleyScenario('base', screens: [Uri.parse('/home')]),
  ];

  @override
  List<String> get sourceRoots => const ['test/support'];

  @override
  Future<Widget> mount(GalleyFrame frame) async {
    mounts++;
    return bare ?? ToyApp(opening: frame.uri, screens: screens);
  }

  @override
  Future<void> arrive(WidgetTester tester, GalleyFrame frame) async => arrival?.call(tester);
}

final _builtIn = BuiltInAxes(GalleyAxes());

GalleyFrame _frame(String path, {String device = 'pixel-7', String scale = '1.0'}) => GalleyFrame(
  key: FrameKey({
    'scenario': 'base',
    'screen': 'x',
    'device': device,
    'text-scale': scale,
    'brightness': 'light',
    'platform': 'android',
    'locale': 'en',
  }),
  scenario: GalleyScenario('base', screens: [Uri.parse(path)]),
  uri: Uri.parse(path),
  essential: true,
);

void main() {
  late GalleyFonts fonts;
  setUpAll(() async => fonts = await GalleyFonts.load());

  FrameRenderer renderer(GalleyHost host, Duration? mountBudget) => FrameRenderer(
    host: host,
    recorder: TreeRecorder(roots: ['${_cwd()}/test/support']),
    fonts: fonts,
    mountBudget: mountBudget ?? FrameRenderer.defaultMountBudget,
  );

  Future<RenderOutcome> render(
    WidgetTester tester,
    GalleyHost host,
    GalleyFrame frame, {
    Duration? mountBudget,
  }) async {
    final undo = _builtIn.apply(tester, frame.key);
    try {
      return await renderer(host, mountBudget).render(tester, frame);
    } finally {
      undo();
    }
  }

  testWidgets('a screen that settles: landed, recorded, captured, no errors', (tester) async {
    final o = await render(tester, ToyHost(), _frame('/home'));

    expect(o.errors, isEmpty);
    expect(o.frozen, isFalse);
    expect((o.landing as LandedAt).uri, Uri.parse('/home'));
    // The population, not just "no errors": the toy's own widgets are there, by type, and the
    // framework's are not.
    final types = [for (final n in o.tree!.nodes) n.type];
    expect(types.first, 'Frame');
    // Widgets constructed in the app's source count, Flutter's own types included: a designer
    // means this Scaffold. Those constructed inside Flutter (RichText, inside Text) do not, and
    // neither does ToyApp, which the host constructs outside the roots.
    expect(
      types,
      containsAll(['MaterialApp', 'HomeScreen', 'Scaffold', 'Text', 'ElevatedButton', 'SizedBox']),
    );
    expect(types, isNot(contains('RichText')));
    expect(types, isNot(contains('ToyApp')));
    final where = o.tree!.nodes.singleWhere((n) => n.key == "[<'where'>]");
    expect(where.location!.file, endsWith('test/support/toy_app.dart'));
    // Pixel 7: 1080 × 2400 physical.
    expect((o.pixels!.width, o.pixels!.height), (1080, 2400));
    expect(o.tree!.bounds.width, closeTo(411.43, 0.01));
  });

  testWidgets('a redirect is an error naming both uris', (tester) async {
    final o = await render(tester, ToyHost(), _frame('/redirect'));
    expect(o.errors, ['expected /redirect, landed at /home']);
  });

  testWidgets('arrive reaches a screen no uri opens, and stopping short is an error', (
    tester,
  ) async {
    // The toy sends a direct open of /redirect to /home, like a guard. Only a scripted arrival
    // (a tap, here a delegate call) gets there, like a timer that holds in-memory state.
    final host = ToyHost(
      arrival: (tester) async {
        final router = tester.widget<Router<Object?>>(find.byWidgetPredicate((w) => w is Router));
        (router.routerDelegate as ToyDelegate).go(Uri.parse('/redirect'));
      },
    );
    final reached = await render(tester, host, _frame('/redirect'));
    expect(reached.errors, isEmpty);
    expect((reached.landing as LandedAt).uri, Uri.parse('/redirect'));

    final stopped = await render(tester, ToyHost(arrival: (_) async {}), _frame('/redirect'));
    expect(stopped.errors, ['expected /redirect, landed at /home']);
  });

  testWidgets('a build that throws is an error, and the test itself does not fail', (tester) async {
    final host = ToyHost(screens: {'/boom': (_) => throw StateError('no beans')});
    final o = await render(tester, host, _frame('/boom'));
    expect(o.errors, hasLength(1));
    expect(o.errors.single, contains('no beans'));
    expect(tester.takeException(), isNull);
    expect(o.pixels, isNotNull, reason: 'the error card still has a picture');
  });

  testWidgets('a mount that throws is an error with its stack', (tester) async {
    final o = await render(tester, _ThrowingHost(), _frame('/home'));
    expect(o.errors.single, startsWith('Bad state: no fakes'));
    expect(o.errors.single, contains('render_test.dart'));
  });

  // Observed in the first adopting app: a mount that seeded its fakes with real I/O hung the run
  // with no output, because a testWidgets body runs on a fake clock that nothing advanced.
  testWidgets('a mount that awaits real I/O renders, on the fake clock of a widget test', (
    tester,
  ) async {
    final host = _RealIoHost(() async {});
    final o = await render(tester, host, _frame('/home'));
    expect(o.errors, isEmpty);
    expect(o.landing, isA<LandedAt>().having((l) => l.uri.path, 'path', '/home'));
    expect(host.wrote, isTrue, reason: 'the real write finished before the app was pumped');
  });

  testWidgets('a mount that throws after real I/O is an error with its stack', (tester) async {
    final o = await render(
      tester,
      _RealIoHost(() async => throw StateError('seed failed')),
      _frame('/home'),
    );
    expect(o.errors, hasLength(1));
    expect(o.errors.single, startsWith('Bad state: seed failed'));
    expect(o.errors.single, contains('render_test.dart'));
    expect(o.pixels, isNotNull, reason: 'the error card still has a picture');
  });

  testWidgets('a mount that never finishes is an error naming the budget, not a stalled run', (
    tester,
  ) async {
    final o = await render(
      tester,
      _NeverMountsHost(),
      _frame('/home'),
      mountBudget: const Duration(milliseconds: 200),
    );
    expect(o.errors, hasLength(1));
    expect(o.errors.single, contains('mount did not finish within 0.2 s of real time'));
    expect(o.pixels, isNotNull);
  });

  testWidgets('an animation that never ends is frozen, said so, and still captured', (
    tester,
  ) async {
    final host = ToyHost(
      screens: {'/spin': (_) => const Center(child: CircularProgressIndicator())},
    );
    final o = await render(tester, host, _frame('/spin'));
    expect(o.errors, isEmpty);
    expect(o.frozen, isTrue);
    expect(o.findings.map((f) => f.kind), contains('frozen'));
    expect(o.pixels, isNotNull);
  });

  testWidgets('a settled frame has no frozen finding', (tester) async {
    final o = await render(tester, ToyHost(), _frame('/home'));
    expect(o.findings.map((f) => f.kind), isNot(contains('frozen')));
  });

  testWidgets('no Router: the landing is unknown, as a finding, never a match', (tester) async {
    final host = ToyHost(bare: const MaterialApp(home: Text('plain')));
    final o = await render(tester, host, _frame('/home'));
    expect(o.landing, isA<LandingUnknown>());
    expect(o.errors, isEmpty);
    expect(o.findings.map((f) => f.kind), contains('landing-unknown'));
  });

  testWidgets('network images draw a placeholder and are listed', (tester) async {
    final url = 'https://example.invalid/bean.jpg';
    final host = ToyHost(
      screens: {'/img': (_) => Image.network(url, width: 100, height: 100, fit: BoxFit.cover)},
    );
    final o = await render(tester, host, _frame('/img'));
    expect(o.errors, isEmpty, reason: 'without the placeholder flutter_test answers 400');
    final f = o.findings.singleWhere((f) => f.kind == 'network-image');
    expect(f.message, contains(url));
    expect(debugNetworkImageHttpClientProvider, isNull, reason: 'uninstalled after the render');
  });

  testWidgets('text in a family nobody loaded is a finding; Roboto text is not', (tester) async {
    final host = ToyHost(
      screens: {
        '/type': (_) => const Scaffold(
          body: Column(
            children: [
              Text('menu', style: TextStyle(fontFamily: 'NotAFont')),
              Text('plain Material text, in Roboto'),
            ],
          ),
        ),
      },
    );
    final o = await render(tester, host, _frame('/type'));
    final fonts = o.findings.where((f) => f.kind.endsWith('-font')).toList();
    expect(fonts, hasLength(1), reason: '$fonts');
    expect(fonts.single.kind, 'missing-font');
    expect(fonts.single.message, startsWith('1 text span(s) ask for "NotAFont"'));
  });

  testWidgets('a label too wide for a small phone at 2.0× breaks mid-word, and says so', (
    tester,
  ) async {
    final host = ToyHost(
      screens: {
        '/label': (_) => const Scaffold(
          body: Row(
            children: [
              Expanded(child: Text('COMPLIMENTARY')),
              Expanded(child: Text('two short words')),
            ],
          ),
        ),
      },
    );
    final small = await render(tester, host, _frame('/label', device: 'small-phone', scale: '2.0'));
    final broken = small.findings.where((f) => f.kind == 'broken-word').toList();
    expect(broken, hasLength(1), reason: '${small.findings}');
    expect(broken.single.message, contains('COMPLIMEN'));
    expect(broken.single.message, isNot(contains('short')), reason: 'it wrapped at spaces');

    // The same screen at 1.0× fits, so the finding is the scale's doing.
    final fits = await render(tester, host, _frame('/label', device: 'small-phone'));
    expect(fits.findings.map((f) => f.kind), isNot(contains('broken-word')));
  });

  testWidgets('pixels the app never paints are a finding; a Scaffold paints them all', (
    tester,
  ) async {
    final bare = ToyHost(
      bare: const Directionality(textDirection: TextDirection.ltr, child: Text('x')),
    );
    final o = await render(tester, bare, _frame('/home'));
    expect(o.findings.map((f) => f.kind), contains('unpainted'));

    final painted = await render(tester, ToyHost(), _frame('/home'));
    expect(painted.findings.map((f) => f.kind), isNot(contains('unpainted')));
  });

  testWidgets('FlutterError.onError is put back after a render', (tester) async {
    final before = FlutterError.onError;
    await render(tester, ToyHost(), _frame('/home'));
    expect(FlutterError.onError, same(before));
  });

  testWidgets('the axes reach the app, and undo puts the view back', (tester) async {
    late MediaQueryData seen;
    late TargetPlatform platform;
    late double scaled;
    final host = ToyHost(
      screens: {
        '/mq': (context) {
          seen = MediaQuery.of(context);
          scaled = MediaQuery.textScalerOf(context).scale(10);
          platform = Theme.of(context).platform;
          return const SizedBox();
        },
      },
    );
    final frame = _frame('/mq', device: 'small-phone', scale: '2.0');
    await render(tester, host, frame);
    expect(seen.size, const Size(360, 800));
    expect(seen.devicePixelRatio, 2);
    expect(seen.padding, const EdgeInsets.only(top: 24, bottom: 48));
    // Read during the build: a SystemTextScaler asks the dispatcher live, so after undo it says 1.
    expect(scaled, 20);
    expect(platform, TargetPlatform.android);
    expect(tester.view.physicalSize, isNot(const Size(720, 1600)), reason: 'reset by undo');
  });
}

class _ThrowingHost extends ToyHost {
  @override
  Future<Widget> mount(GalleyFrame frame) async => throw StateError('no fakes');
}

/// Mounts the toy app after a real file write, then runs [after].
class _RealIoHost extends ToyHost {
  _RealIoHost(this.after);

  final Future<void> Function() after;
  var wrote = false;

  @override
  Future<Widget> mount(GalleyFrame frame) async {
    final dir = await Directory.systemTemp.createTemp('galley_mount');
    try {
      await File('${dir.path}/seed.json').writeAsString('{}');
      wrote = true;
    } finally {
      await dir.delete(recursive: true);
    }
    await after();
    return super.mount(frame);
  }
}

class _NeverMountsHost extends ToyHost {
  @override
  Future<Widget> mount(GalleyFrame frame) => Completer<Widget>().future;
}

String _cwd() => Uri.base.toFilePath().replaceAll(RegExp(r'/$'), '');
