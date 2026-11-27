import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One zip entry to write. [mode] is the Unix mode kept in its external attributes, and
/// [unix] says the zip says it was made on Unix, which is when a reader takes [mode] for one.
typedef ZipEntry = ({String name, List<int> data, int method, int mode, bool unix, int flags});

ZipEntry zfile(String name, String text, {int method = 8, int mode = 0x81a4, bool unix = true}) =>
    (name: name, data: utf8.encode(text), method: method, mode: mode, unix: unix, flags: 0);
ZipEntry zdir(String name) =>
    (name: name, data: const [], method: 0, mode: 0x41ed, unix: true, flags: 0);
ZipEntry zlink(String name, String to) =>
    (name: name, data: utf8.encode(to), method: 0, mode: 0xa1ff, unix: true, flags: 0);

/// A zip of [entries], as one part, with [comment] after its end record. [central] edits each
/// central directory entry after it is written, and [sizes] overrides the sizes it declares.
Uint8List zipOf(
  List<ZipEntry> entries, {
  String comment = '',
  void Function(ByteData central)? central,
  ({int packed, int unpacked})? sizes,
}) {
  final out = BytesBuilder();
  final directory = BytesBuilder();
  for (final e in entries) {
    final name = utf8.encode(e.name);
    final packed = e.method == 8 ? ZLibEncoder(raw: true).convert(e.data) : e.data;
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, e.flags, Endian.little)
      ..setUint16(8, e.method, Endian.little)
      ..setUint32(18, packed.length, Endian.little)
      ..setUint32(22, e.data.length, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    final offset = out.length;
    out
      ..add(local.buffer.asUint8List())
      ..add(name)
      ..add(packed);
    final c = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, (e.unix ? 3 : 0) << 8 | 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, e.flags, Endian.little)
      ..setUint16(10, e.method, Endian.little)
      ..setUint32(20, sizes?.packed ?? packed.length, Endian.little)
      ..setUint32(24, sizes?.unpacked ?? e.data.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(38, e.mode << 16, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central?.call(c);
    directory
      ..add(c.buffer.asUint8List())
      ..add(name);
  }
  final start = out.length, size = directory.length;
  out.add(directory.takeBytes());
  final note = utf8.encode(comment);
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, size, Endian.little)
    ..setUint32(16, start, Endian.little)
    ..setUint16(20, note.length, Endian.little);
  out
    ..add(end.buffer.asUint8List())
    ..add(note);
  return out.takeBytes();
}
