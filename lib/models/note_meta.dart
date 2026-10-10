import 'dart:convert';
import 'dart:typed_data';

/// Per-note and per-folder settings that sync with the notes (favorites,
/// folder colors), stored in `.rmoca/meta.json`.
///
/// Every entry carries its own `updated` time so two devices' changes can be
/// merged key by key instead of producing a conflict copy.
class NoteMeta {
  NoteMeta({Map<String, MetaEntry>? notes, Map<String, MetaEntry>? folders})
    : notes = notes ?? {},
      folders = folders ?? {};

  static const path = '.rmoca/meta.json';

  final Map<String, MetaEntry> notes;
  final Map<String, MetaEntry> folders;

  bool isFavorite(String note) => notes[note]?.favorite ?? false;
  int? folderColor(String folder) => folders[folder]?.color;

  void setFavorite(String note, bool value, DateTime now) {
    notes[note] = (notes[note] ?? MetaEntry()).copyWith(
      favorite: value,
      updated: now,
    );
  }

  void setFolderColor(String folder, int? color, DateTime now) {
    folders[folder] = (folders[folder] ?? MetaEntry()).copyWith(
      color: color,
      clearColor: color == null,
      updated: now,
    );
  }

  /// Carries entries over when notes/folders move (old path -> new path).
  void applyMoves(Map<String, String> moves, DateTime now) {
    void move(Map<String, MetaEntry> map) {
      for (final e in moves.entries) {
        final entry = map.remove(e.key);
        if (entry != null) map[e.value] = entry.copyWith(updated: now);
      }
    }

    move(notes);
    move(folders);
    // Folder moves: entries for things inside the folder.
    for (final map in [notes, folders]) {
      for (final key in map.keys.toList()) {
        for (final e in moves.entries) {
          if (key.startsWith('${e.key}/')) {
            map['${e.value}${key.substring(e.key.length)}'] = map
                .remove(key)!
                .copyWith(updated: now);
            break;
          }
        }
      }
    }
  }

  Map<String, Object?> toJson() => {
    'notes': {for (final e in _sorted(notes)) e.key: e.value.toJson()},
    'folders': {for (final e in _sorted(folders)) e.key: e.value.toJson()},
  };

  Uint8List encode() => Uint8List.fromList(
    utf8.encode('${const JsonEncoder.withIndent('  ').convert(toJson())}\n'),
  );

  static NoteMeta decode(List<int> bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      Map<String, MetaEntry> read(Object? m) => {
        for (final e in (m as Map? ?? const {}).entries)
          '${e.key}': MetaEntry.fromJson(
            Map<String, Object?>.from(e.value as Map),
          ),
      };
      return NoteMeta(
        notes: read(json['notes']),
        folders: read(json['folders']),
      );
    } catch (_) {
      return NoteMeta();
    }
  }

  /// Newest entry wins per key; used when both devices changed the file.
  static Uint8List merge(Uint8List local, Uint8List remote) {
    final a = decode(local), b = decode(remote);
    Map<String, MetaEntry> pick(
      Map<String, MetaEntry> x,
      Map<String, MetaEntry> y,
    ) => {
      for (final key in {...x.keys, ...y.keys})
        key: switch ((x[key], y[key])) {
          (final l?, final r?) => l.updated.isAfter(r.updated) ? l : r,
          (final l?, null) => l,
          (null, final r?) => r,
          _ => MetaEntry(),
        },
    };
    return NoteMeta(
      notes: pick(a.notes, b.notes),
      folders: pick(a.folders, b.folders),
    ).encode();
  }

  static Iterable<MapEntry<String, MetaEntry>> _sorted(
    Map<String, MetaEntry> m,
  ) => m.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
}

class MetaEntry {
  MetaEntry({this.favorite = false, this.color, DateTime? updated})
    : updated = updated ?? DateTime.fromMillisecondsSinceEpoch(0);

  final bool favorite;

  /// Folder color as 0xRRGGBB.
  final int? color;
  final DateTime updated;

  MetaEntry copyWith({
    bool? favorite,
    int? color,
    bool clearColor = false,
    DateTime? updated,
  }) => MetaEntry(
    favorite: favorite ?? this.favorite,
    color: clearColor ? null : (color ?? this.color),
    updated: updated ?? this.updated,
  );

  Map<String, Object?> toJson() => {
    if (favorite) 'favorite': true,
    if (color != null) 'color': '#${color!.toRadixString(16).padLeft(6, '0')}',
    'updated': updated.toUtc().toIso8601String(),
  };

  factory MetaEntry.fromJson(Map<String, Object?> json) => MetaEntry(
    favorite: json['favorite'] == true,
    color: json['color'] is String
        ? int.tryParse(
            (json['color'] as String).replaceFirst('#', ''),
            radix: 16,
          )
        : null,
    updated: DateTime.tryParse('${json['updated']}') ?? DateTime(1970),
  );
}
