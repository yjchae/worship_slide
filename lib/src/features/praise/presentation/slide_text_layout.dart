import 'package:flutter/material.dart';

import '../domain/export_style.dart';
import 'slide_page_data.dart';

/// 가사 상자(본문 → 보조 → 추가 보조)의 글자 배치. 미리보기 렌더러와 넘침 측정이 같이 쓴다 —
/// 둘이 다르면 미리보기는 들어가는데 경고가 뜨거나 그 반대가 된다.
///
/// 좌표는 슬라이드 기준(13.333 x 7.5 인치, 높이 540pt)이고 [fontScale] 은 pt → 화면 px 배율.
class SlideTextLayout {
  SlideTextLayout._();

  static const double slideW = 13.333;
  static const double slideH = 7.5;
  static const double lyricsBoxT = 0.6;
  static const double lyricsBoxH = 5.4;
  static const double lyricsBoxW = slideW * 0.9;
  static const double lyricsBoxL = (slideW - lyricsBoxW) / 2;

  static const double _mainHeight = 1.25;
  static const double _subHeight = 1.3;

  /// 가사 상자 글자. [originalOnly] 면 보조·추가 보조를 투명하게 그린다 — 자리는 그대로라
  /// 원본 위치가 관객 화면과 같다(발표 보기의 영역 확대·포인터 좌표가 어긋나지 않게).
  static TextSpan bodySpan(
    SlidePageData data, {
    double fontScale = 1,
    bool originalOnly = false,
  }) {
    final style = data.style;
    final isBible = data.isBible;
    final bodyFontSize = isBible ? style.bibleFontSize : style.fontSize;
    final bodyColor = isBible ? style.bibleTextColor : style.textColor;
    Color hideable(Color color) => originalOnly ? Colors.transparent : color;
    TextStyle textStyle(Color color, double size, double height) => TextStyle(
      color: color,
      fontSize: size * fontScale,
      fontFamily: style.fontFamily,
      fontWeight: FontWeight.w700,
      height: height,
    );

    return TextSpan(
      children: [
        TextSpan(
          text: data.mainText,
          style: textStyle(bodyColor, bodyFontSize, _mainHeight),
        ),
        if (showsSub(data))
          TextSpan(
            text: '\n${data.englishText}',
            style: textStyle(
              hideable(style.englishTextColor),
              style.subFontSizeFor(isBible: isBible),
              _subHeight,
            ),
          ),
        if (showsExtra(data))
          TextSpan(
            text: '\n${data.extraText}',
            style: textStyle(
              hideable(style.extraTextColor),
              style.extraFontSizeFor(isBible: isBible),
              _subHeight,
            ),
          ),
      ],
    );
  }

  static bool showsSub(SlidePageData data) =>
      data.style.includeEnglishLyrics && data.englishText.isNotEmpty;

  static bool showsExtra(SlidePageData data) =>
      data.style.includeExtraLyrics && data.extraText.isNotEmpty;

  static TextAlign textAlign(SlidePageData data) => switch (data.isBible
      ? data.style.bibleTextAlign
      : data.style.lyricsTextAlign) {
    HorizontalPosition.left => TextAlign.left,
    HorizontalPosition.center => TextAlign.center,
    HorizontalPosition.right => TextAlign.right,
  };

  /// 가사 상자 높이 대비 글자 높이(1.0 초과 = 넘침). PPT 이미지·글자 없는 페이지는 0.
  /// 발표 창(HTML·GDI)·PPTX 의 실제 줄바꿈과 조금 다를 수 있어 화면엔 "약" 으로 낸다.
  static double overflowRatio(SlidePageData data) {
    if (data.imagePath != null) return 0;
    if (data.mainText.isEmpty && !showsSub(data) && !showsExtra(data)) {
      return 0;
    }
    final painter = TextPainter(
      text: bodySpan(data),
      textAlign: textAlign(data),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: lyricsBoxW * 72);
    final ratio = painter.height / (lyricsBoxH * 72);
    painter.dispose();
    return ratio;
  }

  static final Map<String, double> _overflowCache = {};

  /// [overflowRatio] 를 페이지 글자·스타일로 기억해 둔다(썸네일 수백 장을 다시 재지 않게).
  static double cachedOverflowRatio(SlidePageData data) {
    if (data.imagePath != null) return 0;
    final style = data.style;
    final key = [
      data.isBible,
      data.mainText,
      data.englishText,
      data.extraText,
      style.fontFamily,
      style.fontSize,
      style.bibleFontSize,
      style.subFontSizeFor(isBible: data.isBible),
      style.extraFontSizeFor(isBible: data.isBible),
      style.includeEnglishLyrics,
      style.includeExtraLyrics,
    ].join('\u0000');
    if (_overflowCache.length > 2000) _overflowCache.clear();
    return _overflowCache[key] ??= overflowRatio(data);
  }

  /// 넘침으로 볼 비율. 측정 오차(글꼴 대체 등)로 경계에서 깜빡이지 않게 조금 여유를 둔다.
  static const double overflowThreshold = 1.02;

  static bool overflows(SlidePageData data) =>
      cachedOverflowRatio(data) > overflowThreshold;

  /// '약 112%' 처럼 화면에 낼 값(5% 단위로 반올림).
  static String overflowLabel(double ratio) =>
      '약 ${((ratio * 100) / 5).round() * 5}%';
}
