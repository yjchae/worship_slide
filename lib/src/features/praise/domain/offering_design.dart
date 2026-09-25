import 'package:flutter/material.dart';

import 'export_style.dart';

/// 헌금송 배경 디자인.
///
/// 배경 이미지 위에 "헌금" + "은행 계좌번호" 두 줄과 위아래 라인을 얹은 한 장의 그림이다.
/// 이 그림을 PNG 로 구워 콘티 항목의 배경 오버라이드([SlideBackground])로 쓰므로,
/// 찬양 가사는 그 위에 평소처럼 그려진다. 렌더러 네 곳(미리보기·macOS·Windows·PPTX)은
/// 헌금송을 전혀 모르고 "배경 이미지 한 장"으로만 본다.
///
/// 좌표는 다른 슬라이드 요소와 같은 기준이다 — 슬라이드 13.333 x 7.5 인치,
/// 글자 크기는 높이 540pt 기준.
@immutable
class OfferingDesign {
  const OfferingDesign({
    this.backgroundImagePath,
    this.backgroundColor = const Color(0xFF0B132B),
    this.label = '헌금',
    this.bankName = '',
    this.accountNumber = '',
    this.textColor = const Color(0xFFFFE600),
    this.lineColor = const Color(0xFFFFE600),
    this.labelFontSize = 34,
    this.accountFontSize = 38,
    this.bandCenterY = defaultBandCenterY,
    this.lyricsAboveBand = false,
    this.lyricsGap = defaultLyricsGap,
    this.showLines = true,
    this.lineWidth = 5.6,
    this.lineThickness = 2,
    this.linePadding = 0.2,
    this.fontFamily = 'Pretendard',
  });

  static const double slideWidth = 13.333;
  static const double slideHeight = 7.5;

  /// 높낮이(띠 중심) 허용 범위. 띠가 화면 밖으로 나가지 않을 만큼만 연다.
  static const double minBandCenterY = 0.6;
  static const double maxBandCenterY = slideHeight - 0.6;

  /// 가사 마지막 줄과 띠 윗선 사이 기본 여백(인치)과 조절 범위.
  static const double defaultLyricsGap = 0.4;
  static const double maxLyricsGap = 1.5;

  /// 기본 높낮이. 가사를 띠 위쪽에 놓으려면 띠가 아래쪽에 있어야 자리가 넉넉하다.
  static const double defaultBandCenterY = 5.9;

  /// 배경 이미지. null 이면 [backgroundColor] 단색 위에 그린다.
  final String? backgroundImagePath;
  final Color backgroundColor;

  /// 윗줄 문구 (기본 "헌금").
  final String label;

  /// 아랫줄 = "[bankName] [accountNumber]".
  final String bankName;
  final String accountNumber;

  final Color textColor;
  final Color lineColor;

  /// 540pt 기준 글자 크기.
  final double labelFontSize;
  final double accountFontSize;

  /// 띠(라인 + 두 줄 글씨) 중심의 세로 위치, 인치. 가사가 길면 위나 아래로 비킨다.
  final double bandCenterY;

  /// 가사를 띠 위쪽에 붙여 놓는다(가사 아래쪽 끝 = 띠 윗선 바로 위, 길면 위로 자란다).
  /// 끄면(기본) 가사는 전역 찬양 디자인 위치 그대로 띠 위에 겹쳐 그려진다.
  /// JSON 키가 `lyrics_above_band` 가 아닌 이유: 예전엔 기본이 켬이라 저장된 true 가
  /// 사용자가 고른 값인지 알 수 없다. 옛 키는 무시하고 기본(끔)에서 다시 시작한다.
  final bool lyricsAboveBand;

  /// 가사 마지막 줄과 띠 윗선 사이 여백(인치). [lyricsAboveBand] 일 때만 쓴다.
  final double lyricsGap;

  final bool showLines;

  /// 라인 길이(인치)와 굵기(540pt 기준 pt).
  final double lineWidth;
  final double lineThickness;

  /// 글씨와 라인 사이 간격(인치).
  final double linePadding;

  final String fontFamily;

  bool get hasImage =>
      backgroundImagePath != null && backgroundImagePath!.isNotEmpty;

  /// 계좌 줄. 은행명·계좌번호 중 빈 쪽은 빼고 잇는다.
  String get accountLine => [
    bankName.trim(),
    accountNumber.trim(),
  ].where((part) => part.isNotEmpty).join(' ');

  static double clampBandCenterY(double value) =>
      value.clamp(minBandCenterY, maxBandCenterY).toDouble();

  OfferingDesign copyWith({
    Object? backgroundImagePath = _sentinel,
    Color? backgroundColor,
    String? label,
    String? bankName,
    String? accountNumber,
    Color? textColor,
    Color? lineColor,
    double? labelFontSize,
    double? accountFontSize,
    double? bandCenterY,
    bool? lyricsAboveBand,
    double? lyricsGap,
    bool? showLines,
    double? lineWidth,
    double? lineThickness,
    double? linePadding,
    String? fontFamily,
  }) {
    return OfferingDesign(
      backgroundImagePath: identical(backgroundImagePath, _sentinel)
          ? this.backgroundImagePath
          : backgroundImagePath as String?,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      label: label ?? this.label,
      bankName: bankName ?? this.bankName,
      accountNumber: accountNumber ?? this.accountNumber,
      textColor: textColor ?? this.textColor,
      lineColor: lineColor ?? this.lineColor,
      labelFontSize: labelFontSize ?? this.labelFontSize,
      accountFontSize: accountFontSize ?? this.accountFontSize,
      bandCenterY: clampBandCenterY(bandCenterY ?? this.bandCenterY),
      lyricsAboveBand: lyricsAboveBand ?? this.lyricsAboveBand,
      lyricsGap: (lyricsGap ?? this.lyricsGap).clamp(0.0, maxLyricsGap),
      showLines: showLines ?? this.showLines,
      lineWidth: lineWidth ?? this.lineWidth,
      lineThickness: lineThickness ?? this.lineThickness,
      linePadding: linePadding ?? this.linePadding,
      fontFamily: fontFamily ?? this.fontFamily,
    );
  }

  Map<String, dynamic> toJson() => {
    if (hasImage) 'background_image_path': backgroundImagePath,
    'background_color': colorToHex(backgroundColor),
    'label': label,
    'bank_name': bankName,
    'account_number': accountNumber,
    'text_color': colorToHex(textColor),
    'line_color': colorToHex(lineColor),
    'label_font_size': labelFontSize,
    'account_font_size': accountFontSize,
    'band_center_y': bandCenterY,
    'lyrics_above_band_v2': lyricsAboveBand,
    'lyrics_gap': lyricsGap,
    'show_lines': showLines,
    'line_width': lineWidth,
    'line_thickness': lineThickness,
    'line_padding': linePadding,
    'font_family': fontFamily,
  };

  /// 키가 빠져 있으면 기본값으로 채운다(나중에 항목이 늘어도 예전 설정이 그대로 읽힌다).
  factory OfferingDesign.fromJson(Map<String, dynamic> json) {
    const d = OfferingDesign();
    double num_(String key, double fallback) =>
        (json[key] as num?)?.toDouble() ?? fallback;
    final path = json['background_image_path'] as String?;
    return OfferingDesign(
      backgroundImagePath: (path == null || path.isEmpty) ? null : path,
      backgroundColor: parseHexColor(
        json['background_color'] as String?,
        d.backgroundColor,
      ),
      label: json['label'] as String? ?? d.label,
      bankName: json['bank_name'] as String? ?? d.bankName,
      accountNumber: json['account_number'] as String? ?? d.accountNumber,
      textColor: parseHexColor(json['text_color'] as String?, d.textColor),
      lineColor: parseHexColor(json['line_color'] as String?, d.lineColor),
      labelFontSize: num_('label_font_size', d.labelFontSize),
      accountFontSize: num_('account_font_size', d.accountFontSize),
      bandCenterY: clampBandCenterY(num_('band_center_y', d.bandCenterY)),
      lyricsAboveBand: json['lyrics_above_band_v2'] as bool? ?? d.lyricsAboveBand,
      lyricsGap: num_('lyrics_gap', d.lyricsGap).clamp(0.0, maxLyricsGap),
      showLines: json['show_lines'] as bool? ?? d.showLines,
      lineWidth: num_('line_width', d.lineWidth),
      lineThickness: num_('line_thickness', d.lineThickness),
      linePadding: num_('line_padding', d.linePadding),
      fontFamily: json['font_family'] as String? ?? d.fontFamily,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OfferingDesign &&
      other.backgroundImagePath == backgroundImagePath &&
      other.backgroundColor == backgroundColor &&
      other.label == label &&
      other.bankName == bankName &&
      other.accountNumber == accountNumber &&
      other.textColor == textColor &&
      other.lineColor == lineColor &&
      other.labelFontSize == labelFontSize &&
      other.accountFontSize == accountFontSize &&
      other.bandCenterY == bandCenterY &&
      other.lyricsAboveBand == lyricsAboveBand &&
      other.lyricsGap == lyricsGap &&
      other.showLines == showLines &&
      other.lineWidth == lineWidth &&
      other.lineThickness == lineThickness &&
      other.linePadding == linePadding &&
      other.fontFamily == fontFamily;

  @override
  int get hashCode => Object.hash(
    backgroundImagePath,
    backgroundColor,
    label,
    bankName,
    accountNumber,
    textColor,
    lineColor,
    labelFontSize,
    accountFontSize,
    bandCenterY,
    lyricsAboveBand,
    lyricsGap,
    showLines,
    lineWidth,
    lineThickness,
    linePadding,
    fontFamily,
  );

  static const Object _sentinel = Object();
}
