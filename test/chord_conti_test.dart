import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/praise_repository.dart';
import 'package:worship_slides/src/features/praise/data/worship_conti_repository.dart';
import 'package:worship_slides/src/features/praise/domain/chord_lyrics.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';

/// 콘티 스냅샷의 코드 네 칸(§3-3): 저장·불러오기·.wsconti 왕복·범위 밖 값 버리기.
void main() {
  setUpAll(sqfliteFfiInit);

  Future<Database> freshDatabase() async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(db.close);
    await createPraiseSchema(db);
    return db;
  }

  WorshipContiRepository contisOn(Database db) => WorshipContiRepository(
    database: PraiseDatabase.forTesting(db),
    supportDirectory: () async => Directory.systemTemp,
  );

  const chordSong = PraiseSong(
    id: null,
    fileName: 'grace.pptx',
    title: '주 은혜',
    lyrics: '주 은혜\n\n놀라워',
    englishLyrics: 'grace',
    chordLyrics: '[G]주 은혜\n\n[D]놀라워',
    chordKey: 'G',
    chordTranspose: 2,
    chordAccidental: ChordAccidental.flat,
  );

  PraiseSong loadedSong(LoadContiResult r, [int i = 0]) =>
      (r.items[i].item as SongStagingItem).song;

  test('저장·불러오기: 코드·원래 조·조 값·♯/♭ 이 남는다', () async {
    final db = await freshDatabase();
    final contis = contisOn(db);
    final id = await contis.saveConti('주일', [
      (uid: 1, item: SongStagingItem(chordSong)),
      (
        uid: 2,
        item: SongStagingItem(
          chordSong.copyWith(
            chordTranspose: 0,
            chordAccidental: ChordAccidental.auto,
          ),
        ),
      ),
    ]);
    final row = (await db.query(
      'worship_conti_items',
      orderBy: 'position',
    )).first;
    expect(row['song_chord_lyrics'], '[G]주 은혜\n\n[D]놀라워');
    expect(row['song_chord_key'], 'G');
    expect(row['song_transpose'], 2);
    expect(row['song_chord_accidental'], 'b');

    final loaded = await contis.loadConti(id, 10);
    final a = loadedSong(loaded);
    expect(a.chordLyrics, chordSong.chordLyrics);
    expect(a.chordKey, 'G');
    expect(a.chordTranspose, 2);
    expect(a.chordAccidental, ChordAccidental.flat);
    final b = loadedSong(loaded, 1);
    expect(b.chordTranspose, 0);
    expect(b.chordAccidental, ChordAccidental.auto);
  });

  test('라이브러리 곡의 코드를 고쳐도 저장한 콘티는 그대로다', () async {
    final db = await freshDatabase();
    final songs = PraiseRepository(database: PraiseDatabase.forTesting(db));
    await songs.insertSong(chordSong);
    final lib = (await songs.searchSongs('')).single;
    await songs.saveChords(
      lib.id!,
      chordLyrics: '[G]주 은혜\n\n[D]놀라워',
      chordKey: 'G',
    );
    final withChords = (await songs.searchSongs('')).single;
    final contis = contisOn(db);
    final id = await contis.saveConti('주일', [
      (uid: 1, item: SongStagingItem(withChords)),
    ]);
    await songs.saveChords(lib.id!, chordLyrics: '[A]주 은혜', chordKey: 'A');
    final song = loadedSong(await contis.loadConti(id, 1));
    expect(song.chordLyrics, '[G]주 은혜\n\n[D]놀라워');
    expect(song.chordKey, 'G');
  });

  test('v19 이전 행(코드 칸 NULL)은 코드 없음 — 라이브러리 코드를 따라가지 않는다', () async {
    final db = await freshDatabase();
    final songs = PraiseRepository(database: PraiseDatabase.forTesting(db));
    await songs.insertSong(chordSong);
    final lib = (await songs.searchSongs('')).single;
    await songs.saveChords(lib.id!, chordLyrics: '[G]주 은혜', chordKey: 'G');
    final contiId = await db.insert('worship_contis', {
      'name': '옛 콘티',
      'created_at': 1,
    });
    await db.insert('worship_conti_items', {
      'conti_id': contiId,
      'position': 0,
      'item_type': 'song',
      'song_id': lib.id,
      'song_title': '주 은혜',
      'song_lyrics': '주 은혜\n\n놀라워',
      'song_english_lyrics': '',
    });
    final song = loadedSong(await contisOn(db).loadConti(contiId, 1));
    expect(song.chordLyrics, isNull);
    expect(song.chordTranspose, 0);
  });

  test('song_transpose 가 범위 밖·정수가 아니면 0, ♯/♭ 이 이상하면 자동', () async {
    final db = await freshDatabase();
    final contiId = await db.insert('worship_contis', {
      'name': '이상한 값',
      'created_at': 1,
    });
    for (final (i, t, acc) in [(0, 99, 'x'), (1, 'x', '#'), (2, -11, 'b')]) {
      await db.insert('worship_conti_items', {
        'conti_id': contiId,
        'position': i,
        'item_type': 'song',
        'song_title': '곡',
        'song_lyrics': '가사',
        'song_transpose': t,
        'song_chord_accidental': acc,
      });
    }
    final loaded = await contisOn(db).loadConti(contiId, 1);
    expect(
      [for (var i = 0; i < 3; i++) loadedSong(loaded, i).chordTranspose],
      [0, 0, -11],
    );
    expect(
      [for (var i = 0; i < 3; i++) loadedSong(loaded, i).chordAccidental],
      [ChordAccidental.auto, ChordAccidental.sharp, ChordAccidental.flat],
    );
    expect(WorshipContiRepository.readTranspose(11), 11);
    expect(WorshipContiRepository.readTranspose(12), 0);
    expect(WorshipContiRepository.readTranspose(2.0), 0);
    expect(WorshipContiRepository.readTranspose(null), 0);
  });

  test('.wsconti 왕복으로 코드·조가 옮겨지고, 남이 만든 이상한 값은 버린다', () async {
    final tmp = await Directory.systemTemp.createTemp('chord_conti_');
    addTearDown(() => tmp.delete(recursive: true));
    final source = contisOn(await freshDatabase());
    final id = await source.saveConti('주일', [
      (uid: 1, item: SongStagingItem(chordSong)),
    ]);
    final file = p.join(tmp.path, 'a.wsconti');
    await source.exportContiFile(id, file);
    final json = jsonDecode(File(file).readAsStringSync()) as Map;
    final item = (json['items'] as List).single as Map;
    expect(item['song_chord_lyrics'], chordSong.chordLyrics);
    expect(item['song_transpose'], 2);

    final targetDb = await freshDatabase();
    final target = contisOn(targetDb);
    final imported = await target.importContiFile(
      file,
      filesDir: Directory(p.join(tmp.path, 'in1')),
    );
    final song = loadedSong(await target.loadConti(imported, 1));
    expect(song.chordLyrics, chordSong.chordLyrics);
    expect(song.chordKey, 'G');
    expect(song.chordTranspose, 2);
    expect(song.chordAccidental, ChordAccidental.flat);

    // 남이 만든 파일: 조 값 99·글자, ♯/♭ 'z'.
    item['song_transpose'] = 99;
    item['song_chord_accidental'] = 'z';
    final bad = p.join(tmp.path, 'bad.wsconti');
    File(bad).writeAsStringSync(jsonEncode(json));
    final badId = await target.importContiFile(
      bad,
      filesDir: Directory(p.join(tmp.path, 'in2')),
    );
    final row = (await targetDb.query(
      'worship_conti_items',
      where: 'conti_id = ?',
      whereArgs: [badId],
    )).single;
    expect(row['song_transpose'], isNull);
    expect(row['song_chord_accidental'], '');
    expect(loadedSong(await target.loadConti(badId, 1)).chordTranspose, 0);
  });

  test('옛 .wsconti(코드 칸 없음)도 그대로 들어온다', () async {
    final tmp = await Directory.systemTemp.createTemp('chord_conti_old_');
    addTearDown(() => tmp.delete(recursive: true));
    final file = File(p.join(tmp.path, 'old.wsconti'))
      ..writeAsStringSync(
        jsonEncode({
          'format': WorshipContiRepository.contiFileFormat,
          'version': 1,
          'name': '옛 콘티',
          'created_at': 1,
          'items': [
            {
              'item_type': 'song',
              'position': 0,
              'song_title': '주 은혜',
              'song_lyrics': '주 은혜',
              'song_english_lyrics': '',
            },
          ],
          'files': {},
        }),
      );
    final target = contisOn(await freshDatabase());
    final id = await target.importContiFile(
      file.path,
      filesDir: Directory(p.join(tmp.path, 'in')),
    );
    final song = loadedSong(await target.loadConti(id, 1));
    expect(song.lyrics, '주 은혜');
    expect(song.chordLyrics, isNull);
    expect(song.chordTranspose, 0);
  });

  test('옛 콘티(가사 스냅샷 없음)를 보낼 때는 지금 곡의 코드로 채운다', () {
    final base = {
      'item_type': 'song',
      'song_lyrics': null,
      'cur_lyrics': '주 은혜',
      'cur_title': '주 은혜',
      'cur_chord_lyrics': '[G]주 은혜',
      'cur_chord_key': 'G',
    };
    final filled = WorshipContiRepository.portableItemRow(base);
    expect(filled['song_lyrics'], '주 은혜');
    expect(filled['song_chord_lyrics'], '[G]주 은혜');
    expect(filled['song_chord_key'], 'G');
    expect(filled.keys.where((k) => k.startsWith('cur_')), isEmpty);

    // 가사 스냅샷이 있으면 빈 코드는 '코드 없음' 그대로.
    final kept = WorshipContiRepository.portableItemRow({
      ...base,
      'song_lyrics': '주 은혜',
    });
    expect(kept['song_chord_lyrics'], isNull);
  });
}
