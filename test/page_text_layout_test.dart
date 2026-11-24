import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/page_element.dart';
import 'package:worship_slides/src/features/praise/presentation/page_canvas.dart';
import 'package:worship_slides/src/features/praise/presentation/page_rich_text.dart';
import 'package:worship_slides/src/features/praise/presentation/page_text_editor.dart';

/// 캔버스 안 편집기(Quill)와 굽기(PageTextBlock)가 같은 자리에 같은 줄로 글을 놓는지.
/// 글자(RenderParagraph)마다 화면 위치·크기·줄 수를 비교한다.
void main() {
  setUpAll(() async {
    for (final (family, files) in [
      ('Pretendard', ['Pretendard-Regular', 'Pretendard-Bold']),
      ('NanumMyeongjo', ['NanumMyeongjo-Regular', 'NanumMyeongjo-Bold']),
    ]) {
      final loader = FontLoader(family);
      for (final f in files) {
        loader.addFont(
          Future.value(
            ByteData.sublistView(File('assets/fonts/$f.ttf').readAsBytesSync()),
          ),
        );
      }
      await loader.load();
    }
  });

  List<(String, Rect, int)> paragraphs(WidgetTester t) {
    final out = <(String, Rect, int)>[];
    void visit(RenderObject o) {
      if (o is RenderParagraph) {
        final topLeft = o.localToGlobal(Offset.zero);
        out.add((
          o.text.toPlainText(),
          topLeft & o.size,
          // 줄마다 첫 글자 위치(줄바꿈 자리)를 센다 — 높이만 같고 바꾼 자리가 다른 것을 잡는다.
          o
              .getBoxesForSelection(
                TextSelection(
                  baseOffset: 0,
                  extentOffset: o.text.toPlainText().length,
                ),
              )
              .map((b) => b.top.round())
              .toSet()
              .length,
        ));
      }
      o.visitChildren(visit);
    }

    visit(t.renderObject(find.byType(PageCanvas)));
    out.sort(
      (a, b) => a.$2.top != b.$2.top
          ? a.$2.top.compareTo(b.$2.top)
          : a.$2.left.compareTo(b.$2.left),
    );
    return out;
  }

  Future<void> expectSameLayout(WidgetTester t, PageTextElement e) async {
    t.view.physicalSize = const Size(1000, 600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    Widget host(Widget canvas) => MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 960, height: 540, child: canvas),
      ),
    );

    await t.pumpWidget(
      host(PageCanvas(elements: [e], backgroundColor: Colors.black)),
    );
    final baked = paragraphs(t);

    final controller = QuillController(
      document: pageEditorDocument(e),
      selection: const TextSelection.collapsed(offset: 0),
    );
    final focus = FocusNode();
    final scroll = ScrollController();
    addTearDown(() {
      controller.dispose();
      focus.dispose();
      scroll.dispose();
    });
    await t.pumpWidget(
      host(
        PageCanvas(
          elements: [e],
          backgroundColor: Colors.black,
          editingId: e.id,
          editor: PageTextEditor(
            element: e,
            fontScale: PageCanvas.fontScale,
            controller: controller,
            focusNode: focus,
            scrollController: scroll,
            editorKey: GlobalKey<EditorState>(),
            onExit: () {},
            onFormat: (_) {},
          ),
        ),
      ),
    );
    await t.pump();
    final edited = paragraphs(t);

    expect(find.byType(QuillEditor), findsOneWidget);
    expect(edited.map((p) => p.$1), baked.map((p) => p.$1));
    for (var i = 0; i < baked.length; i++) {
      final (text, a, lines) = baked[i];
      final (_, b, editLines) = edited[i];
      expect(editLines, lines, reason: '줄 수: $text');
      for (final (x, y) in [
        (a.left, b.left),
        (a.top, b.top),
        (a.width, b.width),
        (a.height, b.height),
      ]) {
        expect(y, closeTo(x, 1), reason: '$text: $a vs $b');
      }
    }
  }

  const long =
      '주님의 은혜가 넘치는 이 자리에 우리 모두 함께 모여 Amazing grace how sweet the sound 찬양합니다';

  for (final family in ['Pretendard', 'NanumMyeongjo']) {
    for (final size in [24.0, 40.0, 96.0]) {
      for (final align in [TextAlign.center, TextAlign.left, TextAlign.right]) {
        testWidgets('$family ${size}pt $align: 편집 중과 굽기 줄 배치가 같다', (t) async {
          final ops = [
            {'insert': '$long\n둘째 줄 '},
            {
              'insert': '작은 글자',
              'attributes': {'size': '${(size * 0.5).round()}'},
            },
            {
              'insert': ' 와 굵게',
              'attributes': {'bold': true, 'color': '#FFF176'},
            },
            {'insert': '\n\n'},
            {
              'insert': '작게만',
              'attributes': {'size': '${(size * 0.6).round()}'},
            },
            {'insert': '\n글머리 $long'},
            {
              'insert': '\n',
              'attributes': {'list': 'bullet'},
            },
            {'insert': '하나'},
            {
              'insert': '\n',
              'attributes': {'list': 'ordered'},
            },
            {'insert': '둘 $long'},
            {
              'insert': '\n',
              'attributes': {'list': 'ordered'},
            },
            {'insert': 'English only line that is long enough to wrap twice'},
            {'insert': '\n'},
          ];
          final e = PageTextElement(
            id: 'a',
            rect: const Rect.fromLTWH(0.1, 0.05, 0.6, 0.9),
            fontSize: size,
            fontFamily: family,
            align: align,
            bold: size == 40,
            rich: jsonEncode(ops),
            text: pageRichLinesFromOps(ops).map((l) => l.text).join('\n'),
          );
          await expectSameLayout(t, e);
          // 측정 높이는 굽기 칸 높이와 같다.
          final measured = measurePageText(
            e,
            PageCanvas.fontScale,
            e.rect.width * PageCanvas.width,
          );
          await t.pumpWidget(
            MaterialApp(
              home: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: e.rect.width * PageCanvas.width,
                maxWidth: e.rect.width * PageCanvas.width,
                minHeight: 0,
                maxHeight: double.infinity,
                child: Center(
                  heightFactor: 1,
                  child: PageTextBlock(
                    element: e,
                    fontScale: PageCanvas.fontScale,
                  ),
                ),
              ),
            ),
          );
          expect(
            t.getSize(find.byType(PageTextBlock)).height,
            closeTo(measured, 0.5),
          );
        });
      }
    }
  }

  testWidgets('평문 상자(rich 없음)도 같다', (t) async {
    await expectSameLayout(
      t,
      const PageTextElement(
        id: 'a',
        rect: Rect.fromLTWH(0.2, 0.3, 0.4, 0.3),
        text: '$long\n\n셋째 줄',
      ),
    );
  });
}
