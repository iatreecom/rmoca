import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Computes the git blob SHA-1 of [bytes], identical to `git hash-object`.
///
/// Using the same hash git uses lets us compare local files with remote
/// tree entries without downloading anything.
String gitBlobSha(Uint8List bytes) {
  final header = utf8.encode('blob ${bytes.length}\u0000');
  final builder = BytesBuilder(copy: false)
    ..add(header)
    ..add(bytes);
  return sha1.convert(builder.takeBytes()).toString();
}
