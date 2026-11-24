import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/page_template_store.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/page_element.dart';
import 'package:worship_slides/src/features/praise/domain/slide_background.dart';
import 'package:worship_slides/src/features/praise/presentation/page_canvas.dart';
import 'package:worship_slides/src/features/praise/presentation/page_editor_dialog.dart';

const _style = ExportStyle(
  fontSize: 30,
  bibleFontSize: 30,
  backgroundColor: Color(0xFF1B1B1B),
  textColor: Colors.white,
  bibleTextColor: Colors.white,
  textPosition: VerticalTextPosition.bottom,
  bibleTextPosition: VerticalTextPosition.middle,
  lyricsTextAlign: HorizontalPosition.center,
  bibleTextAlign: HorizontalPosition.center,
  includeEnglishLyrics: true,
  englishTextColor: Color(0xFFFFF176),
  showSongTitle: true,
  showBibleTitle: false,
  titleFontSize: 14,
  bibleTitleFontSize: 14,
  titleTextColor: Colors.white,
  bibleTitleTextColor: Colors.white,
  titleHorizontalPosition: HorizontalPosition.right,
  titleVerticalPosition: VerticalTextPosition.bottom,
  bibleTitleHorizontalPosition: HorizontalPosition.right,
  bibleTitleVerticalPosition: VerticalTextPosition.bottom,
);

/// 편집 창을 열고 결과를 받아 둔다.
class _Harness {
  List<PageElement>? composed;
  PageEditorResult? result;
}

Future<_Harness> _open(
  WidgetTester tester, {
  List<PageElement>? elements,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            h.result = await showDialog<PageEditorResult>(
              context: context,
              builder: (_) => PageEditorDialog(
                elements: elements,
                background: const SlideBackground(color: Colors.black),
                style: _style,
                compose: (e, _) async {
                  h.composed = e;
                  return '/tmp/render.png';
                },
                readClipboardImage: () async => null,
              ),
            );
          },
          child: const Text('열기'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
  return h;
}

/// 캔버스 위 요소 자리(가운데)의 화면 좌표.
Offset _at(WidgetTester t, Rect r) {
  final box = t.getRect(find.byType(PageCanvas));
  return box.topLeft +
      Offset(r.center.dx * box.width, r.center.dy * box.height);
}

QuillController _quill(WidgetTester t) =>
    t.widget<QuillEditor>(find.byType(QuillEditor)).controller;

/// 글 칸(Quill)의 글을 통째로 바꾼다.
void _typeInQuill(WidgetTester t, String text) {
  final c = _quill(t);
  c.replaceText(0, c.document.length - 1, text, null);
}

void main() {
  const start = Rect.fromLTWH(0.2, 0.2, 0.4, 0.2);

  bool near(Rect a, Rect b) =>
      (a.left - b.left).abs() < 1e-9 &&
      (a.top - b.top).abs() < 1e-9 &&
      (a.width - b.width).abs() < 1e-9 &&
      (a.height - b.height).abs() < 1e-9;

  group('resizePageRect', () {
    test('변 손잡이는 그 변만 움직인다', () {
      final r = resizePageRect(start, PageHandle.right, const Offset(0.1, 0.3));
      expect(near(r, const Rect.fromLTWH(0.2, 0.2, 0.5, 0.2)), isTrue);
      final l = resizePageRect(start, PageHandle.left, const Offset(0.1, 0));
      expect(near(l, const Rect.fromLTWH(0.3, 0.2, 0.3, 0.2)), isTrue);
    });

    test('모서리 비율 유지는 반대쪽 모서리를 붙잡고 비율을 지킨다', () {
      final r = resizePageRect(
        start,
        PageHandle.topLeft,
        const Offset(-0.2, 0),
        keepAspect: true,
      );
      expect(r.width / r.height, closeTo(2, 1e-9));
      expect(r.right, closeTo(start.right, 1e-9));
      expect(r.bottom, closeTo(start.bottom, 1e-9));
      expect(r.width, closeTo(0.6, 1e-9));
    });

    test('비율 풀기(Shift)면 모서리가 두 변을 따로 움직인다', () {
      final r = resizePageRect(
        start,
        PageHandle.bottomRight,
        const Offset(0.1, 0.3),
      );
      expect(near(r, const Rect.fromLTWH(0.2, 0.2, 0.5, 0.5)), isTrue);
    });

    test('반대쪽을 넘겨 끌어도 가장 작은 크기에서 멈춘다', () {
      final r = resizePageRect(start, PageHandle.right, const Offset(-1, 0));
      expect(r.width, closeTo(PageElement.minSize, 1e-9));
      expect(r.left, closeTo(start.left, 1e-9));
    });
  });

  test('새 그림은 원래 비율로 60% 안에 가운데, 다음 장은 3%씩 비킨다', () {
    final r = newImageRect(const Size(3840, 1080), 0);
    expect(r.width, closeTo(0.6, 1e-9));
    expect(r.width * 1920 / (r.height * 1080), closeTo(3840 / 1080, 1e-9));
    expect(r.center.dx, closeTo(0.5, 1e-9));
    final small = newImageRect(const Size(192, 108), 1);
    expect(small.width, closeTo(0.1, 1e-9)); // 키우지 않는다
    expect(small.center.dx, closeTo(0.53, 1e-9));
  });

  test('원래 비율로 = 너비 그대로, 높이를 그림 비율에', () {
    final r = originalAspectRect(start, const Size(1000, 1000));
    expect(r.width, start.width);
    expect(r.width * 1920, closeTo(r.height * 1080, 1e-6));
  });

  test('되돌리기·다시 하기, 새로 바꾸면 다시 하기는 버린다', () {
    final a = <PageElement>[];
    final b = [PageImageElement(id: 'x', rect: start, path: '/a.png')];
    final h = PageEditHistory()..record(a);
    expect(h.undo(b), same(a));
    expect(h.redo(a), same(b));
    h.record(b);
    expect(h.canRedo, isFalse);
    for (var i = 0; i < 60; i++) {
      h.record(a);
    }
    var count = 0;
    while (h.undo(a) != null) {
      count++;
    }
    expect(count, PageEditHistory.limit);
  });

  test('자동 이름 = 첫 글 상자 첫 줄, 없으면 기본 이름', () {
    expect(pageAutoName(const []), '슬라이드 편집 페이지');
    expect(
      pageAutoName([
        PageImageElement(id: 'a', rect: start, path: '/a.png'),
        PageTextElement(id: 'b', rect: start, text: '\n  광고  \n둘째'),
      ]),
      '광고',
    );
  });

  test('새 글 상자는 고른(없으면 마지막) 글 상자 꼴을 이어받는다', () {
    const fancy = PageTextElement(
      id: 'a',
      rect: start,
      fontSize: 72,
      color: Color(0xFFFFF176),
      bold: true,
      align: TextAlign.left,
      fontFamily: 'NanumMyeongjo',
    );
    const plain = PageTextElement(id: 'b', rect: start);
    final image = PageImageElement(id: 'c', rect: start, path: '/a.png');
    bool sameLook(PageTextElement x, PageTextElement y) =>
        x.fontSize == y.fontSize &&
        x.color == y.color &&
        x.bold == y.bold &&
        x.align == y.align &&
        x.fontFamily == y.fontFamily;

    final picked = newTextBox([fancy, plain], 'a', text: '둘째');
    expect(sameLook(picked, fancy), isTrue);
    expect(picked.text, '둘째');
    expect(picked.id, isNot('a'));
    // 그림을 골랐거나 미선택이면 마지막 글 상자.
    expect(sameLook(newTextBox([plain, fancy, image], 'c'), fancy), isTrue);
    expect(sameLook(newTextBox([plain, fancy], null), fancy), isTrue);
    // 글 상자가 없으면 기본값.
    final first = newTextBox([image], null);
    expect(first.fontSize, PageTextElement.defaultFontSize);
    expect(first.color, Colors.white);
    expect(first.align, TextAlign.center);
    expect(first.fontFamily, PageTextElement.defaultFontFamily);
  });

  testWidgets('새 페이지: 제목 글 상자를 바로 고치고 확인하면 굽고 돌려준다', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    List<PageElement>? composed;
    PageEditorResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<PageEditorResult>(
                context: context,
                builder: (_) => PageEditorDialog(
                  style: _style,
                  compose: (elements, _) async {
                    composed = elements;
                    return '/tmp/render.png';
                  },
                  readClipboardImage: () async => null,
                ),
              );
            },
            child: const Text('열기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    // 처음엔 '제목' 글 상자가 골라져 '글' 칸에 들어 있다.
    _typeInQuill(tester, '광고');
    await tester.pump();
    // 글 상자 하나 더 → 빈 글 상자는 확인 때 빠진다.
    await tester.tap(find.byTooltip('글 상자 추가 (고른 글 상자와 같은 글꼴·색)'));
    await tester.pump();
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();

    expect(composed, hasLength(1));
    expect((composed!.single as PageTextElement).text, '광고');
    expect(result?.name, '광고');
    expect(result?.imagePath, '/tmp/render.png');
  });

  testWidgets('편집 중 되돌리기는 글자 단위, 편집을 끝낸 뒤 되돌리기 한 번 = 편집 통째', (tester) async {
    final h = await _open(tester);

    // 새 페이지는 '제목' 글 상자를 바로 편집 중(글 전체가 골라져 있다).
    final c = _quill(tester);
    c.replaceText(0, c.document.length - 1, '광고', null);
    await tester.pump();
    // Quill 은 0.4초 안의 변경을 한 묶음으로 친다(실제 시계).
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    c.formatText(0, 1, Attribute.bold);
    await tester.pump();
    // 편집 중 되돌리기 버튼 = 편집기 안 되돌리기(굵게만 풀린다).
    await tester.tap(find.byTooltip(RegExp('^되돌리기')));
    await tester.pump();
    expect(c.document.toPlainText(), '광고\n');
    expect(
      c.document.toDelta().toJson().any(
        (op) => (op['attributes'] as Map?)?.containsKey('bold') ?? false,
      ),
      isFalse,
    );
    c.formatText(1, 1, Attribute.italic);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(QuillEditor), findsNothing);
    await tester.tap(find.byTooltip(RegExp('^되돌리기')));
    await tester.pump();

    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    final box = h.composed!.single as PageTextElement;
    expect(box.text, '제목');
    expect(box.rich, isNull);
  });

  testWidgets('상자만 고르고 굵게·색 = 글 전체, 같은 속성 직접 지정은 지운다', (tester) async {
    final box = PageTextElement(
      id: 'a',
      rect: const Rect.fromLTWH(0.1, 0.1, 0.6, 0.3),
      text: '광고입니다',
      rich: jsonEncode([
        {
          'insert': '광고',
          'attributes': {'bold': false, 'italic': true, 'color': '#FF0000'},
        },
        {'insert': '입니다\n'},
      ]),
    );
    final h = await _open(tester, elements: [box]);
    await tester.tapAt(_at(tester, box.rect));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(QuillEditor), findsNothing);

    await tester.tap(find.byTooltip(RegExp('^굵게')));
    await tester.pump();
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();

    final out = h.result!.elements.single as PageTextElement;
    expect(out.bold, isTrue);
    final attrs = (jsonDecode(out.rich!) as List).first['attributes'] as Map;
    expect(attrs, {'italic': true, 'color': '#FF0000'});
  });

  testWidgets('편집 중 고른 글자에 굵게 = 그 글자만', (tester) async {
    final box = PageTextElement(
      id: 'a',
      rect: const Rect.fromLTWH(0.1, 0.1, 0.6, 0.3),
      text: '광고입니다',
    );
    final h = await _open(tester, elements: [box]);
    await tester.tapAt(_at(tester, box.rect));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();
    final c = _quill(tester);
    c.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      ChangeSource.local,
    );
    await tester.pump();
    await tester.tap(find.byTooltip(RegExp('^굵게')));
    await tester.pump();
    // 리본을 눌러도 편집은 이어진다.
    expect(find.byType(QuillEditor), findsOneWidget);
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();

    final out = h.result!.elements.single as PageTextElement;
    expect(out.bold, isFalse);
    expect(jsonDecode(out.rich!), [
      {
        'insert': '광고',
        'attributes': {'bold': true},
      },
      {'insert': '입니다\n'},
    ]);
  });

  testWidgets('더블클릭 = 그 자리 편집, 편집 중 지우기는 글자만, ESC 한 번 = 편집 끝·두 번 = 해제', (
    tester,
  ) async {
    final box = PageTextElement(
      id: 'a',
      rect: const Rect.fromLTWH(0.1, 0.1, 0.8, 0.3),
      text: '가나다라마바사',
    );
    final h = await _open(tester, elements: [box]);
    final point = _at(tester, box.rect);
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(point);
    await tester.pumpAndSettle();

    expect(find.byType(QuillEditor), findsOneWidget);
    expect(_quill(tester).selection.isCollapsed, isTrue);
    // 누른 자리(가운데쯤)에 커서 — 글 끝이 아니다.
    expect(_quill(tester).selection.baseOffset, inInclusiveRange(1, 6));
    // 오른쪽 패널에 글 입력칸이 없다.
    expect(find.byType(QuillEditor), findsOneWidget);
    expect(find.text('위치·크기 (1920×1080 기준)'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(
      _quill(tester).document.toPlainText().length,
      '가나다라마바사\n'.length - 2,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(QuillEditor), findsNothing);
    expect(find.text('위치·크기 (1920×1080 기준)'), findsOneWidget); // 상자는 고른 채
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('페이지 이름'), findsOneWidget);

    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect((h.result!.elements.single as PageTextElement).text.length, 5);
  });

  testWidgets('상자를 고른 채 글자를 치면 편집만 시작하고(글자는 안 넣음 — 한글 입력기), 편집 밖 Delete 는 상자를 지운다', (
    tester,
  ) async {
    final a = PageTextElement(
      id: 'a',
      rect: const Rect.fromLTWH(0.1, 0.1, 0.4, 0.2),
      text: '광고',
    );
    final b = PageTextElement(
      id: 'b',
      rect: const Rect.fromLTWH(0.1, 0.6, 0.4, 0.2),
      text: '지울 것',
    );
    final h = await _open(tester, elements: [a, b]);
    await tester.tapAt(_at(tester, a.rect));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(find.byType(QuillEditor), findsOneWidget);
    expect(_quill(tester).document.toPlainText(), '광고\n');
    expect(_quill(tester).selection.baseOffset, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    await tester.tapAt(_at(tester, b.rect));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(h.result!.elements.map((e) => (e as PageTextElement).text), ['광고']);
  });

  testWidgets('아무것도 안 고르면 글자 서식 줄은 비활성, 골라도 캔버스 위치는 그대로', (tester) async {
    final box = PageTextElement(
      id: 'a',
      rect: const Rect.fromLTWH(0.1, 0.1, 0.6, 0.3),
      text: '광고',
    );
    await _open(tester, elements: [box]);
    expect(find.text('글 상자나 도형을 고르면 쓸 수 있습니다.'), findsOneWidget);
    IconButton bold() => tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.format_bold_rounded),
        matching: find.byType(IconButton),
      ),
    );
    expect(bold().onPressed, isNull);
    final top = tester.getTopLeft(find.byType(PageCanvas)).dy;

    await tester.tapAt(_at(tester, box.rect));
    await tester.pump(const Duration(milliseconds: 500));
    expect(bold().onPressed, isNotNull);
    expect(find.text('글 상자나 도형을 고르면 쓸 수 있습니다.'), findsNothing);
    expect(tester.getTopLeft(find.byType(PageCanvas)).dy, top);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byType(QuillEditor), findsOneWidget);
    expect(tester.getTopLeft(find.byType(PageCanvas)).dy, top);
  });

  testWidgets(
    'Shift+클릭으로 여러 개: 손잡이 없이 함께 끌고, Delete 로 함께 지우고, 되돌리기 한 번에 되살린다',
    (tester) async {
      final elements = [
        for (final (id, x) in [('a', 0.05), ('b', 0.4), ('c', 0.7)])
          PageTextElement(
            id: id,
            rect: Rect.fromLTWH(x, 0.4, 0.2, 0.2),
            text: id,
          ),
      ];
      final h = await _open(tester, elements: elements);
      Finder handles() => find.byWidgetPredicate(
        (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeUpDown,
      );

      await tester.tapAt(_at(tester, elements[0].rect));
      await tester.pump(const Duration(milliseconds: 500));
      expect(handles(), findsWidgets);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      for (final e in elements.skip(1)) {
        await tester.tapAt(_at(tester, e.rect));
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(find.text('요소 3개를 골랐습니다'), findsOneWidget);
      expect(handles(), findsNothing);

      final canvas = tester.getRect(find.byType(PageCanvas));
      await tester.dragFrom(
        _at(tester, elements[1].rect),
        Offset(canvas.width * 0.1, 0),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(find.text('페이지 이름'), findsOneWidget);
      await tester.tap(find.byTooltip(RegExp('^되돌리기')));
      await tester.pump();
      await tester.tap(find.text('확인'));
      await tester.pumpAndSettle();

      final out = h.result!.elements;
      expect(out.map((e) => e.id), ['a', 'b', 'c']);
      for (var i = 0; i < 3; i++) {
        // 끈 거리(드래그 시작 문턱만큼 덜 갈 수 있다)만큼 셋 다 같이 옮겨졌다.
        expect(out[i].rect.left - elements[i].rect.left, closeTo(0.1, 0.02));
        expect(
          out[i].rect.left - elements[i].rect.left,
          closeTo(out[0].rect.left - elements[0].rect.left, 1e-9),
        );
      }
    },
  );

  test('순서 바꾸기: 고른 것끼리 순서를 지킨다', () {
    final list = [
      for (final id in ['a', 'b', 'c', 'd'])
        PageTextElement(id: id, rect: start),
    ];
    List<String> ids(PageOrder o, Set<String> picked) =>
        reorderPageElements(list, picked, o).map((e) => e.id).toList();
    expect(ids(PageOrder.toFront, {'a', 'c'}), ['b', 'd', 'a', 'c']);
    expect(ids(PageOrder.toBack, {'b', 'd'}), ['b', 'd', 'a', 'c']);
    expect(ids(PageOrder.forward, {'a', 'b'}), ['c', 'a', 'b', 'd']);
    expect(ids(PageOrder.backward, {'c', 'd'}), ['a', 'c', 'd', 'b']);
    expect(ids(PageOrder.forward, {'d'}), ['a', 'b', 'c', 'd']);
  });

  testWidgets('모르는 종류 요소는 그리지·고르지 않지만 확인하면 그대로 돌려준다', (tester) async {
    final unknown =
        PageElement.fromJson({
              'type': 'table',
              'id': 's',
              'rect': [0, 0.5, 1, 0],
              'shape': 'line',
            })
            as PageUnknownElement;
    final text = PageTextElement(
      id: 't',
      rect: const Rect.fromLTWH(0.1, 0.1, 0.5, 0.2),
      text: '글',
    );
    final h = await _open(tester, elements: [unknown, text]);
    // Tab 으로 돌아도 모르는 요소는 건너뛴다.
    await tester.tapAt(_at(tester, text.rect));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(find.text('위치·크기 (1920×1080 기준)'), findsOneWidget);
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(h.result!.elements, [unknown, text]);
    expect(h.composed, [unknown, text]);
    expect(
      jsonEncode(h.result!.elements.first.toJson()),
      jsonEncode(unknown.raw),
    );
  });

  testWidgets('클립보드 그림 읽기가 실패해도 글자가 있으면 글 상자로 넣는다', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, dynamic>{'text': '  알림  '}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PageEditorDialog(
          style: _style,
          compose: (_, _) async => '/tmp/render.png',
          readClipboardImage: () async => throw Exception('ppt_tool 실패'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('붙여 넣기 (⌘V / Ctrl+V)'));
    // 로그 쓰기(실제 파일 IO)가 끝나도록 진짜 시간으로 기다린다.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('클립보드 그림을 읽지 못했습니다'), findsNothing);
    expect(_quill(tester).document.toPlainText(), '알림\n');
  });

  testWidgets('틀 배경 칩: 누르면 배경 색만 바뀌고 글 상자는 그대로', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const red = Color(0xFFCC2200);
    final PageTemplate template = (
      id: 't1',
      name: '주일 광고',
      design: const SlideBackground(color: red, pageElements: []),
      previewPath: null,
    );
    final box = PageTextElement(
      id: 'a',
      rect: const Rect.fromLTWH(0.1, 0.1, 0.5, 0.2),
      text: '광고',
    );
    PageEditorResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<PageEditorResult>(
                context: context,
                builder: (_) => PageEditorDialog(
                  elements: [box],
                  background: const SlideBackground(color: Colors.black),
                  style: _style,
                  compose: (_, _) async => '/tmp/render.png',
                  readClipboardImage: () async => null,
                  templates: [template],
                ),
              );
            },
            child: const Text('열기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    expect(find.text('틀 배경'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);
    await tester.tap(find.widgetWithText(ActionChip, '주일 광고'));
    await tester.pump();
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();

    expect(result?.background.color, red);
    expect(result?.elements, [box]);
  });

  testWidgets('틀이 없으면 틀 배경 줄이 없다', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: PageEditorDialog(
          elements: const [],
          style: _style,
          compose: (_, _) async => '/tmp/render.png',
          readClipboardImage: () async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('페이지 배경'), findsOneWidget);
    expect(find.text('틀 배경'), findsNothing);
  });

  testWidgets('틀 편집: 이름 칸은 틀 이름, 칩 없음, 빈 글 상자도 남긴다', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final elements = [
      PageTextElement(
        id: 'a',
        rect: const Rect.fromLTWH(0.1, 0.1, 0.5, 0.2),
        text: '생일을 축하합니다',
      ),
      PageTextElement(id: 'b', rect: const Rect.fromLTWH(0.1, 0.4, 0.5, 0.2)),
    ];
    List<PageElement>? composed;
    PageEditorResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<PageEditorResult>(
                context: context,
                builder: (_) => PageEditorDialog(
                  name: '생일자',
                  elements: elements,
                  style: _style,
                  compose: (e, _) async {
                    composed = e;
                    return '/tmp/render.png';
                  },
                  readClipboardImage: () async => null,
                  templates: defaultPageTemplates(_style),
                  templateMode: true,
                ),
              );
            },
            child: const Text('열기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    expect(find.text('틀 편집'), findsOneWidget);
    expect(find.widgetWithText(TextField, '틀 이름'), findsOneWidget);
    expect(find.text('틀 배경'), findsNothing);
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();

    expect(composed, hasLength(1));
    expect(result?.elements, elements);
    expect(result?.name, '생일자');
  });

  testWidgets('틀로 새로 넣기: 새 페이지 제목, 첫 빈 글 상자가 골라져 바로 입력', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    List<PageElement>? composed;
    await tester.pumpWidget(
      MaterialApp(
        home: PageEditorDialog(
          name: '주일 광고',
          elements: [
            PageTextElement(
              id: 'a',
              rect: const Rect.fromLTWH(0.1, 0.1, 0.5, 0.2),
              text: '주일 광고',
            ),
            PageTextElement(
              id: 'b',
              rect: const Rect.fromLTWH(0.1, 0.4, 0.5, 0.2),
            ),
          ],
          style: _style,
          compose: (e, _) async {
            composed = e;
            return '/tmp/render.png';
          },
          readClipboardImage: () async => null,
          isNew: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('슬라이드 편집 페이지'), findsOneWidget);
    expect(find.text('슬라이드 편집 페이지 수정'), findsNothing);
    expect(
      tester.widget<QuillEditor>(find.byType(QuillEditor)).focusNode.hasFocus,
      isTrue,
    );
    _typeInQuill(tester, '수요 예배 안내');
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();

    expect(composed!.whereType<PageTextElement>().map((e) => (e.id, e.text)), [
      ('a', '주일 광고'),
      ('b', '수요 예배 안내'),
    ]);
  });
}
