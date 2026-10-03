import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/praise_repository.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';

/// 폴더 다시 가져오기: 원본/보조 나누기만 바뀐 곡은 중복으로 넣지 않고 고친다.
void main() {
  setUpAll(sqfliteFfiInit);

  PraiseSong song(String lyrics, String english) => PraiseSong(
    id: null,
    fileName: '위대하신주.pptx',
    title: '위대하신주',
    lyrics: lyrics,
    englishLyrics: english,
  );

  test('나누기만 다르면 고치고, 같으면 건너뛰고, 가사가 다르면 새로 넣는다', () async {
    final dir = await Directory.systemTemp.createTemp('add_new_songs_');
    addTearDown(() => dir.delete(recursive: true));
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/test.db');
    addTearDown(db.close);
    await createPraiseSchema(db);
    final repo = PraiseRepository(database: PraiseDatabase.forTesting(db));

    // 예전 규칙: 원곡의 영어 줄이 보조 가사로 빠져 있었다.
    await repo.addNewSongs([song('위대하신 주', 'How great is our God')]);

    final resplit = await repo.addNewSongs([
      song('위대하신 주\nHow great is our God', ''),
    ]);
    expect(resplit.updatedCount, 1);
    expect(resplit.insertedCount, 0);

    final again = await repo.addNewSongs([
      song('위대하신 주\nHow great is our God', ''),
    ]);
    expect(again.skippedCount, 1);

    final changed = await repo.addNewSongs([song('다른 가사', '')]);
    expect(changed.insertedCount, 1);

    final songs = await repo.searchSongs('');
    expect(songs.length, 2);
    expect(
      songs.map((s) => s.lyrics),
      contains('위대하신 주\nHow great is our God'),
    );
  });
}
