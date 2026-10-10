import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Keeps a copy of every remote image (http/https) a note uses, so notes
/// look the same offline. Files live next to the notes in app support
/// storage (not the OS cache, which may be purged).
class MediaCache {
  MediaCache(this.dir, {http.Client? client})
    : _client = client ?? http.Client();

  final Directory dir;
  final http.Client _client;
  final Map<String, Future<Uint8List?>> _inFlight = {};

  /// Recent failures, so an offline device does not retry on every frame.
  final Map<String, DateTime> _failed = {};

  static const maxBytes = 25 * 1024 * 1024;

  File _fileFor(String url) =>
      File(p.join(dir.path, sha1.convert(utf8.encode(url)).toString()));

  Future<bool> has(String url) => _fileFor(url).exists();

  /// Bytes from the cache, or downloaded (and cached) when [fetch] is true.
  /// Null when unavailable (offline and not cached, or a failed download).
  Future<Uint8List?> get(String url, {bool fetch = true}) async {
    final file = _fileFor(url);
    if (await file.exists()) return file.readAsBytes();
    if (!fetch) return null;
    final failedAt = _failed[url];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < const Duration(minutes: 2)) {
      return null;
    }
    // A block body: returning the removed future from whenComplete would
    // make it wait on itself.
    return _inFlight[url] ??= _download(url, file).whenComplete(() {
      _inFlight.remove(url);
    });
  }

  Future<Uint8List?> _download(String url, File file) async {
    try {
      final response = await _client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200 || response.bodyBytes.length > maxBytes) {
        _failed[url] = DateTime.now();
        return null;
      }
      await dir.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(response.bodyBytes, flush: true);
      await tmp.rename(file.path);
      _failed.remove(url);
      return response.bodyBytes;
    } catch (_) {
      _failed[url] = DateTime.now();
      return null;
    }
  }

  /// Downloads everything missing, a few at a time. Returns how many new
  /// files were cached.
  Future<int> prefetch(Iterable<String> urls) async {
    final missing = <String>[];
    for (final url in urls.toSet()) {
      if (!await has(url)) missing.add(url);
    }
    var cached = 0;
    for (var i = 0; i < missing.length; i += 4) {
      final batch = missing.skip(i).take(4);
      final results = await Future.wait(batch.map((u) => get(u)));
      cached += results.whereType<Uint8List>().length;
    }
    return cached;
  }
}

/// Whether [bytes] (or the declared [mime]) is an SVG document.
bool looksLikeSvg(Uint8List bytes, {String? mime}) {
  if (mime != null && mime.contains('svg')) return true;
  final head = String.fromCharCodes(bytes.take(512)).toLowerCase();
  return head.contains('<svg');
}

/// Parses a `data:` URI leniently: base64, percent-encoded, and the common
/// but non-standard `;utf8,<svg …>` form.
({Uint8List bytes, String mime})? parseDataUri(String uri) {
  try {
    final data = UriData.parse(uri);
    return (bytes: data.contentAsBytes(), mime: data.mimeType);
  } catch (_) {
    final comma = uri.indexOf(',');
    if (comma < 5) return null;
    final header = uri.substring(5, comma);
    final body = uri.substring(comma + 1);
    try {
      final bytes = header.contains(';base64')
          ? base64Decode(body.replaceAll(RegExp(r'\s'), ''))
          : utf8.encode(Uri.decodeComponent(body));
      return (bytes: Uint8List.fromList(bytes), mime: header.split(';').first);
    } catch (_) {
      return null;
    }
  }
}
