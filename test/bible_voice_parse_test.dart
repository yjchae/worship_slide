import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/bible/domain/bible_voice_parse.dart';

const versions = ['NIV', '개역개정', '새번역'];

String? parse(String text) {
  final c = parseBibleVoice(text, versions);
  if (c == null) return null;
  final book = c.book == null ? '-' : bibleCanonKorean[c.book!];
  final verses = c.fromVerse == null
      ? ''
      : c.toVerse == c.fromVerse
      ? ':${c.fromVerse}'
      : ':${c.fromVerse}-${c.toVerse}';
  return '${c.version ?? '-'} $book ${c.chapter ?? '-'}$verses';
}

void main() {
  test('사용자가 정한 말하기 방식', () {
    expect(parse('다니엘 3장1절 에서 10절'), '- 다니엘 3:1-10');
    expect(parse('다니엘 3장 1절에서 10절'), '- 다니엘 3:1-10');
    expect(parse('에베소서 1장 1절'), '- 에베소서 1:1');
    expect(parse('시편 107편 5절'), '- 시편 107:5');
  });

  test('역본', () {
    expect(parse('개역개정 요한복음 3장 16절'), '개역개정 요한복음 3:16');
    expect(parse('개역 개정으로 바꿔 주세요'), '개역개정 - -');
    expect(parse('새번역으로'), '새번역 - -');
    expect(parse('엔아이브이 로마서 8장 28절'), 'NIV 로마서 8:28');
  });

  test('DB 역본 이름이 자모가 풀린 꼴(NFD)이어도 찾는다', () {
    final nfd = [
      '개역개정',
      '새번역',
    ].map((v) => String.fromCharCodes(_decompose(v))).toList();
    expect(nfd[1] == '새번역', isFalse);
    expect(composeHangul(nfd[1]), '새번역');
    expect(parseBibleVoice('새 번역으로', nfd)!.version, nfd[1]);
    expect(parseBibleVoice('개역개정 시편 1편', nfd)!.version, nfd[0]);
  });

  test('한글 수사·범위·장 전체', () {
    expect(parse('요한복음 삼 장 십육 절'), '- 요한복음 3:16');
    expect(parse('시편 이십삼편'), '- 시편 23');
    expect(parse('시편 백십구편 백오절'), '- 시편 119:105');
    expect(parse('로마서 8장 28절부터 30절까지'), '- 로마서 8:28-30');
    expect(parse('고린도 전서 13장'), '- 고린도전서 13');
    expect(parse('요한 1서 4장 8절'), '- 요한일서 4:8');
    expect(parse('요한일서 4장 8절'), '- 요한일서 4:8');
    expect(parse('요한계시록 21:1-4'), '- 요한계시록 21:1-4');
  });

  test('앞뒤 말 무시 · 마지막 구절', () {
    expect(parse('오늘 말씀은 이사야 40장 31절 말씀입니다'), '- 이사야 40:31');
    expect(parse('창세기 1장 아니 출애굽기 3장 14절'), '- 출애굽기 3:14');
  });

  test('절 범위 "16-18절" · 줄여 말한 복음서 · 뒤에 말한 절', () {
    expect(parse('데살로니가전서 5장 16-18절'), '- 데살로니가전서 5:16-18');
    expect(parse('마태복음 5장 3~10절'), '- 마태복음 5:3-10');
    expect(parse('로마서 8장이 말하는'), '- 로마서 8');
    expect(parse('요한 3장 16절'), '- 요한복음 3:16');
    expect(parse('요한 일서 4장 8절'), '- 요한일서 4:8');
    expect(parse('시편 23편 그리고 17절'), '- 시편 23:17');
    expect(parse('시편 23편 5절'), '- 시편 23:5');
  });

  test('책 뒤에 붙는 말 · 시간은 구절이 아니다', () {
    expect(parse('로마서에서 8장 28절'), '- 로마서 8:28');
    expect(parse('다니엘서 3장 1절'), '- 다니엘 3:1');
    expect(parse('이어서 5장 1절'), '- - 5:1');
    expect(parse('본문에서 3장'), '- - 3');
    expect(parse('오후 3:30에 모입니다'), isNull);
  });

  test('이어 말하기 (책·장 없음)', () {
    expect(parse('17절'), '- - -:17');
    expect(parse('18절에서 20절'), '- - -:18-20');
    expect(parse('십칠절'), '- - -:17');
    // 문장 중간의 한글 수사는 낱말일 가능성이 커서 받지 않는다
    expect(parse('그것이 사절입니다'), isNull);
  });

  test('구절이 없는 말', () {
    expect(parse('여러분 사랑합니다'), isNull);
    expect(parse(''), isNull);
  });

  test('수사', () {
    for (var n = 1; n <= 176; n++) {
      expect(parseKoreanNumber(koreanNumber(n)), n);
    }
    expect(parseKoreanNumber('일이'), isNull);
  });

  test('SRGS 문법', () {
    final g = bibleVoiceGrammar(versions);
    expect(g, contains('<item>다니엘</item>'));
    expect(g, contains('<item>백칠십육</item>'));
    expect(g, contains('<item>개역개정</item>'));
    expect(g, contains('<item>엔아이브이</item>'));
  });
}

// 완성형 → 자모 (테스트용 NFD)
List<int> _decompose(String s) => [
  for (final c in s.runes)
    if (c >= 0xAC00 && c <= 0xD7A3) ...[
      0x1100 + (c - 0xAC00) ~/ 588,
      0x1161 + (c - 0xAC00) % 588 ~/ 28,
      if ((c - 0xAC00) % 28 != 0) 0x11A7 + (c - 0xAC00) % 28,
    ] else
      c,
];
