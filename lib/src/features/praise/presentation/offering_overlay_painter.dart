import 'package:flutter/material.dart';

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

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // 다른 슬라이드 요소와 같은 좌표계: 1인치 = 높이 / 7.5, 글자는 높이 540pt 기준.
    final inch = size.height / OfferingDesign.slideHeight;
    final fontScale = size.height / 540;

    final painters = <TextPainter>[
      if (design.label.trim().isNotEmpty)
        _layout(design.label.trim(), design.labelFontSize * fontScale, size),
      if (design.accountLine.isNotEmpty)
        _layout(design.accountLine, design.accountFontSize * fontScale, size),
    ];

    final gap = _lineGap * inch;
    final textHeight = painters.isEmpty
        ? 0.0
        : painters.fold<double>(0, (sum, tp) => sum + tp.height) +
              gap * (painters.length - 1);

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

  TextPainter _layout(String text, double fontSize, Size size) {
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
