import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';

void main() {
  test('와이드스크린 표시를 뗀다', () {
    const cases = {
      '(와이드 스크린) 그 나라': '그 나라',
      '(와이드 스크린 )왕이신 나의 하나님': '왕이신 나의 하나님',
      '(와이드스크린)감사해': '감사해',
      '와이드스크린 감사해': '감사해',
      '(와이드 스크림) 주님은 아시네': '주님은 아시네',
      '(와일이드 스크린) 주 임재 안에서': '주 임재 안에서',
      '(와일드스크린 그 사랑 감사해)': '그 사랑 감사해',
      '내 영혼의 그윽히 깊은 데서(와이드).ppt': '내 영혼의 그윽히 깊은 데서',
      '우리하나되어(와이드)': '우리하나되어',
      '(와이드스크린) 그 이름(your name)_ 아침이 밝아 올 때에':
          '그 이름(your name)_ 아침이 밝아 올 때에',
    };
    cases.forEach((input, expected) {
      expect(PraiseSong.cleanDisplayTitle(input), expected, reason: input);
    });
  });

  test('와이드스크린 표시가 없는 제목은 그대로 둔다', () {
    for (final title in ['소원(Onething)', '그 나라', 'Way Maker']) {
      expect(PraiseSong.cleanDisplayTitle(title), title);
    }
  });
}
