import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/worship_conti_repository.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/page_element.dart';
import 'package:worship_slides/src/features/praise/domain/slide_background.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';
import 'package:worship_slides/src/features/praise/presentation/page_canvas.dart';
import 'package:worship_slides/src/features/praise/presentation/praise_home_page.dart';

// 편집 페이지 클릭 단계(appear): JSON 왕복·단계 나누기·다시 매기기·단계별 굽기·저장·나눈 조각.
void main() {
  PageTextElement box(String id, int appear, [int disappear = 0]) =>
      PageTextElement(
        id: id,
        rect: const Rect.fromLTWH(0.1, 0.1, 0.3, 0.2),
        text: id,
        appear: appear,
        disappear: disappear,
      );

  test('appear 왕복: 0 이면 키 없음, 틀린 값은 0·상한 30, 그림·글 상자·도형 모두 보존', () {
    const image = PageImageElement(
      id: 'i',
      rect: Rect.fromLTWH(0, 0, 0.5, 0.5),
      path: '/p/a.png',
      appear: 2,
    );
    final shape = PageShapeElement.withText(
      box('s', 3),
      kind: PageShapeKind.ellipse,
    );
    final text = box('t', 1);
    expect(box('z', 0).toJson().containsKey('appear'), isFalse);
    final json = jsonDecode(jsonEncode([image, text, shape]));
    expect(PageElement.listFromJson(json), [image, text, shape]);

    int parse(Object? v) =>
        PageElement.fromJson({...box('x', 0).toJson(), 'appear': v})!.appear;
    expect([parse(-1), parse('x'), parse(31), parse(2.0)], [0, 0, 30, 2]);
  });

  test('{0,1,1,3} → 3장(0 / 0·1·1 / 전부), 다시 매기면 {0,1,1,2}', () {
    final els = [box('a', 0), box('b', 1), box('c', 1), box('d', 3)];
    final steps = pageSteps(els);
    expect(steps.map((s) => s.map((e) => e.id).join()), ['a', 'abc', 'abcd']);
    expect(pageStepCount(els), 3);
    expect(normalizeAppear(els).map((e) => e.appear), [0, 1, 1, 2]);
    // 애니메이션 없으면 그대로 한 장.
    expect(pageSteps([box('a', 0)]), [
      [box('a', 0)],
    ]);
  });

  test('disappear 왕복: 0 이면 키 없음, 틀린 값·appear 이하·상한, 그림·글 상자·도형 모두 보존', () {
    const image = PageImageElement(
      id: 'i',
      rect: Rect.fromLTWH(0, 0, 0.5, 0.5),
      path: '/p/a.png',
      appear: 1,
      disappear: 2,
    );
    final shape = PageShapeElement.withText(
      box('s', 0, 3),
      kind: PageShapeKind.ellipse,
    );
    final text = box('t', 1, 4);
    expect(box('z', 1).toJson().containsKey('disappear'), isFalse);
    expect(text.toJson()['disappear'], 4);
    final json = jsonDecode(jsonEncode([image, text, shape]));
    expect(PageElement.listFromJson(json), [image, text, shape]);
    // 복제(copyWith id)도 이어받는다.
    expect(text.copyWith(id: 'u').disappear, 4);

    int parse(Object? appear, Object? v) => PageElement.fromJson({
      ...box('x', 0).toJson(),
      'appear': appear,
      'disappear': v,
    })!.disappear;
    expect(
      [parse(0, -1), parse(0, 'x'), parse(0, 31), parse(2, 2), parse(3, 1)],
      [0, 0, 30, 0, 0],
    );
    expect(parse(30, 31), 0);
  });

  test('나타남·사라짐 단계: 클릭1 나타남 → 클릭2 사라짐 → 클릭3 다른 요소', () {
    final els = [box('a', 1, 2), box('b', 3), box('c', 0, 2)];
    expect(pageStepCount(els), 4);
    expect(pageSteps(els).map((s) => s.map((e) => e.id).join()), [
      'c',
      'ac',
      '',
      'b',
    ]);
    // 다시 매기기는 appear·disappear 를 합쳐 연속으로, 없음(0)은 그대로.
    expect(
      normalizeAppear([
        box('a', 2, 5),
        box('b', 0, 7),
        box('c', 0),
      ]).map((e) => (e.appear, e.disappear)),
      [(1, 2), (0, 3), (0, 0)],
    );
  });

  test('나눈 조각: 여러 장 편집 페이지를 일부만 떼면 요소를 빼고, 통째면 그대로', () {
    final free = SlideBackground(
      color: Colors.black,
      pageElements: [box('a', 0), box('b', 1)],
    );
    expect(pieceBackground(free, 2, 1)!.isFreePage, isFalse);
    expect(pieceBackground(free, 2, 1)!.color, Colors.black);
    expect(identical(pieceBackground(free, 2, 2), free), isTrue);
    const plain = SlideBackground(color: Colors.black);
    expect(identical(pieceBackground(plain, 3, 1), plain), isTrue);
    expect(pieceBackground(null, 3, 1), isNull);
  });

  test('콘티 저장·불러오기·.wsconti 경로 바꾸기에 장 수·appear 가 남는다', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(db.close);
    await createPraiseSchema(db);
    final repository = WorshipContiRepository(
      database: PraiseDatabase.forTesting(db),
      supportDirectory: () async => Directory.systemTemp,
    );
    final page = SlideBackground(
      color: Colors.black,
      pageElements: [box('a', 0), box('b', 1), box('c', 2)],
    );
    const paths = ['/no/r1.png', '/no/r2.png', '/no/r3.png'];
    final id = await repository.saveConti(
      '단계',
      [
        (
          uid: 1,
          item: const ImageStagingItem(sourceName: '광고', imagePaths: paths),
        ),
      ],
      backgrounds: {1: page},
    );
    final loaded = await repository.loadConti(id, 10);
    expect((loaded.items.single.item as ImageStagingItem).imagePaths, paths);
    expect(
      loaded.backgrounds[loaded.items.single.uid]!.pageElements!.map(
        (e) => e.appear,
      ),
      [0, 1, 2],
    );
    final mapped = WorshipContiRepository.mapBackgroundPaths(
      SlideBackground.encode(page),
      (p) => p,
    );
    expect(SlideBackground.decode(mapped)!.pageElements, page.pageElements);
  });

  test('지운 장이 있는 3단계 페이지를 저장 → 불러오면 2장·요소 없음·메모 그대로(다시 굽기 안 함)', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(db.close);
    await createPraiseSchema(db);
    final repository = WorshipContiRepository(
      database: PraiseDatabase.forTesting(db),
      supportDirectory: () async => Directory.systemTemp,
    );
    final page = SlideBackground(
      color: Colors.black,
      pageElements: [box('a', 0), box('b', 1), box('c', 2)],
    );
    const item = ImageStagingItem(
      sourceName: '광고',
      imagePaths: ['/no/r1.png', '/no/r2.png', '/no/r3.png'],
    );
    final saved = savedBackgrounds([(uid: 1, item: item)], {1: page}, {'1:1'});
    expect(saved[1]!.isFreePage, isFalse);
    expect(saved[1]!.color, Colors.black);
    // 지운 장이 없으면 그대로.
    expect(
      identical(
        savedBackgrounds([(uid: 1, item: item)], {1: page}, {})[1],
        page,
      ),
      isTrue,
    );

    // 저장되는 항목·메모는 _effectiveStagingItems·_effectiveSlideNotes 처럼 지운 장을 빼고 당긴 것.
    // 일반 그림 페이지는 PNG 가 있어야 불러오므로 실제 파일로 둔다.
    final temp = await Directory.systemTemp.createTemp('page_anim_save');
    addTearDown(() => temp.delete(recursive: true));
    final kept = [
      for (final n in ['r1.png', 'r3.png'])
        (File('${temp.path}/$n')..writeAsBytesSync([0])).path,
    ];
    final id = await repository.saveConti(
      '단계',
      [(uid: 1, item: ImageStagingItem(sourceName: '광고', imagePaths: kept))],
      notes: {'1:1': '세 번째 장'},
      backgrounds: saved,
    );
    final loaded = await repository.loadConti(id, 10);
    final uid = loaded.items.single.uid;
    expect((loaded.items.single.item as ImageStagingItem).imagePaths, kept);
    // 요소가 없어 _restoreFreePages 가 3장으로 다시 굽지 않는다.
    expect(loaded.backgrounds[uid]!.isFreePage, isFalse);
    expect(loaded.notes['$uid:1'], '세 번째 장');
  });

  testWidgets('단계마다 다른 PNG, 사라짐이 없으면 마지막 장은 단계 무시하고 구운 것과 같은 파일', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('page_anim');
      addTearDown(() => temp.delete(recursive: true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => temp.path,
          );
      const style = ExportStyle(
        fontSize: 30,
        bibleFontSize: 30,
        backgroundColor: Colors.black,
        textColor: Colors.white,
        bibleTextColor: Colors.white,
        textPosition: VerticalTextPosition.bottom,
        bibleTextPosition: VerticalTextPosition.middle,
        lyricsTextAlign: HorizontalPosition.center,
        bibleTextAlign: HorizontalPosition.center,
        includeEnglishLyrics: true,
        englishTextColor: Colors.white,
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
      final els = [box('a', 0), box('b', 1), box('c', 2)];
      const bg = SlideBackground(color: Colors.black);
      final pngs = [
        for (final step in pageSteps(els))
          await const PageComposer().compose(
            elements: step,
            background: bg,
            style: style,
          ),
      ];
      expect(pngs, hasLength(3));
      expect(pngs.toSet(), hasLength(3));
      final whole = await const PageComposer().compose(
        elements: els,
        background: bg,
        style: style,
      );
      expect(pngs.last, whole);
      expect(File(whole).existsSync(), isTrue);

      // 사라짐: [없음, a, 빈 화면, b] — 빈 화면은 요소 없이 구운 것과 같은 파일, 마지막 장은 '전부'가 아니다.
      final gone = [box('a', 1, 2), box('b', 3)];
      final gonePngs = [
        for (final step in pageSteps(gone))
          await const PageComposer().compose(
            elements: step,
            background: bg,
            style: style,
          ),
      ];
      expect(gonePngs, hasLength(4));
      expect(gonePngs[0], gonePngs[2]);
      expect(gonePngs.toSet(), hasLength(3));
      expect(
        gonePngs.last,
        await const PageComposer().compose(
          elements: [gone[1]],
          background: bg,
          style: style,
        ),
      );
    });
  });
}
