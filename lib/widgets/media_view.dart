import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../markdown/svg_css.dart';
import '../models/note.dart';
import '../services/media_cache.dart';

/// SVG from text, with `<style>` CSS applied; a placeholder if invalid.
class SvgView extends StatelessWidget {
  const SvgView(
    this.svg, {
    super.key,
    this.fit = BoxFit.contain,
    this.width,
    this.height,
  });

  final String svg;
  final BoxFit fit;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) => SvgPicture.string(
    SvgCss.prepare(svg),
    fit: fit,
    width: width,
    height: height,
    placeholderBuilder: (_) => const SizedBox(width: 48, height: 48),
    errorBuilder: (context, error, _) => const _Placeholder(
      icon: Icons.broken_image_outlined,
      text: 'SVG를 표시할 수 없습니다',
    ),
  );
}

/// Shows an image from any source a note can use:
/// `data:` URIs (base64 or URL-encoded, raster or SVG), files next to the
/// note or synced attachments, and http(s) URLs (stored for offline use).
class MediaView extends StatelessWidget {
  const MediaView({
    super.key,
    required this.src,
    required this.notePath,
    this.alt,
    this.width,
    this.height,
    this.onOpen,
  });

  final String src;
  final String notePath;
  final String? alt;
  final double? width;
  final double? height;

  /// Tapping a local drawing/attachment opens it (path within the notes).
  final void Function(String path)? onOpen;

  static final _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final source = src.trim();

    if (source.startsWith('data:')) {
      final data = parseDataUri(source);
      if (data == null) return _missing('잘못된 data URI');
      return _sized(_fromBytes(data.bytes, mime: data.mime));
    }

    if (source.startsWith('http://') || source.startsWith('https://')) {
      return _sized(
        FutureBuilder<Uint8List?>(
          future: app.media.get(source),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 48,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            final bytes = snap.data;
            if (bytes == null) {
              return _Placeholder(
                icon: Icons.cloud_off_rounded,
                text:
                    '오프라인이라 이미지를 불러올 수 없습니다${alt == null || alt!.isEmpty ? '' : ': $alt'}',
              );
            }
            return _fromBytes(bytes, mime: _mimeFromPath(source));
          },
        ),
      );
    }

    if (_scheme.hasMatch(source)) return _missing('지원하지 않는 주소: $source');

    // A path next to the note, or (like Obsidian) any attachment by name.
    final path = _resolveLocal(app, source);
    if (path == null) {
      return _missing('그림 없음: ${alt?.isNotEmpty == true ? alt : source}');
    }
    final file = app.store.fileFor(path);
    final isSvg = path.toLowerCase().endsWith('.svg');
    final child = isSvg
        ? FutureBuilder<String>(
            future: file.readAsString(),
            builder: (context, snap) => snap.hasData
                ? Container(
                    color: Note.isDrawingPath(path) ? Colors.white : null,
                    child: SvgView(snap.data!),
                  )
                : const SizedBox(height: 48),
          )
        : Image.file(
            file,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const _Placeholder(
              icon: Icons.broken_image_outlined,
              text: '이미지를 열 수 없습니다',
            ),
          );
    return GestureDetector(
      onTap: onOpen == null || !isSvg ? null : () => onOpen!(path),
      child: _sized(child),
    );
  }

  String? _resolveLocal(AppState app, String source) {
    String decoded;
    try {
      decoded = Uri.decodeFull(source.split('#').first.split('?').first);
    } catch (_) {
      decoded = source;
    }
    final dir = Note.parentOf(notePath);
    final joined = p.posix.normalize(
      p.posix.join(dir.isEmpty ? '.' : dir, decoded),
    );
    if (!joined.startsWith('..') && app.store.fileFor(joined).existsSync()) {
      return joined;
    }
    return app.resolveWiki(p.posix.basename(decoded), notePath);
  }

  Widget _fromBytes(Uint8List bytes, {String? mime}) {
    if (looksLikeSvg(bytes, mime: mime)) {
      return SvgView(utf8.decode(bytes, allowMalformed: true));
    }
    return Image.memory(
      bytes,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const _Placeholder(
        icon: Icons.broken_image_outlined,
        text: '이미지를 열 수 없습니다',
      ),
    );
  }

  Widget _sized(Widget child) {
    if (width != null || height != null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(width: width, height: height, child: child),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 520),
      child: child,
    );
  }

  Widget _missing(String text) =>
      _Placeholder(icon: Icons.image_not_supported_outlined, text: text);

  static String? _mimeFromPath(String url) =>
      url.toLowerCase().split('?').first.endsWith('.svg')
      ? 'image/svg+xml'
      : null;
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: scheme.outline),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(color: scheme.outline, fontSize: 13),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }
}
