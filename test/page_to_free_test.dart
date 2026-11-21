import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_repository.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/page_element.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/presentation/page_to_free.dart';
import 'package:worship_slides/src/features/praise/presentation/praise_home_page.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_render_view.dart';

/// 발표 보기 '자유 편집 페이지로 바꾸기': 요소 목록 만들기(순수) + 곡이 앞/편집/뒤로 나뉘고 ⌘Z 로 돌아오는지.
void main() {
  late Directory temp;

  const style = ExportStyle(
    fontSize: 40,
    bibleFontSize: 30,
    backgroundColor: Color(0xFF1B1B1B),
    textColor: Color(0xFFFF0000),
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

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('page_to_free');
    sqfliteFfiInit();
    databaseFactory = _MemoryDatabaseFactory();
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => temp.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('worship_slides/presentation'),
      (call) async => null,
    );
    await PraiseRepository().replaceAllSongs([
      PraiseSong(
        id: 1,
        fileName: 'f.pptx',
        title: '변환 곡',
        lyrics: '하나\n\n둘\n\n셋',
        englishLyrics: 'one\n\ntwo\n\nthree',
      ),
    ]);
  });

  tearDownAll(() => temp.delete(recursive: true));

  test('요소 목록: 본문·보조는 한 상자(현재 색·크기), 제목은 따로, 하단 기준이면 아래쪽', () {
    final els = freePageElements(
      style,
      main: '하나',
      sub: 'one',
      isBible: false,
      title: '곡',
    );
    expect(els, hasLength(2));
    final body = els[0] as PageTextElement;
    expect(body.text, '하나\none');
    expect(body.color, const Color(0xFFFF0000));
    expect(body.fontSize, 40);
    final ops = jsonDecode(body.rich!) as List;
    final sub = ops.firstWhere((o) => o['insert'] == 'one') as Map;
    expect(sub['attributes']['color'], '#FFF176');
    expect(sub['attributes']['size'], '32'); // 40 × 0.8
    // 하단 기준: 글 상자 아래끝이 가사 상자 아래(6.0인치 = 0.8)
    expect(body.rect.bottom, closeTo(6.0 / 7.5, 0.01));
    expect((els[1] as PageTextElement).text, '곡');
    // 성경은 제목 끔 + 보조가 없으면 평문
    final bible = freePageElements(
      style,
      main: '1 태초에',
      isBible: true,
      title: '창 1:1',
    );
    expect(bible, hasLength(1));
    expect((bible.single as PageTextElement).rich, isNull);
  });

  testWidgets('가운데 페이지만 바뀌고 앞뒤는 곡으로 남고, ⌘Z 로 한 곡이 돌아온다', (tester) async {
    tester.view.physicalSize = const Size(1920, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    await tester.pumpWidget(const MaterialApp(home: PraiseHomePage()));
    await settle(tester);
    await tester.tap(find.text('변환 곡'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('변환 곡'));
    await settle(tester);
    await tester.tap(find.text('발표 보기'));
    await settle(tester);

    // 현재 칸과 썸네일 줄에 같은 페이지가 겹쳐 그려지므로 겹침은 뺀다.
    List<String> pages() => <String>{
      for (final v in tester.widgetList<SlideRenderView>(
        find.byType(SlideRenderView),
      ))
        if (v.data.mainText.isNotEmpty) v.data.mainText,
    }.toList();
    int total() =>
        tester.widgetList<SlideRenderView>(find.byType(SlideRenderView)).length;

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    Future<void> openEdit(String page) async {
      final thumb = find
          .ancestor(
            of: find.byWidgetPredicate(
              (w) => w is SlideRenderView && w.data.mainText == page,
            ),
            matching: find.byType(MouseRegion),
          )
          .first;
      await mouse.moveTo(tester.getCenter(thumb));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.edit_rounded).first);
      await settle(tester);
    }

    final beforePages = pages();
    final beforeTotal = total();
    expect(beforePages, containsAll(['하나', '둘', '셋']));

    const convert = '이 페이지를 자유 편집 페이지로 바꾸기… (일부 글자만 서식)';
    // 취소하면 불변
    await openEdit('둘');
    await tester.ensureVisible(find.text(convert));
    await tester.tap(find.text(convert));
    await settle(tester);
    expect(find.textContaining('그림 페이지가 되어'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await settle(tester);
    expect(pages(), beforePages);

    // 바꾸기 → 편집 창 → 확인
    await openEdit('둘');
    await tester.ensureVisible(find.text(convert));
    await tester.tap(find.text(convert));
    await settle(tester);
    await tester.tap(find.text('바꾸기'));
    await settle(tester);
    await tester.tap(find.text('확인'));
    await settle(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await settle(tester);

    expect(pages(), ['하나', '셋']); // 둘은 그림이 되어 글이 없다
    expect(total(), beforeTotal); // 장 수 그대로(여백이 끼지 않음)
    final images = tester
        .widgetList<SlideRenderView>(find.byType(SlideRenderView))
        .where((v) => v.data.imagePath != null);
    expect(images, hasLength(1));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(pages(), beforePages);
    expect(total(), beforeTotal);
  });
}

class _MemoryDatabaseFactory implements SqfliteDatabaseFactoryLogger {
  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) =>
      databaseFactoryFfiNoIsolate.openDatabase(
        inMemoryDatabasePath,
        options: options,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
