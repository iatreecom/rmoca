import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rmoca/markdown/line_diff.dart';
import 'package:rmoca/markdown/note_links.dart';
import 'package:rmoca/models/note.dart';
import 'package:rmoca/services/local_store.dart';
import 'package:rmoca/services/conflicts.dart';
import 'package:rmoca/services/search.dart';

void main() {
  Note note(String path, String body, {Set<String> tags = const {}}) => Note(
    path: path,
    modified: DateTime(2026),
    body: body,
    preview: body.split('\n').first,
    links: NoteLinks(tags: tags, wikiTargets: [], paths: []),
  );

  test('search needs every term, ranks titles first, makes snippets', () {
    final notes = [
      note('회의/주간 회의.md', '# 주간 회의\n\n예산 검토와 일정 조율', tags: {'work'}),
      note('예산.md', '올해 예산 계획'),
      note('기타.md', '${'긴 서론 ' * 20}여기에 예산 이야기가 나온다'),
    ];
    var hits = searchNotes(notes, '예산');
    expect(hits.map((h) => h.note.title), ['예산', '주간 회의', '기타']);
    expect(hits.last.snippet, startsWith('… '));
    expect(hits.last.snippet, contains('예산 이야기'));

    hits = searchNotes(notes, '예산 일정');
    expect(hits.map((h) => h.note.title), ['주간 회의']);

    expect(searchNotes(notes, '#work 예산').single.note.title, '주간 회의');
    expect(searchNotes(notes, '"예산 계획"').single.note.title, '예산');
    expect(searchNotes(notes, '없는말'), isEmpty);
  });

  test('line diff', () {
    final d = diffLines('a\nb\nc\nd', 'a\nB\nc\nd\ne');
    expect(d.map((l) => '$l'), [' a', '-b', '+B', ' c', ' d', '+e']);
    expect(diffStats(d), (2, 1));
    expect(diffLines('same', 'same').every((l) => l.op == DiffOp.same), isTrue);
  });

  test('version history keeps earlier text', () async {
    final dir = await Directory.systemTemp.createTemp('history');
    addTearDown(() => dir.delete(recursive: true));
    final store = await LocalStore.openAt(dir);
    await store.writeText('a.md', 'v1');
    expect(await store.versions('a.md'), isEmpty);

    await store.writeText('a.md', 'v2');
    var versions = await store.versions('a.md');
    expect(versions, hasLength(1));
    expect(await versions.single.read(), 'v1');

    // While typing, at most one version every few minutes...
    await store.writeText('a.md', 'v3');
    expect(await store.versions('a.md'), hasLength(1));
    // ...unless forced (sync replacing the note, restore).
    await store.writeText('a.md', 'v4', keepVersion: true);
    versions = await store.versions('a.md');
    expect(versions, hasLength(2));
    expect(await versions.first.read(), 'v3');

    // History follows a rename.
    await store.rename('a.md', 'b.md');
    expect(await store.versions('b.md'), hasLength(2));
    expect(await store.versions('a.md'), isEmpty);
  });

  test('conflict copies are paired with their notes', () {
    Note n(String path) => Note(path: path, modified: DateTime(2026));
    final found = findConflicts([
      n('회의/주간 (충돌 my-iPad 2026-10-11 09.30).md'),
      n('그림 (충돌 phone 2026-10-11 10.05 2).svg'),
      n('보통 메모 (참고).md'),
    ]);
    expect(found, hasLength(2));
    expect(found[0].original, '회의/주간.md');
    expect(found[0].device, 'my-iPad');
    expect(found[0].when, '2026-10-11 09:30');
    expect(found[1].original, '그림.svg');
  });
}
