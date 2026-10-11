import 'package:path/path.dart' as p;

import '../models/note.dart';

/// A conflict copy made by the sync engine (`name (충돌 device date).md`)
/// and the note it belongs to.
class ConflictPair {
  ConflictPair({
    required this.copy,
    required this.original,
    required this.device,
    required this.when,
  });

  /// The copy holding this device's version.
  final Note copy;

  /// Path of the note that kept the other device's version.
  final String original;
  final String device;
  final String when;
}

final _conflictName = RegExp(
  r'^(.*) \(충돌 (.+) (\d{4}-\d{2}-\d{2} \d{2}\.\d{2})(?: \d+)?\)$',
);

ConflictPair? conflictOf(Note note) {
  final m = _conflictName.firstMatch(
    p.posix.basenameWithoutExtension(note.path),
  );
  if (m == null) return null;
  final ext = p.posix.extension(note.path);
  return ConflictPair(
    copy: note,
    original: Note.join(note.folder, '${m[1]}$ext'),
    device: m[2]!,
    when: m[3]!.replaceFirst('.', ':', 13),
  );
}

List<ConflictPair> findConflicts(Iterable<Note> notes) => [
  for (final n in notes)
    if (conflictOf(n) case final ConflictPair c) c,
];
