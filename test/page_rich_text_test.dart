import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/page_element.dart';
import 'package:worship_slides/src/features/praise/presentation/page_rich_text.dart';

void main() {
  const rect = Rect.fromLTWH(0, 0, 0.5, 0.5);

  PageTextElement withOps(List<Map<String, Object>> ops, {bool bold = false}) =>
      PageTextElement(
        id: 'a',
        rect: rect,
        bold: bold,
        rich: jsonEncode(ops),
        text: pageRichLinesFromOps(ops).map((l) => l.text).join('\n'),
      );

  test('rich 가 없으면 평문 줄, JSON 왕복에서 rich 유지', () {
    const plain = PageTextElement(id: 'a', rect: rect, text: '안녕\n\n셋');
    expect(pageRichLines(plain).map((l) => l.text), ['안녕', '', '셋']);
    expect(plain.toJson().containsKey('rich'), isFalse);

    final rich = plain.copyWith(rich: '[{"insert":"안녕\\n"}]');
    final back = PageElement.fromJson(rich.toJson()) as PageTextElement;
    expect(back, rich);
    expect(back.copyWith(text: 'x').rich, rich.rich); // 안 넘기면 유지
    expect(back.copyWith(rich: null).rich, isNull); // null 이면 지움
  });

  test('부분 서식·글머리·번호는 줄 단위로 읽는다', () {
    final e = withOps([
      {'insert': '큰'},
      {
        'insert': '빨강',
        'attributes': {'bold': true, 'color': '#ff0000', 'size': '60'},
      },
      {'insert': '\n'},
      {'insert': '하나'},
      {
        'insert': '\n',
        'attributes': {'list': 'bullet'},
      },
      {'insert': '둘'},
      {
        'insert': '\n',
        'attributes': {'list': 'ordered'},
      },
    ]);
    final lines = pageRichLines(e);
    expect(lines.map((l) => (l.text, l.list)), [
      ('큰빨강', null),
      ('하나', 'bullet'),
      ('둘', 'ordered'),
    ]);
    final red = pageInlineStyle(lines.first.spans[1].attrs, 2)!;
    expect(red.fontSize, 120);
    expect(red.fontWeight, FontWeight.w700);
    expect(red.color, const Color(0xFFFF0000));
    // 목록 기호 칸 폭 = flutter_quill 공식(글머리 = 글자 2개, 번호 1~2자리도 2개).
    expect(pageListIndent('bullet', 1, 80), 160);
    expect(pageListIndent('ordered', 120, 80), 200);
  });

  test('깨진 rich 는 평문으로', () {
    final e = PageTextElement(id: 'a', rect: rect, text: '글', rich: '{망가짐');
    expect(pageRichLines(e).single.text, '글');
  });

  test('Quill 색 선택기의 8자리 #AARRGGBB 도 색으로 읽고, bold:false 는 보통 굵기', () {
    final e = withOps([
      {
        'insert': '가',
        'attributes': {'color': '#FFFF0000', 'bold': false},
      },
      {'insert': '나\n'},
    ], bold: true);
    final first = pageInlineStyle(
      pageRichLines(e).single.spans.first.attrs,
      2,
    )!;
    expect(first.color, const Color(0xFFFF0000));
    expect(first.fontWeight, FontWeight.w400);
  });

  test('저장 형식: 굽기가 모르는 서식·정렬은 버리고, 서식이 없으면 null', () {
    final lines = pageRichLinesFromOps([
      {
        'insert': '제목',
        'attributes': {'italic': false, 'link': 'x'},
      },
      {
        'insert': '\n',
        'attributes': {'header': 1, 'align': 'center'},
      },
    ]);
    expect(encodePageRich(lines), isNull);
    expect(pageRichOps(lines, align: 'center'), [
      {'insert': '제목'},
      {
        'insert': '\n',
        'attributes': {'align': 'center'},
      },
    ]);
  });

  test('상자째 서식: 상자 기본값을 바꾸고 같은 속성의 직접 지정만 지운다', () {
    final e = withOps([
      {
        'insert': '광고',
        'attributes': {'italic': true, 'color': '#FF0000', 'size': '60'},
      },
      {'insert': '입니다\n'},
    ]);
    final red = applyBoxFormat(e, 'color', const Color(0xFF00FF00));
    expect(red.color, const Color(0xFF00FF00));
    expect(pageRichLines(red).single.spans.first.attrs, {
      'italic': true,
      'size': '60',
    });

    final bold = applyBoxFormat(e, 'bold', true);
    expect(bold.bold, isTrue);
    final italic = applyBoxFormat(e, 'italic', true);
    expect(pageBoxFormat([italic]).italic, isTrue);
    expect(
      pageBoxFormat([applyBoxFormat(italic, 'italic', false)]).italic,
      isFalse,
    );

    final listed = applyBoxFormat(e, 'list', 'bullet');
    expect(pageRichLines(listed).single.list, 'bullet');

    // 크기가 섞이면 빈칸, 한 단계 크게는 차이를 지킨 채 둘 다 키운다.
    expect(pageBoxFormat([e]).size, isNull);
    final bigger = applyBoxFormat(e, 'step', 1);
    expect(bigger.fontSize, 48);
    expect(pageRichLines(bigger).single.spans.first.attrs['size'], '72');

    final cleared = applyBoxFormat(e, 'clear', null);
    expect(cleared.rich, isNull);
    expect(cleared.text, e.text);
    expect(pageBoxFormat([cleared]).size, PageTextElement.defaultFontSize);
  });

  test('모르는 종류 요소는 JSON 그대로 보존·왕복한다', () {
    final raw = {
      'type': 'table',
      'id': 's1',
      'rect': [0.1, 0.5, 0.3, 0.0], // 가로선: 높이 0
      'shape': 'line',
      'stroke': '#FFFFFF',
      'stroke_width': 2,
    };
    final list = PageElement.listFromJson([
      raw,
      {'type': 7},
      {
        'type': 'text',
        'rect': [0, 0, 0.5, 0.2],
        'text': '글',
      },
    ]);
    expect(list, hasLength(2));
    final unknown = list.first as PageUnknownElement;
    expect(unknown.type, 'table');
    expect(jsonEncode(unknown.toJson()), jsonEncode(raw));
    expect(
      PageElement.fromJson(jsonDecode(jsonEncode(unknown.toJson()))),
      unknown,
    );
  });
}
