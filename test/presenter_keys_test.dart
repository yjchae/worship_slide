import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_repository.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/presentation/praise_home_page.dart';

void main() {
  bool active({bool route = true, bool open = false, bool tab = false}) =>
      presenterKeysActive(
        isCurrentRoute: route,
        isPresentationOpen: open,
        isPresenterTab: tab,
      );

  test('발표 전에도 발표 보기 탭이면 받는다', () {
    expect(active(tab: true), isTrue);
  });

  test('발표 중이면 편집 탭에서도 받는다', () {
    expect(active(open: true), isTrue);
  });

  test('편집 탭에서 발표 전이면 가로채지 않는다', () {
    expect(active(), isFalse);
  });

  test('다이얼로그·메뉴가 떠 있으면 받지 않는다', () {
    expect(active(route: false, open: true, tab: true), isFalse);
  });

  group('실제 페이지 키 입력', () {
    const pageCount = 12;
    const title = '키 시험 곡';
    late Directory temp;
    final calls = <MethodCall>[];

    int called(String method) => calls.where((c) => c.method == method).length;

    /// 관객 창에 마지막으로 보낸 쪽 번호(1부터).
    int shownPage() {
      final call = calls.lastWhere(
        (c) => c.method == 'updatePage' || c.method == 'openWindow',
      );
      return (call.arguments as Map)['page_index'] + 1;
    }

    String? focusLabel() => FocusManager.instance.primaryFocus?.debugLabel;

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await simulateKeyDownEvent(key);
      await simulateKeyUpEvent(key);
      await settle(tester);
    }

    Future<void> startPresentation(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: PraiseHomePage()));
      await settle(tester);
      await tester.tap(find.text(title));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text(title));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('발표 시작'));
      await settle(tester);
      expect(find.text('발표 종료'), findsOneWidget);
      expect(focusLabel(), 'presentation-shortcuts');
    }

    /// 타이머·리스너를 남기지 않게 페이지를 치운다.
    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
    }

    setUpAll(() async {
      temp = await Directory.systemTemp.createTemp('presenter_keys');
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
        (call) async {
          calls.add(call);
          return null;
        },
      );
      await PraiseRepository().replaceAllSongs([
        PraiseSong(
          id: 1,
          fileName: 'keys.pptx',
          title: title,
          lyrics: [for (var i = 1; i <= pageCount; i++) '가사 $i'].join('\n\n'),
          englishLyrics: '',
        ),
      ]);
    });

    tearDownAll(() => temp.delete(recursive: true));

    setUp(calls.clear);

    testWidgets('방향키를 여러 번 눌러도 포커스가 안 움직여 Space 가 발표를 끄지 않는다', (tester) async {
      await startPresentation(tester);
      for (var i = 0; i < 8; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      await press(tester, LogicalKeyboardKey.space);
      expect(called('closeWindow'), 0);
      expect(focusLabel(), 'presentation-shortcuts');
      expect(shownPage(), 10);
      await finish(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('아래 방향키 뒤에도 번호 이동이 된다', (tester) async {
      await startPresentation(tester);
      for (var i = 0; i < 4; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      await press(tester, LogicalKeyboardKey.digit2);
      await press(tester, LogicalKeyboardKey.enter);
      expect(shownPage(), 2);
      await finish(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('키를 누르고 있어도 한 번만 넘어가고 포커스가 그대로다', (tester) async {
      await startPresentation(tester);
      await simulateKeyDownEvent(LogicalKeyboardKey.arrowDown);
      for (var i = 0; i < 6; i++) {
        await simulateKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      }
      await simulateKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await settle(tester);
      expect(shownPage(), 2);
      expect(focusLabel(), 'presentation-shortcuts');
      await finish(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('입력칸에서는 Space·방향키가 페이지를 옮기지 않고 입력칸에 남는다', (tester) async {
      await startPresentation(tester);
      final before = shownPage();
      final count = calls.length;
      await tester.tap(find.byType(TextField).hitTestable().first);
      await settle(tester);
      final field = FocusManager.instance.primaryFocus;
      expect(
        field?.context?.findAncestorWidgetOfExactType<EditableText>(),
        isNotNull,
      );
      await press(tester, LogicalKeyboardKey.space);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.digit3);
      expect(FocusManager.instance.primaryFocus, field);
      expect(calls.length, count);
      expect(shownPage(), before);
      await finish(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('포커스가 스코프 밖이어도 방향키가 처리된다', (tester) async {
      await startPresentation(tester);
      FocusManager.instance.rootScope.requestScopeFocus();
      await tester.pump();
      expect(focusLabel(), isNot('presentation-shortcuts'));

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(shownPage(), 2);
      expect(focusLabel(), 'presentation-shortcuts');
      await finish(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('다른 키는 포커스를 끌어오지 않는다', (tester) async {
      await startPresentation(tester);
      FocusManager.instance.rootScope.requestScopeFocus();
      await tester.pump();
      final outside = FocusManager.instance.primaryFocus;

      await press(tester, LogicalKeyboardKey.keyK);
      expect(FocusManager.instance.primaryFocus, outside);
      await finish(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });
}

/// DB 를 실행 파일 옆이 아니라 메모리에 연다. 테스트가 파일을 남기지 않게.
/// `databaseFactory` 는 sqflite 자체 팩터리만 받아서 그 인터페이스 중 공개된 것을 쓴다.
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
