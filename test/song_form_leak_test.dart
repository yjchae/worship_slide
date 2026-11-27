import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/python_bridge.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/page_format.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/song_form.dart';
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

/// 송폼은 싱어·발표자 화면 전용이다. 관객 화면·PPTX 로 새지 않는다.
void main() {
  final song = PraiseSong(
    id: 1,
    fileName: 'grace.pptx',
    title: '주 은혜',
    lyrics: '주 은혜\n\n놀라워',
    englishLyrics: 'grace\n\namazing',
    songForm: SongForm([
      (key: pageKey('주 은혜') ?? '', labels: labelsFromText('V1,PC')),
      (key: pageKey('놀라워') ?? '', labels: labelsFromText('=직접 라벨')),
    ]),
  );

  bool leaks(String json) =>
      json.contains('song_form') ||
      json.contains('"form"') ||
      json.contains('V1') ||
      json.contains('PC') ||
      json.contains('직접 라벨');

  test('관객 페이지(SlidePageData) JSON 에 송폼이 없다', () {
    final pairs = song.pairedPages;
    expect(pairs.first.form, 'V1,PC'); // 라벨은 있다 — 그래도 안 나간다.
    for (var j = 0; j < pairs.length; j++) {
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
    }
  });

  test('PPTX payload 에 송폼 키·라벨이 없다', () {
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
    expect(leaks(jsonEncode(songs)), isFalse);
  });
}
