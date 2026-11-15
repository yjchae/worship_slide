import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/page_element.dart';
import 'package:worship_slides/src/features/praise/presentation/page_rich_text.dart';

void main() {
  const rect = Rect.fromLTWH(0, 0, 0.5, 0.5);

  test('rich 가 없으면 평문 한 덩이, JSON 왕복에서 rich 유지', () {
    const plain = PageTextElement(id: 'a', rect: rect, text: '안녕');
    expect(pageTextSpan(plain, 2).text, '안녕');
    expect(plain.toJson().containsKey('rich'), isFalse);

    final rich = plain.copyWith(rich: '[{"insert":"안녕\\n"}]');
    final back = PageElement.fromJson(rich.toJson()) as PageTextElement;
    expect(back, rich);
    expect(back.copyWith(text: 'x').rich, rich.rich); // 안 넘기면 유지
    expect(back.copyWith(rich: null).rich, isNull); // null 이면 지움
  });

  test('부분 서식·글머리·번호', () {
    final ops = [
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
    ];
    final e = PageTextElement(
      id: 'a',
      rect: rect,
      text: '큰빨강\n하나\n둘',
      rich: jsonEncode(ops),
    );
    final span = pageTextSpan(e, 2);
    expect(span.toPlainText(), '큰빨강\n• 하나\n1. 둘');
    final red = (span.children!.whereType<TextSpan>().firstWhere(
      (s) => s.text == '빨강',
    )).style!;
    expect(red.fontSize, 120);
    expect(red.fontWeight, FontWeight.w700);
    expect(red.color, const Color(0xFFFF0000));
  });

  test('깨진 rich 는 평문으로', () {
    final e = PageTextElement(id: 'a', rect: rect, text: '글', rich: '{망가짐');
    expect(pageTextSpan(e, 2).text, '글');
  });

  test('Quill 색 선택기의 8자리 #AARRGGBB 도 색으로 읽고, bold:false 는 보통 굵기', () {
    final e = PageTextElement(
      id: 'a',
      rect: rect,
      text: '가나',
      bold: true,
      rich: jsonEncode([
        {
          'insert': '가',
          'attributes': {'color': '#FFFF0000', 'bold': false},
        },
        {'insert': '나\n'},
      ]),
    );
    final first = pageTextSpan(e, 2).children!.first as TextSpan;
    expect(first.style!.color, const Color(0xFFFF0000));
    expect(first.style!.fontWeight, FontWeight.w400);
  });
}
