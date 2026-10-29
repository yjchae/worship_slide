import 'bible_verse.dart';

/// 본문 검색 범위. 구약·신약은 역본의 책 순서(= 정경 순서) 앞 39권 / 뒤 27권으로 가른다.
enum BibleSearchScope {
  all('전체'),
  oldTestament('구약'),
  newTestament('신약'),
  book('책');

  const BibleSearchScope(this.label);
  final String label;

  static const _oldTestamentCount = 39;
  static const _fullCanonCount = 66;

  /// 구약·신약으로 가를 수 있는 역본인가 (66권 전권).
  static bool canSplitTestaments(List<String> allBooks) =>
      allBooks.length == _fullCanonCount;

  /// 이 범위에 드는 책 이름. null = 모든 책, 빈 목록 = 찾을 책 없음.
  ///
  /// ponytail: 66권 역본이 정경 순서로 담겨 있다고 가정한다 (`mapBookName` 과 같은 가정).
  /// 66권이 아니면 구약·신약을 가를 수 없어 빈 목록이다 — 화면은 그때 그 두 칸을 숨긴다.
  List<String>? booksOf(List<String> allBooks, {String? book}) {
    switch (this) {
      case BibleSearchScope.all:
        return null;
      case BibleSearchScope.oldTestament:
        if (!canSplitTestaments(allBooks)) return const [];
        return allBooks.sublist(0, _oldTestamentCount);
      case BibleSearchScope.newTestament:
        if (!canSplitTestaments(allBooks)) return const [];
        return allBooks.sublist(_oldTestamentCount);
      case BibleSearchScope.book:
        return book == null ? const [] : [book];
    }
  }
}

class BibleSearchResult {
  const BibleSearchResult({required this.verses, required this.totalCount});

  static const empty = BibleSearchResult(verses: [], totalCount: 0);

  /// 앞에서부터 limit 절까지 (정경 순서).
  final List<BibleVerse> verses;

  /// limit 와 상관없는 전체 결과 수.
  final int totalCount;
}

/// 띄어쓰기로 보고 무시하는 글자. SQL(`BibleRepository`)과 강조(`bibleMatchRanges`)가 같은 목록을 써야
/// 'DB 에선 걸렸는데 강조가 안 됨'·그 반대가 생기지 않는다.
/// 공백·탭·줄바꿈 + 일부 성경 JSON 이 낱말 사이에 쓰는 NBSP(U+00A0)·전각 공백(U+3000).
const bibleIgnoredSpaces = [' ', '\t', '\n', '\r', '\u00A0', '\u3000'];

final _ignoredSpace = RegExp('[${bibleIgnoredSpaces.join()}]');

/// 검색어를 낱말로 나눈다. 낱말끼리는 AND, 각 낱말은 띄어쓰기를 무시하고 찾는다.
/// 그래서 '이처럼사랑' 과 '이처럼 사랑' 이 둘 다 '이처럼 사랑하사' 에 걸린다.
List<String> bibleSearchTerms(String query) =>
    query.split(_ignoredSpace).where((t) => t.isNotEmpty).toList();

/// 검색할 만한 길이인가 (공백 뺀 글자 2개 이상). 한 글자는 결과가 너무 많다.
bool isSearchableBibleQuery(String query) =>
    query.replaceAll(_ignoredSpace, '').length >= 2;

/// [text] 에서 [terms] 가 걸린 자리(원문 기준 [시작, 끝)). 강조 표시용.
///
/// 띄어쓰기를 무시하고 찾으므로 공백을 뺀 문자열에서 찾은 뒤 원문 위치로 되돌린다.
/// 겹치거나 맞닿은 자리는 하나로 합친다. 영문은 대소문자를 가리지 않는다 (SQLite LIKE 와 같게).
List<(int, int)> bibleMatchRanges(String text, List<String> terms) {
  final compact = StringBuffer();
  final originalIndex = <int>[];
  for (var i = 0; i < text.length; i++) {
    if (_ignoredSpace.hasMatch(text[i])) continue;
    final lower = text[i].toLowerCase();
    // 소문자로 바꾸며 길이가 달라지는 글자(드묾)는 그대로 둔다 — 원문 위치가 어긋나지 않게.
    compact.write(lower.length == 1 ? lower : text[i]);
    originalIndex.add(i);
  }
  final haystack = compact.toString();

  final ranges = <(int, int)>[];
  for (final term in terms) {
    final needle = term.toLowerCase();
    if (needle.isEmpty) continue;
    var from = 0;
    while (true) {
      final at = haystack.indexOf(needle, from);
      if (at < 0) break;
      final end = at + needle.length;
      ranges.add((originalIndex[at], originalIndex[end - 1] + 1));
      from = end;
    }
  }
  if (ranges.isEmpty) return const [];

  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[ranges.first];
  for (final range in ranges.skip(1)) {
    final last = merged.last;
    if (range.$1 <= last.$2) {
      merged[merged.length - 1] = (
        last.$1,
        range.$2 > last.$2 ? range.$2 : last.$2,
      );
    } else {
      merged.add(range);
    }
  }
  return merged;
}

/// 고른 절을 슬라이드 페이지로 나눈다.
///
/// 페이지 하나는 한 책·한 장 안에서만 만든다 (참조가 '요 3:16-17' 처럼 한 장을 가리키므로).
/// (책, 장) 묶음은 [verses] 에서 처음 나온 순서, 묶음 안은 절 번호 순서.
/// 장절 검색은 묶음이 늘 하나라 예전과 결과가 같다.
List<List<BibleVerse>> bibleVersePages(List<BibleVerse> verses, int perPage) {
  final groups = <(String, int), List<BibleVerse>>{};
  for (final v in verses) {
    groups.putIfAbsent((v.bookName, v.chapter), () => []).add(v);
  }
  final pages = <List<BibleVerse>>[];
  for (final group in groups.values) {
    group.sort((a, b) => a.verse.compareTo(b.verse));
    for (var i = 0; i < group.length; i += perPage) {
      final end = i + perPage > group.length ? group.length : i + perPage;
      pages.add(group.sublist(i, end));
    }
  }
  return pages;
}

/// 다른 역본(보조·추가 역본) 본문을 [page] 의 절 순서대로 `절. 본문` 줄로 잇는다.
/// 그 역본에 없는 절은 뺀다. [texts] 가 null(역본을 안 골랐거나 못 찾음)이면 빈 문자열.
String versesText(List<BibleVerse> page, Map<int, String>? texts) =>
    verseNumbersText([for (final v in page) v.verse], texts);

/// [versesText] 를 절 번호만으로. 이미 담아 둔 성경 항목에 역본을 다시 입힐 때 쓴다.
String verseNumbersText(List<int> verses, Map<int, String>? texts) {
  if (texts == null) return '';
  return verses
      .where(texts.containsKey)
      .map((v) => '$v. ${texts[v]}')
      .join('\n');
}

/// 성경 항목 참조(`역본 책 장:절`)를 푼 값.
typedef BibleReference = ({
  String version,
  String book,
  int chapter,
  List<int> verses,
});

/// 담을 때 만든 참조 문자열(`개역개정 요한복음 3:16-18`, `KJV 1 John 4:9,11`)을 다시 푼다.
/// 역본 이름에 공백이 있을 수 있어 [versions] 중 앞에 맞는 가장 긴 이름을 역본으로 본다.
/// 책 이름은 그 뒤부터 마지막 `장:절` 앞까지(`1 John`·`Song of Songs` 처럼 공백이 있어도 된다).
/// 모양이 다르거나 아는 역본이 아니면 null.
BibleReference? parseBibleReference(String reference, List<String> versions) {
  final sorted = [...versions]..sort((a, b) => b.length - a.length);
  final version = sorted
      .where((v) => v.isNotEmpty && reference.startsWith('$v '))
      .firstOrNull;
  if (version == null) return null;
  final rest = reference.substring(version.length + 1);
  final match = RegExp(r'^(.+) (\d+):([\d,-]+)$').firstMatch(rest);
  if (match == null) return null;
  final verseStr = match.group(3)!;
  final List<int> verses;
  final range = RegExp(r'^(\d+)-(\d+)$').firstMatch(verseStr);
  if (range != null) {
    final from = int.parse(range.group(1)!);
    final to = int.parse(range.group(2)!);
    if (to < from) return null;
    verses = [for (var v = from; v <= to; v++) v];
  } else {
    final parts = verseStr.split(',').map(int.tryParse).toList();
    if (parts.any((v) => v == null)) return null;
    verses = parts.cast<int>();
  }
  return (
    version: version,
    book: match.group(1)!,
    chapter: int.parse(match.group(2)!),
    verses: verses,
  );
}
