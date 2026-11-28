import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/presentation/conti_group_widgets.dart';
import 'package:worship_slides/src/features/praise/presentation/ppt_layout_dialog.dart';
import 'package:worship_slides/src/features/praise/domain/ppt_layout.dart';
import 'package:worship_slides/src/features/praise/presentation/libreoffice_install_dialog.dart';
import 'package:worship_slides/src/features/praise/presentation/cloud_conti_dialog.dart';
import 'package:worship_slides/src/features/praise/presentation/presenter_pin_dialog.dart';
import 'package:worship_slides/src/features/praise/presentation/conti_text_import_dialog.dart';
import 'package:worship_slides/src/features/praise/presentation/page_template_dialog.dart';
import 'package:worship_slides/src/features/praise/presentation/praise_home_page.dart';
import 'package:worship_slides/src/features/praise/presentation/sync_dialog.dart';
import 'package:worship_slides/src/features/praise/data/sync_service.dart';
import 'package:worship_slides/src/features/praise/presentation/chord_edit_widgets.dart';
import 'package:worship_slides/src/features/praise/presentation/chord_key_controls.dart';
import 'package:worship_slides/src/features/praise/presentation/style_fields.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';

void main() {
  final connectedService = SyncService()
    ..status.value = const SyncStatus(folder: '테스트');
  testWidgets('그룹 이름 입력은 작은 창과 큰 글자에서 사용할 수 있다', (tester) async {
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
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showGroupNameDialog(
                context,
                title: '그룹 만들기',
                confirmLabel: '만들기',
                takenNames: const [],
                selectedTitle: '예시 찬양',
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(find.text('만들기'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (name, dialog) in <(String, Widget)>[
    (
      'PPT 가져오기 결과',
      const PptLayoutResultDialog(
        layout: PptLayout(
          sourceName: '예시.pptx',
          slides: [
            PptLayoutSlide(index: 1, droppedCount: 3, effectsLost: 2, steps: 3),
          ],
          fontsMissing: ['예시 글꼴'],
        ),
        groupName: '예배',
      ),
    ),
    (
      '설치 안내',
      LibreOfficeInstallDialog(
        reason: 'PPT 파일을 열려면 필요합니다.',
        onOpenDownloadPage: () {},
      ),
    ),
    ('클라우드 콘티', CloudContiDialog(service: SyncService())),
    ('발표자 PIN', const PresenterPinDialog(initial: '1234')),
    ('콘티 입력', ContiTextImportDialog(loadSongs: () async => [])),
    (
      '페이지 틀',
      PageTemplateDialog(
        templates: const [],
        broken: false,
        edit: (_) async => null,
        save: (_) async => true,
      ),
    ),
    ('콘티 저장', const SaveContiDialog(initialName: '예시 콘티')),
    ('곡 변경 확인', const StagedSongUpdateDialog(count: 2, skipped: 1)),
    (
      '동기화 연결됨',
      SyncDialog(
        service: connectedService,
        onSyncSongs: () async {},
        onOpenCloudContis: () {},
      ),
    ),
    (
      '동기화',
      SyncDialog(
        service: SyncService(),
        onSyncSongs: () async {},
        onOpenCloudContis: () {},
      ),
    ),
    (
      '코드 입력',
      const ChordPickDialog(
        songKey: 'C',
        songChords: [
          'C',
          'Dm',
          'Em',
          'F',
          'G',
          'Am',
          'Bdim',
          'C7',
          'Dm7',
          'Em7',
          'Fmaj7',
          'G7',
        ],
        charLabel: '가',
      ),
    ),
    (
      '조 변경',
      ChordTransposeDialog(
        song: const PraiseSong(
          id: 1,
          fileName: '',
          title: '긴 제목의 예시 찬양',
          lyrics: '가사',
          englishLyrics: '',
          chordLyrics: '[C]가사',
        ),
        onChanged: (_, _) {},
        onEditKey: () {},
      ),
    ),
    (
      '색상 선택',
      HexColorDialog(
        title: '색상 선택',
        initialColor: Colors.blue,
        colors: const [Colors.red, Colors.blue],
        inputFormatter: FilteringTextInputFormatter.singleLineFormatter,
      ),
    ),
  ]) {
    testWidgets('$name 작은 창과 큰 글자', (tester) async {
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
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    showDialog(context: context, builder: (_) => dialog),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      if (name == '설치 안내') {
        await tester.pump(const Duration(milliseconds: 500));
      } else {
        await tester.pumpAndSettle();
      }
      if (name == '클라우드 콘티') {
        expect(find.textContaining('FileSystemException'), findsNothing);
        expect(find.textContaining('동기화 접속 키를 먼저 넣어 주세요'), findsOneWidget);
      }
      if (name == '코드 입력') {
        await tester.ensureVisible(find.text('조립'));
        await tester.pumpAndSettle();
        expect(find.text('조립'), findsOneWidget);
      }
      if (name == '동기화 연결됨') {
        expect(find.text('찬양 동기화'), findsOneWidget);
        expect(find.text('닫기'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
