// 성경 음성 검색: 음성 인식이 준 글("다니엘 3장 1절에서 10절", "개역개정 시편 107편 5절")에서
// 역본·책·장·절을 뽑는다. 화면·DB 를 모르는 순수 함수다.

/// 정경 순서 66권. 역본마다 책 이름이 달라서(창세기/Genesis) 이 순서 번호로 역본의 책을 찾는다
/// (`BibleRepository.mapBookName` 과 같은 가정).
const bibleCanonKorean = [
  '창세기', '출애굽기', '레위기', '민수기', '신명기', '여호수아', '사사기', '룻기', //
  '사무엘상', '사무엘하', '열왕기상', '열왕기하', '역대상', '역대하', '에스라', '느헤미야',
  '에스더', '욥기', '시편', '잠언', '전도서', '아가', '이사야', '예레미야', '예레미야애가',
  '에스겔', '다니엘', '호세아', '요엘', '아모스', '오바댜', '요나', '미가', '나훔', '하박국',
  '스바냐', '학개', '스가랴', '말라기', //
  '마태복음', '마가복음', '누가복음', '요한복음', '사도행전', '로마서', '고린도전서', '고린도후서',
  '갈라디아서', '에베소서', '빌립보서', '골로새서', '데살로니가전서', '데살로니가후서',
  '디모데전서', '디모데후서', '디도서', '빌레몬서', '히브리서', '야고보서', '베드로전서',
  '베드로후서', '요한일서', '요한이서', '요한삼서', '유다서', '요한계시록',
];

/// 말로 흔히 하는(또는 인식기가 흔히 적는) 다른 이름 → 정경 번호.
const _bookAliases = {
  '사무엘서상': 8,
  '사무엘서하': 9,
  '열왕기서상': 10,
  '열왕기서하': 11,
  '역대기상': 12,
  '역대기하': 13,
  '아가서': 21,
  '애가': 24,
  '예레미야 애가': 24,
  '요한1서': 61,
  '요한2서': 62,
  '요한3서': 63,
  '계시록': 65,
  // 복음서는 '복음' 을 빼고 말하기도 한다("요한 3장 16절"). 요한일서 등은 '서' 가 붙어 긴 이름이 먼저 걸린다.
  '마태': 39,
  '마가': 40,
  '누가': 41,
  '요한': 42,
};

/// 역본 이름을 말로 부를 때(인식기는 영문 약자를 한글 소리로 적는다) → 역본 이름.
const _versionAliases = {
  '엔아이브이': 'NIV',
  '엔아이비': 'NIV',
  '케이제이브이': 'KJV',
  '킹제임스': 'KJV',
  '이에스브이': 'ESV',
};

class BibleVoiceCommand {
  const BibleVoiceCommand({
    this.version,
    this.book,
    this.chapter,
    this.fromVerse,
    this.toVerse,
  });

  /// 말한 역본(그 역본의 실제 이름). null = 말하지 않음.
  final String? version;

  /// 정경 번호(0~65). null = 책을 말하지 않음(앞에 말한 책을 이어 쓴다).
  final int? book;

  /// null = 장을 말하지 않음(절만 말함 → 앞 장을 이어 쓴다).
  final int? chapter;

  /// null = 장 전체.
  final int? fromVerse;
  final int? toVerse;

  /// 구절을 말했는지. false 면 역본만 바꾼다.
  bool get hasReference => chapter != null || fromVerse != null;

  @override
  String toString() => '$version $book $chapter:$fromVerse-$toVerse';
}

final _drop = RegExp(r'[\s.,!?·"“”‘’()\[\]]');
const _num = r'(\d+|[영일이삼사오육륙칠팔구십백]+)';
const _rangeWord = r'(?:에서부터|에서|부터|~|-|내지)';

final _bookPattern = () {
  final names = [
    ...bibleCanonKorean,
    for (final a in _bookAliases.keys) a.replaceAll(' ', ''),
  ]..sort((a, b) => b.length.compareTo(a.length)); // 긴 이름 먼저(요한복음 > 요한)
  return names.join('|');
}();

// 책 이름과 숫자 사이에 붙는 말: "다니엘서 3장", "로마서에서 8장", "요한복음의 3장".
// 책 묶음 안에 둬야 한다 — 밖에 두면 책 없는 "이어서 5장" 의 '서' 까지 삼켜 장을 놓친다.
const _bookFiller = r'(?:에서|서|기|의)?';

// 책 + N장(편) [+ 절]. 책이 없으면 앞 책을 이어 쓴다. 절은 둘 중 하나:
//   "16절" / "16절에서 18절"(그룹 3·4)  ·  "16-18절" / "3~10절"(그룹 5·6, 끝에 '절' 하나)
// 숫자만 있고 '절' 이 없는 "8장이" 는 절로 보지 않는다('이' 가 수사 2 라서).
final _chapterRef = RegExp(
  '(?:($_bookPattern)$_bookFiller)?$_num(?:장|편)'
  '(?:$_num절(?:$_rangeWord$_num절?)?|$_num$_rangeWord$_num절)?',
);
// 책 + N:N[-N]. 책이 꼭 있어야 한다 — 없으면 "오후 3:30" 같은 시간이 구절이 된다.
final _colonRef = RegExp(
  '($_bookPattern)$_bookFiller(\\d+):(\\d+)(?:-(\\d+))?',
);
// 절만: "17절", "18절에서 20절"
final _verseRef = RegExp('$_num절(?:$_rangeWord$_num절?)?');

/// 아라비아 숫자 또는 한자어 수사(일·이·삼…십·백). 못 읽으면 null.
int? parseKoreanNumber(String s) {
  final digits = int.tryParse(s);
  if (digits != null) return digits;
  const units = {
    '영': 0,
    '일': 1,
    '이': 2,
    '삼': 3,
    '사': 4,
    '오': 5,
    '육': 6,
    '륙': 6,
    '칠': 7,
    '팔': 8,
    '구': 9,
  };
  var total = 0;
  int? current;
  for (final ch in s.split('')) {
    if (ch == '십' || ch == '백') {
      total += (current ?? 1) * (ch == '십' ? 10 : 100);
      current = null;
    } else {
      final d = units[ch];
      if (d == null || current != null) return null; // '일이' 같은 건 수가 아니다
      current = d;
    }
  }
  final n = total + (current ?? 0);
  return n > 0 ? n : null;
}

int _bookIndex(String name) {
  final i = bibleCanonKorean.indexOf(name);
  if (i >= 0) return i;
  return _bookAliases.entries
      .firstWhere((e) => e.key.replaceAll(' ', '') == name)
      .value;
}

/// 음성 인식 글 하나 → 명령. 구절도 역본도 없으면 null.
/// 한 문장에 구절이 여럿이면 마지막 것(설교자가 고쳐 말한 것으로 본다).
/// [versions] 는 DB 에 있는 역본 이름들.
BibleVoiceCommand? parseBibleVoice(String text, List<String> versions) {
  final s = composeHangul(text).replaceAll(_drop, '');
  if (s.isEmpty) return null;

  // 역본: 이름(공백 무시) 또는 소리 별칭. 여럿이면 마지막에 말한 것.
  String? version;
  var versionAt = -1;
  var versionKeyLength = 0;
  final spoken = {
    for (final v in versions)
      composeHangul(v).replaceAll(_drop, '').toLowerCase(): v,
    for (final e in _versionAliases.entries)
      if (versions.any((v) => v.toUpperCase() == e.value))
        e.key: versions.firstWhere((v) => v.toUpperCase() == e.value),
  };
  final lower = s.toLowerCase();
  for (final e in spoken.entries) {
    if (e.key.isEmpty) continue;
    final at = lower.lastIndexOf(e.key);
    // 같은 자리면 긴 이름(개역개정 > 개역)
    if (at > versionAt ||
        (at >= 0 && at == versionAt && e.key.length > versionKeyLength)) {
      versionAt = at;
      versionKeyLength = e.key.length;
      version = e.value;
    }
  }

  // 책·장이 든 구절 중 마지막 것.
  BibleVoiceCommand? ref;
  var refEnd = 0;
  final chapterMatch = _chapterRef.allMatches(s).where(_allowed).lastOrNull;
  final colonMatch = _colonRef.allMatches(s).lastOrNull;
  if (colonMatch != null &&
      (chapterMatch == null || colonMatch.start > chapterMatch.start)) {
    final from = int.parse(colonMatch[3]!);
    ref = BibleVoiceCommand(
      book: _bookIndex(colonMatch[1]!),
      chapter: int.parse(colonMatch[2]!),
      fromVerse: from,
      toVerse: colonMatch[4] == null ? from : int.parse(colonMatch[4]!),
    );
    refEnd = colonMatch.end;
  } else if (chapterMatch != null) {
    final chapter = parseKoreanNumber(chapterMatch[2]!);
    final fromText = chapterMatch[3] ?? chapterMatch[5];
    final toText = chapterMatch[4] ?? chapterMatch[6];
    final from = fromText == null ? null : parseKoreanNumber(fromText);
    final to = toText == null ? from : parseKoreanNumber(toText);
    if (chapter != null) {
      ref = BibleVoiceCommand(
        book: chapterMatch[1] == null ? null : _bookIndex(chapterMatch[1]!),
        chapter: chapter,
        fromVerse: from,
        toVerse: from == null ? null : to,
      );
      refEnd = chapterMatch.end;
    }
  }
  // 그 뒤에 절만 또 말했으면("시편 23편 그리고 17절") 그 절이 마지막 구절이다 — 같은 책·장.
  final verseMatch = _verseRef
      .allMatches(s)
      .where((m) => m.start >= refEnd && _allowed(m))
      .lastOrNull;
  final from = verseMatch == null ? null : parseKoreanNumber(verseMatch[1]!);
  if (from != null) {
    final to = verseMatch![2] == null
        ? from
        : parseKoreanNumber(verseMatch[2]!);
    ref = BibleVoiceCommand(
      book: ref?.book,
      chapter: ref?.chapter,
      fromVerse: from,
      toVerse: to ?? from,
    );
  }

  if (ref == null) {
    return version == null ? null : BibleVoiceCommand(version: version);
  }
  var to = ref.toVerse;
  if (to != null && ref.fromVerse != null && to < ref.fromVerse!) {
    to = ref.fromVerse;
  }
  return BibleVoiceCommand(
    version: version,
    book: ref.book,
    chapter: ref.chapter,
    fromVerse: ref.fromVerse,
    toVerse: to,
  );
}

// 책 없이 한글 수사로 시작하는 장·절("이장", "사절")은 보통 말 속 낱말이다 — 글 맨 앞일 때만 받는다.
// 책이 있거나 아라비아 숫자면 어디서든 받는다.
bool _allowed(RegExpMatch m) {
  if (m.groupCount >= 1 && m[1] != null && _isBook(m[1]!)) return true;
  final first = m[0]!;
  return m.start == 0 || RegExp(r'^\d').hasMatch(first);
}

bool _isBook(String s) =>
    bibleCanonKorean.contains(s) ||
    _bookAliases.keys.any((a) => a.replaceAll(' ', '') == s);

/// Windows 음성 인식용 SRGS 문법. 책·숫자·장·절·역본만 알아듣게 해서 인터넷 없이 돌고
/// 설교 중 다른 말에는 덜 걸린다. 앞뒤 다른 말은 GARBAGE 로 흘려보낸다.
/// 인식 결과 글은 항목 글자를 이은 것이라 [parseBibleVoice] 가 그대로 읽는다.
String bibleVoiceGrammar(List<String> versions) {
  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  String oneOf(Iterable<String> items) =>
      '<one-of>${items.map((i) => '<item>${esc(i)}</item>').join()}</one-of>';
  final numbers = [for (var n = 1; n <= 176; n++) koreanNumber(n)];
  final books = {...bibleCanonKorean, ..._bookAliases.keys};
  final versionWords = {
    for (final v in versions)
      if (RegExp(r'[가-힣]').hasMatch(composeHangul(v))) composeHangul(v),
    for (final e in _versionAliases.entries)
      if (versions.any((v) => v.toUpperCase() == e.value)) e.key,
  };
  const garbage = '<item repeat="0-1"><ruleref special="GARBAGE"/></item>';
  final version = versionWords.isEmpty
      ? ''
      : '<item repeat="0-1"><ruleref uri="#version"/></item>';
  final ranged =
      '<item repeat="0-1">${oneOf(['에서', '부터'])}<ruleref uri="#num"/>'
      '<item repeat="0-1">절</item><item repeat="0-1">까지</item></item>';
  return '''<?xml version="1.0" encoding="utf-8"?>
<grammar version="1.0" xml:lang="ko-KR" root="command" xmlns="http://www.w3.org/2001/06/grammar">
<rule id="command" scope="public">$garbage<one-of>
<item>$version<ruleref uri="#book"/><ruleref uri="#num"/>${oneOf(['장', '편'])}<item repeat="0-1"><ruleref uri="#num"/>절$ranged</item></item>
<item><ruleref uri="#num"/>절$ranged</item>
${versionWords.isEmpty ? '' : '<item><ruleref uri="#version"/></item>'}
</one-of>$garbage</rule>
<rule id="book">${oneOf(books)}</rule>
<rule id="num">${oneOf(numbers)}</rule>
${versionWords.isEmpty ? '' : '<rule id="version">${oneOf(versionWords)}</rule>'}
</grammar>''';
}

/// 1~999 → 한자어 수사 글("십육", "백칠").
String koreanNumber(int n) {
  const digits = ['', '일', '이', '삼', '사', '오', '육', '칠', '팔', '구'];
  final h = n ~/ 100, t = n ~/ 10 % 10, o = n % 10;
  return '${h == 0 ? '' : '${h == 1 ? '' : digits[h]}백'}'
      '${t == 0 ? '' : '${t == 1 ? '' : digits[t]}십'}'
      '${digits[o]}';
}

/// 풀어 쓴 한글 자모(NFD, macOS 파일 이름·일부 성경 JSON)를 완성형 음절(NFC)로 합친다.
/// DB 의 역본 이름이 NFD 면 '새번역' 과 글자가 달라 못 찾는다. Dart 에는 정규화 함수가 없어 한글만 직접 합친다.
String composeHangul(String text) {
  final out = <int>[];
  for (final c in text.runes) {
    final last = out.isEmpty ? -1 : out.last;
    if (c >= 0x1161 && c <= 0x1175 && last >= 0x1100 && last <= 0x1112) {
      // 초성 + 중성
      out[out.length - 1] = 0xAC00 + ((last - 0x1100) * 21 + (c - 0x1161)) * 28;
    } else if (c >= 0x11A8 &&
        c <= 0x11C2 &&
        last >= 0xAC00 &&
        last <= 0xD7A3 &&
        (last - 0xAC00) % 28 == 0) {
      // 받침 없는 음절 + 종성
      out[out.length - 1] = last + (c - 0x11A7);
    } else {
      out.add(c);
    }
  }
  return String.fromCharCodes(out);
}
