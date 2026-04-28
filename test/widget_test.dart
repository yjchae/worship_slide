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
      lyricsTextAlign: HorizontalPosition.center,
      includeEnglishLyrics: true,
      englishTextColor: Color(0xFFE3F2FD),
      showSongTitle: false,
      titleFontSize: 14,
      titleTextColor: Color(0xB3FFFFFF),
      titleHorizontalPosition: HorizontalPosition.right,
      titleVerticalPosition: VerticalTextPosition.bottom,
    );

    final json = style.toJson();
    expect(json['font_size'], 32.0);
    expect(json['background_color'], '#0F4C5C');
    expect(json['text_color'], '#FFFFFF');
    expect(json['text_position'], 'bottom');
    expect(json['lyrics_text_align'], 'center');
    expect(json['include_english_lyrics'], true);
    expect(json['english_text_color'], '#E3F2FD');
    expect(json['show_song_title'], false);
  });
}
