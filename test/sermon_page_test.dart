import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/slide_background.dart';

void main() {
  const global = ExportStyle(
    fontSize: 30,
    bibleFontSize: 30,
    backgroundColor: Color(0xFF1B1B1B),
    textColor: Colors.white,
    bibleTextColor: Colors.white,
    textPosition: VerticalTextPosition.bottom,
    bibleTextPosition: VerticalTextPosition.middle,
    lyricsTextAlign: HorizontalPosition.center,
    bibleTextAlign: HorizontalPosition.center,
    includeEnglishLyrics: true,
    englishTextColor: Color(0xFFFFF176),
    showSongTitle: false,
    showBibleTitle: false,
    titleFontSize: 14,
    bibleTitleFontSize: 14,
    titleTextColor: Colors.white,
    bibleTitleTextColor: Colors.white,
    titleHorizontalPosition: HorizontalPosition.right,
    titleVerticalPosition: VerticalTextPosition.bottom,
    bibleTitleHorizontalPosition: HorizontalPosition.right,
    bibleTitleVerticalPosition: VerticalTextPosition.bottom,
  );

  test('설교 제목 디자인은 저장 후에도 그대로이고 그 항목 글꼴·크기·색만 바꾼다', () {
    final design = SlideBackground.sermonDefault(global).copyWith(
      fontFamily: 'NanumMyeongjo',
      fontSize: 64,
      textColor: const Color(0xFFFFD700),
    );
    final restored = SlideBackground.decode(SlideBackground.encode(design));
    expect(restored, design);
    expect(restored!.isSermon, isTrue);

    final style = global.withBackground(restored);
    expect(style.fontFamily, 'NanumMyeongjo');
    expect(style.fontSize, 64);
    expect(style.textColor, const Color(0xFFFFD700));
    expect(style.textPosition, VerticalTextPosition.middle);
    expect(style.bibleFontSize, 30); // 성경 키는 그대로

    // 부제: 따로 정한 크기·색, 보조 언어 스위치를 꺼도 보인다.
    final withSub = global
        .copyWith(includeEnglishLyrics: false)
        .withBackground(
          restored.copyWith(
            subFontSize: 36,
            subTextColor: const Color(0xFFAABBCC),
          ),
        );
    expect(withSub.effectiveEnglishFontSize, 36);
    expect(withSub.englishTextColor, const Color(0xFFAABBCC));
    expect(withSub.includeEnglishLyrics, isTrue);

    // 글꼴 값이 없는 예전 배경(헌금송 등)은 전역 글꼴을 그대로 쓴다.
    final plain = global.withBackground(
      const SlideBackground(color: Color(0xFF123456)),
    );
    expect(plain.fontFamily, global.fontFamily);
    expect(plain.fontSize, 30);
    expect(plain.textColor, Colors.white);
    expect(plain.effectiveEnglishFontSize, 24); // 예전처럼 본문의 0.8 배
    expect(plain.includeEnglishLyrics, isTrue);
    expect(
      global
          .copyWith(includeEnglishLyrics: false)
          .withBackground(const SlideBackground(color: Color(0xFF123456)))
          .includeEnglishLyrics,
      isFalse,
    );
  });

  test('설교 글자 기본값: 크기·위치만 되돌리고 배경은 둔다, 색은 고를 수 있다', () {
    final custom = SlideBackground.sermonDefault(global).copyWith(
      color: const Color(0xFF112233),
      fontSize: 90,
      subFontSize: 50,
      textColor: const Color(0xFFFF0000),
      lyricsPosition: VerticalTextPosition.top,
    );
    final keepColors = custom.withSermonDefaultText(
      global,
      includeColors: false,
    );
    expect(keepColors.fontSize, 60);
    expect(keepColors.subFontSize, 34);
    expect(keepColors.lyricsPosition, VerticalTextPosition.middle);
    expect(keepColors.textColor, const Color(0xFFFF0000));
    expect(keepColors.color, const Color(0xFF112233));
    expect(custom.withSermonDefaultText(global).textColor, global.textColor);
  });
}
