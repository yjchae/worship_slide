import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/python_bridge.dart';
import 'package:worship_slides/src/features/praise/data/worship_conti_repository.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/page_format.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/slide_background.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';

const _style = ExportStyle(
  fontSize: 40,
  bibleFontSize: 30,
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
  titleTextColor: Colors.white,
  bibleTitleTextColor: Colors.white,
  titleHorizontalPosition: HorizontalPosition.right,
  titleVerticalPosition: VerticalTextPosition.bottom,
  bibleTitleHorizontalPosition: HorizontalPosition.right,
  bibleTitleVerticalPosition: VerticalTextPosition.bottom,
);

const _red = Color(0xFFFF0000);

PageFormat _sample() => PageFormat({
  pageKey('후렴')!: PageEntry(
    main: PageTextFormat(color: _red, scale: 1.2),
    sub: PageTextFormat(scale: 0.9),
  ),
});

void main() {
  setUpAll(sqfliteFfiInit);

  test('JSON 왕복·clamp·빈 서식 버림', () {
    final f = _sample();
    expect(PageFormat.parse(PageFormat.encode(f)), f);
    expect(PageTextFormat(scale: 9).scale, kMaxPageScale);
    expect(PageTextFormat(scale: 0.1).scale, kMinPageScale);
    expect(PageFormat.encode(const PageFormat({})), isNull);
    expect(PageFormat.encode(null), isNull);
    final json = jsonDecode(PageFormat.encode(f)!) as Map;
    expect(json['v'], 1);
    final entry = (json['pages'] as Map).values.single as Map;
    expect(entry['main'], {'c': '#FF0000', 's': 1.2});
    // 서식이 빈 항목·모르는 키는 무시.
    final k = pageKey('a')!;
    final parsed = PageFormat.parse(
      jsonEncode({
        'v': 1,
        'pages': {
          k: {
            'main': {'s': 50, 'runs': []},
            'x': 1,
          },
          'empty': {'main': {}},
        },
      }),
    )!;
    expect(parsed.pages.keys, [k]);
    expect(parsed.pages[k]!.main!.scale, kMaxPageScale);
  });

  test('깨진 입력·모르는 버전은 서식 없음(예외 없음)', () {
    for (final bad in <Object?>[
      null,
      '',
      'not json',
      '[]',
      '{"v":2,"pages":{"a":{"main":{"s":1.2}}}}',
      '{"v":1}',
      '{"v":1,"pages":[]}',
      '{"v":1,"pages":{"a":5}}',
      '{"v":1,"pages":{"a":{"main":{"c":"zz","s":"x"}}}}',
      42,
    ]) {
      expect(PageFormat.parse(bad), isNull, reason: '$bad');
    }
  });

  test('pageKey: 공백 무시·비면 null·pruneTo·withEntry', () {
    expect(pageKey('  '), isNull);
    expect(pageKey(' 후렴 '), pageKey('후렴'));
    expect(pageKey('후렴'), isNot(pageKey('1절')));
    final f = _sample().withEntry(
      pageKey('1절')!,
      const PageEntry(extra: null, main: null),
    );
    expect(f.pages.length, 1); // 빈 서식은 넣지 않는다
    expect(f.pruneTo({pageKey('후렴')!}).pages.length, 1);
    expect(f.pruneTo({}).isEmpty, isTrue);
    expect(f.withEntry(pageKey('후렴')!, null).isEmpty, isTrue);
  });

  test('withPageFormat: 찬양은 text_*, 성경은 bible_* 만 덮는다', () {
    final e = PageEntry(
      main: PageTextFormat(color: _red, scale: 1.5),
      sub: PageTextFormat(color: Colors.blue, scale: 0.5),
      extra: PageTextFormat(color: Colors.green),
    );
    final s = _style.withPageFormat(e, isBible: false);
    expect(s.textColor, _red);
    expect(s.fontSize, 60);
    expect(s.bibleTextColor, Colors.white);
    expect(s.bibleFontSize, 30);
    expect(s.englishTextColor, Colors.blue);
    expect(s.subFontSizeFor(isBible: false), 40 * 0.8 * 0.5);
    expect(s.extraTextColor, Colors.green);
    // 추가 보조 크기는 본문 서식과 상관없이 전역 그대로.
    expect(
      s.extraFontSizeFor(isBible: false),
      closeTo(_style.extraFontSizeFor(isBible: false), 1e-9),
    );
    final b = _style.withPageFormat(e, isBible: true);
    expect(b.bibleTextColor, _red);
    expect(b.bibleFontSize, 45);
    expect(b.textColor, Colors.white);
    expect(b.fontSize, 40);
    expect(_style.withPageFormat(null, isBible: false), same(_style));
    // 색만 바꾸면 크기 키는 안 생긴다.
    final c = _style.withPageFormat(
      PageEntry(sub: PageTextFormat(color: _red)),
      isBible: false,
    );
    expect(c.englishFontSize, isNull);
  });

  test('pageStylesFor: 페이지 순서·서식 없는 페이지는 null·전혀 없으면 null', () {
    const song = PraiseSong(
      id: 1,
      fileName: 'a.pptx',
      title: 't',
      lyrics: '1절\n\n후렴\n\n3절',
      englishLyrics: '',
    );
    final item = SongStagingItem(song);
    final styles = pageStylesFor(item, _sample(), _style)!;
    expect(styles.length, 3);
    expect(styles[0], isNull);
    expect(styles[2], isNull);
    expect(styles[1]!['text_color'], '#FF0000');
    expect(styles[1]!['font_size'], 48);
    expect(styles[1]!.containsKey('bible_font_size'), isFalse);
    expect(pageStylesFor(item, null, _style), isNull);
    expect(
      pageStylesFor(
        item,
        PageFormat({pageKey('없는 글')!: _sample().pages.values.first}),
        _style,
      ),
      isNull,
    );
    // 성경: 빈 줄로 나눈 페이지, bible_* 키.
    final bible = BibleStagingItem(reference: 'r', text: 'a\n\n후렴');
    final b = pageStylesFor(bible, _sample(), _style)!;
    expect(b[0], isNull);
    expect(b[1]!['bible_text_color'], '#FF0000');
    expect(b[1]!['bible_font_size'], 36);
    expect(livePageKeys(bible), {pageKey('a'), pageKey('후렴')});
  });

  test('exportPayload: page_styles 는 서식이 있을 때만 실린다', () {
    final item = BibleStagingItem(reference: 'r', text: '후렴');
    List<({StagingItem item, SlideBackground? background, bool noSpacer})>
    items() => [(item: item, background: null, noSpacer: false)];
    Map first(String payload) =>
        ((jsonDecode(payload) as Map)['songs'] as List).first as Map;
    final plain = PythonBridge.exportPayload(
      outputPath: 'o',
      stagingItems: items(),
      style: _style,
    );
    expect(first(plain).containsKey('page_styles'), isFalse);
    final withFmt = PythonBridge.exportPayload(
      outputPath: 'o',
      stagingItems: items(),
      pageFormats: [_sample()],
      style: _style,
    );
    expect(first(withFmt)['page_styles'], isNotNull);
  });

  group('저장·불러오기·.wsconti', () {
    Future<Database> freshDb() async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(db.close);
      await createPraiseSchema(db);
      return db;
    }

    WorshipContiRepository repoOn(Database db) => WorshipContiRepository(
      database: PraiseDatabase.forTesting(db),
      supportDirectory: () async => Directory.systemTemp,
    );

    List<({int uid, StagingItem item})> items() => [
      (uid: 1, item: BibleStagingItem(reference: '요 3:16', text: '후렴')),
      (uid: 2, item: BibleStagingItem(reference: '요 3:17', text: 'b')),
    ];

    test('저장·덮어쓰기·불러오기, 깨진 값은 서식 없음', () async {
      final db = await freshDb();
      final repo = repoOn(db);
      final id = await repo.saveConti(
        'c',
        items(),
        pageFormats: {1: _sample()},
      );
      var loaded = await repo.loadConti(id, 10);
      expect(loaded.pageFormats, {loaded.items[0].uid: _sample()});

      final uid = (await repo.listContis()).single.uid;
      await repo.saveConti('c', items(), overwriteUid: uid);
      loaded = await repo.loadConti(id, 10);
      expect(loaded.pageFormats, isEmpty);

      await db.update('worship_conti_items', {'page_format': '{깨짐'});
      expect((await repo.loadConti(id, 10)).pageFormats, isEmpty);
    });

    test('.wsconti 왕복과 옛 파일(키 없음)·깨진 값', () async {
      final tmp = await Directory.systemTemp.createTemp('page_format');
      addTearDown(() => tmp.delete(recursive: true));
      final src = repoOn(await freshDb());
      final id = await src.saveConti('c', items(), pageFormats: {2: _sample()});
      final file = p.join(tmp.path, 'o.wsconti');
      await src.exportContiFile(id, file);

      final dst = repoOn(await freshDb());
      final newId = await dst.importContiFile(
        file,
        filesDir: Directory(p.join(tmp.path, 'imp')),
      );
      final loaded = await dst.loadConti(newId, 10);
      expect(loaded.pageFormats, {loaded.items[1].uid: _sample()});

      // 남이 만든 파일: 깨진 값은 NULL, 키가 없으면 서식 없음.
      final json = jsonDecode(File(file).readAsStringSync()) as Map;
      final its = json['items'] as List;
      (its[0] as Map)['page_format'] = '{깨짐';
      (its[1] as Map).remove('page_format');
      final f2 = p.join(tmp.path, 'p.wsconti');
      File(f2).writeAsStringSync(jsonEncode(json));
      final id2 = await dst.importContiFile(
        f2,
        filesDir: Directory(p.join(tmp.path, 'imp2')),
      );
      expect((await dst.loadConti(id2, 10)).pageFormats, isEmpty);
    });

    test('칸 없는 옛 DB 를 열면 멱등하게 추가', () async {
      final db = await freshDb();
      await db.execute(
        'ALTER TABLE worship_conti_items DROP COLUMN page_format',
      );
      await ensurePageFormatColumn(db);
      await ensurePageFormatColumn(db);
      final cols = await db.rawQuery('PRAGMA table_info(worship_conti_items)');
      expect(cols.any((c) => c['name'] == 'page_format'), isTrue);
    });
  });
}
