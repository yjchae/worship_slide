import 'dart:convert';

import 'package:flutter/painting.dart';

import '../domain/export_style.dart';
import '../domain/page_element.dart';
import 'page_rich_text.dart';
import 'slide_page_data.dart';
import 'slide_text_layout.dart';

/// 찬양·성경 글 페이지 한 장을 슬라이드 편집 페이지의 글 상자 목록으로 바꾼다.
/// [style] 은 이 페이지에 실제로 쓰이는 스타일(항목 배경·페이지 서식까지 입힌 것)이다.
///
/// 본문·보조·추가 보조는 글 상자 하나에 줄로 담고(보조 줄은 크기·색을 글자 서식으로),
/// 제목은 따로 한 상자다. 상자 자리는 가사 상자(위 0.6인치·높이 5.4인치)에서 상단/중단/하단·미세 조정을
/// 따라 글 높이를 재서 정한다.
/// ponytail: 줄 간격(본문 1.25·보조 1.3)·보조 앞 틈·성경 내어쓰기는 편집 페이지에 없어
/// 렌더러와 픽셀 단위로는 다를 수 있다.
List<PageElement> freePageElements(
  ExportStyle style, {
  required String main,
  String sub = '',
  String extra = '',
  required bool isBible,
  String? title,
}) {
  const slideW = SlideTextLayout.slideW;
  const slideH = SlideTextLayout.slideH;
  // 넘치면 렌더러처럼 글자만 줄인다.
  final scale = SlideTextLayout.fitScale(
    SlidePageData(
      mainText: main,
      englishText: sub,
      extraText: extra,
      isBible: isBible,
      pageIndex: 0,
      totalPages: 1,
      style: style,
    ),
  );
  final showSub = style.includeEnglishLyrics && sub.isNotEmpty;
  final showExtra = style.includeExtraLyrics && extra.isNotEmpty;
  final bodySize = (isBible ? style.bibleFontSize : style.fontSize) * scale;
  final align = switch (isBible
      ? style.bibleTextAlign
      : style.lyricsTextAlign) {
    HorizontalPosition.left => TextAlign.left,
    HorizontalPosition.center => TextAlign.center,
    HorizontalPosition.right => TextAlign.right,
  };

  String sizeAttr(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
  Map<String, Object> ops(String text, Color color, double size) => {
    'insert': text,
    'attributes': {'color': colorToHex(color), 'size': sizeAttr(size)},
  };

  final lines = [main, if (showSub) sub, if (showExtra) extra];
  var body = PageTextElement(
    id: PageElement.newId(),
    rect: Rect.zero,
    text: lines.join('\n'),
    fontSize: bodySize,
    color: isBible ? style.bibleTextColor : style.textColor,
    bold: true,
    align: align,
    fontFamily: style.fontFamily,
    rich: lines.length == 1
        ? null
        : jsonEncode([
            {'insert': '$main\n'},
            if (showSub)
              ops(
                sub,
                style.englishTextColor,
                style.subFontSizeFor(isBible: isBible) * scale,
              ),
            if (showSub) {'insert': '\n'},
            if (showExtra)
              ops(
                extra,
                style.extraTextColor,
                style.extraFontSizeFor(isBible: isBible) * scale,
              ),
            if (showExtra) {'insert': '\n'},
          ]),
  );

  final boxW = SlideTextLayout.boxW(isBible);
  final painter = TextPainter(
    text: pageTextSpan(body, 1),
    textAlign: align,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: boxW * 72);
  final textH = painter.height / 72;
  painter.dispose();
  final boxTop =
      SlideTextLayout.lyricsBoxT +
      clampTextOffsetY(isBible ? style.bibleTextOffsetY : style.textOffsetY);
  final free = (SlideTextLayout.lyricsBoxH - textH).clamp(0.0, double.infinity);
  final top =
      boxTop +
      free *
          switch (isBible ? style.bibleTextPosition : style.textPosition) {
            VerticalTextPosition.top => 0.0,
            VerticalTextPosition.middle => 0.5,
            VerticalTextPosition.bottom => 1.0,
          };
  body = body.copyWith(
    rect: PageElement.clampRect(
      Rect.fromLTWH(
        SlideTextLayout.boxL(isBible) / slideW,
        top / slideH,
        boxW / slideW,
        textH / slideH,
      ),
    ),
  );

  final showTitle = isBible ? style.showBibleTitle : style.showSongTitle;
  return [
    body,
    if (showTitle && title != null && title.isNotEmpty)
      _titleBox(style, title, isBible),
  ];
}

// slide_render_view.dart 의 제목 상자 상수와 같다(비공개라 옮겨 적었다).
const _titleBoxH = 0.55;
const _titlePad = 0.2;

PageTextElement _titleBox(ExportStyle style, String title, bool isBible) {
  const slideW = SlideTextLayout.slideW;
  const slideH = SlideTextLayout.slideH;
  final h = isBible
      ? style.bibleTitleHorizontalPosition
      : style.titleHorizontalPosition;
  final v = isBible
      ? style.bibleTitleVerticalPosition
      : style.titleVerticalPosition;
  final (left, width, align) = switch (h) {
    HorizontalPosition.left => (
      _titlePad,
      slideW - _titlePad * 2,
      TextAlign.left,
    ),
    HorizontalPosition.center => ((slideW - 10.0) / 2, 10.0, TextAlign.center),
    HorizontalPosition.right => (
      _titlePad,
      slideW - _titlePad * 2,
      TextAlign.right,
    ),
  };
  final top =
      switch (v) {
        VerticalTextPosition.top => _titlePad,
        VerticalTextPosition.middle => (slideH - _titleBoxH) / 2,
        VerticalTextPosition.bottom => slideH - _titlePad - _titleBoxH,
      } +
      clampTextOffsetY(isBible ? style.bibleTitleOffsetY : style.titleOffsetY);
  return PageTextElement(
    id: PageElement.newId(),
    rect: PageElement.clampRect(
      Rect.fromLTWH(
        left / slideW,
        top / slideH,
        width / slideW,
        _titleBoxH / slideH,
      ),
    ),
    text: title,
    fontSize: isBible ? style.bibleTitleFontSize : style.titleFontSize,
    color: isBible ? style.bibleTitleTextColor : style.titleTextColor,
    align: align,
    fontFamily: style.fontFamily,
  );
}
