import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/bible/domain/bible_text_search.dart';

void main() {
  const versions = ['개역개정', '새번역', 'KJV', '쉬운성경 간추림'];

  test('참조 풀기: 이어진 절·흩어진 절·모르는 역본·깨진 모양', () {
    final r = parseBibleReference('개역개정 요한복음 3:16-18', versions)!;
    expect([r.version, r.book, r.chapter], ['개역개정', '요한복음', 3]);
    expect(r.verses, [16, 17, 18]);
    expect(parseBibleReference('KJV 1 John 4:9,11', versions)!.verses, [9, 11]);
    expect(parseBibleReference('NIV 요한복음 3:16', versions), isNull);
    expect(parseBibleReference('개역개정 요한복음', versions), isNull);
  });

  test('새 역본으로 다시 만들기: 참조 앞 역본·본문 줄', () {
    final ref = parseBibleReference('개역개정 요한복음 3:16-17', versions)!;
    final s = switchBibleVersion(ref, '새번역', '요한복음', {
      16: '가',
      17: '나',
      18: '다',
    })!;
    expect(s.reference, '새번역 요한복음 3:16-17');
    expect(s.text, '16. 가\n17. 나');
    expect(s.missing, isEmpty);
  });

  test('다른 이름의 책(KJV)과 흩어진 절', () {
    final ref = parseBibleReference('새번역 요한일서 4:9,11', versions)!;
    final s = switchBibleVersion(ref, 'KJV', '1 John', {9: 'a', 11: 'b'})!;
    expect(s.reference, 'KJV 1 John 4:9,11');
  });

  test('일부 절이 없으면 참조를 줄이고 알린다, 전부 없으면 null', () {
    final ref = parseBibleReference('개역개정 요한복음 3:16-18', versions)!;
    final s = switchBibleVersion(ref, 'KJV', 'John', {16: 'a', 17: 'b'})!;
    expect(s.reference, 'KJV John 3:16-17');
    expect(s.missing, [18]);
    expect(switchBibleVersion(ref, 'KJV', 'John', {1: 'x'}), isNull);
    expect(switchBibleVersion(ref, 'KJV', 'John', {}), isNull);
  });

  test('보조 칸: 새 본문 역본과 같으면 비고(null), 되돌리면 다시 채워진다', () {
    // 전역 보조 = 새번역. 본문을 새번역으로 바꾸면 그 칸은 비고, 개역개정으로 돌아오면 새번역 본문이 다시 온다.
    final subWhenMain = {
      '개역개정': verseNumbersText([16], {16: '새번역 본문'}),
      '새번역': verseNumbersText([
        16,
      ], null), // _loadOtherVersionVerses 가 같은 역본이면 null
    };
    expect(subWhenMain['새번역'], '');
    expect(subWhenMain['개역개정'], '16. 새번역 본문');
  });

  test('buildBibleReference: 빈 절·정렬·한 절', () {
    expect(buildBibleReference('A', 'B', 1, []), '');
    expect(buildBibleReference('A', 'B', 1, [3, 1, 2]), 'A B 1:1-3');
    expect(buildBibleReference('A', 'B', 1, [5]), 'A B 1:5');
  });
}
