import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// The archives a galley fetches (docs/DESIGN.md D14, D15): the canvas build, a gzipped tar, and
// PocketBase, a zip. Each reader keeps only what those are made of, regular files and
// directories, and refuses the rest, so nothing in an archive can write outside the directory
// it is unpacked into or point out of it.
//
// Rejected: `package:archive`, which reads every kind of entry and would leave the same
// refusals to be written here, and brings in an FFI dependency for file modes. Rejected too:
// running `tar` or `unzip`, whose handling of `..` and links differs between the
// implementations a reviewer's machine might have, and which Windows may not have at all.

/// One entry of an archive: a file with its [bytes], or a directory (null). [executable] when
/// its mode lets its owner run it, which is kept on unpacking.
typedef ArchiveEntry = ({String path, Uint8List? bytes, bool executable});

/// The entries of the gzipped tar [archive], with every path checked to stay inside the
/// directory it is unpacked into.
///
/// Only regular files and directories are read, in ustar headers, with pax headers for long
/// names. Anything else, a link, a device or a FIFO above all, is refused.
///
/// Throws [FormatException] naming the entry when the archive is not that.
List<ArchiveEntry> readTarGz(Uint8List archive) {
  final Uint8List tar;
  try {
    tar = Uint8List.fromList(gzip.decode(archive));
  } on FormatException catch (e) {
    throw FormatException('not gzip (${e.message})');
  }
  return readTar(tar);
}

/// The entries of the tar [tar]: see [readTarGz].
List<ArchiveEntry> readTar(Uint8List tar) {
  const block = 512;
  final entries = <ArchiveEntry>[];
  String? paxPath;
  var at = 0;
  while (true) {
    if (at + block > tar.length) throw const FormatException('it ends inside a header');
    final header = Uint8List.sublistView(tar, at, at + block);
    if (header.every((b) => b == 0)) return entries;
    _checksum(header, at);
    final type = header[156];
    final size = _octal(header, 124, 12, 'size');
    final start = at + block;
    if (start + size > tar.length) throw const FormatException('it ends inside an entry');
    final data = Uint8List.sublistView(tar, start, start + size);
    at = start + (size + block - 1) ~/ block * block;

    switch (type) {
      case 0x78: // 'x': a pax header for the next entry. Only its path is kept.
        paxPath = _paxPath(data);
      case 0x67: // 'g': a pax header for the whole archive, of nothing a build needs.
        break;
      case 0x30 || 0x00 || 0x35: // '0' or NUL: a file. '5': a directory.
        final named = paxPath ?? _name(header);
        paxPath = null;
        final path = _safePath(named);
        if (path == null) continue; // `./`, the archive's own root.
        final directory = type == 0x35;
        entries.add((
          path: path,
          bytes: directory ? null : Uint8List.fromList(data),
          executable: !directory && _octal(header, 100, 8, 'mode') & _ownerRuns != 0,
        ));
      default:
        throw FormatException(
          '${paxPath ?? _name(header)} is a "${String.fromCharCode(type)}" entry: '
          'only files and directories are unpacked',
        );
    }
  }
}

/// The owner's execute bit of a Unix mode.
const _ownerRuns = 0x40; // 0o100

void _checksum(Uint8List header, int at) {
  var sum = 0;
  for (var i = 0; i < header.length; i++) {
    sum += i >= 148 && i < 156 ? 0x20 : header[i];
  }
  if (_octal(header, 148, 8, 'checksum') != sum) {
    throw FormatException('the header at byte $at does not match its checksum');
  }
}

int _octal(Uint8List header, int offset, int length, String field) {
  final text = _string(header, offset, length).trim();
  final n = int.tryParse(text.isEmpty ? '0' : text, radix: 8);
  if (n == null) throw FormatException('a header\'s $field is not octal: "$text"');
  return n;
}

String _string(Uint8List bytes, int offset, int length) {
  final field = Uint8List.sublistView(bytes, offset, offset + length);
  final end = field.indexOf(0);
  return _utf8(end < 0 ? field : field.sublist(0, end));
}

String _name(Uint8List header) {
  final name = _string(header, 0, 100);
  final prefix = _string(header, 345, 155);
  return prefix.isEmpty ? name : '$prefix/$name';
}

/// The `path` record of a pax header: lines of `<length> <key>=<value>\n`.
String? _paxPath(Uint8List data) {
  // A record's length counts bytes, so it is walked over the bytes, not the decoded text: a
  // name with a character outside ASCII would otherwise put every later record off.
  String? path;
  var i = 0;
  while (i < data.length) {
    final space = data.indexOf(0x20, i);
    final length = space < 0 ? null : int.tryParse(String.fromCharCodes(data, i, space));
    if (length == null || space + 1 > i + length - 1 || i + length > data.length) {
      throw const FormatException('a pax header does not read');
    }
    // Only the path is decoded. Observed: macOS tar writes extended attributes as pax
    // records whose values are not UTF-8, and decoding every record refused its archives.
    final record = Uint8List.sublistView(data, space + 1, i + length - 1);
    if (record.length >= 5 && String.fromCharCodes(record, 0, 5) == 'path=') {
      path = _utf8(Uint8List.sublistView(record, 5));
    }
    i += length;
  }
  return path;
}

/// The entries of the zip [archive], with every path checked as [readTarGz] checks it.
///
/// Read from the central directory, which is the zip's own index: a local header may defer
/// its sizes to a data descriptor after the data, and the central entry always has them.
/// Only what PocketBase's release zips are made of is read: entries stored or deflated,
/// unencrypted, without zip64, in one part, whose Unix mode (when the zip was made on Unix)
/// is a regular file's or a directory's. Anything else is refused, naming the entry.
///
/// Each entry's CRC-32 is not checked: the whole archive is checked against its pinned
/// SHA-256 before it is read, which a damaged entry could not pass.
///
/// Throws [FormatException] when the archive is not that.
List<ArchiveEntry> readZip(Uint8List archive) {
  final z = ByteData.sublistView(archive);
  int u16(int at) => z.getUint16(at, Endian.little);
  int u32(int at) => z.getUint32(at, Endian.little);
  bool fits(int at, int length) => at >= 0 && at + length <= archive.length;

  // The end of central directory record: 22 bytes and a comment of up to 65535, last.
  var end = -1;
  for (var at = archive.length - 22; at >= 0 && at >= archive.length - 22 - 0xffff; at--) {
    if (u32(at) == 0x06054b50 && at + 22 + u16(at + 20) == archive.length) {
      end = at;
      break;
    }
  }
  if (end < 0) throw const FormatException('not a zip: it has no end of central directory');
  final count = u16(end + 10), size = u32(end + 12), first = u32(end + 16);
  if (u16(end + 4) != 0 || u16(end + 6) != 0 || u16(end + 8) != count) {
    throw const FormatException('a zip in parts is not unpacked');
  }
  if (count == 0xffff || size == 0xffffffff || first == 0xffffffff) {
    throw const FormatException('a zip64 archive is not unpacked');
  }
  if (!fits(first, size)) throw const FormatException('its central directory is outside it');

  final entries = <ArchiveEntry>[];
  var at = first;
  for (var i = 0; i < count; i++) {
    if (!fits(at, 46) || u32(at) != 0x02014b50) {
      throw FormatException('central directory entry ${i + 1} does not read');
    }
    final madeOnUnix = u16(at + 4) >> 8 == 3;
    final flags = u16(at + 8), method = u16(at + 10);
    final packed = u32(at + 20), unpacked = u32(at + 24);
    final nameLength = u16(at + 28), extraLength = u16(at + 30), commentLength = u16(at + 32);
    final mode = u32(at + 38) >> 16, local = u32(at + 42);
    if (!fits(at + 46, nameLength)) throw FormatException('entry ${i + 1} ends outside it');
    final name = _utf8(Uint8List.sublistView(archive, at + 46, at + 46 + nameLength));
    at += 46 + nameLength + extraLength + commentLength;

    if (flags & 1 != 0) throw FormatException('$name is encrypted');
    if (packed == 0xffffffff || unpacked == 0xffffffff || local == 0xffffffff) {
      throw FormatException('$name is a zip64 entry, which is not unpacked');
    }
    final directory = name.endsWith('/');
    // Unix keeps the file type in the mode's top bits: 0o100000 a file, 0o040000 a directory,
    // 0o120000 a symbolic link. Zero is a zip that kept no mode, read by its name.
    final kind = madeOnUnix ? mode & 0xf000 : 0;
    if (kind != 0 && kind != (directory ? 0x4000 : 0x8000)) {
      throw FormatException(
        '$name is a "0o${kind.toRadixString(8)}" entry: only files and directories are unpacked',
      );
    }
    final path = _safePath(name);
    if (path == null) continue;
    if (directory) {
      entries.add((path: path, bytes: null, executable: false));
      continue;
    }

    if (!fits(local, 30) || u32(local) != 0x04034b50) {
      throw FormatException('$name: its local header does not read');
    }
    final data = local + 30 + u16(local + 26) + u16(local + 28);
    if (!fits(data, packed)) throw FormatException('$name ends outside the archive');
    final raw = Uint8List.sublistView(archive, data, data + packed);
    final Uint8List bytes;
    try {
      bytes = switch (method) {
        0 => Uint8List.fromList(raw),
        8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(raw)),
        _ => throw FormatException('$name is compressed by method $method, not stored or deflated'),
      };
    } on FormatException catch (e) {
      if (e.message.startsWith(name)) rethrow;
      throw FormatException('$name does not inflate (${e.message})');
    }
    if (bytes.length != unpacked) {
      throw FormatException('$name is ${bytes.length} bytes, and its entry says $unpacked');
    }
    entries.add((path: path, bytes: bytes, executable: madeOnUnix && mode & _ownerRuns != 0));
  }
  return entries;
}

String _utf8(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const FormatException('a name is not UTF-8');
  }
}

/// [name] relative to the directory it is unpacked into, or null for that directory itself.
/// Throws when it would leave it: absolute, a `..`, a drive, or a backslash, which Windows
/// reads as a separator.
String? _safePath(String name) {
  final segments = name.split('/').where((s) => s.isNotEmpty && s != '.').toList();
  if (segments.isEmpty) return null;
  if (name.startsWith('/') ||
      segments.any((s) => s == '..' || s.contains(r'\') || s.contains(':'))) {
    throw FormatException('$name would be unpacked outside its directory');
  }
  return segments.join('/');
}
