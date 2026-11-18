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

/// 편집 탭 콘티 목록 다중 선택: Shift 범위·Ctrl 토글·다중 끌기·Delete 삭제·그룹 만들기.
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
    temp = await Directory.systemTemp.createTemp('conti_multi_select');
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
      for (final (i, t) in ['가곡', '나곡', '다곡', '라곡'].indexed)
        PraiseSong(
          id: i + 1,
          fileName: '$t.pptx',
          title: t,
          lyrics: '가사',
          englishLyrics: '',
        ),
    ]);
  });

  tearDownAll(() => temp.delete(recursive: true));

  const titles = ['가곡', '나곡', '다곡', '라곡'];

  Finder inList(String t) =>
      find.descendant(of: find.byType(ContiTreeList), matching: find.text(t));

  bool selected(WidgetTester tester, String t) {
    final m = tester.widget<Material>(
      find.ancestor(of: inList(t), matching: find.byType(Material)).first,
    );
    return m.color ==
        Theme.of(tester.element(inList(t))).colorScheme.secondaryContainer;
  }

  List<String> order(WidgetTester tester) {
    final ys = {for (final t in titles) t: tester.getTopLeft(inList(t)).dy};
    return ([...ys.keys]..sort((a, b) => ys[a]!.compareTo(ys[b]!)));
  }

  Future<void> tapWith(
    WidgetTester tester,
    String t, {
    LogicalKeyboardKey? key,
  }) async {
    if (key != null) await tester.sendKeyDownEvent(key);
    await tester.tap(inList(t));
    if (key != null) await tester.sendKeyUpEvent(key);
    await settle(tester);
  }

  testWidgets('Shift 범위·Ctrl 토글·다중 끌기·Delete 삭제', (tester) async {
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

    for (final t in titles) {
      await tester.tap(find.text(t));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text(t));
      await settle(tester);
    }
    expect(order(tester), titles);

    // 클릭 = 하나, Shift = 앵커~클릭 범위
    await tapWith(tester, '가곡');
    await tapWith(tester, '다곡', key: LogicalKeyboardKey.shiftLeft);
    expect(
      [for (final t in titles) selected(tester, t)],
      [true, true, true, false],
    );

    // Ctrl 토글: 나곡 빼고 라곡 더하기
    await tapWith(tester, '나곡', key: LogicalKeyboardKey.controlLeft);
    await tapWith(tester, '라곡', key: LogicalKeyboardKey.controlLeft);
    expect(
      [for (final t in titles) selected(tester, t)],
      [true, false, true, true],
    );

    // 그냥 클릭하면 그 하나만
    await tapWith(tester, '나곡');
    expect(
      [for (final t in titles) selected(tester, t)],
      [false, true, false, false],
    );

    // 가곡·다곡을 고르고 가곡 손잡이를 라곡 아래로 끌면 둘이 같이 간다
    await tapWith(tester, '가곡');
    await tapWith(tester, '다곡', key: LogicalKeyboardKey.controlLeft);
    final handle = find.byIcon(Icons.drag_handle_rounded).first;
    final last = tester.getRect(
      find.ancestor(of: inList('라곡'), matching: find.byType(InkWell)).first,
    );
    final g = await tester.startGesture(
      tester.getCenter(handle),
      kind: PointerDeviceKind.mouse,
    );
    await g.moveTo(tester.getCenter(handle) + const Offset(0, 8));
    await g.moveTo(Offset(last.center.dx, last.bottom - 4));
    await tester.pump();
    await g.up();
    await settle(tester);
    expect(order(tester), ['나곡', '라곡', '가곡', '다곡']);

    // Delete = 확인 뒤 고른 둘 삭제
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await settle(tester);
    expect(find.text('항목 삭제'), findsOneWidget);
    await tester.tap(find.text('삭제'));
    await settle(tester);
    expect(inList('가곡'), findsNothing);
    expect(inList('다곡'), findsNothing);
    expect(inList('나곡'), findsOneWidget);
    expect(inList('라곡'), findsOneWidget);

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
