import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/bible/data/bible_repository.dart';
import 'package:worship_slides/src/features/bible/domain/bible_text_search.dart';
import 'package:worship_slides/src/features/bible/domain/bible_verse.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';

/// 성경 본문 검색: 띄어쓰기 무시·낱말 AND·범위·LIKE escape, 강조 위치, 여러 장 선택의 페이지 나누기.
void main() {
  setUpAll(sqfliteFfiInit);

  Future<BibleRepository> openRepository() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createPraiseSchema(db);
    addTearDown(db.close);
    final repository = BibleRepository(database: PraiseDatabase.forTesting(db));
    await repository.importFromJson('''
      {
        "창세기": {"1": {"1": "태초에 하나님이 천지를 창조하시니라"}},
        "요한복음": {"3": {
          "16": "하나님이 세상을 이처럼 사랑하사 독생자를 주셨으니 이는 그를 믿는 자마다 멸망하지 않고 영생을 얻게 하려 하심이라",
          "17": "하나님이 그 아들을 세상에 보내신 것은 세상을 심판하려 하심이 아니요"
        }},
        "요한일서": {"4": {"9": "하나님의 사랑이 우리에게 이렇게 나타난 바 되었으니 하나님이 자기의 독생자를 세상에 보내심은 100% 그로 말미암아 우리를 살리려 하심이라"}}
      }
    ''', version: '개역개정');
    await repository.importFromJson('''
      {"John": {"3": {"16": "For God so loved the world"}}}
    ''', version: 'KJV');
    return repository;
  }

  List<String> refs(BibleSearchResult result) =>
      result.verses.map((v) => v.reference).toList();

  group('searchVerses', () {
    test('띄어쓰기를 무시하고 찾는다', () async {
      final repository = await openRepository();
      final joined = await repository.searchVerses(
        version: '개역개정',
        query: '이처럼사랑',
      );
      final spaced = await repository.searchVerses(
        version: '개역개정',
        query: '이처럼 사랑',
      );
      expect(refs(joined), ['요한복음 3:16']);
      expect(refs(spaced), ['요한복음 3:16']);
    });

    test('여러 낱말은 모두 들어간 절만 (순서 무관), 결과는 정경 순서', () async {
      final repository = await openRepository();
      expect(
        refs(await repository.searchVerses(version: '개역개정', query: '독생자')),
        ['요한복음 3:16', '요한일서 4:9'],
      );
      expect(
        refs(await repository.searchVerses(version: '개역개정', query: '영생 독생자')),
        ['요한복음 3:16'],
      );
    });

    test('역본끼리 섞이지 않고 영문은 대소문자를 가리지 않는다', () async {
      final repository = await openRepository();
      expect(
        refs(await repository.searchVerses(version: '개역개정', query: 'loved')),
        isEmpty,
      );
      expect(
        refs(await repository.searchVerses(version: 'KJV', query: 'GODSO')),
        ['John 3:16'],
      );
    });

    test('% 와 _ 는 와일드카드가 아니라 글자 그대로', () async {
      final repository = await openRepository();
      expect(
        refs(await repository.searchVerses(version: '개역개정', query: '100%')),
        ['요한일서 4:9'],
      );
      expect(
        refs(await repository.searchVerses(version: '개역개정', query: '하%님')),
        isEmpty,
      );
      expect(
        refs(await repository.searchVerses(version: '개역개정', query: '하_님')),
        isEmpty,
      );
    });

    test('책 범위: null 은 전체, 빈 목록은 결과 없음', () async {
      final repository = await openRepository();
      expect(
        refs(
          await repository.searchVerses(
            version: '개역개정',
            query: '하나님',
            books: ['요한복음'],
          ),
        ),
        ['요한복음 3:16', '요한복음 3:17'],
      );
      final none = await repository.searchVerses(
        version: '개역개정',
        query: '하나님',
        books: const [],
      );
      expect(none.verses, isEmpty);
      expect(none.totalCount, 0);
    });

    test('limit 를 넘으면 앞부분만, 전체 수는 따로 센다', () async {
      final repository = await openRepository();
      final result = await repository.searchVerses(
        version: '개역개정',
        query: '하나님',
        limit: 2,
      );
      expect(refs(result), ['창세기 1:1', '요한복음 3:16']);
      expect(result.totalCount, 4);
    });
  });

  group('BibleSearchScope', () {
    final canon = [for (var i = 1; i <= 66; i++) 'b$i'];

    test('66권이면 앞 39권이 구약, 뒤 27권이 신약', () {
      expect(BibleSearchScope.all.booksOf(canon), isNull);
      expect(BibleSearchScope.oldTestament.booksOf(canon), hasLength(39));
      expect(BibleSearchScope.oldTestament.booksOf(canon)!.last, 'b39');
      expect(BibleSearchScope.newTestament.booksOf(canon), hasLength(27));
      expect(BibleSearchScope.newTestament.booksOf(canon)!.first, 'b40');
    });

    test('66권이 아니면 구약·신약을 가르지 않는다, 책은 고른 책만', () {
      final partial = canon.take(27).toList();
      expect(BibleSearchScope.canSplitTestaments(partial), isFalse);
      expect(BibleSearchScope.newTestament.booksOf(partial), isEmpty);
      expect(BibleSearchScope.book.booksOf(canon), isEmpty);
      expect(BibleSearchScope.book.booksOf(canon, book: 'b43'), ['b43']);
    });
  });

  group('검색어·강조', () {
    test('낱말 나누기와 최소 길이', () {
      expect(bibleSearchTerms('  독생자   영생 '), ['독생자', '영생']);
      expect(isSearchableBibleQuery('주'), isFalse);
      expect(isSearchableBibleQuery('주 님'), isTrue);
    });

    test('띄어쓰기를 건너 걸린 자리도 원문 위치로 강조한다', () {
      const text = '세상을 이처럼 사랑하사';
      final ranges = bibleMatchRanges(text, ['이처럼사랑']);
      expect(ranges, [(4, 10)]);
      expect(text.substring(4, 10), '이처럼 사랑');
    });

    test('여러 번·겹친 자리는 합치고 대소문자를 가리지 않는다', () {
      expect(bibleMatchRanges('God so loved God', ['god']), [(0, 3), (13, 16)]);
      expect(bibleMatchRanges('abcdef', ['abc', 'cde']), [(0, 5)]);
      expect(bibleMatchRanges('abc', ['xyz']), isEmpty);
    });
  });

  group('bibleVersePages', () {
    BibleVerse verse(String book, int chapter, int number) => BibleVerse(
      id: chapter * 100 + number,
      bookName: book,
      chapter: chapter,
      verse: number,
      text: '',
    );

    test('한 장이면 예전처럼 절 번호 순으로 N절씩', () {
      final pages = bibleVersePages([
        verse('요한복음', 3, 18),
        verse('요한복음', 3, 16),
        verse('요한복음', 3, 17),
      ], 2);
      expect(pages.map((p) => p.map((v) => v.verse).toList()).toList(), [
        [16, 17],
        [18],
      ]);
    });

    test('여러 책·장은 장마다 따로 페이지를 만든다', () {
      final pages = bibleVersePages([
        verse('요한복음', 3, 16),
        verse('요한일서', 4, 9),
        verse('요한복음', 3, 17),
      ], 5);
      expect(
        pages
            .map((p) => p.map((v) => '${v.bookName} ${v.verse}').toList())
            .toList(),
        [
          ['요한복음 16', '요한복음 17'],
          ['요한일서 9'],
        ],
      );
    });
  });
}
