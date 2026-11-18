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
      (call) async => null,
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
