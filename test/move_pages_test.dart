import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/chord_lyrics.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';
import 'package:worship_slides/src/features/praise/presentation/praise_home_page.dart';

// 발표 보기 페이지 나누기·복사·옮기기가 같이 쓰는 "일부 페이지만 담은 항목" 만들기.
void main() {
  SongStagingItem song(List<String> pages) => SongStagingItem(
    PraiseSong(
      id: 1,
      fileName: 'a.pptx',
      title: '곡',
      lyrics: encodePages(pages),
      englishLyrics: '',
    ),
  );

  List<String> pagesOf(StagingItem item) =>
      (item as SongStagingItem).song.pages;

  test('곡 일부 페이지만 담는다', () {
    final result = itemsFromPages(song(['A', 'B', 'C']), [0, 2]);
    expect(result, hasLength(1));
    expect(pagesOf(result.single.item), ['A', 'C']);
    expect(result.single.from, [0, 2]);
  });

  test('끝 빈 페이지는 버리지 않고 빈 페이지 항목으로 뗀다', () {
    final result = itemsFromPages(song(['A', '', 'B']), [0, 1]);
    expect(result, hasLength(2));
    expect(pagesOf(result[0].item), ['A']);
    expect(result[0].from, [0]);
    expect(result[1].item, isA<BlankStagingItem>());
    expect(result[1].from, [1]);
  });

  test('남은 페이지가 빈 페이지뿐이면 0장짜리 곡을 만들지 않는다', () {
    final result = itemsFromPages(song(['', 'A', 'B']), [0]);
    expect(result, hasLength(1));
    expect(result.single.item, isA<BlankStagingItem>());
  });

  test('앞쪽 빈 페이지는 곡 안에 남는다', () {
    final result = itemsFromPages(song(['', 'A', 'B']), [0, 1]);
    expect(result, hasLength(1));
    expect(pagesOf(result.single.item), ['', 'A']);
  });

  test('페이지 전부면 원래 항목 그대로(PPT 원본 경로 유지)', () {
    const ppt = ImageStagingItem(
      sourceName: 'x.pptx',
      imagePaths: ['1.png', '2.png'],
      sourcePath: '/a/x.pptx',
    );
    expect(identical(itemsFromPages(ppt, [0, 1]).single.item, ppt), isTrue);
  });

  test('PPT 일부만 담으면 원본 경로를 뺀다(다시 구우면 페이지가 겹치므로)', () {
    const ppt = ImageStagingItem(
      sourceName: 'x.pptx',
      imagePaths: ['1.png', '2.png', '3.png'],
      sourcePath: '/a/x.pptx',
    );
    final item = itemsFromPages(ppt, [0, 2]).single.item as ImageStagingItem;
    expect(item.imagePaths, ['1.png', '3.png']);
    expect(item.sourcePath, isNull);
  });

  test('같은 이름 항목 번호: 둘 이상일 때만, 빈 제목은 빼고', () {
    expect(sameTitleOrdinals(['A', 'B', 'A', '', 'A']), [
      (n: 1, total: 3),
      null,
      (n: 2, total: 3),
      null,
      (n: 3, total: 3),
    ]);
  });

  group('코드 곡 (§3-7)', () {
    SongStagingItem chordSong() => SongStagingItem(
      const PraiseSong(
        id: 1,
        fileName: 'a.pptx',
        title: '곡',
        lyrics: 'A\n\nB [A]\n\nC\n\n',
        englishLyrics: 'a\n\nb\n\nc',
        chordLyrics: '[G]A\n\nB \\[A]\n\n[D]C\n[E] [F]',
        chordKey: 'G',
        chordTranspose: 3,
        chordAccidental: ChordAccidental.flat,
      ),
    );

    PraiseSong songOf(StagingItem item) => (item as SongStagingItem).song;

    test('나누기·옮기기: 코드가 페이지를 따라가고 조 값은 그대로', () {
      final first = songOf(itemsFromPages(chordSong(), [0, 1]).single.item);
      expect(first.pages, ['A', 'B [A]']);
      expect(first.pairedPages.map((p) => p.chord), ['[G]A', '']);
      expect(first.chordLyrics, '[G]A\n\nB \\[A]');
      expect(first.chordKey, 'G');
      expect(first.chordTranspose, 3);
      expect(first.chordAccidental, ChordAccidental.flat);
      expect(chordsMatchLyrics(first.chordLyrics, first.lyrics), isTrue);

      final last = songOf(itemsFromPages(chordSong(), [2]).single.item);
      expect(last.pairedPages.single.chord, '[D]C\n[E] [F]');
      expect(last.chordTranspose, 3);
    });

    test('코드 없는 페이지만 담으면 코드 없음', () {
      final mid = songOf(itemsFromPages(chordSong(), [1]).single.item);
      expect(mid.chordLyrics, isNull);
      expect(mid.chordKey, 'G');
    });

    test('곡 끝 빈 페이지는 빈 페이지 항목으로 — 그 페이지 코드는 버린다', () {
      final item = SongStagingItem(
        const PraiseSong(
          id: 1,
          fileName: 'a.pptx',
          title: '곡',
          lyrics: 'A\n\n\n\nB',
          englishLyrics: '',
          chordLyrics: '[G]A\n\n[C] [D]\n\n[E]B',
        ),
      );
      final result = itemsFromPages(item, [0, 1]);
      expect(result, hasLength(2));
      expect(songOf(result[0].item).chordLyrics, '[G]A');
      expect(result[1].item, isA<BlankStagingItem>());
    });

    test('가운데 코드만 있는 페이지는 따라간다', () {
      final item = SongStagingItem(
        const PraiseSong(
          id: 1,
          fileName: 'a.pptx',
          title: '곡',
          lyrics: 'A\n\n\n\nB',
          englishLyrics: '',
          chordLyrics: '[G]A\n\n[C] [D]\n\n[E]B',
        ),
      );
      final s = songOf(itemsFromPages(item, [1, 2]).single.item);
      expect(s.pairedPages.map((p) => p.chord), ['[C] [D]', '[E]B']);
      expect(stripChords(s.chordLyrics!), s.lyrics);
    });
  });
}
