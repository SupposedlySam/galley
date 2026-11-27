import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:galley_cli/galley_cli.dart';
import 'package:test/test.dart';

/// One entry to write: [type] is the ustar typeflag ('0' a file, '5' a directory, '2' a
/// symlink, 'x' a pax header...).
typedef Entry = ({String name, String type, List<int> data, String link});

Entry file(String name, String text) => (name: name, type: '0', data: utf8.encode(text), link: '');
Entry dir(String name) => (name: name, type: '5', data: const [], link: '');
Entry link(String name, String to, {String type = '2'}) =>
    (name: name, type: type, data: const [], link: to);

/// A pax header giving the next entry [path].
Entry pax(String path) {
  final body = utf8.encode(' path=$path\n');
  // The record's length counts its own digits: grow it until it is stable.
  var length = body.length;
  while ('$length'.length + body.length != length) {
    length = '$length'.length + body.length;
  }
  return (name: 'PaxHeader', type: 'x', data: [...ascii.encode('$length'), ...body], link: '');
}

/// A ustar archive of [entries], with [corrupt] applied to each header after its checksum.
Uint8List tarOf(List<Entry> entries, {void Function(Uint8List header)? corrupt}) {
  final out = BytesBuilder();
  for (final e in entries) {
    final h = Uint8List(512);
    void put(int at, int length, List<int> bytes) =>
        h.setRange(at, at + bytes.length.clamp(0, length), bytes);
    void octal(int at, int length, int n) =>
        put(at, length, ascii.encode('${n.toRadixString(8).padLeft(length - 1, '0')}\x00'));
    final name = utf8.encode(e.name);
    if (name.length > 100) {
      // Split at a `/` into the 155-byte prefix and the 100-byte name, as ustar does.
      final cut = e.name.lastIndexOf('/', e.name.length.clamp(0, 155));
      put(345, 155, utf8.encode(e.name.substring(0, cut)));
      put(0, 100, utf8.encode(e.name.substring(cut + 1)));
    } else {
      put(0, 100, name);
    }
    octal(100, 8, e.type == '5' ? 0x1ed : 0x1a4);
    octal(108, 8, 0);
    octal(116, 8, 0);
    octal(124, 12, e.data.length);
    octal(136, 12, 0);
    h[156] = e.type.codeUnitAt(0);
    put(157, 100, utf8.encode(e.link));
    put(257, 6, ascii.encode('ustar\x00'));
    put(263, 2, ascii.encode('00'));
    h.setRange(148, 156, List.filled(8, 0x20));
    final sum = h.fold(0, (a, b) => a + b);
    put(148, 8, ascii.encode('${sum.toRadixString(8).padLeft(6, '0')}\x00 '));
    corrupt?.call(h);
    out
      ..add(h)
      ..add(e.data)
      ..add(Uint8List((512 - e.data.length % 512) % 512));
  }
  out.add(Uint8List(1024));
  return out.takeBytes();
}

Uint8List gz(Uint8List tar) => Uint8List.fromList(gzip.encode(tar));

/// The files of the tar [archive] that were read, as `path: text`, and directories as
/// `path/`.
Map<String, String?> read(Uint8List archive) => readable(readTarGz(archive));

/// [entries] as `path: text`, and directories as `path/`.
Map<String, String?> readable(List<ArchiveEntry> entries) => {
  for (final e in entries)
    if (e.bytes case final b?) e.path: utf8.decode(b) else '${e.path}/': null,
};

/// What [FormatException] an archive is refused with.
Matcher refusedWith(Object message) =>
    throwsA(isA<FormatException>().having((e) => e.message, 'message', message));

/// A canvas build's files, as tar entries.
final canvasFiles = [
  dir('./'),
  file('./index.html', '<html>canvas</html>'),
  dir('./canvaskit/'),
  file('./canvaskit/canvaskit.wasm', 'wasm'),
];
