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

  /// 성경만: 절 번호 밑으로 줄이 감기는 내어쓰기(PPTX 와 같은 1.7em). 찬양은 [bodySpan] 그대로.
  /// 줄마다 첫 공백 앞(절 번호)을 따로 두고 나머지를 번호 폭만큼 들여 그린다.
  static List<(String, TextStyle, double)> _bibleBlocks(
    SlidePageData data,
    double fontScale,
    bool originalOnly,
  ) {
    final span = bodySpan(
      data,
      fontScale: fontScale,
      originalOnly: originalOnly,
    );
    final blocks = <(String, TextStyle, double)>[];
    for (final c in span.children!.cast<TextSpan>()) {
      final style = c.style!;
      final text = blocks.isEmpty
          ? c.text!
          : c.text!.substring(1); // 앞의 '\n' 뺀다
      blocks.add((text, style, style.fontSize! * 1.7));
    }
    return blocks;
  }

  static (String, String) _splitNum(String line) {
    final i = line.indexOf(' ');
    return i < 0
        ? ('', _keepWords(line))
        : (line.substring(0, i), _keepWords(line.substring(i + 1)));
  }

  /// 한글은 글자마다 줄이 나뉠 수 있어, 공백이 아닌 글자 사이에 word joiner 를 넣어 낱말째 다음 줄로 보낸다.
  static String _keepWords(String s) =>
      s.replaceAllMapped(RegExp(r'(?<=\S)(?=\S)'), (_) => '\u2060');

  static Widget bibleBody(
    SlidePageData data, {
    double fontScale = 1,
    bool originalOnly = false,
  }) {
    final align = textAlign(data);
    final blocks = _bibleBlocks(data, fontScale, originalOnly);
    final bodySize = data.style.bibleFontSize * fontScale;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var b = 0; b < blocks.length; b++) ...[
          if (b > 0) SizedBox(height: bodySize * _blockGap),
          for (final line in blocks[b].$1.split('\n'))
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: blocks[b].$3,
                  child: Text(
                    _splitNum(line).$1,
                    style: blocks[b].$2,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                  ),
                ),
                Expanded(
                  child: Text(
                    _splitNum(line).$2,
                    style: blocks[b].$2,
                    textAlign: align,
                  ),
                ),
              ],
            ),
        ],
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
    var textHeight = 0.0;
    if (data.isBible) {
      for (final b in _bibleBlocks(data, scale, false)) {
        for (final line in b.$1.split('\n')) {
          final p = TextPainter(
            text: TextSpan(text: _splitNum(line).$2, style: b.$2),
            textAlign: textAlign(data),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: boxW(true) * 72 - b.$3);
          textHeight += p.height;
          p.dispose();
        }
      }
    } else {
      final painter = TextPainter(
        text: bodySpan(data, fontScale: scale),
        textAlign: textAlign(data),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: boxW(false) * 72);
      textHeight = painter.height;
      painter.dispose();
    }
    final blocks = (showsSub(data) ? 1 : 0) + (showsExtra(data) ? 1 : 0);
    final bodyFontSize = data.isBible
        ? data.style.bibleFontSize
        : data.style.fontSize;
    final height = textHeight + blocks * bodyFontSize * scale * _blockGap;
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
