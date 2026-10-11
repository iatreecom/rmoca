import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Inflate, InputMemoryStream;
import 'package:crypto/crypto.dart';

import 'objects.dart';

// --- pkt-line --------------------------------------------------------------

/// Git's pkt-line framing: 4 hex digits of length (including themselves).
Uint8List pktLine(String line) {
  final bytes = utf8.encode(line);
  final len = (bytes.length + 4).toRadixString(16).padLeft(4, '0');
  return Uint8List.fromList([...ascii.encode(len), ...bytes]);
}

final Uint8List flushPkt = ascii.encode('0000');

/// A parsed pkt-line; [data] is null for a flush (`0000`) or delimiter.
class Pkt {
  Pkt(this.data);

  final Uint8List? data;

  bool get isFlush => data == null;
  String get text => utf8.decode(data!, allowMalformed: true);
}

List<Pkt> readPkts(Uint8List bytes) {
  final out = <Pkt>[];
  var i = 0;
  while (i + 4 <= bytes.length) {
    final len = int.tryParse(ascii.decode(bytes.sublist(i, i + 4)), radix: 16);
    if (len == null) break;
    if (len < 4) {
      out.add(Pkt(null));
      i += 4;
      continue;
    }
    if (i + len > bytes.length) break;
    out.add(Pkt(Uint8List.sublistView(bytes, i + 4, i + len)));
    i += len;
  }
  return out;
}

// --- reading packs ---------------------------------------------------------

/// Parses a packfile into objects, resolving deltas (also against objects
/// already in [store], for thin packs).
List<GitObject> parsePack(Uint8List pack, ObjectStore store) {
  if (pack.length < 12 || ascii.decode(pack.sublist(0, 4)) != 'PACK') {
    throw const FormatException('Not a packfile');
  }
  final view = ByteData.sublistView(pack);
  final count = view.getUint32(8);
  var pos = 12;

  final byOffset = <int, GitObject>{};
  final pendingOfs = <int, (int base, Uint8List delta)>{};
  final pendingRef = <int, (String base, Uint8List delta)>{};
  final order = <int>[];

  for (var n = 0; n < count; n++) {
    final start = pos;
    var c = pack[pos++];
    final type = (c >> 4) & 7;
    var size = c & 15;
    var shift = 4;
    while (c & 0x80 != 0) {
      c = pack[pos++];
      size |= (c & 0x7f) << shift;
      shift += 7;
    }
    int? baseOffset;
    String? baseSha;
    if (type == 6) {
      c = pack[pos++];
      var off = c & 0x7f;
      while (c & 0x80 != 0) {
        c = pack[pos++];
        off = ((off + 1) << 7) | (c & 0x7f);
      }
      baseOffset = start - off;
    } else if (type == 7) {
      baseSha = hexOf(pack.sublist(pos, pos + 20));
      pos += 20;
    }
    final (data, end) = _inflateAt(pack, pos, size);
    pos = end;
    order.add(start);
    if (type == 6) {
      pendingOfs[start] = (baseOffset!, data);
    } else if (type == 7) {
      pendingRef[start] = (baseSha!, data);
    } else {
      byOffset[start] = GitObject(GitType.byCode(type), data);
    }
  }

  // Resolve deltas until nothing changes (bases can be deltas themselves).
  final bySha = {for (final o in byOffset.values) o.sha: o};
  var progress = true;
  while ((pendingOfs.isNotEmpty || pendingRef.isNotEmpty) && progress) {
    progress = false;
    for (final e in pendingOfs.entries.toList()) {
      final base = byOffset[e.value.$1];
      if (base == null) continue;
      final obj = GitObject(base.type, applyDelta(base.data, e.value.$2));
      byOffset[e.key] = obj;
      bySha[obj.sha] = obj;
      pendingOfs.remove(e.key);
      progress = true;
    }
    for (final e in pendingRef.entries.toList()) {
      final base = bySha[e.value.$1] ?? store.get(e.value.$1);
      if (base == null) continue;
      final obj = GitObject(base.type, applyDelta(base.data, e.value.$2));
      byOffset[e.key] = obj;
      bySha[obj.sha] = obj;
      pendingRef.remove(e.key);
      progress = true;
    }
  }
  if (pendingOfs.isNotEmpty || pendingRef.isNotEmpty) {
    throw const FormatException('Pack has deltas against missing objects');
  }
  return [for (final o in order) byOffset[o]!];
}

/// Inflates the zlib stream at [pos]; returns the data and the offset just
/// past the stream. The inflater may read ahead, so the exact end is found
/// from the stream's Adler-32 trailer.
(Uint8List, int) _inflateAt(Uint8List pack, int pos, int size) {
  // Skip the 2-byte zlib header and inflate the raw deflate data.
  final input = InputMemoryStream(Uint8List.sublistView(pack, pos + 2));
  final out = Uint8List.fromList(
    Inflate.stream(input, uncompressedSize: size).getBytes(),
  );
  if (out.length != size) {
    throw FormatException('Bad object size: ${out.length} != $size');
  }
  final adler = _adler32(out);
  final approx = pos + 2 + input.position;
  for (var d = -8; d <= 8; d++) {
    final at = approx + d;
    if (at < pos || at + 4 > pack.length) continue;
    if (pack[at] == (adler >> 24) & 0xff &&
        pack[at + 1] == (adler >> 16) & 0xff &&
        pack[at + 2] == (adler >> 8) & 0xff &&
        pack[at + 3] == adler & 0xff) {
      return (out, at + 4);
    }
  }
  throw const FormatException('Could not find end of compressed object');
}

int _adler32(List<int> data) {
  var a = 1, b = 0;
  for (var i = 0; i < data.length; i++) {
    a = (a + data[i]) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}

Uint8List applyDelta(Uint8List base, Uint8List delta) {
  var i = 0;
  int varint() {
    var result = 0, shift = 0, c = 0;
    do {
      c = delta[i++];
      result |= (c & 0x7f) << shift;
      shift += 7;
    } while (c & 0x80 != 0);
    return result;
  }

  final baseSize = varint();
  if (baseSize != base.length) {
    throw const FormatException('Delta base size mismatch');
  }
  final targetSize = varint();
  final out = BytesBuilder(copy: false);
  while (i < delta.length) {
    final op = delta[i++];
    if (op & 0x80 != 0) {
      var offset = 0, len = 0;
      for (var b = 0; b < 4; b++) {
        if (op & (1 << b) != 0) offset |= delta[i++] << (8 * b);
      }
      for (var b = 0; b < 3; b++) {
        if (op & (0x10 << b) != 0) len |= delta[i++] << (8 * b);
      }
      if (len == 0) len = 0x10000;
      out.add(Uint8List.sublistView(base, offset, offset + len));
    } else if (op != 0) {
      out.add(Uint8List.sublistView(delta, i, i + op));
      i += op;
    } else {
      throw const FormatException('Bad delta opcode');
    }
  }
  final result = out.takeBytes();
  if (result.length != targetSize) {
    throw const FormatException('Delta result size mismatch');
  }
  return result;
}

// --- writing packs ---------------------------------------------------------

/// A packfile with [objects] stored whole (no deltas).
Uint8List writePack(List<GitObject> objects) {
  final out = BytesBuilder(copy: false)
    ..add(ascii.encode('PACK'))
    ..add(_u32(2))
    ..add(_u32(objects.length));
  for (final obj in objects) {
    var size = obj.data.length;
    var c = (obj.type.code << 4) | (size & 15);
    size >>= 4;
    while (size > 0) {
      out.addByte(c | 0x80);
      c = size & 0x7f;
      size >>= 7;
    }
    out
      ..addByte(c)
      ..add(zlib.encode(obj.data));
  }
  final body = out.takeBytes();
  return Uint8List.fromList([...body, ...sha1.convert(body).bytes]);
}

Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);
