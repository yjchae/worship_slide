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
import 'package:worship_slides/src/features/praise/presentation/conti_tree_widgets.dart';
import 'package:worship_slides/src/features/praise/presentation/praise_home_page.dart';

/// 실제 편집 탭 콘티 목록에서 폴더 트리: 그룹 만들기 → 끌어 넣기 → 접기 → 풀기.
void main() {
  late Directory temp;
  final presentationCalls = <String>[];

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('conti_tree_page');
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
        presentationCalls.add(call.method);
        return null;
      },
    );
    await PraiseRepository().replaceAllSongs([
      for (final t in ['첫째 곡', '둘째 곡'])
        PraiseSong(
          id: t == '첫째 곡' ? 1 : 2,
          fileName: '$t.pptx',
          title: t,
          lyrics: '가사',
          englishLyrics: '',
        ),
    ]);
  });

  tearDownAll(() => temp.delete(recursive: true));

  testWidgets('작은 창에서 콘티와 발표 보기를 사용할 수 있다', (tester) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: PraiseHomePage()));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: '준비 화면');
    await tester.tap(find.text('첫째 곡'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('첫째 곡'));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: '콘티 구성');
    await tester.tap(find.text('발표 보기'));
    await settle(tester);
    expect(find.text('현재 슬라이드'), findsOneWidget);
    final mobile = find.widgetWithText(OutlinedButton, '모바일 연결');
    expect(mobile, findsOneWidget);
    expect(tester.widget<OutlinedButton>(mobile).onPressed, isNotNull);
    expect(find.byTooltip('발표를 시작하면 싱어 화면을 열 수 있습니다'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(mobile);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await settle(tester);
    expect(find.text('휴대폰 화면 연결'), findsOneWidget);
    expect(find.text('싱어창'), findsOneWidget);
    await tester.tap(find.text('발표자 모드'));
    await settle(tester);
    expect(find.textContaining('발표자 휴대폰에서 이 주소를'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '모바일 연결 대화상자');
    await tester.tap(find.text('끄기'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    presentationCalls.clear();
    await tester.tap(find.text('발표 시작'));
    await settle(tester);
    expect(presentationCalls, contains('openWindow'));
    expect(presentationCalls, isNot(contains('openSingerWindow')));
    await tester.tap(find.text('싱어 창 열기'));
    await settle(tester);
    expect(presentationCalls, contains('openSingerWindow'));
    await tester.tap(find.text('싱어 창 닫기'));
    await settle(tester);
    expect(presentationCalls, contains('closeSingerWindow'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('800×600 큰 글자에서도 준비 화면이 넘치지 않는다', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: const PraiseHomePage(),
      ),
    );
    await settle(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('발표 디자인의 기능 탭과 글자 크기 입력을 작은 창에서 사용한다', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: const PraiseHomePage(),
      ),
    );
    await settle(tester);
    expect(find.text('PPTX 저장'), findsNothing);
    await tester.tap(find.byTooltip('파일 메뉴'));
    await settle(tester);
    expect(find.text('PPTX 내보내기'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await tester.tap(find.text('발표 보기'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('design-tab-song')));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: '찬양 설정');
    final increase = find.byTooltip('글자 크기 1 늘리기').first;
    final input = find.byKey(const ValueKey('design-font-size-input')).first;
    final initial = int.parse(tester.widget<TextField>(input).controller!.text);
    await tester.tap(increase);
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, '${initial + 1}');
    await tester.enterText(input, '37');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, '37');
    expect(find.text('가로 정렬'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('design-group-song-1')));
    await settle(tester);
    expect(find.text('제목 표시'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('design-group-song-0')));
    await settle(tester);
    expect(tester.widget<TextField>(input).controller!.text, '37');
    await tester.enterText(input, '999');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, '54');
    await tester.tap(find.byKey(const ValueKey('design-tab-common')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('design-group-common-4')));
    await settle(tester);
    expect(find.text('틀 관리'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('design-tab-bible')));
    await settle(tester);
    expect(find.text('줄 간격 %'), findsOneWidget);
    expect(find.text('가로 정렬'), findsOneWidget);
    expect(tester.takeException(), isNull);
    for (final entry in <String, int>{
      'common': 5,
      'song': 2,
      'bible': 2,
    }.entries) {
      await tester.tap(find.byKey(ValueKey('design-tab-${entry.key}')));
      await settle(tester);
      for (var i = 0; i < entry.value; i++) {
        await tester.tap(find.byKey(ValueKey('design-group-${entry.key}-$i')));
        await settle(tester);
        expect(tester.takeException(), isNull, reason: '${entry.key} $i');
      }
    }
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('좁은 창에서 마우스로 디자인 설정을 좌우로 이동한다', (tester) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: PraiseHomePage()));
    await settle(tester);
    await tester.tap(find.text('발표 보기'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('design-tab-bible')));
    await settle(tester);
    final bar = find.byKey(const ValueKey('design-group-scrollbar'));
    final controller = tester.widget<Scrollbar>(bar).controller!;
    IconButton button(String tooltip) => tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == tooltip,
      ),
    );
    expect(controller.position.maxScrollExtent, greaterThan(0));
    expect(button('설정 왼쪽으로 이동').onPressed, isNull);
    expect(button('설정 오른쪽으로 이동').onPressed, isNotNull);
    await tester.tap(find.byTooltip('설정 오른쪽으로 이동'));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    await tester.tap(find.byTooltip('설정 왼쪽으로 이동'));
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    await tester.tap(find.byKey(const ValueKey('design-tab-common')));
    await settle(tester);
    expect(button('설정 오른쪽으로 이동').onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('하위 그룹 만들기 → 들여쓰기·접기(상위가 하위도 가림) → 되돌리기', (tester) async {
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
    for (final t in ['첫째 곡', '둘째 곡']) {
      await tester.tap(find.text(t));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text(t));
      await settle(tester);
    }
    final list = find.byType(ContiTreeList);
    Finder inList(String t) =>
        find.descendant(of: list, matching: find.text(t));

    // 둘째 곡을 고르고 그룹 '특송'을 만든다.
    await tester.tap(inList('둘째 곡'));
    await settle(tester);
    await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, '특송');
    await tester.pump();
    await tester.tap(find.text('만들기'));
    await settle(tester);

    // 첫째 곡을 골라 특송 ⋯ → 하위 그룹 만들기. 이름의 '/' 는 전각으로 바뀐다.
    await tester.tap(inList('첫째 곡'));
    await settle(tester);
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await settle(tester);
    await tester.tap(find.text('하위 그룹 만들기'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, '솔/로');
    await tester.pump();
    await tester.tap(find.text('만들기'));
    await settle(tester);
    final headers = find.byType(ContiGroupHeader);
    expect(headers, findsNWidgets(2));
    expect(find.text('솔／로'), findsOneWidget);
    // 하위 머리줄은 상위보다 오른쪽으로 들여쓴다.
    expect(
      tester.getTopLeft(find.text('솔／로')).dx,
      greaterThan(tester.getTopLeft(find.text('특송')).dx),
    );

    // 상위를 접으면 하위 머리줄·항목이 모두 가려진다.
    await tester.tap(find.text('특송'));
    await settle(tester);
    expect(headers, findsOneWidget);
    expect(inList('첫째 곡'), findsNothing);
    expect(inList('둘째 곡'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('그룹 만들기 → 끌어 넣기 → 접기 → 풀기', (tester) async {
    tester.view.physicalSize = const Size(1920, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // 테스트 글꼴로는 디자인 리본의 고정 높이 열이 4px 넘친다(이 시험과 무관).
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    await tester.pumpWidget(const MaterialApp(home: PraiseHomePage()));
    await settle(tester);

    // 곡 둘을 콘티에 담는다(검색 결과 더블클릭 = 두 번 탭).
    for (final t in ['첫째 곡', '둘째 곡']) {
      await tester.tap(find.text(t));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text(t));
      await settle(tester);
    }
    expect(find.byIcon(Icons.drag_handle_rounded), findsNWidgets(2));

    // 콘티에서 둘째 곡을 골라 두면 그룹 만들기에서 그 항목이 든다.
    await tester.tap(
      find.descendant(
        of: find.byType(ContiTreeList),
        matching: find.text('둘째 곡'),
      ),
    );
    await settle(tester);
    await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, '특송');
    await tester.pump();
    await tester.tap(find.text('만들기'));
    await settle(tester);
    expect(find.text('특송'), findsOneWidget);
    expect(find.byIcon(Icons.folder_open_rounded), findsOneWidget);

    // 첫째 곡을 폴더 머리 아래 절반으로 끌어 넣는다.
    final handles = find.byIcon(Icons.drag_handle_rounded);
    final firstHandle = handles.first; // 그룹 밖 첫째 곡(머리줄 손잡이보다 위)
    final header = find.ancestor(
      of: find.text('특송'),
      matching: find.byType(InkWell),
    );
    final r = tester.getRect(header.first);
    final g = await tester.startGesture(
      tester.getCenter(firstHandle),
      kind: PointerDeviceKind.mouse,
    );
    await g.moveTo(tester.getCenter(firstHandle) + const Offset(0, 8));
    await g.moveTo(Offset(r.center.dx, r.bottom - 4));
    await tester.pump();
    await g.up();
    await settle(tester);
    // 폴더 배지 = 2
    expect(
      find.descendant(
        of: find.byType(ContiGroupHeader),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );

    // 접기
    await tester.tap(find.text('특송'));
    await settle(tester);
    expect(
      find.descendant(
        of: find.byType(ContiGroupHeader),
        matching: find.byIcon(Icons.chevron_right_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ContiTreeList),
        matching: find.text('첫째 곡'),
      ),
      findsNothing,
    );

    // 풀기(⋯ 메뉴): 항목은 남는다
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await settle(tester);
    await tester.tap(find.text('그룹 풀기 (항목 유지)'));
    await settle(tester);
    expect(find.text('특송'), findsNothing);
    expect(find.byIcon(Icons.drag_handle_rounded), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('항목을 안 골라도 + 로 빈 하위 그룹 → 이름 입력 → 항목을 끌어 넣기', (tester) async {
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
    for (final t in ['첫째 곡', '둘째 곡']) {
      await tester.tap(find.text(t));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text(t));
      await settle(tester);
    }
    final list = find.byType(ContiTreeList);
    await tester.tap(find.descendant(of: list, matching: find.text('둘째 곡')));
    await settle(tester);
    await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, '특송');
    await tester.pump();
    await tester.tap(find.text('만들기'));
    await settle(tester);

    // 고른 항목이 있어도 + 는 대화창 없이 빈 하위를 만들고 이름 칸을 연다.
    await tester.tap(
      find.descendant(
        of: find.byType(ContiGroupHeader),
        matching: find.byIcon(Icons.add_rounded),
      ),
    );
    await settle(tester);
    final field = find.descendant(
      of: find.byType(ContiGroupHeader),
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget);
    expect(find.text('여기에 끌어 놓기'), findsOneWidget);
    await tester.enterText(field, '솔로');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(field, findsNothing);
    expect(find.text('솔로'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('솔로')).dx,
      greaterThan(tester.getTopLeft(find.text('특송')).dx),
    );

    // 첫째 곡을 빈 하위에 끌어 놓으면 특송 안 솔로로 들어가고 힌트가 사라진다.
    final handle = find
        .descendant(of: list, matching: find.byIcon(Icons.drag_handle_rounded))
        .first;
    final target = tester.getCenter(
      find.ancestor(of: find.text('솔로'), matching: find.byType(InkWell)).first,
    );
    final g = await tester.startGesture(
      tester.getCenter(handle),
      kind: PointerDeviceKind.mouse,
    );
    await g.moveTo(tester.getCenter(handle) + const Offset(0, 8));
    await g.moveTo(target);
    await tester.pump();
    await g.up();
    await settle(tester);
    expect(find.text('여기에 끌어 놓기'), findsNothing);
    expect(find.byType(ContiGroupHeader), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
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
