import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/praise_repository.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';

/// 곡 모음 내보내기/가져오기: 같은 제목은 새로 넣지 않고 빠진 보조 가사만 채운다.
void main() {
  setUpAll(sqfliteFfiInit);

  Future<PraiseRepository> freshRepo() async {
    // PC 두 대를 흉내 내야 하므로 메모리 DB(하나를 공유함) 대신 임시 파일을 쓴다.
    final dir = await Directory.systemTemp.createTemp('song_bundle_');
    addTearDown(() => dir.delete(recursive: true));
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/test.db');
    await createPraiseSchema(db);
    addTearDown(db.close);
    return PraiseRepository(database: PraiseDatabase.forTesting(db));
  }

  PraiseSong song(String title, String lyrics, [String english = '']) =>
      PraiseSong(
        id: null,
        fileName: '$title.pptx',
        title: title,
        lyrics: lyrics,
        englishLyrics: english,
      );

  test('다른 PC 의 곡을 합친다 — 같은 제목은 중복되지 않는다', () async {
    // A PC: 은혜(영어 없음, 인도네시아어 있음), 축복
    final a = await freshRepo();
    await a.insertSong(song('은혜', 'A 의 은혜 가사'));
    await a.insertSong(song('축복', '축복 가사', 'Blessing'));
    await a.saveTranslations('인도네시아어', {'은혜': 'Kasih karunia'});

    // B PC: "은 혜"(띄어쓰기만 다름, 가사도 다름, 영어·일본어 있음), 사랑
    final b = await freshRepo();
    await b.insertSong(song('은 혜', 'B 의 은혜 가사', 'Grace'));
    await b.insertSong(song('사랑', '사랑 가사'));
    await b.saveTranslations('일본어', {'은 혜': '恵み'});
    await b.saveTranslations('인도네시아어', {'은 혜': 'B 번역'});

    // 파일을 거치는 것처럼 JSON 으로 한 번 굴린다.
    final bundle =
        jsonDecode(jsonEncode(await b.exportSongBundle()))
            as Map<String, Object?>;
    final result = await a.importSongBundle(bundle);

    expect(result.addedCount, 1); // 사랑
    expect(result.skippedCount, 1); // 은 혜 → 은혜
    expect(result.subLyricsAddedCount, 2); // 은혜 영어 + 일본어

    final songs = await a.searchSongs('');
    expect(songs.map((s) => s.title), ['사랑', '은혜', '축복']);
    final grace = songs.firstWhere((s) => s.title == '은혜');
    expect(grace.lyrics, 'A 의 은혜 가사'); // 기존 가사는 그대로
    expect(grace.englishLyrics, 'Grace'); // 비어 있던 영어만 채움
    expect(await a.translationsForTitle('은혜'), {
      '인도네시아어': 'Kasih karunia', // 기존 번역은 덮어쓰지 않음
      '일본어': '恵み',
    });

    // 같은 파일을 또 가져와도 아무것도 늘지 않는다.
    final again = await a.importSongBundle(bundle);
    expect(again.addedCount, 0);
    expect(again.subLyricsAddedCount, 0);
    expect(await a.countSongs(), 3);
  });

  test('곡 모음 파일이 아니면 거부한다', () async {
    final a = await freshRepo();
    expect(
      () => a.importSongBundle({'songs': []}),
      throwsA(isA<FormatException>()),
    );
  });
}
