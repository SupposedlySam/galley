import 'package:galley_server/galley_server.dart';
import 'package:test/test.dart';

void main() {
  test('a link names its galley, and the canvas it opens reads back the galley and the root', () {
    for (final root in ['http://127.0.0.1:8090/', 'https://galley.example/reviews/']) {
      final link = canvasLink(Uri.parse(root), 'g1');
      expect(link.toString(), '$root?galley=g1');
      expect(galleyOf(link), 'g1');
      expect(serverOf(link).toString(), root);
      // As a browser may show it, with the page named.
      expect(serverOf(link.replace(path: '${link.path}index.html')).toString(), root);
    }
  });

  test('a root given without its slash gets one, so the API is under it', () {
    expect(canvasLink(Uri.parse('https://galley.example/reviews'), 'g1').path, '/reviews/');
  });

  test('a page that names no galley, or a blank one, names none', () {
    for (final page in [
      'http://h/',
      'http://h/?galley=',
      'http://h/?galley=%20',
      'http://h/?by=Rae',
    ]) {
      expect(galleyOf(Uri.parse(page)), isNull, reason: page);
    }
    expect(galleyOf(Uri.parse('http://h/?galley=%20g1%20&by=Rae')), 'g1');
  });
}
