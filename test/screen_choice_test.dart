import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/screen_choice_store.dart';

void main() {
  ScreenInfo s(int i, String name) =>
      ScreenInfo(index: i, name: name, width: 1920, height: 1080, isMain: false);

  test('고른 모니터를 번호·이름으로 찾고, 없으면 자동(-1)', () {
    final screens = [s(0, 'Built-in'), s(1, 'DELL'), s(2, 'DELL')];
    expect(ScreenChoice.resolve(null, screens), -1);
    // 같은 이름 모니터가 둘이어도 고른 번호를 지킨다.
    expect(ScreenChoice.resolve(const ScreenChoice(2, 'DELL'), screens), 2);
    // 번호와 이름이 안 맞으면(연결 순서가 바뀜) 같은 이름이 있어도 자동.
    expect(ScreenChoice.resolve(const ScreenChoice(0, 'DELL'), screens), -1);
    // 빠진 모니터면 자동.
    expect(ScreenChoice.resolve(const ScreenChoice(1, 'LG'), screens), -1);
  });
}
