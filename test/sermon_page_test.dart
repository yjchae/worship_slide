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

    // 글꼴 값이 없는 예전 배경(헌금송 등)은 전역 글꼴을 그대로 쓴다.
    final plain = global.withBackground(
      const SlideBackground(color: Color(0xFF123456)),
    );
    expect(plain.fontFamily, global.fontFamily);
    expect(plain.fontSize, 30);
    expect(plain.textColor, Colors.white);
  });
}
