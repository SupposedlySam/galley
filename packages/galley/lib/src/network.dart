import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

/// Stands in for the network while a frame renders, so that every `NetworkImage` draws a gray
/// placeholder.
///
/// **Why.** A frame runs on the app's fakes only (DESIGN.md), but an image URL in fake data is
/// still a real URL. flutter_test answers every HTTP request with an empty 400
/// (`_binding_io.dart`, `_MockHttpOverrides`). So without this, each image is an error that
/// fails the frame for a reason no reviewer can act on.
///
/// **How.** Flutter's own debug hook, `debugNetworkImageHttpClientProvider`
/// (painting/debug.dart), which `NetworkImage` consults before its shared client
/// (`_network_image_io.dart`, `_httpClient`). Rejected: replacing `HttpOverrides.global`. That
/// is the binding's, and every other HTTP call in the frame would then succeed instead of
/// failing loudly, which hides a real backend reaching into a frame.
///
/// Every URL asked for is kept in [requested], so the frame card can say which images are
/// placeholders.
final class NetworkPlaceholder {
  /// A placeholder that has served nothing yet.
  NetworkPlaceholder();

  /// A 1 × 1 mid-gray PNG (grayscale, 8 bit, value 128). An image stretched to any box is a
  /// flat gray box, which reads as "an image goes here".
  static final Uint8List png = Uint8List.fromList(const [
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 0, //
    0, 0, 0, 58, 126, 155, 85, 0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 104, 0, 0, 0, 130, 0,
    129, 119, 205, 114, 182, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
  ]);

  final List<Uri> _requested = [];

  /// The URLs images asked for, in order, repeats included.
  List<Uri> get requested => List.unmodifiable(_requested);

  /// Installs the placeholder, and returns what removes it.
  ///
  /// The removal must run before the test body ends. flutter_test checks that the hook is unset
  /// at the end of each test (painting/debug.dart, `debugAssertAllPaintingVarsUnset`).
  VoidCallback install() {
    if (debugNetworkImageHttpClientProvider != null) {
      throw StateError('debugNetworkImageHttpClientProvider is already set by someone else');
    }
    debugNetworkImageHttpClientProvider = () => _Client(_requested);
    return () => debugNetworkImageHttpClientProvider = null;
  }
}

/// The member `NetworkImage` uses is `getUrl`. Anything else is a caller Galley did not plan
/// for, so it throws and names itself rather than half-working.
final class _Client implements HttpClient {
  _Client(this._requested);

  final List<Uri> _requested;

  @override
  bool autoUncompress = false;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    _requested.add(url);
    return _Request();
  }

  @override
  Never noSuchMethod(Invocation invocation) => _unplanned('HttpClient', invocation);
}

final class _Request implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _Response();

  @override
  Never noSuchMethod(Invocation invocation) => _unplanned('HttpClientRequest', invocation);
}

final class _Response extends Stream<List<int>> implements HttpClientResponse {
  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => NetworkPlaceholder.png.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.value(NetworkPlaceholder.png)
          .listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  Never noSuchMethod(Invocation invocation) => _unplanned('HttpClientResponse', invocation);
}

Never _unplanned(String type, Invocation invocation) => throw UnsupportedError(
  'Galley\'s network placeholder does not support $type.${_name(invocation.memberName)}',
);

String _name(Symbol s) {
  final text = s.toString(); // Symbol("name")
  return text.substring(8, text.length - 2);
}
