import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/presentation/praise_home_page.dart';

/// 원본 PPT 를 다시 구워 장 수가 바뀔 때 지운 페이지·메모가 엉뚱한 페이지로 가지 않는지.
void main() {
  test('장 수가 그대로면 지운 페이지·메모를 건드리지 않는다', () {
    final deleted = {'7:1', '7:2'};
    final notes = {'7:0': '광고 1', '7:5': '여백 메모'};
    final restored = remapReloadedPages(
      uid: 7,
      oldCount: 5,
      newCount: 5,
      deletedKeys: deleted,
      notes: notes,
    );
    expect(restored, isFalse);
    expect(deleted, {'7:1', '7:2'});
    expect(notes, {'7:0': '광고 1', '7:5': '여백 메모'});
  });

  test('장 수가 늘면 여백 메모는 새 끝으로 옮기고 실제 페이지에 붙지 않는다', () {
    final deleted = <String>{};
    final notes = {'7:0': '광고 1', '7:5': '여백 메모'};
    remapReloadedPages(
      uid: 7,
      oldCount: 5,
      newCount: 7,
      deletedKeys: deleted,
      notes: notes,
    );
    expect(notes, {'7:0': '광고 1', '7:7': '여백 메모'});
  });

  test('장 수가 줄면 범위 밖 메모는 버리고 지운 표시는 풀린다', () {
    final deleted = {'7:1', '3:1'};
    final notes = {'7:0': '남음', '7:3': '사라짐', '7:4': '사라짐', '3:4': '다른 항목'};
    final restored = remapReloadedPages(
      uid: 7,
      oldCount: 5,
      newCount: 3,
      deletedKeys: deleted,
      notes: notes,
    );
    expect(restored, isTrue);
    expect(deleted, {'3:1'}, reason: '다른 항목의 표시는 그대로');
    expect(notes, {'7:0': '남음', '3:4': '다른 항목'});
  });

  test('지운 여백 표시도 새 끝으로 따라간다', () {
    final deleted = {'7:5'};
    final restored = remapReloadedPages(
      uid: 7,
      oldCount: 5,
      newCount: 6,
      deletedKeys: deleted,
      notes: {},
    );
    expect(restored, isFalse, reason: '실제 페이지 표시는 없었다');
    expect(deleted, {'7:6'});
  });
}
