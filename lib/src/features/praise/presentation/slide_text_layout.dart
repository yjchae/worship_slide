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

  /// 성경은 줄이 길어 좌우를 더 쓴다(96%). 발표 창 두 곳·PPTX 도 같은 비율이다.
  static const double bibleBoxW = slideW * 0.96;
  static double boxW(bool isBible) => isBible ? bibleBoxW : lyricsBoxW;
  static double boxL(bool isBible) => (slideW - boxW(isBible)) / 2;

  static const double _mainHeight = 1.25;
  static const double _subHeight = 1.3;

  /// 가사 상자 글자. [originalOnly] 면 보조·추가 보조를 투명하게 그린다 — 자리는 그대로라
  /// 원본 위치가 관객 화면과 같다(발표 보기의 영역 확대·포인터 좌표가 어긋나지 않게).
  static TextSpan bodySpan(
    SlidePageData data, {
    double fontScale = 1,
    bool originalOnly = false,
    bool mainOnly = false,
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
        if (!mainOnly && showsSub(data))
          TextSpan(
            text: '\n${data.englishText}',
            style: textStyle(
              hideable(style.englishTextColor),
              style.subFontSizeFor(isBible: isBible),
              _subHeight,
            ),
          ),
        if (!mainOnly && showsExtra(data))
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
  static double overflowRatio(SlidePageData data) => _heightRatio(data, 1);

  /// 글자 크기를 [scale] 배로 했을 때 가사 상자 높이 대비 글자 높이.
  static double _heightRatio(SlidePageData data, double scale) {
    if (data.imagePath != null) return 0;
    if (data.mainText.isEmpty && !showsSub(data) && !showsExtra(data)) {
      return 0;
    }
    final painter = TextPainter(
      text: bodySpan(data, fontScale: scale),
      textAlign: textAlign(data),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: boxW(data.isBible) * 72);
    // 발표 창은 보조·추가 보조 블록 앞에 틈을 둔다(macOS margin-top 0.4em, Windows 본문 크기 × 0.4).
    // 미리보기 글자 배치엔 없지만 실제 화면 높이엔 들어가므로 더 큰 쪽(본문 × 0.4)으로 더해 잰다.
    final blocks = (showsSub(data) ? 1 : 0) + (showsExtra(data) ? 1 : 0);
    final bodyFontSize = data.isBible
        ? data.style.bibleFontSize
        : data.style.fontSize;
    final height = painter.height + blocks * bodyFontSize * scale * _blockGap;
    painter.dispose();
    return height / (lyricsBoxH * 72);
  }

  /// 넘치는 페이지를 상자에 넣을 글자 배율(넘치지 않으면 1). 상자째 줄이면 폭까지 줄어
  /// 좌우가 비므로(성경 두 역본에서 폭 60% 쯤) 글자만 줄여 상자 폭으로 다시 감는다.
  /// macOS 발표 창도 같은 방식(글자 줄이기)이다.
  static double fitScale(SlidePageData data) {
    if (cachedOverflowRatio(data) <= 1) return 1;
    final key = (_cacheKey(data), 'fit');
    if (_overflowCache.length > 2000) _overflowCache.clear();
    return _overflowCache[key] ??= () {
      var scale = 1.0;
      for (var i = 0; i < 60 && _heightRatio(data, scale) > 1; i++) {
        scale *= 0.97;
      }
      return scale;
    }();
  }

  /// 보조 줄이 가사 상자 아래로 내려갈 수 있는 한계 = 슬라이드 아래 끝에서 이만큼(인치) 위.
  static const double subHangBottomMargin = 0.3;

  /// 찬양 가사 '중단' 기준에서 보조·추가 보조가 있을 때 원본 가사 첫 줄의 자리
  /// (가사 상자 위에서 인치). 원본 가사만으로 가운데를 잡고 보조 줄은 그 아래로 늘어뜨린다 —
  /// 보조 가사 길이가 페이지마다 달라도 원본 가사 시작 위치가 흔들리지 않게.
  /// 보조 줄이 [subHangBottomMargin] 한계를 넘으면 그만큼만 올린다(그때만 위치가 바뀐다).
  /// null = 예전처럼 상자 안에서 통째로 정렬(상단·하단 기준, 성경, 보조 없음).
  /// 발표 창 두 곳(macOS·Windows)·PPTX 도 같은 규칙이다.
  static double? anchoredTopInBox(SlidePageData data, double boxTop) {
    if (data.imagePath != null || data.isBible) return null;
    if (data.style.textPosition != VerticalTextPosition.middle) return null;
    if (data.mainText.isEmpty || (!showsSub(data) && !showsExtra(data))) {
      return null;
    }
    final key = (_cacheKey(data), 'top', boxTop, data.style.textPosition);
    if (_overflowCache.length > 2000) _overflowCache.clear();
    return _overflowCache[key] ??= () {
      final scale = fitScale(data);
      double measure(bool mainOnly) {
        final painter = TextPainter(
          text: bodySpan(data, fontScale: scale, mainOnly: mainOnly),
          textAlign: textAlign(data),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: boxW(false) * 72);
        final h = painter.height / 72;
        painter.dispose();
        return h;
      }

      // 발표 창은 보조 블록마다 앞에 틈(본문 × 0.4)을 둔다 — 한계 비교엔 그 틈까지 넣는다.
      final blocks = (showsSub(data) ? 1 : 0) + (showsExtra(data) ? 1 : 0);
      final gaps = blocks * data.style.fontSize * scale * _blockGap / 72;
      return placeAnchored(
        mainH: measure(true),
        totalH: measure(false) + gaps,
        boxTop: boxTop,
      );
    }();
  }

  /// [anchoredTopInBox] 의 계산(인치). 원본 가사 가운데 정렬 → 보조 줄이 한계를 넘으면 올리기.
  static double placeAnchored({
    required double mainH,
    required double totalH,
    required double boxTop,
  }) {
    final limit = anchoredLimitInBox(boxTop);
    final anchor = (lyricsBoxH - mainH) / 2;
    final top = anchor < limit - totalH ? anchor : limit - totalH;
    return top < 0 ? 0.0 : top;
  }

  /// 보조 줄이 내려갈 수 있는 아래 끝(가사 상자 위에서 인치). 상자 아래 끝보다 위로는 안 온다.
  static double anchoredLimitInBox(double boxTop) {
    final limit = slideH - subHangBottomMargin - boxTop;
    return limit > lyricsBoxH ? limit : lyricsBoxH;
  }

  /// 발표 창(Windows)의 보조 블록 앞 틈 = 본문 글자 크기 × 이 값.
  static const double _blockGap = 0.4;

  static final Map<Record, double> _overflowCache = {};

  /// [overflowRatio] 를 페이지 글자·스타일로 기억해 둔다(썸네일 수백 장을 다시 재지 않게).
  static double cachedOverflowRatio(SlidePageData data) {
    if (data.imagePath != null) return 0;
    final key = _cacheKey(data);
    if (_overflowCache.length > 2000) _overflowCache.clear();
    return _overflowCache[key] ??= overflowRatio(data);
  }

  static Record _cacheKey(SlidePageData data) {
    final style = data.style;
    // 값 묶음(record)을 키로 — 긴 문자열을 새로 만들지 않고, 해시가 겹쳐도 값 비교로 가린다.
    return (
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
    );
  }

  /// 넘침으로 볼 비율. 측정 오차(글꼴 대체 등)로 경계에서 깜빡이지 않게 조금 여유를 둔다.
  static const double overflowThreshold = 1.02;

  static bool overflows(SlidePageData data) =>
      cachedOverflowRatio(data) > overflowThreshold;

  /// '약 112%' 처럼 화면에 낼 값(5% 단위로 반올림).
  static String overflowLabel(double ratio) =>
      '약 ${((ratio * 100) / 5).round() * 5}%';
}
