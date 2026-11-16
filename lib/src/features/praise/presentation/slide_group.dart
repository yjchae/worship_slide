/// 발표 보기 '모든 페이지' 격자의 그룹 구간 계산(순수 함수). 화면 코드는 이 값만 따른다.
library;

/// 머리줄(이름 줄) 높이와 구간 사이 간격(px).
const double slideGroupHeaderHeight = 28;
const double slideGroupGap = 12;

/// 같은 그룹 이름이 이어진 슬라이드 구간. [name] 이 null 이면 그룹 없는 구간.
class SlideGroupSection {
  const SlideGroupSection(this.name, this.start, this.count);
  final String? name;
  final int start;
  final int count;
  int get end => start + count; // 끝 번호(포함 안 함)

  @override
  bool operator ==(Object other) =>
      other is SlideGroupSection &&
      other.name == name &&
      other.start == start &&
      other.count == count;

  @override
  int get hashCode => Object.hash(name, start, count);

  @override
  String toString() => '$name[$start+$count]';
}

/// 슬라이드마다의 그룹 이름([groups], null = 없음)을 이어진 구간으로 묶는다.
/// 떨어져 있는 같은 이름은 다른 구간이다.
List<SlideGroupSection> slideGroupSections(List<String?> groups) {
  final out = <SlideGroupSection>[];
  var start = 0;
  for (var i = 1; i <= groups.length; i++) {
    if (i == groups.length || groups[i] != groups[start]) {
      out.add(SlideGroupSection(groups[start], start, i - start));
      start = i;
    }
  }
  return out;
}

/// 구간 앞에 놓이는 머리 영역 높이(간격 + 이름 줄). 첫 구간은 간격이 없다.
double sectionLeadHeight(SlideGroupSection s, {required bool first}) =>
    (first ? 0 : slideGroupGap) + (s.name != null ? slideGroupHeaderHeight : 0);

/// 구간의 줄 수. 구간마다 새 줄에서 시작하므로 열 수로 올림한다(5열 6장 = 2줄).
int sectionRows(SlideGroupSection s, int cols) => (s.count + cols - 1) ~/ cols;

/// [index] 번 슬라이드 칸의 세로 가운데(격자 안쪽 여백 안 기준).
double sectionedCenterY(
  List<SlideGroupSection> sections,
  int index, {
  required int cols,
  required double cellH,
  required double spacing,
}) {
  var y = 0.0;
  for (var k = 0; k < sections.length; k++) {
    final s = sections[k];
    y += sectionLeadHeight(s, first: k == 0);
    final rows = sectionRows(s, cols);
    if (index < s.end) {
      final row = (index - s.start) ~/ cols;
      return y + row * (cellH + spacing) + cellH / 2;
    }
    y += rows * cellH + (rows - 1) * spacing;
  }
  return y;
}
