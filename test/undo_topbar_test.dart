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

/// 상단 되돌리기 아이콘 + ⌘/Ctrl+Z: 그룹 만들기를 되돌린다.
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

  testWidgets('상단 되돌리기 아이콘·Ctrl+Z 로 그룹 만들기를 되돌린다', (tester) async {
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

    final undo = find.widgetWithIcon(IconButton, Icons.undo_rounded);
    expect(tester.widget<IconButton>(undo).onPressed, isNull);

    for (final t in ['첫째 곡', '둘째 곡']) {
      await tester.tap(find.text(t));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text(t));
      await settle(tester);
    }

    Future<void> makeGroup(String name) async {
      await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, name);
      await tester.pump();
      await tester.tap(find.text('만들기'));
      await settle(tester);
    }

    await makeGroup('특송');
    expect(find.text('특송'), findsOneWidget);
    expect(tester.widget<IconButton>(undo).onPressed, isNotNull);

    // 아이콘으로 되돌린다.
    await tester.tap(undo);
    await settle(tester);
    expect(find.text('특송'), findsNothing);
    expect(tester.widget<IconButton>(undo).onPressed, isNull);

    // Ctrl+Z 로 되돌린다.
    await makeGroup('말씀');
    expect(find.text('말씀'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(find.text('말씀'), findsNothing);
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
