import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/page_element.dart';
import 'package:worship_slides/src/features/praise/domain/slide_background.dart';
import 'package:worship_slides/src/features/praise/presentation/lyrics_overlay_renderer.dart';
import 'package:worship_slides/src/features/praise/presentation/page_canvas.dart';
import 'package:worship_slides/src/features/praise/presentation/page_editor_dialog.dart';
import 'package:worship_slides/src/features/praise/presentation/page_editor_ribbon.dart';

// 2단계 도형: 모델(JSON·clamp·선 끝점), 굽기 픽셀, 편집 창(넣기·서식·안 글·끝점·범위 고르기·맞춤).

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

class _Harness {
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
                compose: (e, _) async => '/tmp/render.png',
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

/// 캔버스 위 슬라이드 비율 좌표의 화면 좌표.
Offset _point(WidgetTester t, Offset p) {
  final box = t.getRect(find.byType(PageCanvas));
  return box.topLeft + Offset(p.dx * box.width, p.dy * box.height);
}

Future<void> _confirm(WidgetTester t) async {
  await t.tap(find.text('확인'));
  await t.pumpAndSettle();
}

Future<Color> _pixelAt(ui.Image image, int x, int y) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final b = data!.buffer.asUint8List();
  final o = (y * image.width + x) * 4;
  return Color.fromARGB(b[o + 3], b[o], b[o + 1], b[o + 2]);
}

void main() {
  const box = Rect.fromLTWH(0.1, 0.2, 0.3, 0.4);

  group('모델', () {
    // 1단계 이전 앱의 PageElement.fromJson 은 type 'image'·'text' 만 알고 나머지는 null(버림)이었다.
    // 도형이 'text' 로 저장되면 옛 앱이 도형을 글 상자로 잘못 읽으므로 type 이 늘 'shape' 여야 한다.
    test('옛 앱 파서(image·text 만 앎)로 읽으면 도형만 빠진다', () {
      final elements = <PageElement>[
        const PageTextElement(id: 't', rect: box, text: '글'),
        for (final k in PageShapeKind.values)
          PageShapeElement(id: k.name, rect: box, kind: k, text: '안 글'),
      ];
      final json = jsonDecode(
        jsonEncode([for (final e in elements) e.toJson()]),
      ) as List;
      final oldKept = json
          .where((e) => e['type'] == 'image' || e['type'] == 'text')
          .map((e) => e['id'])
          .toList();
      expect(oldKept, ['t']);
    });

    test('도형 JSON 왕복(plan 키 이름)', () {
      final shape = PageShapeElement(
        id: 's',
        rect: box,
        kind: PageShapeKind.roundRect,
        fill: const Color(0xFF112233),
        fillAlpha: 0.5,
        stroke: const Color(0xFFFFFFFF),
        strokeWidth: 4,
        radius: 0.25,
        text: '안녕',
        valign: PageVAlign.bottom,
      );
      final json = shape.toJson();
      expect(json['type'], 'shape');
      expect(json['shape'], 'round_rect');
      expect(json['fill'], '#112233');
      expect(json['fill_alpha'], 0.5);
      expect(json['stroke'], '#FFFFFF');
      expect(json['stroke_width'], 4);
      expect(json['radius'], 0.25);
      expect(json['valign'], 'bottom');
      expect(json['flip_h'], false);
      final back = PageElement.fromJson(jsonDecode(jsonEncode(json)));
      expect(back, shape);
      expect(back, isA<PageShapeElement>());
    });

    test('채우기·테두리 null 은 없음, 키가 없으면 기본값(흰 채우기·테두리 없음·검정 글·세로 가운데)', () {
      final none =
          PageElement.fromJson({
                'type': 'shape',
                'rect': [0, 0, 0.5, 0.5],
                'shape': 'ellipse',
                'fill': null,
                'stroke': null,
              })
              as PageShapeElement;
      expect(none.fill, isNull);
      expect(none.stroke, isNull);
      final plain =
          PageElement.fromJson({
                'type': 'shape',
                'rect': [0, 0, 0.5, 0.5],
              })
              as PageShapeElement;
      expect(plain.kind, PageShapeKind.rect);
      expect(plain.fill, Colors.white);
      expect(plain.stroke, isNull);
      expect(plain.color, Colors.black);
      expect(plain.valign, PageVAlign.middle);
    });

    test('틀린 값: 모르는 shape → 사각형, 숫자는 범위 안, 틀린 색은 기본, rect 없음 → 버림', () {
      final s =
          PageElement.fromJson({
                'type': 'shape',
                'rect': [0, 0, 0.5, 0.5],
                'shape': 'star',
                'fill': 'zzz',
                'fill_alpha': 7,
                'stroke_width': 999,
                'radius': -1,
                'valign': 'sideways',
              })
              as PageShapeElement;
      expect(s.kind, PageShapeKind.rect);
      expect(s.fill, Colors.white);
      expect(s.fillAlpha, 1);
      expect(s.strokeWidth, PageShapeElement.maxStrokeWidth);
      expect(s.radius, 0);
      expect(s.valign, PageVAlign.middle);
      expect(PageElement.fromJson({'type': 'shape', 'shape': 'rect'}), isNull);
      // 사각형은 높이 0 을 받지 않는다(선만 예외).
      expect(
        PageElement.fromJson({
          'type': 'shape',
          'rect': [0, 0, 0.5, 0],
        }),
        isNull,
      );
    });

    test('선은 높이 0 을 그대로 둔다(clamp 예외), 둘 다 0 이나 음수는 버림', () {
      final line =
          PageElement.fromJson({
                'type': 'shape',
                'rect': [0.1, 0.5, 0.3, 0],
                'shape': 'line',
              })
              as PageShapeElement;
      expect(line.rect.height, 0);
      expect(line.holdsText, isFalse);
      expect(
        PageElement.fromJson({
          'type': 'shape',
          'rect': [0.1, 0.5, 0, 0],
          'shape': 'arrow',
        }),
        isNull,
      );
      expect(
        PageElement.fromJson({
          'type': 'shape',
          'rect': [0.1, 0.5, 0.3, -0.1],
          'shape': 'line',
        }),
        isNull,
      );
      // 끌어 옮겨도(fitRect) 가로선은 가로선, 사각형은 최소 크기.
      expect(line.fitRect(line.rect.shift(const Offset(0.1, 0))).height, 0);
      final rect = PageShapeElement(
        id: 'r',
        rect: box,
        kind: PageShapeKind.rect,
      );
      expect(
        rect.fitRect(const Rect.fromLTWH(0, 0, 0.3, 0)).height,
        PageElement.minSize,
      );
    });

    test('선 끝점: 네 방향 flip 왕복', () {
      final line = PageShapeElement(
        id: 'l',
        rect: box,
        kind: PageShapeKind.arrow,
      );
      for (final (a, b) in const [
        (Offset(0.1, 0.2), Offset(0.4, 0.6)),
        (Offset(0.4, 0.2), Offset(0.1, 0.6)),
        (Offset(0.1, 0.6), Offset(0.4, 0.2)),
        (Offset(0.4, 0.6), Offset(0.1, 0.2)),
      ]) {
        final moved = line.withLinePoints(a, b);
        final (s, e) = moved.linePoints;
        expect((s - a).distance, lessThan(1e-9));
        expect((e - b).distance, lessThan(1e-9));
        expect(PageElement.fromJson(moved.toJson()), moved);
      }
    });

    test('valign 없는 옛 글 상자 JSON 은 top, top 은 JSON 에 안 쓴다(옛 굽기 캐시 키 그대로)', () {
      final old =
          PageElement.fromJson({
                'type': 'text',
                'rect': [0, 0, 0.5, 0.2],
                'text': '옛 글',
              })
              as PageTextElement;
      expect(old.valign, PageVAlign.top);
      expect(old.toJson().containsKey('valign'), isFalse);
      final mid = old.copyWith(valign: PageVAlign.middle);
      expect(mid.toJson()['valign'], 'middle');
      expect(PageElement.fromJson(mid.toJson()), mid);
      // 글 상자와 같은 칸의 도형은 같지 않다.
      expect(
        old ==
            PageShapeElement.withText(
              old,
              kind: PageShapeKind.rect,
              fill: null,
            ),
        isFalse,
      );
    });

    test('도형은 이제 아는 종류 — 그 밖의 새 type 만 PageUnknownElement 로 보존', () {
      final list = PageElement.listFromJson([
        {
          'type': 'shape',
          'rect': [0.1, 0.5, 0.3, 0],
          'shape': 'line',
        },
        {
          'type': 'table',
          'rect': [0, 0, 0.5, 0.5],
          'rows': 3,
        },
      ]);
      expect(list[0], isA<PageShapeElement>());
      expect(list[1], isA<PageUnknownElement>());
    });

    test('도형이 든 배경 JSON(콘티 저장·.wsconti·틀 공용)이 그대로 돌아온다', () {
      final bg = SlideBackground(
        color: Colors.black,
        pageElements: [
          PageShapeElement(
            id: 's',
            rect: box,
            kind: PageShapeKind.ellipse,
            text: '말씀',
            rich:
                '[{"insert":"말씀","attributes":{"bold":true}},{"insert":"\\n"}]',
          ),
          PageShapeElement(
            id: 'l',
            rect: const Rect.fromLTWH(0.1, 0.8, 0.5, 0),
            kind: PageShapeKind.line,
            stroke: Colors.white,
          ),
        ],
      );
      expect(SlideBackground.fromJson(jsonDecode(jsonEncode(bg.toJson()))), bg);
    });

    test('newShape: 가운데·선은 가로선, 마지막 도형 서식을 이어받는다', () {
      final first = newShape(const [], null, PageShapeKind.rect);
      expect(first.fill, Colors.white);
      expect(first.stroke, isNull);
      expect(first.color, Colors.black);
      expect(first.fontSize, 40);
      expect(first.align, TextAlign.center);
      expect(first.valign, PageVAlign.middle);
      expect(first.rect.center.dx, closeTo(0.5, 1e-9));
      expect(first.rect.center.dy, closeTo(0.5, 1e-9));
      final line = newShape(const [], null, PageShapeKind.line);
      expect(line.rect.height, 0);
      expect(line.stroke, isNotNull);
      final styled = first.copyWith(
        fill: const Color(0xFF223344),
        stroke: const Color(0xFFAABBCC),
        strokeWidth: 8,
        fontSize: 60,
      );
      final next = newShape([styled], null, PageShapeKind.ellipse);
      expect(next.fill, const Color(0xFF223344));
      expect(next.stroke, const Color(0xFFAABBCC));
      expect(next.strokeWidth, 8);
      expect(next.fontSize, 60);
      expect(next.kind, PageShapeKind.ellipse);
      // 새 글 상자는 도형 서식을 이어받지 않는다.
      expect(newTextBox([styled], styled.id).fontSize, 40);
    });

    test('applyShapeFormat: 선은 채우기·세로 맞춤·테두리 없음을 무시', () {
      final line = newShape(const [], null, PageShapeKind.line);
      expect(applyShapeFormat(line, 'fill', null), line);
      expect(applyShapeFormat(line, 'stroke', null), line);
      expect(applyShapeFormat(line, 'stroke_width', 6.0).strokeWidth, 6);
      final rect = newShape(const [], null, PageShapeKind.rect);
      expect(applyShapeFormat(rect, 'fill', null).fill, isNull);
      expect(
        applyShapeFormat(rect, 'valign', PageVAlign.top).valign,
        PageVAlign.top,
      );
    });

    test('범위 고르기·맞춤 순수 함수', () {
      final a = PageShapeElement(
        id: 'a',
        rect: const Rect.fromLTWH(0.1, 0.1, 0.2, 0.2),
        kind: PageShapeKind.rect,
      );
      final b = PageTextElement(
        id: 'b',
        rect: const Rect.fromLTWH(0.5, 0.5, 0.2, 0.1),
      );
      final line = PageShapeElement(
        id: 'l',
        rect: const Rect.fromLTWH(0.1, 0.8, 0.3, 0),
        kind: PageShapeKind.line,
      );
      final all = <PageElement>[a, b, line];
      expect(pageElementsInRange(all, const Rect.fromLTRB(0, 0, 0.35, 0.35)), [
        'a',
      ]);
      expect(pageElementsInRange(all, const Rect.fromLTRB(0, 0.75, 1, 0.85)), [
        'l',
      ]);
      // 하나 = 슬라이드 기준.
      final one = alignPageElements(all, {'a'}, PageAlign.center);
      expect(one[0].rect.center.dx, closeTo(0.5, 1e-9));
      // 여럿 = 고른 범위 기준(a 왼쪽 0.1 ~ b 오른쪽 0.7, 가운데 0.4).
      final many = alignPageElements(all, {'a', 'b'}, PageAlign.center);
      expect(many[0].rect.center.dx, closeTo(0.4, 1e-9));
      expect(many[1].rect.center.dx, closeTo(0.4, 1e-9));
      final bottom = alignPageElements(all, {'a', 'b'}, PageAlign.bottom);
      expect(bottom[0].rect.bottom, closeTo(0.6, 1e-9));
      expect(bottom[2], line);
      // 선은 맞춰도 가로선 그대로.
      final lineMid = alignPageElements(all, {'l'}, PageAlign.middle);
      expect(lineMid[2].rect.height, 0);
      expect(lineMid[2].rect.top, closeTo(0.5, 1e-9));
    });
  });

  testWidgets('굽기: 채우기·테두리·투명도·선이 그 자리에 찍힌다(편집 캔버스와 같은 위젯)', (tester) async {
    await tester.runAsync(() async {
      const navy = Color(0xFF0B132B);
      const red = Color(0xFFFF0000);
      const blue = Color(0xFF0000FF);
      final shot = await renderWidgetToImage(
        PageCanvas(
          backgroundColor: navy,
          elements: [
            // x 192~768, y 108~540, 테두리 20pt = 40px 안쪽.
            const PageShapeElement(
              id: 'r',
              rect: Rect.fromLTWH(0.1, 0.1, 0.3, 0.4),
              kind: PageShapeKind.rect,
              fill: red,
              stroke: blue,
              strokeWidth: 20,
            ),
            const PageShapeElement(
              id: 'none',
              rect: Rect.fromLTWH(0.5, 0.1, 0.2, 0.2),
              kind: PageShapeKind.ellipse,
              fill: null,
            ),
            const PageShapeElement(
              id: 'half',
              rect: Rect.fromLTWH(0.75, 0.1, 0.2, 0.2),
              kind: PageShapeKind.rect,
              fill: Colors.white,
              fillAlpha: 0.5,
            ),
            // y = 864 가로선, 두께 10pt = 20px.
            const PageShapeElement(
              id: 'l',
              rect: Rect.fromLTWH(0.1, 0.8, 0.5, 0),
              kind: PageShapeKind.line,
              stroke: Colors.white,
              strokeWidth: 10,
            ),
          ],
        ),
        const Size(PageCanvas.width, PageCanvas.height),
      );
      expect(await _pixelAt(shot, 480, 324), red);
      expect(await _pixelAt(shot, 200, 324), blue);
      expect(await _pixelAt(shot, 150, 324), navy);
      expect(await _pixelAt(shot, 1150, 216), navy);
      final half = await _pixelAt(shot, 1632, 216);
      expect(half.r, closeTo((1 + navy.r) / 2, 0.02));
      expect(await _pixelAt(shot, 600, 864), Colors.white);
      expect(await _pixelAt(shot, 600, 890), navy);
      shot.dispose();
    });
  });

  testWidgets('도형 메뉴로 넣기 → 도형 서식 줄 → 채우기 없음·두께 비활성 → 안에 글 쓰기', (tester) async {
    final h = await _open(tester, elements: const []);
    expect(find.text('글 상자나 도형을 고르면 쓸 수 있습니다.'), findsOneWidget);
    await tester.tap(find.byTooltip('도형 넣기'));
    await tester.pumpAndSettle();
    for (final k in PageShapeKind.values) {
      expect(find.text(k.label), findsOneWidget);
    }
    await tester.tap(find.text('타원'));
    await tester.pumpAndSettle();
    expect(find.text('도형 서식'), findsOneWidget);
    PopupMenuButton<double> width() => tester.widget(
      find.byWidgetPredicate(
        (w) => w is PopupMenuButton<double> && w.tooltip == '테두리 두께',
      ),
    );
    expect(width().enabled, isFalse); // 테두리 없음
    expect(find.byTooltip('채우기 색'), findsOneWidget);

    // 채우기 없음.
    await tester.tap(find.byTooltip('채우기 색'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('채우기 없음'));
    await tester.pumpAndSettle();
    // 세로 맞춤 위.
    await tester.tap(find.byTooltip('위에 맞춤'));
    await tester.pump();

    // Enter = 안에 글 쓰기.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byType(QuillEditor), findsOneWidget);
    final c = tester.widget<QuillEditor>(find.byType(QuillEditor)).controller;
    c.replaceText(0, c.document.length - 1, '말씀', null);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await _confirm(tester);

    final shape = h.result!.elements.single as PageShapeElement;
    expect(shape.kind, PageShapeKind.ellipse);
    expect(shape.fill, isNull);
    expect(shape.valign, PageVAlign.top);
    expect(shape.text, '말씀');
    expect(h.result!.name, '말씀');
  });

  testWidgets('선: 더블클릭해도 편집 안 됨, 끝점 손잡이로 방향·길이를 바꾼다', (tester) async {
    const line = PageShapeElement(
      id: 'l',
      rect: Rect.fromLTWH(0.2, 0.5, 0.4, 0),
      kind: PageShapeKind.line,
      stroke: Colors.white,
    );
    final h = await _open(tester, elements: const [line]);
    final mid = _point(tester, const Offset(0.4, 0.5));
    await tester.tapAt(mid);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(mid);
    await tester.pumpAndSettle();
    expect(find.byType(QuillEditor), findsNothing);
    expect(find.text('도형 서식'), findsOneWidget);
    // 양 끝 손잡이 2개, 상자 손잡이 없음.
    expect(find.byKey(const ValueKey('page-line-end-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('page-line-end-1')), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeUpDown,
      ),
      findsNothing,
    );

    final canvas = tester.getRect(find.byType(PageCanvas));
    final end = tester.getCenter(find.byKey(const ValueKey('page-line-end-1')));
    final gesture = await tester.startGesture(end);
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(Offset(0, canvas.height * 0.02));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    await _confirm(tester);

    final out = h.result!.elements.single as PageShapeElement;
    final (a, b) = out.linePoints;
    expect(a.dx, closeTo(0.2, 0.01));
    expect(a.dy, closeTo(0.5, 0.01));
    // 끌기 문턱만큼 덜 갈 수 있다.
    expect(b.dy, closeTo(0.7, 0.05));
    expect(b.dx, closeTo(0.6, 0.01));
    expect(out.flipV, isFalse);
  });

  testWidgets('빈 곳 끌기 = 범위로 고르기, 맞춤 가운데 = 고른 범위 기준', (tester) async {
    final elements = [
      PageShapeElement(
        id: 'a',
        rect: const Rect.fromLTWH(0.1, 0.1, 0.1, 0.1),
        kind: PageShapeKind.rect,
      ),
      PageTextElement(
        id: 'b',
        rect: const Rect.fromLTWH(0.3, 0.3, 0.2, 0.1),
        text: '글',
      ),
      PageShapeElement(
        id: 'c',
        rect: const Rect.fromLTWH(0.8, 0.8, 0.1, 0.1),
        kind: PageShapeKind.rect,
      ),
    ];
    final h = await _open(tester, elements: elements);
    final from = _point(tester, const Offset(0.05, 0.05));
    final to = _point(tester, const Offset(0.6, 0.6));
    final gesture = await tester.startGesture(from);
    await gesture.moveBy((to - from) / 2);
    await gesture.moveTo(to);
    await gesture.up();
    await tester.pump();
    expect(find.text('요소 2개를 골랐습니다'), findsOneWidget);
    // 글 상자와 도형을 같이 고르면 글자 서식만.
    expect(find.text('도형 서식'), findsNothing);

    await tester.tap(find.byTooltip('맞춤'));
    await tester.pumpAndSettle();
    expect(find.text('고른 요소 2개 기준'), findsOneWidget);
    await tester.tap(find.text('가운데 맞춤'));
    await tester.pumpAndSettle();
    await _confirm(tester);

    final out = {for (final e in h.result!.elements) e.id: e.rect};
    // 범위 0.1 ~ 0.5 → 가운데 0.3.
    expect(out['a']!.center.dx, closeTo(0.3, 1e-9));
    expect(out['b']!.center.dx, closeTo(0.3, 1e-9));
    expect(out['c'], elements[2].rect);
  });
}
