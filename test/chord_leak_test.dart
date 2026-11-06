import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/python_bridge.dart';
import 'package:worship_slides/src/features/praise/domain/chord_lyrics.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_page_data.dart';

const _style = ExportStyle(
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
  showSongTitle: true,
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

/// 코드는 싱어·발표자 화면 전용이다(§0). 관객 화면·통역(B)·PPTX 로 새지 않는다.
void main() {
  const song = PraiseSong(
    id: 1,
    fileName: 'grace.pptx',
    title: '주 은혜',
    lyrics: '주 은혜\n\n놀라워',
    englishLyrics: 'grace\n\namazing',
    chordLyrics: '[G]주 은[D/F#]혜\n\n[Em7]놀라워',
    chordKey: 'G',
    chordTranspose: 2,
    chordAccidental: ChordAccidental.sharp,
  );

  bool leaks(String json) =>
      json.contains('chord') ||
      json.contains('[G]') ||
      json.contains('[Em7]') ||
      json.contains('D/F#') ||
      json.contains('key_label') ||
      json.contains('transpose');

  test('관객 페이지(SlidePageData)·통역(B) JSON 에 코드가 없다', () {
    final pairs = song.pairedPages;
    expect(pairs.first.chord, isNotEmpty); // 코드는 있다 — 그래도 안 나간다.
    for (var j = 0; j < pairs.length; j++) {
      // _allSlides 곡 분기와 같은 재료(원본·보조·추가 보조 글)만 받는다.
      final page = SlidePageData(
        mainText: pairs[j].korean,
        englishText: pairs[j].english,
        extraText: pairs[j].extra,
        title: song.displayTitle,
        isBible: false,
        pageIndex: j,
        totalPages: pairs.length,
        style: _style,
      );
      final json = jsonEncode(page.toJson());
      expect(leaks(json), isFalse, reason: json);
      final b = jsonEncode(page.forB(null).toJson());
      expect(leaks(b), isFalse, reason: b);
    }
  });

  test('PPTX payload 에 코드 키·코드 글이 없다', () {
    final payload = PythonBridge.exportPayload(
      outputPath: '/tmp/out.pptx',
      stagingItems: [
        (item: SongStagingItem(song), background: null, noSpacer: false),
      ],
      style: _style,
    );
    final songs = (jsonDecode(payload) as Map)['songs'] as List;
    final item = songs.single as Map;
    expect(item.keys.toSet(), {
      'type',
      'title',
      'lyrics',
      'english_lyrics',
      'extra_lyrics',
      'background',
    });
    expect(item['lyrics'], '주 은혜\n\n놀라워');
    expect(leaks(jsonEncode(songs)), isFalse);
  });
}
