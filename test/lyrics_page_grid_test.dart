import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/app_theme.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/presentation/lyrics_editor_dialog.dart';
import 'package:worship_slides/src/features/praise/presentation/lyrics_page_grid.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_page_data.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_text_layout.dart';

/// 가사 수정 창의 페이지 표(행 = 한 장, 열 = 원본·보조·추가 보조)와 넘침 측정.
void main() {
  LyricsPageGrid grid(String main, String sub, [String extra = '']) =>
      LyricsPageGrid.fromTexts([main, sub, extra]);

  List<List<String>> rowsOf(LyricsPageGrid g) => [
    for (var r = 0; r < g.length; r++) g.row(r),
  ];

  group('페이지 표', () {
    test('세 언어를 페이지 번호끼리 한 행에 놓는다', () {
      final g = grid('A1\n\nA2', 'B1\n\nB2\n\nB3', 'C1');
      expect(rowsOf(g), [
        ['A1', 'B1', 'C1'],
        ['A2', 'B2', ''],
        ['', 'B3', ''],
      ]);
    });

    test('표 ↔ 저장 형식 왕복(앞쪽 빈 페이지 보존, 끝 빈 페이지 제거)', () {
      final g = grid('\n\nA1\n\nA2', 'B1', '');
      expect(g.toTexts(), ['\n\nA1\n\nA2', 'B1', '']);
      expect(g.length, 3);
      expect(g.isBlankRow(0), isFalse); // 보조 B1 이 0번 행에 있다
    });

    test('빈 글이어도 한 행은 있다', () {
      expect(grid('', '').length, 1);
    });

    test('붙여 넣은 가사를 빈 줄마다 나눠 아래 행으로 보내고 그 열만 밀어 낸다', () {
      final g = grid('A1\n\nA2\n\nA3', 'B1\n\nB2');
      g.setCell(0, 2, 'C1\n\nC2\n\nC3');
      expect(g.splitCell(0, 2), 3);
      expect(rowsOf(g), [
        ['A1', 'B1', 'C1'],
        ['A2', 'B2', 'C2'],
        ['A3', '', 'C3'],
      ]);
    });

    test('나눌 때 아래에 있던 같은 열 글은 지우지 않고 내린다', () {
      final g = grid('A1\n\nA2', 'B1\n\nB2');
      g.setCell(0, 1, 'X\n\nY');
      g.splitCell(0, 1);
      expect(g.toTexts()[1], 'X\n\nY\n\nB2');
    });

    test('엔터 두 번 = 다음 페이지에 빈 칸', () {
      final g = grid('A1', '');
      g.setCell(0, 0, 'A1\n\n');
      expect(g.splitCell(0, 0), 2);
      expect(rowsOf(g), [
        ['A1', '', ''],
        ['', '', ''],
      ]);
    });

    test('아래로 밀기 · 위로 당기기는 그 열만 옮긴다', () {
      final g = grid('A1\n\nA2\n\nA3', 'B2\n\nB3');
      g.pushDown(0, 1);
      expect(rowsOf(g).map((r) => r[1]), ['', 'B2', 'B3']);
      g.pullUp(1, 1);
      expect(rowsOf(g).map((r) => r[1]), ['B2', 'B3', '']);
      expect(rowsOf(g).map((r) => r[0]), ['A1', 'A2', 'A3']);
    });

    test('위로 당길 때 위 칸에 글이 있으면 잇는다(버리지 않음)', () {
      final g = grid('A1\n\nA2', 'B1\n\nB2');
      g.pullUp(1, 1);
      expect(g.cell(0, 1), 'B1\nB2');
      expect(g.length, 2); // 원본 A2 는 그대로
    });

    test('다음 페이지와 합치기 · 커서에서 나누기', () {
      final g = grid('A1\n\nA2', 'B1\n\nB2', 'C1');
      g.mergeWithNext(0);
      expect(g.row(0), ['A1\nA2', 'B1\nB2', 'C1']);
      g.splitAt(0, 0, 2);
      expect(g.row(0), ['A1', 'B1\nB2', 'C1']);
      expect(g.row(1), ['A2', '', '']);
    });

    test('행 넣기 · 지우기 · 비우기', () {
      final g = grid('A1\n\nA2', '');
      g.insertRow(1);
      expect(g.toTexts()[0], 'A1\n\n\n\nA2');
      g.removeRow(1);
      expect(g.toTexts()[0], 'A1\n\nA2');
      g.clearRow(0);
      expect(g.toTexts()[0], '\n\nA2');
    });

    test('원본엔 있고 보조가 빈 행을 센다', () {
      final g = grid('A1\n\nA2\n\nA3', 'B1', 'C1\n\nC2\n\nC3');
      expect(g.missingRows(1), [1, 2]);
      expect(g.missingRows(2), isEmpty);
      expect(g.filledCount(0), 3);
    });
  });

  group('넘침', () {
    final style = ExportStyle.fromJson({
      'font_size': 30,
      'bible_font_size': 30,
    });

    SlidePageData page(int lines, {bool extra = true}) {
      String text(String word) => List.filled(lines, word).join('\n');
      return SlidePageData(
        mainText: text('가'),
        englishText: text('a'),
        extraText: extra ? text('b') : '',
        isBible: false,
        pageIndex: 0,
        totalPages: 1,
        style: style,
      );
    }

    test('언어마다 3줄은 들어가고 5줄은 넘친다', () {
      expect(SlideTextLayout.overflows(page(3)), isFalse);
      expect(SlideTextLayout.overflows(page(5)), isTrue);
    });

    test('추가 보조를 끄면 높이에서 빠진다', () {
      final off = page(5);
      final hidden = SlidePageData(
        mainText: off.mainText,
        englishText: off.englishText,
        extraText: off.extraText,
        isBible: false,
        pageIndex: 0,
        totalPages: 1,
        style: style.copyWith(includeExtraLyrics: false),
      );
      expect(
        SlideTextLayout.overflowRatio(hidden),
        lessThan(SlideTextLayout.overflowRatio(off)),
      );
      expect(
        SlideTextLayout.overflowRatio(hidden),
        closeTo(SlideTextLayout.overflowRatio(page(5, extra: false)), 1e-9),
      );
    });

    test('보조 블록 앞 틈(본문 × 0.4)까지 더해 잰다 — 발표 창 높이와 맞게', () {
      SlidePageData one({String sub = ''}) => SlidePageData(
        mainText: '가',
        englishText: sub,
        isBible: false,
        pageIndex: 0,
        totalPages: 1,
        style: style,
      );
      final added =
          SlideTextLayout.overflowRatio(one(sub: 'a')) -
          SlideTextLayout.overflowRatio(one());
      // 보조 한 줄(24pt × 1.3) + 틈(30pt × 0.4), 상자 높이 5.4인치 = 388.8pt.
      expect(added, closeTo((24 * 1.3 + 30 * 0.4) / 388.8, 0.01));
    });

    test('표시 값은 5% 단위', () {
      expect(SlideTextLayout.overflowLabel(1.12), '약 110%');
      expect(SlideTextLayout.overflowLabel(1.13), '약 115%');
    });
  });

  group('가사 수정 창', () {
    const song = PraiseSong(
      id: 1,
      fileName: 'love.pptx',
      title: '주님의 사랑 넓고 깊어',
      lyrics: '주님의 사랑 넓고 깊어\n나의 삶을 감싸 주시네\n\n찬양해 찬양해',
      englishLyrics: 'Your love, O Lord\nIt wraps my life\n\nSing praise',
    );
    final style = ExportStyle.fromJson({
      'font_size': 30,
      'bible_font_size': 30,
    }).copyWith(extraLanguage: '스페인어');

    Future<void> loadFonts() async {
      final loader = FontLoader('Pretendard');
      for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        loader.addFont(
          Future.value(
            ByteData.sublistView(
              File('assets/fonts/Pretendard-$weight.ttf').readAsBytesSync(),
            ),
          ),
        );
      }
      await loader.load();
      // 버튼 글자(Roboto 지정)·아이콘도 보이게. Roboto 자리에 한글이 되는 Pretendard 를 넣는다.
      final roboto = FontLoader('Roboto')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File('assets/fonts/Pretendard-SemiBold.ttf').readAsBytesSync(),
            ),
          ),
        );
      await roboto.load();
      final icons = File(
        '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}'
        '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (icons.existsSync()) {
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(ByteData.sublistView(icons.readAsBytesSync())),
            ))
            .load();
      }
    }

    const shotKey = ValueKey('shot');

    Future<SongEditResult?> openDialog(
      WidgetTester tester, {
      String extraLanguage = '스페인어',
    }) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SongEditResult? result;
      await tester.pumpWidget(
        RepaintBoundary(
          key: shotKey,
          child: MaterialApp(
            theme: AppThemeKind.light.theme,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () async => result = await showDialog(
                      context: context,
                      builder: (_) => LyricsEditorDialog(
                        song: song,
                        translations: const {'스페인어': 'Tu amor, Señor'},
                        languages: const ['영어', '스페인어'],
                        extraLanguage: extraLanguage,
                        style: style,
                      ),
                    ),
                    child: const Text('열기'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('세 칸을 페이지 행으로 보여 주고 저장하면 언어별로 돌려준다', (tester) async {
      await openDialog(tester);
      expect(find.text('Tu amor, Señor'), findsOneWidget);
      expect(find.text('찬양해 찬양해'), findsOneWidget);

      // 추가 보조 2페이지에 붙여 넣기 → 나뉘어 아래 행으로.
      final cells = find.byType(TextField);
      // 0: 제목, 1~3: 1페이지 원본·보조·추가, 4~6: 2페이지
      await tester.enterText(cells.at(6), 'Alabad\n\nPor siempre');
      await tester.pumpAndSettle();
      expect(find.textContaining('붙여 넣은 가사를'), findsNothing); // 두 조각은 알림 없음
      expect(find.text('Por siempre'), findsOneWidget);

      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();
    });

    testWidgets('행 메뉴의 커서 위치에서 나누기가 실제로 나눈다', (tester) async {
      await openDialog(tester);
      final cell = find.byType(TextField).at(1); // 1페이지 원본
      await tester.tap(cell);
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(cell);
      field.controller!.selection = const TextSelection.collapsed(offset: 6);
      await tester.pump();

      await tester.tap(find.byTooltip('페이지 메뉴').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('커서 위치에서 나누기  (Ctrl/⌘+Enter)'));
      await tester.pumpAndSettle();

      expect(find.text('주님의 사랑'), findsOneWidget);
      expect(find.text('넓고 깊어\n나의 삶을 감싸 주시네'), findsOneWidget);
    });

    testWidgets('붙여 넣은 뒤 다른 칸을 고치면 되돌리기가 닫힌다(고친 것을 지우지 않게)', (tester) async {
      await openDialog(tester);
      final cells = find.byType(TextField);
      await tester.enterText(cells.at(6), 'A\n\nB\n\nC');
      await tester.pumpAndSettle();
      expect(find.text('되돌리기'), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(1), '고친 1절');
      await tester.pumpAndSettle();
      expect(find.text('되돌리기'), findsNothing);
      expect(find.text('고친 1절'), findsOneWidget);
    });

    testWidgets('화면을 PNG 로 남긴다(디자인 확인용)', (tester) async {
      await loadFonts();
      await openDialog(tester);
      await tester.tap(find.byType(TextField).at(3));
      await tester.pumpAndSettle();
      final out = Platform.environment['LYRICS_EDITOR_SHOT'];
      if (out == null) return;
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(shotKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(out).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    });
  });
}
