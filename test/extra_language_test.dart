import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/bible/domain/bible_text_search.dart';
import 'package:worship_slides/src/features/bible/domain/bible_verse.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/worship_conti_repository.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';
import 'package:worship_slides/src/features/praise/presentation/praise_home_page.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_page_data.dart';

/// 추가 보조 언어(관객 화면 세 번째 줄): 페이지 짝짓기, 나누기·복사, 콘티 저장(DB version 18),
/// .wsconti 왕복, 스타일 저장값.
void main() {
  setUpAll(sqfliteFfiInit);

  const song = PraiseSong(
    id: 1,
    fileName: 'love.pptx',
    title: '주님의 사랑',
    lyrics: '1절\n\n2절\n\n3절',
    englishLyrics: 'verse 1\n\nverse 2\n\nverse 3',
    extraLyrics: 'verso 1\n\nverso 2',
  );

  group('페이지', () {
    test('세 언어를 페이지별로 짝짓고 모자란 칸은 빈 문자열', () {
      expect(song.pairedPages, [
        (korean: '1절', english: 'verse 1', extra: 'verso 1'),
        (korean: '2절', english: 'verse 2', extra: 'verso 2'),
        (korean: '3절', english: 'verse 3', extra: ''),
      ]);
      expect(song.extraPages, ['verso 1', 'verso 2', '']);
    });

    test('추가 보조만 더 길어도 그 페이지가 생긴다', () {
      const longer = PraiseSong(
        id: 1,
        fileName: '',
        title: '곡',
        lyrics: 'A',
        englishLyrics: '',
        extraLyrics: 'x\n\ny',
      );
      expect(longer.pairedPages.length, 2);
      expect(longer.pairedPages[1], (korean: '', english: '', extra: 'y'));
    });

    test('끝에 세 칸 모두 빈 페이지는 뗀다', () {
      const trailing = PraiseSong(
        id: 1,
        fileName: '',
        title: '곡',
        lyrics: 'A\n\n',
        englishLyrics: '',
        extraLyrics: '',
      );
      expect(trailing.pairedPages.length, 1);
    });

    test('copyWith 는 바꾸지 않은 추가 보조 가사를 남긴다', () {
      final edited = song.copyWith(lyrics: '새 1절');
      expect(edited.extraLyrics, song.extraLyrics);
      expect(edited.id, song.id);
      expect(edited.fileName, song.fileName);
    });

    test('곡 일부 페이지만 담아도 추가 보조 가사가 따라간다', () {
      final result = itemsFromPages(SongStagingItem(song), [1, 2]);
      final picked = (result.single.item as SongStagingItem).song;
      expect(picked.pages, ['2절', '3절']);
      expect(picked.extraPages, ['verso 2', '']);
    });

    test('추가 보조만 있는 끝 페이지는 빈 페이지로 떼지 않는다', () {
      const extraOnly = PraiseSong(
        id: 1,
        fileName: '',
        title: '곡',
        lyrics: 'A',
        englishLyrics: '',
        extraLyrics: 'x\n\ny',
      );
      final result = itemsFromPages(SongStagingItem(extraOnly), [1]);
      expect(result.single.item, isA<SongStagingItem>());
    });
  });

  group('콘티 저장 (DB version 18)', () {
    Future<WorshipContiRepository> freshRepository() async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(db.close);
      await createPraiseSchema(db);
      return WorshipContiRepository(
        database: PraiseDatabase.forTesting(db),
        supportDirectory: () async => Directory.systemTemp,
      );
    }

    final items = <({int uid, StagingItem item})>[
      (uid: 1, item: SongStagingItem(song)),
      (
        uid: 2,
        item: BibleStagingItem(
          reference: '요한복음 3:16',
          text: '16. 하나님이',
          subText: '16. For God',
          extraText: '16. Porque',
        ),
      ),
      (
        uid: 3,
        item: const BlankStagingItem(
          mainText: '환영합니다',
          englishText: 'Welcome',
          extraText: 'Bienvenidos',
        ),
      ),
    ];

    void expectExtras(List<({int uid, StagingItem item})> loaded) {
      final loadedSong = (loaded[0].item as SongStagingItem).song;
      expect(loadedSong.extraLyrics, song.extraLyrics);
      expect((loaded[1].item as BibleStagingItem).extraText, '16. Porque');
      expect((loaded[2].item as BlankStagingItem).extraText, 'Bienvenidos');
    }

    test('곡·성경·빈 페이지의 추가 보조가 저장 → 불러오기를 왕복한다', () async {
      final repository = await freshRepository();
      final contiId = await repository.saveConti('주일 예배', items);
      expectExtras((await repository.loadConti(contiId, 100)).items);
    });

    test('.wsconti 로 다른 PC 에 옮겨도 남는다', () async {
      final tmp = await Directory.systemTemp.createTemp('extra_language_test');
      addTearDown(() => tmp.delete(recursive: true));
      final source = await freshRepository();
      final contiId = await source.saveConti('주일 예배', items);
      final file = p.join(tmp.path, 'out.wsconti');
      await source.exportContiFile(contiId, file);

      final target = await freshRepository();
      final importedId = await target.importContiFile(
        file,
        filesDir: Directory(p.join(tmp.path, 'imported')),
      );
      expectExtras((await target.loadConti(importedId, 100)).items);
    });

    test('추가 보조 칸이 없던 예전 콘티는 빈 칸으로 열린다', () async {
      final repository = await freshRepository();
      final contiId = await repository.saveConti('예전', [
        (uid: 1, item: SongStagingItem(song.copyWith(extraLyrics: ''))),
      ]);
      final loaded = (await repository.loadConti(contiId, 100)).items;
      expect((loaded.single.item as SongStagingItem).song.extraLyrics, '');
    });

    test('version 17 DB 를 올리면 추가 보조 칸이 생긴다', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await createPraiseSchema(db);
      const columns = [
        'song_extra_lyrics',
        'bible_extra_text',
        'blank_extra_text',
      ];
      // version 17 모양으로 되돌린다.
      for (final column in columns) {
        await db.execute('ALTER TABLE worship_conti_items DROP COLUMN $column');
      }

      await upgradePraiseSchema(db, 17);

      final names = {
        for (final c in await db.rawQuery(
          'PRAGMA table_info(worship_conti_items)',
        ))
          c['name'] as String,
      };
      expect(names, containsAll(columns));
      expect(PraiseDatabase.schemaVersion, 18);
    });
  });

  group('성경 추가 역본', () {
    BibleVerse verse(int number) => BibleVerse(
      id: number,
      bookName: '요한복음',
      chapter: 3,
      verse: number,
      text: '본문 $number',
    );

    test('역본 본문을 절 순서대로 잇고 없는 절은 뺀다', () {
      expect(
        versesText(
          [verse(16), verse(17), verse(18)],
          {16: 'Porque', 18: 'El que'},
        ),
        '16. Porque\n18. El que',
      );
    });

    test('역본을 안 골랐으면 빈 문자열', () {
      expect(versesText([verse(16)], null), '');
    });
  });

  group('스타일', () {
    ExportStyle baseStyle() =>
        ExportStyle.fromJson({'font_size': 30, 'bible_font_size': 20});

    test('예전 설정(새 키 없음)은 추가 보조 없음 + 기본 비율', () {
      final style = baseStyle();
      expect(style.extraLanguage, '');
      expect(style.bibleExtraVersion, '');
      expect(style.includeExtraLyrics, isTrue);
      expect(style.subFontRatio, kDefaultSubFontRatio);
      expect(style.extraFontRatio, kDefaultExtraFontRatio);
      // 보조 크기는 예전 규칙(본문 × 0.8)과 같다.
      expect(style.subFontSizeFor(isBible: false), 24);
    });

    test('JSON 왕복', () {
      final style = baseStyle().copyWith(
        extraLanguage: '스페인어',
        bibleExtraVersion: 'RVR1960',
        includeExtraLyrics: false,
        extraTextColor: const Color(0xFF00FF00),
        subFontRatio: 0.9,
        extraFontRatio: 0.6,
        bibleSubFontRatio: 0.75,
        bibleExtraFontRatio: 0.5,
      );
      final restored = ExportStyle.fromJson(style.toJson());
      expect(restored.extraLanguage, '스페인어');
      expect(restored.bibleExtraVersion, 'RVR1960');
      expect(restored.includeExtraLyrics, isFalse);
      expect(restored.extraTextColor, const Color(0xFF00FF00));
      expect(restored.subFontRatio, 0.9);
      expect(restored.extraFontRatio, 0.6);
      expect(restored.bibleSubFontRatio, 0.75);
      expect(restored.bibleExtraFontRatio, 0.5);
    });

    test('글자 크기 = 본문 × 비율, 성경은 성경 본문 기준', () {
      final style = baseStyle();
      expect(style.extraFontSizeFor(isBible: false), closeTo(21, 1e-9));
      expect(style.subFontSizeFor(isBible: true), closeTo(16, 1e-9));
      expect(style.extraFontSizeFor(isBible: true), closeTo(14, 1e-9));
    });

    test('설교 부제처럼 정한 보조 크기가 비율보다 이긴다', () {
      final style = baseStyle().copyWith(englishFontSize: 40);
      expect(style.subFontSizeFor(isBible: false), 40);
      expect(style.subFontSizeFor(isBible: true), 40);
    });

    test('비율은 허용 범위로 자른다', () {
      final style = baseStyle().copyWith(extraFontRatio: 9);
      expect(style.extraFontRatio, kMaxFontRatio);
      final loaded = ExportStyle.fromJson({
        ...baseStyle().toJson(),
        'sub_font_ratio': 0.01,
        'extra_font_ratio': 'big',
      });
      expect(loaded.subFontRatio, kMinFontRatio);
      expect(loaded.extraFontRatio, kDefaultExtraFontRatio);
    });

    test('발표 창 페이지 JSON 에 추가 보조 줄이 실린다', () {
      final page = SlidePageData(
        mainText: '1절',
        englishText: 'verse 1',
        extraText: 'verso 1',
        isBible: false,
        pageIndex: 0,
        totalPages: 1,
        style: baseStyle(),
      );
      expect(page.toJson()['extra_text'], 'verso 1');
      expect(SlidePageData.fromJson(page.toJson()).extraText, 'verso 1');
    });
  });
}
