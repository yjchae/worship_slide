import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_repository.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/page_format.dart';
import 'package:worship_slides/src/features/praise/presentation/page_format_editor.dart';
import 'package:worship_slides/src/features/praise/presentation/praise_home_page.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_render_view.dart';

/// 발표 보기 '수정하기'의 '이 페이지 글자 모양': 그 페이지만 바뀌고, 글을 고쳐도 따라가고, 되돌린다.
void main() {
  late Directory temp;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('page_format_page');
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
        title: '서식 곡',
        lyrics: '가사 하나\n\n가사 둘',
        englishLyrics: '',
      ),
    ]);
  });

  tearDownAll(() => temp.delete(recursive: true));

  /// 발표 보기 격자에 그려진 페이지 글 → 본문 글자 크기(pt).
  Map<String, double> sizes(WidgetTester tester) => {
    for (final v in tester.widgetList<SlideRenderView>(
      find.byType(SlideRenderView),
    ))
      if (v.data.mainText.isNotEmpty) v.data.mainText: v.data.style.fontSize,
  };

  Future<void> openEdit(WidgetTester tester, String page) async {
    final thumb = find
        .ancestor(
          of: find.byWidgetPredicate(
            (w) => w is SlideRenderView && w.data.mainText == page,
          ),
          matching: find.byType(MouseRegion),
        )
        .first;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(thumb));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.edit_rounded).first);
    await settle(tester);
  }

  testWidgets('수정 창에서 크기를 바꾸면 그 페이지만 바뀌고 ⌘Z 로 되돌린다', (tester) async {
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
    await tester.tap(find.text('서식 곡'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('서식 곡'));
    await settle(tester);
    await tester.tap(find.text('발표 보기'));
    await settle(tester);

    final before = sizes(tester);
    expect(before['가사 하나'], before['가사 둘']);

    await openEdit(tester, '가사 하나');
    expect(find.byType(PageFormatEditor), findsOneWidget);
    // 원본 슬라이더를 오른쪽 끝(200%)으로.
    await tester.drag(
      find.byKey(const ValueKey('format-scale-main')),
      const Offset(600, 0),
    );
    await tester.pump();
    expect(find.text('200%'), findsOneWidget);
    // 글도 같이 고친다 — 서식이 새 글로 따라가야 한다.
    await tester.enterText(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .first,
      '가사 하나 고침',
    );
    await tester.tap(find.text('적용'));
    await settle(tester);

    final after = sizes(tester);
    expect(after['가사 하나 고침'], before['가사 둘']! * 2);
    expect(after['가사 둘'], before['가사 둘']);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(sizes(tester), before);
  });

  testWidgets('글자 모양 줄: 크기·기본값으로·색 칸', (tester) async {
    PageEntry? entry;
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: StatefulBuilder(
            builder: (_, set) => PageFormatEditor(
              entry: entry,
              style: const ExportStyle(
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
              ),
              isBible: false,
              swatches: const [Colors.red],
              onChanged: (e) => set(() => entry = e),
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('format-color-sub')), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('format-scale-sub')),
      const Offset(600, 0),
    );
    await tester.pump();
    expect(entry?.sub?.scale, 2.0);
    expect(entry?.main, isNull);
    await tester.tap(find.text('기본값으로'));
    await tester.pump();
    expect(entry, isNull);
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
