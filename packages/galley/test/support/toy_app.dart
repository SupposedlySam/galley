import 'package:material_ui/material_ui.dart';

/// A tiny router app for Galley's own tests: a uri in, a screen out, and a router Galley can
/// read the landing from. It is built the way a typical router app is: `MaterialApp.router`
/// over a delegate whose configuration is a [Uri].
class ToyApp extends StatefulWidget {
  const ToyApp({required this.opening, this.screens = const {}, super.key});

  final Uri opening;

  /// Extra screens by path, for tests that need a misbehaving one.
  final Map<String, WidgetBuilder> screens;

  @override
  State<ToyApp> createState() => _ToyAppState();
}

class _ToyAppState extends State<ToyApp> {
  late final _delegate = ToyDelegate(widget.screens);
  late final _provider = PlatformRouteInformationProvider(
    initialRouteInformation: RouteInformation(uri: widget.opening),
  );

  @override
  void dispose() {
    _delegate.dispose();
    _provider.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    debugShowCheckedModeBanner: false,
    routerDelegate: _delegate,
    routeInformationParser: const ToyParser(),
    routeInformationProvider: _provider,
  );
}

class ToyParser extends RouteInformationParser<Uri> {
  const ToyParser();

  @override
  Future<Uri> parseRouteInformation(RouteInformation routeInformation) async =>
      routeInformation.uri;

  @override
  RouteInformation restoreRouteInformation(Uri configuration) =>
      RouteInformation(uri: configuration);
}

class ToyDelegate extends RouterDelegate<Uri> with ChangeNotifier {
  ToyDelegate(this._extra);

  final Map<String, WidgetBuilder> _extra;
  Uri _current = Uri.parse('/');

  @override
  Uri get currentConfiguration => _current;

  /// Goes to [uri], as a tap in the app would.
  void go(Uri uri) {
    _current = uri;
    notifyListeners();
  }

  @override
  Future<void> setNewRoutePath(Uri configuration) async {
    // `/redirect` lands somewhere else, like an auth guard would.
    _current = configuration.path == '/redirect' ? Uri.parse('/home') : configuration;
    notifyListeners();
  }

  @override
  Future<bool> popRoute() async => false;

  @override
  Widget build(BuildContext context) {
    final extra = _extra[_current.path];
    return Navigator(
      pages: [
        MaterialPage<void>(
          key: ValueKey(_current.toString()),
          child: extra != null ? Builder(builder: extra) : HomeScreen(uri: _current),
        ),
      ],
      onDidRemovePage: (_) {},
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({required this.uri, super.key});

  final Uri uri;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Text('at ${uri.path}', key: const ValueKey('where')),
          const SizedBox(height: 8),
          ElevatedButton(onPressed: () {}, child: const Text('Go')),
        ],
      ),
    ),
  );
}

/// Shows how many times it has been built in this process. A fake shared between mounts, on
/// purpose: two renders of one frame show different numbers.
class DriftingLabel extends StatelessWidget {
  const DriftingLabel({super.key});

  static int _builds = 0;

  @override
  Widget build(BuildContext context) {
    _builds++;
    return Scaffold(
      body: Center(child: Text('build $_builds', key: const ValueKey('drift'))),
    );
  }
}
