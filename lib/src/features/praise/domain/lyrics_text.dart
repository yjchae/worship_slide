/// 가사 글 공통 규칙(화면·도메인 공용). Flutter 를 쓰지 않는다.
library;

/// 페이지 구분 = 빈 줄(공백·탭만 있는 줄 포함).
final lyricsPageBreak = RegExp(r'\n[ \t]*\n');

// 편집 텍스트 → 저장 형식 정규화.
// 규칙: 빈 줄 1개(\n\n) = 페이지 구분, 빈 줄 N개 = 빈 페이지 N-1장.
// ###, ==== 은 명시적 페이지 구분자로 허용.
String normalizeEditableLyrics(String raw) {
  var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // ###, ==== → \n\n (주변 줄바꿈 포함 소비)
  text = text.replaceAll(RegExp(r'\n?[ \t]*(###|====)[ \t]*\n?'), '\n\n');
  // 분리 → 각 페이지 trim → 후행 빈 페이지 제거 → 재결합
  final pages = text.split(lyricsPageBreak).map((p) => p.trim()).toList();
  while (pages.isNotEmpty && pages.last.isEmpty) {
    pages.removeLast();
  }
  return pages.join('\n\n');
}
