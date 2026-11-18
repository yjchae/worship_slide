import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/presentation/conti_group_widgets.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_group.dart';

void main() {
  test('같은 이름이 이어진 것만 한 구간, 떨어진 같은 이름은 별개', () {
    final s = slideGroupSections(['a', 'a', null, 'a', 'b', 'b']);
    expect(s, [
      const SlideGroupSection('a', 0, 2),
      const SlideGroupSection(null, 2, 1),
      const SlideGroupSection('a', 3, 1),
      const SlideGroupSection('b', 4, 2),
    ]);
  });

  test('빈 목록은 구간 없음', () => expect(slideGroupSections([]), isEmpty));

  test('5열 6장 = 5+1 줄, 다음 그룹은 새 줄', () {
    final s = slideGroupSections(['a', 'a', 'a', 'a', 'a', 'a', 'b']);
    expect(sectionRows(s[0], 5), 2);
    expect(sectionRows(s[1], 5), 1);
    // 칸 높이 100, 간격 8: a 머리 28 → 0번 가운데 78, 5번(둘째 줄) 가운데 186
    double y(int i) => sectionedCenterY(s, i, cols: 5, cellH: 100, spacing: 8);
    expect(y(0), 28 + 50);
    expect(y(4), y(0));
    expect(y(5), 28 + 108 + 50);
    // b: a 끝(28+208=236) + 간격 12 + 머리 28 + 가운데 50
    expect(y(6), 236 + 12 + 28 + 50);
  });

  test('그룹 없는 구간은 머리줄 없이 간격만', () {
    final s = slideGroupSections([null, 'a']);
    expect(
      sectionedCenterY(s, 1, cols: 3, cellH: 10, spacing: 2),
      10 + 12 + 28 + 5,
    );
  });

  test('번호 범위 오류 문구', () {
    expect(groupRangeError(1, 3, 12), isNull);
    expect(groupRangeError(0, 3, 12), '1~12 사이 번호를 넣어 주세요.');
    expect(groupRangeError(1, 13, 12), '1~12 사이 번호를 넣어 주세요.');
    expect(groupRangeError(null, 3, 12), '1~12 사이 번호를 넣어 주세요.');
    expect(groupRangeError(4, 3, 12), '시작 번호는 끝 번호보다 클 수 없습니다.');
  });
}
