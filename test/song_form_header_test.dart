import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_repository.dart';
import 'package:worship_slides/src/features/praise/domain/page_format.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/song_form.dart';
import 'package:worship_slides/src/features/praise/presentation/praise_home_page.dart';

/// 송폼 라벨이 붙은 곡의 발표 보기 머리줄(현재 슬라이드 + 라벨 배지 + '다음')이 좁은 창에서도 넘치지 않는다.
void main() {
  const title = '송폼 머리줄 곡';
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
    temp = await Directory.systemTemp.createTemp('song_form_header');
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
      (_) async => null,
    );
    final repo = PraiseRepository();
    await repo.replaceAllSongs([
      PraiseSong(
        id: 1,
        fileName: 'f.pptx',
        title: title,
        lyrics: '가사 1\n\n가사 2\n\n가사 3',
        englishLyrics: '',
      ),
    ]);
    final id = (await repo.searchSongs('')).first.id!;
    SectionLabel l(SectionKind k, [int? n]) => SectionLabel.of(k, num: n);
    await repo.saveSongForm(
      id,
      SongForm([
        (
          key: pageKey('가사 1')!,
          labels: [l(SectionKind.verse, 1), l(SectionKind.prechorus)],
        ),
        (key: pageKey('가사 2')!, labels: [l(SectionKind.chorus)]),
        (key: pageKey('가사 3')!, labels: const <SectionLabel>[]),
      ]),
    );
  });

  tearDownAll(() => temp.delete(recursive: true));

  testWidgets('좁은 폭에서도 머리줄이 넘치지 않는다', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: PraiseHomePage()));
    await settle(tester);
    await tester.tap(find.text(title));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text(title));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('발표 보기'));
    await settle(tester);
    expect(find.text('현재 슬라이드'), findsOneWidget);
    expect(find.text('V1·PC'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
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
