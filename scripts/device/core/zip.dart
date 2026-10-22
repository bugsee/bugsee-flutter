// A zip reader for the harness: the entries of an APK or a report bundle, with where each one's data
// starts (an APK keeps native libraries stored, and `/proc/<pid>/maps` names a mapped library only by
// its offset inside base.apk, so the offset is how a library is recognised). No dependency: `dart:io`
// has the inflate, and the central directory is a page of code.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One entry of a zip.
class ZipEntry {
  const ZipEntry({
    required this.name,
    required this.method,
    required this.dataStart,
    required this.compressedSize,
    required this.size,
  });

  final String name;

  /// 0 stored, 8 deflated.
  final int method;

  /// Where the entry's bytes start inside the archive.
  final int dataStart;
  final int compressedSize;
  final int size;

  bool get isStored => method == 0;

  /// Whether [offset] (a file offset inside the archive) falls inside this entry's data.
  bool contains(int offset) =>
      offset >= dataStart && offset < dataStart + compressedSize;
}

/// The entries of [bytes], in central-directory order. Throws [FormatException] for anything that is
/// not a zip.
List<ZipEntry> zipEntries(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var eocd = -1;
  for (
    var i = bytes.length - 22;
    i >= 0 && i >= bytes.length - 22 - 65535;
    i--
  ) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw const FormatException('not a zip: no end record');
  final count = data.getUint16(eocd + 10, Endian.little);
  var at = data.getUint32(eocd + 16, Endian.little);
  final out = <ZipEntry>[];
  for (var n = 0; n < count; n++) {
    if (data.getUint32(at, Endian.little) != 0x02014b50) {
      throw const FormatException('bad central directory');
    }
    final method = data.getUint16(at + 10, Endian.little);
    final compressedSize = data.getUint32(at + 20, Endian.little);
    final size = data.getUint32(at + 24, Endian.little);
    final nameLength = data.getUint16(at + 28, Endian.little);
    final extraLength = data.getUint16(at + 30, Endian.little);
    final commentLength = data.getUint16(at + 32, Endian.little);
    final localOffset = data.getUint32(at + 42, Endian.little);
    final name = utf8.decode(bytes.sublist(at + 46, at + 46 + nameLength));
    final localNameLength = data.getUint16(localOffset + 26, Endian.little);
    final localExtraLength = data.getUint16(localOffset + 28, Endian.little);
    out.add(
      ZipEntry(
        name: name,
        method: method,
        dataStart: localOffset + 30 + localNameLength + localExtraLength,
        compressedSize: compressedSize,
        size: size,
      ),
    );
    at += 46 + nameLength + extraLength + commentLength;
  }
  return out;
}

/// The content of [entry].
Uint8List zipRead(Uint8List bytes, ZipEntry entry) {
  final raw = bytes.sublist(
    entry.dataStart,
    entry.dataStart + entry.compressedSize,
  );
  return entry.method == 0
      ? Uint8List.fromList(raw)
      : Uint8List.fromList(ZLibCodec(raw: true).decode(raw));
}

/// Name to content of every entry.
Map<String, Uint8List> zipContents(Uint8List bytes) => {
  for (final e in zipEntries(bytes)) e.name: zipRead(bytes, e),
};
