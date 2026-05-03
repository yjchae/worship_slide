import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';

void main() {
  test('lyrics are split into pages by ###', () {
    const song = PraiseSong(
      id: 1,
      fileName: 'sample.pptx',
      title: '샘플 찬양',
      lyrics: '첫 페이지 첫 줄\n둘째 줄\n###\n두 번째 페이지',
      englishLyrics: 'first page line one\n###\nsecond page line one',
    );

    expect(song.pages, ['첫 페이지 첫 줄\n둘째 줄', '두 번째 페이지']);
    expect(song.englishPages, ['first page line one', 'second page line one']);
  });

  test('export style serializes presentation options', () {
    const style = ExportStyle(
      fontSize: 32,
      bibleFontSize: 36,
      backgroundColor: Color(0xFF0F4C5C),
      textColor: Colors.white,
      bibleTextColor: Color(0xFFFFF8E1),
      textPosition: VerticalTextPosition.bottom,
      bibleTextPosition: VerticalTextPosition.top,
      lyricsTextAlign: HorizontalPosition.center,
      bibleTextAlign: HorizontalPosition.left,
      includeEnglishLyrics: true,
      englishTextColor: Color(0xFFE3F2FD),
      showSongTitle: false,
      showBibleTitle: true,
      titleFontSize: 14,
      bibleTitleFontSize: 16,
      titleTextColor: Color(0xB3FFFFFF),
      bibleTitleTextColor: Color(0xFFFFFFFF),
      titleHorizontalPosition: HorizontalPosition.right,
      titleVerticalPosition: VerticalTextPosition.bottom,
      bibleTitleHorizontalPosition: HorizontalPosition.center,
      bibleTitleVerticalPosition: VerticalTextPosition.top,
    );

    final json = style.toJson();
    expect(json['font_size'], 32.0);
    expect(json['bible_font_size'], 36.0);
    expect(json['background_color'], '#0F4C5C');
    expect(json['text_color'], '#FFFFFF');
    expect(json['bible_text_color'], '#FFF8E1');
    expect(json['text_position'], 'bottom');
    expect(json['bible_text_position'], 'top');
    expect(json['lyrics_text_align'], 'center');
    expect(json['bible_text_align'], 'left');
    expect(json['include_english_lyrics'], true);
    expect(json['english_text_color'], '#E3F2FD');
    expect(json['show_song_title'], false);
    expect(json['show_bible_title'], true);
    expect(json['bible_title_font_size'], 16.0);
    expect(json['bible_title_text_color'], '#FFFFFF');
    expect(json['bible_title_horizontal_position'], 'center');
    expect(json['bible_title_vertical_position'], 'top');
  });

  test('hex colors parse consistently', () {
    expect(colorToHex(const Color(0xFFFFF8E1)), '#FFF8E1');
    expect(tryParseHexColor('#0f4c5c'), const Color(0xFF0F4C5C));
    expect(tryParseHexColor('FFF8E1'), const Color(0xFFFFF8E1));
    expect(tryParseHexColor('#XYZXYZ'), isNull);
  });
}
