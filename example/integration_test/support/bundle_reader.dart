// A reader for the report bundle the SDKs write (a zip), and a SHA-256, for the integration tests that
// check what actually reached the bundle. No dependency: `dart:io` has the inflate, and the zip format's
// central directory is a page of code. Test support only.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The entries of a zip: name to content.
Map<String, Uint8List> readZip(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  // The end-of-central-directory record is the last 22 bytes plus a comment (none here); search back.
  var eocd = -1;
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw const FormatException('not a zip: no end record');
  final count = data.getUint16(eocd + 10, Endian.little);
  var at = data.getUint32(eocd + 16, Endian.little);
  final out = <String, Uint8List>{};
  for (var n = 0; n < count; n++) {
    if (data.getUint32(at, Endian.little) != 0x02014b50) {
      throw const FormatException('bad central directory');
    }
    final method = data.getUint16(at + 10, Endian.little);
    final compressedSize = data.getUint32(at + 20, Endian.little);
    final nameLength = data.getUint16(at + 28, Endian.little);
    final extraLength = data.getUint16(at + 30, Endian.little);
    final commentLength = data.getUint16(at + 32, Endian.little);
    final localOffset = data.getUint32(at + 42, Endian.little);
    final name = utf8.decode(bytes.sublist(at + 46, at + 46 + nameLength));
    final localNameLength = data.getUint16(localOffset + 26, Endian.little);
    final localExtraLength = data.getUint16(localOffset + 28, Endian.little);
    final start = localOffset + 30 + localNameLength + localExtraLength;
    final raw = bytes.sublist(start, start + compressedSize);
    out[name] = method == 0
        ? Uint8List.fromList(raw)
        : Uint8List.fromList(ZLibCodec(raw: true).decode(raw));
    at += 46 + nameLength + extraLength + commentLength;
  }
  return out;
}

/// The newest `*.bundle.zip` under [root], or `null`.
File? newestBundle(Directory root) {
  File? best;
  for (final e in root.listSync(recursive: true, followLinks: false)) {
    if (e is File && e.path.endsWith('.bundle.zip')) {
      if (best == null ||
          e.lastModifiedSync().isAfter(best.lastModifiedSync())) {
        best = e;
      }
    }
  }
  return best;
}

/// Every `*.bundle.zip` under [root].
List<File> bundles(Directory root) => [
  for (final e in root.listSync(recursive: true, followLinks: false))
    if (e is File && e.path.endsWith('.bundle.zip')) e,
];

// ---- SHA-256 ----------------------------------------------------------------------------------

const _k = <int>[
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

String sha256Hex(List<int> message) {
  final h = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  final length = message.length;
  final padded = <int>[...message, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  final bits = length * 8;
  for (var i = 7; i >= 0; i--) {
    padded.add((bits >> (i * 8)) & 0xff);
  }
  final w = List<int>.filled(64, 0);
  for (var chunk = 0; chunk < padded.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] =
          (padded[chunk + i * 4] << 24) |
          (padded[chunk + i * 4 + 1] << 16) |
          (padded[chunk + i * 4 + 2] << 8) |
          padded[chunk + i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }
    var a = h[0],
        b = h[1],
        c = h[2],
        d = h[3],
        e = h[4],
        f = h[5],
        g = h[6],
        hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final t1 = (hh + s1 + ch + _k[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }
  return h.map((x) => x.toRadixString(16).padLeft(8, '0')).join();
}
