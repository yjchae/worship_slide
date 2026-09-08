import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/bible/data/bible_repository.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/praise_repository.dart';
import 'package:worship_slides/src/features/praise/data/worship_conti_repository.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';

/// 다국어: 언어별 가사 저장, 성경 보조 역본 본문의 콘티 왕복, 역본 간 책 이름 매칭.
void main() {
  setUpAll(sqfliteFfiInit);

  Future<PraiseDatabase> openFreshDb() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createPraiseSchema(db);
    addTearDown(db.close);
    return PraiseDatabase.forTesting(db);
  }

  const song = PraiseSong(
    id: 1,
    fileName: 'grace.pptx',
    title: '은혜',
    lyrics: '주의 은혜',
    englishLyrics: 'Your grace',
  );

  test('영어는 곡에서, 다른 언어는 번역표에서 읽는다', () async {
    final repository = PraiseRepository(database: await openFreshDb());
    await repository.saveTranslations('일본어', {'은혜': '主の恵み'});

    expect(await repository.subLyricsFor(song, '영어'), 'Your grace');
    expect(await repository.subLyricsFor(song, '일본어'), '主の恵み');
    // 등록되지 않은 언어는 빈 문자열 (슬라이드에서 보조 줄이 사라진다)
    expect(await repository.subLyricsFor(song, '중국어'), '');
    expect(await repository.getSubLanguages(), ['영어', '일본어']);
  });

  test('번역은 제목으로 묶여 곡을 다시 임포트해도 살아남는다', () async {
    final database = await openFreshDb();
    final repository = PraiseRepository(database: database);
    await repository.replaceAllSongs([song]);
    await repository.saveTranslations('일본어', {'은혜': '主の恵み'});

    // 재임포트 = 전체 삭제 후 재삽입이라 id 가 바뀐다.
    await repository.replaceAllSongs([song]);
    final reimported = (await repository.searchSongs('')).single;

    expect(await repository.subLyricsFor(reimported, '일본어'), '主の恵み');
  });

  test('빈 가사를 저장하면 그 언어 항목이 지워진다', () async {
    final repository = PraiseRepository(database: await openFreshDb());
    await repository.saveTranslations('일본어', {'은혜': '主の恵み'});
    await repository.saveTranslations('일본어', {'은혜': '   '});

    expect(await repository.subLyricsFor(song, '일본어'), '');
    expect(await repository.countTranslations('일본어'), 0);
  });

  test('성경 보조 역본 본문이 콘티 저장 → 불러오기를 왕복한다', () async {
    final database = await openFreshDb();
    final repository = WorshipContiRepository(database: database);

    final contiId = await repository.saveConti('주일 예배', [
      (
        uid: 1,
        item: BibleStagingItem(
          reference: '요한복음 3:16',
          text: '16. 하나님이 세상을 이처럼 사랑하사',
          subText: '16. For God so loved the world',
        ),
      ),
    ]);

    final loaded = await repository.loadConti(contiId, 100);
    final item = loaded.items.single.item as BibleStagingItem;
    expect(item.subText, '16. For God so loved the world');
  });

  test('역본마다 책 이름이 달라도 정경 순서로 짝을 찾는다', () async {
    final database = await openFreshDb();
    final db = await database.database;
    for (final (version, book) in [
      ('개역개정', '창세기'),
      ('개역개정', '요한복음'),
      ('NIV', 'Genesis'),
      ('NIV', 'John'),
    ]) {
      await db.insert('bible_verses', {
        'bible_version': version,
        'book_name': book,
        'chapter': 1,
        'verse': 1,
        'text': '$book 1:1',
      });
    }
    final bible = BibleRepository(database: database);

    expect(
      await bible.mapBookName(
        bookName: '요한복음',
        fromVersion: '개역개정',
        inVersion: 'NIV',
      ),
      'John',
    );
    // 권 수가 다르면 짝을 못 믿으므로 포기한다.
    await db.insert('bible_verses', {
      'bible_version': 'NIV',
      'book_name': 'Acts',
      'chapter': 1,
      'verse': 1,
      'text': 'Acts 1:1',
    });
    expect(
      await bible.mapBookName(
        bookName: '요한복음',
        fromVersion: '개역개정',
        inVersion: 'NIV',
      ),
      isNull,
    );
  });
}
