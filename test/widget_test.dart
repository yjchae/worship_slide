import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/presentation/praise_home_page.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_page_data.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_render_view.dart';

void main() {
  // ── 페이지 파싱 ────────────────────────────────────────────────────────────

  test('빈 줄(\\n\\n)로 페이지를 구분한다', () {
    const song = PraiseSong(
      id: 1,
      fileName: 'sample.pptx',
      title: '샘플 찬양',
      lyrics: '첫 페이지 첫 줄\n둘째 줄\n\n두 번째 페이지',
      englishLyrics: 'first page line one\n\nsecond page line one',
    );

    expect(song.pages, ['첫 페이지 첫 줄\n둘째 줄', '두 번째 페이지']);
    expect(song.englishPages, ['first page line one', 'second page line one']);
  });

  test('앞쪽 빈 페이지(\\n\\n)가 보존된다', () {
    const song = PraiseSong(
      id: 1,
      fileName: 'blank-first.pptx',
      title: '빈 첫 장',
      lyrics: '\n\n첫 가사',
      englishLyrics: '',
    );

    expect(song.pages, ['', '첫 가사']);
    expect(song.englishPages, ['', '']);
  });

  test('앞쪽 빈 페이지 2장이 보존된다', () {
    const song = PraiseSong(
      id: 1,
      fileName: 'two-blank-first.pptx',
      title: '앞 두 장 빈 페이지',
      lyrics: '첫 가사',
      englishLyrics: '\n\n\n\nFirst lyrics',
    );

    expect(song.englishPages, ['', '', 'First lyrics']);
  });

  test('중간 빈 페이지(빈 줄 2개)가 보존된다', () {
    const song = PraiseSong(
      id: 1,
      fileName: 'middle-blank.pptx',
      title: '중간 빈 장',
      lyrics: '첫 가사\n\n\n\n세 번째',
      englishLyrics: '',
    );

    expect(song.pages, ['첫 가사', '', '세 번째']);
  });

  test('후행 빈 페이지는 무시된다', () {
    const song = PraiseSong(
      id: 1,
      fileName: 'trailing-blank.pptx',
      title: '끝 빈 장',
      lyrics: '첫 가사\n\n',
      englishLyrics: '',
    );

    expect(song.pages, ['첫 가사']);
  });

  test('한/영 앞쪽 빈 페이지 인덱스가 맞춰진다', () {
    const song = PraiseSong(
      id: 1,
      fileName: 'english-blank-first.pptx',
      title: '영어 빈 첫 장',
      lyrics: '\n\n첫 가사',
      englishLyrics: '\n\nFirst lyrics',
    );

    expect(song.pages, ['', '첫 가사']);
    expect(song.englishPages, ['', 'First lyrics']);
  });

  // ── normalizeEditableLyrics ───────────────────────────────────────────────

  test('빈 줄이 페이지 구분자로 정규화된다', () {
    expect(normalizeEditableLyrics('1절\n\n2절'), '1절\n\n2절');
    expect(normalizeEditableLyrics('1절\n\n2절\n\n3절'), '1절\n\n2절\n\n3절');
  });

  test('앞쪽 빈 줄이 빈 페이지로 정규화된다', () {
    expect(normalizeEditableLyrics('\n\n첫 가사'), '\n\n첫 가사');
    expect(normalizeEditableLyrics('\n\n\n\n첫 가사'), '\n\n\n\n첫 가사');
  });

  test('빈 줄 3개는 빈 줄 2개와 같다 (홀수 줄바꿈 정규화)', () {
    expect(normalizeEditableLyrics('1절\n\n\n2절'), '1절\n\n2절');
  });

  test('### 구분자도 허용된다 (하위 호환)', () {
    expect(normalizeEditableLyrics('1절###2절'), '1절\n\n2절');
    expect(normalizeEditableLyrics('1절\n###\n2절'), '1절\n\n2절');
    expect(normalizeEditableLyrics('###\n첫 가사'), '\n\n첫 가사');
  });

  test('후행 빈 페이지가 제거된다', () {
    expect(normalizeEditableLyrics('첫 가사\n\n'), '첫 가사');
  });

  // ── lyricsToEditText / encodePages round-trip ─────────────────────────────

  test('lyricsToEditText는 저장값을 그대로 반환한다', () {
    const stored = '1절\n\n2절\n\n3절';
    expect(lyricsToEditText(stored), stored);
  });

  test('encodePages → pairedPages 왕복 변환이 일치한다', () {
    void roundTrip(List<String> pages) {
      final encoded = encodePages(pages);
      final parsed = PraiseSong(
        id: 1,
        fileName: 'test.pptx',
        title: 'test',
        lyrics: encoded,
        englishLyrics: '',
      ).pages;
      final trimmed = [...pages];
      while (trimmed.isNotEmpty && trimmed.last.isEmpty) {
        trimmed.removeLast();
      }
      expect(parsed, trimmed);
    }

    roundTrip(['1절', '2절', '3절']);
    roundTrip(['', '1절']);
    roundTrip(['', '', '1절']);
    roundTrip(['1절', '', '3절']);
  });

  test('normalizeEditableLyrics → pairedPages 왕복 변환이 일치한다', () {
    String rt(String raw) =>
        normalizeEditableLyrics(lyricsToEditText(raw));

    expect(rt('1절\n\n2절\n\n3절'), '1절\n\n2절\n\n3절');
    expect(rt('\n\n첫 가사'), '\n\n첫 가사');
    expect(rt('\n\n\n\n첫 가사'), '\n\n\n\n첫 가사');
    expect(rt('\n\n첫 가사\n\n두 번째'), '\n\n첫 가사\n\n두 번째');
  });

  // ── ExportStyle ───────────────────────────────────────────────────────────

  test('export style serializes presentation options', () {
    const style = ExportStyle(
      fontSize: 32,
      bibleFontSize: 36,
      textBoxTop: 0.8,
      bibleTextBoxTop: 1.1,
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
    expect(json['text_box_top'], 0.8);
    expect(json['bible_text_box_top'], 1.1);
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

  // ── UI ────────────────────────────────────────────────────────────────────

  testWidgets('slide preview tolerates very small layout constraints', (
    tester,
  ) async {
    const style = ExportStyle(
      fontSize: 54,
      bibleFontSize: 54,
      textBoxTop: 0.6,
      bibleTextBoxTop: 0.6,
      backgroundColor: Color(0xFF1B1B1B),
      textColor: Colors.white,
      bibleTextColor: Colors.white,
      textPosition: VerticalTextPosition.middle,
      bibleTextPosition: VerticalTextPosition.middle,
      lyricsTextAlign: HorizontalPosition.center,
      bibleTextAlign: HorizontalPosition.center,
      includeEnglishLyrics: true,
      englishTextColor: Color(0xFFFFF176),
      showSongTitle: false,
      showBibleTitle: false,
      titleFontSize: 14,
      bibleTitleFontSize: 14,
      titleTextColor: Color(0xB3FFFFFF),
      bibleTitleTextColor: Color(0xB3FFFFFF),
      titleHorizontalPosition: HorizontalPosition.right,
      titleVerticalPosition: VerticalTextPosition.bottom,
      bibleTitleHorizontalPosition: HorizontalPosition.right,
      bibleTitleVerticalPosition: VerticalTextPosition.bottom,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 300,
          height: 80,
          child: SlideRenderView(
            data: SlidePageData(
              mainText: '선택한 항목이 여기에 미리보기로 보입니다.',
              englishText: 'Preview text',
              title: null,
              isBible: false,
              pageIndex: 0,
              totalPages: 1,
              style: style,
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  test('split ratio clamp tolerates layouts smaller than both minimums', () {
    final ratio = clampSplitRatioForLayout(
      ratio: 0.5703703703703704,
      available: 180,
      firstMin: 100,
      secondMin: 120,
      minRatioMin: 0.1,
      minRatioMax: 0.8,
      maxRatioMin: 0.2,
      maxRatioMax: 0.9,
    );

    expect(ratio, 0.5703703703703704);
  });
}
