import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/app_theme.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/page_format.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/song_form.dart';
import 'package:worship_slides/src/features/praise/presentation/lyrics_editor_dialog.dart';
import 'package:worship_slides/src/features/praise/presentation/lyrics_page_grid.dart';
import 'package:worship_slides/src/features/praise/presentation/song_form_widgets.dart';

/// 송폼 편집 규칙(순수 함수)과 가사 수정 창의 송폼 칩 바·라벨 줄·순서 줄·확인 경고.
void main() {
  SectionLabel l(SectionKind k, [int? n]) => SectionLabel.of(k, num: n);

  group('편집 규칙', () {
    test('벌스 칩은 곡 안 최대 번호 + 1 을 같은 라벨로 없는 행에 붙이고, 전부 가졌으면 뺀다', () {
      final songLabels = [
        [l(SectionKind.verse, 1)],
        <SectionLabel>[],
        <SectionLabel>[],
      ];
      final r = toggleKind(
        [songLabels[1], songLabels[2]],
        SectionKind.verse,
        songLabels,
      );
      expect(r.added, l(SectionKind.verse, 2));
      expect(r.rows, [
        [l(SectionKind.verse, 2)],
        [l(SectionKind.verse, 2)],
      ]);
      final off = toggleKind(r.rows, SectionKind.verse, songLabels);
      expect(off.added, isNull);
      expect(off.rows, [<SectionLabel>[], <SectionLabel>[]]);
    });

    test('일부 행만 가졌으면 반선택이고 누르면 나머지에 붙는다', () {
      final rows = [
        [l(SectionKind.chorus)],
        <SectionLabel>[],
      ];
      expect(
        selectionState(rows, (x) => x.kind == SectionKind.chorus),
        KindState.some,
      );
      final r = toggleKind(rows, SectionKind.chorus, rows);
      expect(r.rows[1], [l(SectionKind.chorus)]);
    });

    test('한 행에 두 라벨(V2 + PC)을 붙일 수 있다', () {
      var rows = [<SectionLabel>[]];
      rows = toggleKind(rows, SectionKind.verse, rows).rows;
      rows = toggleKind(rows, SectionKind.prechorus, rows).rows;
      expect(labelsToText(rows.first), 'V1,PC');
    });

    test('같은 가사 다른 행 제안, 번호 스텝', () {
      final originals = ['주여', '다른', '주여', '주여'];
      final labels = [
        [l(SectionKind.chorus)],
        <SectionLabel>[],
        <SectionLabel>[],
        [l(SectionKind.chorus)],
      ];
      expect(
        sameTextRowsWithout(originals, labels, [0], l(SectionKind.chorus)),
        [2],
      );
      expect(stepLabelNumber(null, 1), 1);
      expect(stepLabelNumber(1, -1), isNull);
      expect(stepLabelNumber(2, -1), 1);
      expect(stepLabelNumber(kMaxLabelNumber, 1), kMaxLabelNumber);
    });

    test('썸네일 배지 글', () {
      expect(formThumbText([l(SectionKind.verse, 2)]), 'V2');
      expect(
        formThumbText([l(SectionKind.verse, 2), l(SectionKind.prechorus)]),
        'V2·PC',
      );
      expect(
        formThumbText([
          l(SectionKind.verse, 2),
          l(SectionKind.prechorus),
          l(SectionKind.chorus),
        ]),
        'V2+2',
      );
    });
  });

  group('행 라벨은 표 연산을 따라간다', () {
    LyricsPageGrid g() => LyricsPageGrid.fromTexts(
      ['A\n\nB\n\nC', '', ''],
      forms: ['V1', 'C', ''],
    );

    test('합치면 라벨을 잇고, 나누면 복사하며, 행을 넣어도 밀리지 않는다', () {
      final grid = g()..mergeWithNext(0);
      expect(grid.toForms(), ['V1,C', '']);
      final split = g()..splitAt(1, 0, 0);
      expect(split.toForms(), ['V1', 'C', 'C', '']);
      final ins = g()..insertRow(1);
      expect(ins.toForms(), ['V1', '', 'C', '']);
    });

    test('행 복사(rowWithForm)와 붙여 넣기는 라벨을 가져가고 글 칸 row 는 3칸이다', () {
      final grid = g();
      expect(grid.row(0), ['A', '', '']);
      grid.insertRows(3, [grid.rowWithForm(1)]);
      expect(grid.form(3), 'C');
    });
  });

  group('가사 수정 창', () {
    final style = ExportStyle.fromJson({
      'font_size': 30,
      'bible_font_size': 30,
    });
    PraiseSong song({SongForm? form}) => PraiseSong(
      id: 1,
      fileName: 'a',
      title: '곡',
      lyrics: '첫째 줄\n\n둘째 줄\n\n셋째 줄',
      englishLyrics: '',
      songForm: form,
    );

    Future<SongEditResult?> open(WidgetTester tester, PraiseSong s) async {
      SongEditResult? result;
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeKind.light.theme,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async => result = await showDialog(
                    context: context,
                    builder: (_) => LyricsEditorDialog(song: s, style: style),
                  ),
                  child: const Text('열기'),
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

    Future<void> pickRow(WidgetTester tester, int i) async {
      await tester.tap(find.byTooltip(RegExp('^눌러서 페이지 고르기')).at(i));
      await tester.pumpAndSettle();
    }

    Future<void> chip(WidgetTester tester, String tooltip) async {
      await tester.tap(find.byTooltip(tooltip));
      await tester.pumpAndSettle();
    }

    Finder rowLine(int i) => find.byType(FormRowLine).at(i);

    testWidgets('칩 바에 한글+약어 칩이 보이고, 행을 고른 뒤 칩 한 번으로 라벨이 붙는다', (tester) async {
      await open(tester, song());
      expect(find.byType(SongFormBar), findsOneWidget);
      expect(find.text('벌스'), findsOneWidget);
      expect(find.text('프리코러스'), findsOneWidget);
      // 순서 줄은 라벨이 없으면 숨는다.
      expect(find.byType(SongFormOrderLine), findsOneWidget);
      expect(find.text('송폼'), findsOneWidget); // 칩 바 머리말만
      await pickRow(tester, 0);
      await chip(tester, '벌스 V');
      expect(
        find.descendant(of: rowLine(0), matching: find.text('V1')),
        findsOneWidget,
      );
      expect(find.text('1행 선택됨'), findsOneWidget);
    });

    testWidgets('행을 안 골랐으면 안내한다', (tester) async {
      await open(tester, song());
      await chip(tester, '코러스 C');
      expect(find.text('먼저 행을 골라 주세요'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('먼저 행을 골라 주세요'), findsNothing);
    });

    testWidgets('저장하면 결과 곡에 송폼이 실린다', (tester) async {
      SongEditResult? result;
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeKind.light.theme,
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async => result = await showDialog(
                  context: context,
                  builder: (_) =>
                      LyricsEditorDialog(song: song(), style: style),
                ),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      await pickRow(tester, 1);
      await chip(tester, '벌스 V');
      await chip(tester, '프리코러스 PC');
      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();
      final saved = result!.$1;
      expect(saved.songForm, isNotNull);
      expect(saved.pairedPages[1].form, 'V1,PC');
      expect(saved.pairedPages[0].form, '');
    });

    testWidgets('순서 줄은 연속 같은 라벨을 ×2 로 줄이고 눌러서 행으로 이동한다', (tester) async {
      await open(tester, song());
      await pickRow(tester, 0);
      await chip(tester, '코러스 C');
      await pickRow(tester, 1);
      await chip(tester, '코러스 C');
      expect(find.text('C ×2'), findsOneWidget);
      await tester.tap(find.text('C ×2'));
      await tester.pumpAndSettle();
      expect(find.text('1행 선택됨'), findsOneWidget);
    });

    testWidgets('같은 가사 다른 페이지 제안 배너와 ⌘Z 되돌리기', (tester) async {
      final s = PraiseSong(
        id: 1,
        fileName: 'a',
        title: '곡',
        lyrics: '후렴\n\n절\n\n후렴',
        englishLyrics: '',
      );
      await open(tester, s);
      await pickRow(tester, 0);
      await chip(tester, '코러스 C');
      expect(find.textContaining('같은 가사 1페이지(3)에도 C 넣기'), findsOneWidget);
      await tester.tap(find.text('넣기'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: rowLine(2), matching: find.text('C')),
        findsOneWidget,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: rowLine(2), matching: find.text('C')),
        findsNothing,
      );
    });

    testWidgets('글이 바뀌어 짝이 안 맞는 페이지만 송폼 확인 칩이 뜨고 라벨은 지워지지 않는다', (tester) async {
      final old = PraiseSong(
        id: 1,
        fileName: 'a',
        title: '곡',
        lyrics: '첫째 줄\n\n옛 둘째\n\n셋째 줄',
        englishLyrics: '',
        songForm: SongForm([
          (key: pageKey('첫째 줄')!, labels: [l(SectionKind.verse, 1)]),
          (key: pageKey('옛 둘째')!, labels: [l(SectionKind.chorus)]),
          (key: pageKey('셋째 줄')!, labels: const <SectionLabel>[]),
        ]),
      );
      // 가사만 바뀐 곡(송폼은 옛 글 기준).
      final changed = old.copyWith(lyrics: '첫째 줄\n\n새 둘째\n\n셋째 줄');
      await open(tester, changed);
      expect(find.text('! 송폼 확인'), findsOneWidget);
      expect(find.text('! 송폼 확인 1'), findsOneWidget); // 순서 줄 옆
      expect(
        find.descendant(of: rowLine(0), matching: find.text('V1')),
        findsOneWidget,
      );
      await tester.tap(find.text('! 송폼 확인').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('숨긴 라벨: C'), findsOneWidget);
      await tester.tap(find.text('이 페이지에 그대로 적용'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: rowLine(1), matching: find.text('C')),
        findsOneWidget,
      );
      expect(find.text('! 송폼 확인'), findsNothing);
    });

    testWidgets('통째로 보기에서 페이지를 끼우거나 지우거나 바꿔도 라벨은 글을 따라간다', (tester) async {
      final withForm = song(
        form: SongForm([
          (key: pageKey('첫째 줄')!, labels: [l(SectionKind.verse, 1)]),
          (key: pageKey('둘째 줄')!, labels: [l(SectionKind.chorus)]),
          (key: pageKey('셋째 줄')!, labels: const <SectionLabel>[]),
        ]),
      );
      Future<void> edit(String text) async {
        await tester.tap(find.text('통째로'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, '첫째 줄\n\n둘째 줄\n\n셋째 줄').first,
          text,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('페이지 표'));
        await tester.pumpAndSettle();
      }

      Finder has(int row, String label) =>
          find.descendant(of: rowLine(row), matching: find.text(label));

      // 맨 앞에 끼우기
      await open(tester, withForm);
      await edit('새 줄\n\n첫째 줄\n\n둘째 줄\n\n셋째 줄');
      expect(has(0, 'V1'), findsNothing);
      expect(has(1, 'V1'), findsOneWidget);
      expect(has(2, 'C'), findsOneWidget);
      expect(find.text('! 송폼 확인'), findsNothing);
    });

    testWidgets('통째로 보기에서 순서를 바꾸면 라벨이 글을 따라간다', (tester) async {
      final withForm = song(
        form: SongForm([
          (key: pageKey('첫째 줄')!, labels: [l(SectionKind.verse, 1)]),
          (key: pageKey('둘째 줄')!, labels: [l(SectionKind.chorus)]),
          (key: pageKey('셋째 줄')!, labels: const <SectionLabel>[]),
        ]),
      );
      await open(tester, withForm);
      await tester.tap(find.text('통째로'));
      await tester.pumpAndSettle();
      final field = find
          .widgetWithText(TextField, '첫째 줄\n\n둘째 줄\n\n셋째 줄')
          .first;
      await tester.enterText(field, '둘째 줄\n\n첫째 줄\n\n셋째 줄');
      await tester.tap(find.text('페이지 표'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: rowLine(0), matching: find.text('C')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: rowLine(1), matching: find.text('V1')),
        findsOneWidget,
      );
    });

    testWidgets('통째로 보기에서 라벨 있는 페이지를 지우면 그 라벨은 송폼 확인으로 숨는다', (tester) async {
      await open(
        tester,
        song(
          form: SongForm([
            (key: pageKey('첫째 줄')!, labels: [l(SectionKind.verse, 1)]),
            (key: pageKey('둘째 줄')!, labels: [l(SectionKind.chorus)]),
            (key: pageKey('셋째 줄')!, labels: const <SectionLabel>[]),
          ]),
        ),
      );
      await tester.tap(find.text('통째로'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '첫째 줄\n\n둘째 줄\n\n셋째 줄').first,
        '첫째 줄\n\n셋째 줄',
      );
      await tester.tap(find.text('페이지 표'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: rowLine(0), matching: find.text('V1')),
        findsOneWidget,
      );
      expect(find.text('! 송폼 확인'), findsWidgets);
    });

    testWidgets('라벨 칩 메뉴에서 번호를 올리고 라벨을 뺄 수 있다', (tester) async {
      await open(tester, song());
      await pickRow(tester, 0);
      await chip(tester, '벌스 V');
      await tester.tap(
        find.descendant(of: rowLine(0), matching: find.text('V1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('번호 늘리기'));
      await tester.pumpAndSettle();
      expect(find.text('송폼 벌스 2'), findsOneWidget);
      await tester.tap(find.text('이 라벨 빼기'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: rowLine(0), matching: find.text('V2')),
        findsNothing,
      );
    });

    testWidgets('직접… 입력은 12자까지, 빈 값은 무시한다', (tester) async {
      await open(tester, song());
      await pickRow(tester, 0);
      await tester.tap(find.text('직접…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '1234567890123456');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: rowLine(0), matching: find.text('123456789012')),
        findsOneWidget,
      );
    });
  });
}
