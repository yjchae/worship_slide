import 'package:flutter/material.dart';

import '../domain/export_style.dart';
import '../domain/offering_design.dart';

/// 헌금송 배경의 "띠"(위 라인 · 헌금 · 계좌 · 아래 라인)를 그린다. 배경 이미지는 그리지 않는다.
///
/// 다이얼로그 미리보기와 PNG 굽기([OfferingBackgroundComposer])가 이 painter 하나를
/// 같이 쓴다. 그래야 미리보기에서 맞춘 높낮이가 실제 발표·PPTX 와 한 치도 다르지 않다.
class OfferingOverlayPainter extends CustomPainter {
  const OfferingOverlayPainter(this.design);

  final OfferingDesign design;

  // 두 줄 글씨 사이 간격(인치).
  static const double _lineGap = 0.06;

  // 가사 상자 아래쪽 기준선(인치). 상자는 0.6인치 위 + 5.4인치 높이로 고정이다
  // (slide_render_view.dart · ppt_tool.py 의 _LYRICS_BOX_TOP/HEIGHT 와 같은 값).
  static const double _lyricsBoxBottom = 0.6 + 5.4;

  // 가사 마지막 줄과 띠 윗선 사이 여백(인치).
  static const double _lyricsGap = 0.15;

  /// 띠(윗선 ~ 아랫선)가 차지하는 세로 범위, 인치.
  static ({double top, double bottom}) bandBounds(OfferingDesign design) {
    // 글자 높이는 화면 크기에 비례하므로 아무 크기에서 재어 인치로 바꾸면 된다.
    const size = Size(1920, 1080);
    const inch = 1080 / OfferingDesign.slideHeight;
    final painters = _layoutAll(design, size);
    final textHeight = _textHeight(painters, _lineGap * inch) / inch;
    for (final tp in painters) {
      tp.dispose();
    }
    final pad = design.showLines ? design.linePadding : 0.0;
    return (
      top: design.bandCenterY - textHeight / 2 - pad,
      bottom: design.bandCenterY + textHeight / 2 + pad,
    );
  }

  /// "가사는 띠 위쪽"을 만드는 가사 미세 조정 값(인치, 하단 기준).
  ///
  /// 가사 상자를 하단 기준으로 두고 상자 아래쪽이 띠 윗선 바로 위에 오도록 민다.
  /// 가사가 길어지면 위로 자란다. 미세 조정 허용 범위(±2.0)를 넘으면 잘리므로,
  /// 그때는 [fitsLyricsAbove] 가 false 다(띠를 더 내려야 한다).
  static double lyricsOffsetAboveBand(OfferingDesign design) =>
      clampTextOffsetY(_rawLyricsOffset(design));

  /// 헌금송 항목에 걸 가사 위치. "가사는 띠 위쪽"이 꺼져 있으면 둘 다 null(전역 설정 그대로).
  /// 미리보기와 실제 항목 배경([SlideBackground]) 이 이 값 하나를 같이 쓴다.
  static ({VerticalTextPosition? position, double? offsetY}) lyricsPlacement(
    OfferingDesign design,
  ) {
    if (!design.lyricsAboveBand) return (position: null, offsetY: null);
    return (
      position: VerticalTextPosition.bottom,
      offsetY: lyricsOffsetAboveBand(design),
    );
  }

  static bool fitsLyricsAbove(OfferingDesign design) =>
      _rawLyricsOffset(design) >= kMinTextOffsetY;

  static double _rawLyricsOffset(OfferingDesign design) {
    final raw = bandBounds(design).top - _lyricsGap - _lyricsBoxBottom;
    // 저장·비교가 흔들리지 않게 0.01인치로 맞춘다.
    return (raw * 100).floor() / 100;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // 다른 슬라이드 요소와 같은 좌표계: 1인치 = 높이 / 7.5, 글자는 높이 540pt 기준.
    final inch = size.height / OfferingDesign.slideHeight;
    final fontScale = size.height / 540;

    final painters = _layoutAll(design, size);
    final gap = _lineGap * inch;
    final textHeight = _textHeight(painters, gap);

    final centerY = design.bandCenterY * inch;
    var y = centerY - textHeight / 2;
    for (final tp in painters) {
      tp.paint(canvas, Offset((size.width - tp.width) / 2, y));
      y += tp.height + gap;
      tp.dispose();
    }

    if (design.showLines) {
      final lineWidth = design.lineWidth * inch;
      final left = (size.width - lineWidth) / 2;
      final pad = design.linePadding * inch;
      final paint = Paint()
        ..color = design.lineColor
        ..strokeWidth = design.lineThickness * fontScale
        ..isAntiAlias = true;
      final top = centerY - textHeight / 2 - pad;
      final bottom = centerY + textHeight / 2 + pad;
      canvas.drawLine(Offset(left, top), Offset(left + lineWidth, top), paint);
      canvas.drawLine(
        Offset(left, bottom),
        Offset(left + lineWidth, bottom),
        paint,
      );
    }
  }

  static List<TextPainter> _layoutAll(OfferingDesign design, Size size) {
    final fontScale = size.height / 540;
    return [
      if (design.label.trim().isNotEmpty)
        _layout(
          design,
          design.label.trim(),
          design.labelFontSize * fontScale,
          size,
        ),
      if (design.accountLine.isNotEmpty)
        _layout(
          design,
          design.accountLine,
          design.accountFontSize * fontScale,
          size,
        ),
    ];
  }

  static double _textHeight(List<TextPainter> painters, double gap) =>
      painters.isEmpty
      ? 0.0
      : painters.fold<double>(0, (sum, tp) => sum + tp.height) +
            gap * (painters.length - 1);

  static TextPainter _layout(
    OfferingDesign design,
    String text,
    double fontSize,
    Size size,
  ) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: design.textColor,
          fontSize: fontSize,
          fontFamily: design.fontFamily,
          fontWeight: FontWeight.w700,
          height: 1.15,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: size.width * 0.95);
  }

  @override
  bool shouldRepaint(OfferingOverlayPainter oldDelegate) =>
      oldDelegate.design != design;
}
