/// 발표 보기 썸네일 클릭의 고르기 규칙(순수 함수). 수정키는 누른 순간의 값을 받는다.
/// Shift = 범위, toggle(⌘/Ctrl) = 하나씩, 둘 다 아니면 그 하나만.
({Set<int> marked, int? anchor}) applyThumbSelect({
  required Set<int> marked,
  required int? anchor,
  required int currentIndex,
  required int i,
  required bool shift,
  required bool toggle,
}) {
  final next = {...marked};
  if (shift) {
    final from = anchor ?? currentIndex;
    final (a, b) = from <= i ? (from, i) : (i, from);
    next.addAll([for (var k = a; k <= b; k++) k]);
    return (marked: next, anchor: anchor);
  }
  if (toggle) {
    if (!next.remove(i)) next.add(i);
    return (marked: next, anchor: i);
  }
  return (marked: {i}, anchor: i);
}
