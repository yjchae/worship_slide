import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/conti_text_parse.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';

PraiseSong _song(int id, String title, {String lyrics = '가사'}) => PraiseSong(
  id: id,
  fileName: '$title.pptx',
  title: title,
  lyrics: lyrics,
  englishLyrics: '',
);

void main() {
  group('parseContiText', () {
    test('예시 콘티: 머리말은 빼고 번호·제목·조·대신 부를 곡을 나눈다', () {
      final entries = parseContiText('''
<11.01 (주일) 예배 콘티>

1. 아침에 주의 인자하심을 F
2. 갈길을 밝히 보이시니(or 죄에서 자유를 얻게 함은) G
3. 나의 반석이신 하나님 G
4. 생수의 강이 G
5. 신부의 노래 G
6. -> 그날에 예수 주 다시오셔서 G
''');
      expect(entries.map((e) => e.number), [1, 2, 3, 4, 5, 6]);
      expect(entries[0].titles, ['아침에 주의 인자하심을']);
      expect(entries[0].key, 'F');
      expect(entries[1].titles, ['갈길을 밝히 보이시니', '죄에서 자유를 얻게 함은']);
      expect(entries[1].key, 'G');
      expect(entries[5].titles, ['그날에 예수 주 다시오셔서']);
    });

    test('조 표기: 반음·단조·조 바꿈·Key 괄호, 영어 제목 끝 낱말은 조가 아니다', () {
      final entries = parseContiText('''
1) How great is our God (Key Bb)
2 10000 Reasons F-G
3. 주 은혜임을 F#m
4. Way Maker
''');
      expect(entries[0].titles, ['How great is our God']);
      expect(entries[0].key, 'Bb');
      expect(entries[1].titles, ['10000 Reasons']);
      expect(entries[1].key, 'F-G');
      expect(entries[2].key, 'F#m');
      expect(entries[3].titles, ['Way Maker']);
      expect(entries[3].key, '');
    });

    test('번호 줄이 있으면 설명 줄은 빼고, 없으면 모든 줄을 곡으로 본다', () {
      expect(
        parseContiText('인도: 홍길동\n1. 생수의 강이 G\n(헌금송 뒤)').map((e) => e.titles.first),
        ['생수의 강이'],
      );
      expect(
        parseContiText('생수의 강이 G\n신부의 노래').map((e) => e.titles.first),
        ['생수의 강이', '신부의 노래'],
      );
    });
  });

  group('parseContiText 리뷰 수정', () {
    test('번호 줄 사이 번호 없는 -> 이어 부르기 줄도 곡이다', () {
      final entries = parseContiText(
        '1. 아침에 주의 인자하심을 F\n-> 주의 인자하심 G\n2. 생수의 강이 G',
      );
      expect(entries.map((e) => e.titles.first), [
        '아침에 주의 인자하심을',
        '주의 인자하심',
        '생수의 강이',
      ]);
      expect(entries.map((e) => e.number), [1, null, 2]);
    });

    test('날짜·시각 줄은 번호 줄이 아니다', () {
      final entries = parseContiText(
        '11.01 (주일) 예배 콘티\n7:30 리허설\n1. 생수의 강이 G\n2. 신부의 노래 G',
      );
      expect(entries.map((e) => e.number), [1, 2]);
    });

    test('숫자로 시작하는 제목 하나가 번호 모드를 켜지 않는다', () {
      final entries = parseContiText('생수의 강이\n7 Days\n신부의 노래');
      expect(entries.map((e) => e.titles.first), [
        '생수의 강이',
        '7 Days',
        '신부의 노래',
      ]);
    });

    test('번호 뒤 한두 자리 숫자로 시작하는 제목도 번호 줄이다', () {
      final entries = parseContiText('1 7 Days\n2 10 Thousand Reasons G');
      expect(entries.map((e) => e.number), [1, 2]);
      expect(entries.map((e) => e.titles.first), ['7 Days', '10 Thousand Reasons']);
      expect(entries[1].key, 'G');
    });

    test('숫자만 있는 줄과 날짜는 번호 줄이 아니다', () {
      final entries = parseContiText(
        '11 01\n11  01\n11.01\n1. 생수의 강이 G\n2. 신부의 노래 G',
      );
      expect(entries.map((e) => e.number), [1, 2]);
    });

    test('숫자만 있는 줄은 두 줄이어도 번호 모드를 켜지 않는다', () {
      final entries = parseContiText('11 01\n11 08\n생수의 강이');
      expect(entries.map((e) => e.number), [null, null, null]);
      expect(entries.map((e) => e.titles.first), ['11 01', '11 08', '생수의 강이']);
    });

    test('7 Days 하나만 있는 글은 번호 모드를 켜지 않는다', () {
      final entry = parseContiText('7 Days').single;
      expect(entry.number, isNull);
      expect(entry.titles, ['7 Days']);
    });

    test('번호 목록 안 숫자 제목은 그대로 남는다', () {
      expect(parseContiText('1. 10000 Reasons G').single.titles, ['10000 Reasons']);
    });

    test('(or …) 가 조처럼 보이는 낱말로 끝나도 괄호가 깨지지 않는다', () {
      final entry = parseContiText('1. 주님 (or Here I Am)').single;
      expect(entry.titles, ['주님', 'Here I Am']);
      expect(entry.key, '');
    });

    test('꺾쇠 뒤에 글이 더 붙은 머리말도 뺀다', () {
      expect(
        parseContiText('<11.01 주일 콘티> 인도 홍길동\n생수의 강이').map((e) => e.titles.first),
        ['생수의 강이'],
      );
    });

    test('자모가 풀린(NFD) 글도 합쳐서 읽는다', () {
      // '강' = ᄀ(1100) ᅡ(1161) ᆼ(11BC)
      final nfd = String.fromCharCodes([0x1100, 0x1161, 0x11BC]);
      expect(normalizeSongTitle('생수의 $nfd이'), normalizeSongTitle('생수의 강이'));
    });
  });

  group('ContiSongMatcher', () {
    final songs = [
      _song(1, '아침에 주의 인자하심을'),
      _song(2, '갈 길을 밝히 보이시니'),
      _song(3, '죄에서 자유를 얻게 함은'),
      _song(4, '신부의 노래', lyrics: '첫 번째 신부의 노래'),
      _song(5, '신부의 노래', lyrics: '두 번째 신부의 노래'),
      _song(6, '그날에 예수 주 다시 오셔서 (와이드 스크린)'),
      _song(7, 'Here I Am'),
    ];
    final matcher = ContiSongMatcher(songs);
    ContiSongMatch matchLine(String line) => matcher.match(parseContiText(line).single);

    test('띄어쓰기를 무시하고 똑같은 제목을 찾는다', () {
      final m = matchLine('1. 아침에 주의 인자하심을 F');
      expect(m.kind, ContiMatchKind.exact);
      expect(m.candidates.map((s) => s.id), [1]);
      expect(matchLine('6. -> 그날에 예수 주 다시오셔서 G').candidates.map((s) => s.id), [6]);
    });

    test('같은 제목 곡이 여럿이면 모두 후보로 준다', () {
      expect(matchLine('5. 신부의 노래 G').candidates.map((s) => s.id), [4, 5]);
    });

    test('(or …) 대신 부를 곡도 후보에 넣는다', () {
      final m = matchLine('2. 갈길을 밝히 보이시니(or 죄에서 자유를 얻게 함은) G');
      expect(m.candidates.map((s) => s.id), [2, 3]);
    });

    test('제목 일부만 적었으면 비슷한 제목으로 찾는다', () {
      final m = matchLine('1. 아침에 주의 G');
      expect(m.kind, ContiMatchKind.partial);
      expect(m.candidates.map((s) => s.id), [1]);
    });

    test('조로 떼어진 제목 끝 낱말도 붙여 맞춘다', () {
      expect(matchLine('1. Here I Am').candidates.map((s) => s.id), [7]);
    });

    test('없는 곡은 후보가 없다', () {
      final m = matchLine('1. 없는 찬양 제목 G');
      expect(m.candidates, isEmpty);
      expect(m.kind, isNull);
    });

    test('NFD 제목의 곡도 찾는다', () {
      final nfdTitle = '생수의 ${String.fromCharCodes([0x1100, 0x1161, 0x11BC])}이';
      final m = ContiSongMatcher([_song(9, nfdTitle)]).match(
        parseContiText('1. 생수의 강이 G').single,
      );
      expect(m.candidates.map((s) => s.id), [9]);
    });

    test('build 는 다른 isolate 에서 만들어도 같은 결과를 준다', () async {
      final built = await ContiSongMatcher.build(songs);
      expect(
        built.match(parseContiText('5. 신부의 노래 G').single).candidates.map((s) => s.id),
        [4, 5],
      );
    });

    test('직접 찾기는 제목·가사 둘 다 본다', () {
      expect(matcher.search('두번째').map((s) => s.id), [5]);
      expect(matcher.search('갈길').map((s) => s.id), [2]);
    });
  });
}
