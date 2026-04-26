import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:praise_lyrics_app/src/features/praise/domain/export_style.dart';
import 'package:praise_lyrics_app/src/features/praise/domain/praise_song.dart';

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
      backgroundColor: Color(0xFF0F4C5C),
      textColor: Colors.white,
      textPosition: VerticalTextPosition.bottom,
      includeEnglishLyrics: true,
      englishTextColor: Color(0xFFE3F2FD),
    );

    expect(style.toJson(), {
      'font_size': 32.0,
      'background_color': '#0F4C5C',
      'text_color': '#FFFFFF',
      'text_position': 'bottom',
      'include_english_lyrics': true,
      'english_text_color': '#E3F2FD',
    });
  });
}
