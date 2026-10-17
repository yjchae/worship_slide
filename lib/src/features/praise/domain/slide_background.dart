import 'dart:convert';

import 'package:flutter/material.dart';

import 'export_style.dart';
import 'offering_design.dart';

/// 콘티 항목 하나에만 적용되는 배경.
///
/// 전역 [ExportStyle]의 배경(색 + 이미지)을 통째로 대체한다. "헌금송만 다른 배경"처럼
/// 콘티의 일부 항목만 배경을 다르게 하고 싶을 때 쓴다. 배경 외의 디자인(글자 색·크기·
/// 위치 등)은 값을 담은 것만 덮어쓰고 나머지는 전역 설정을 따른다.
///
/// 오버라이드가 없는 항목은 이 객체 자체가 `null` 이고, 전역 배경이 그대로 쓰인다.
@immutable
class SlideBackground {
  const SlideBackground({
    required this.color,
    this.imagePath,
    this.offering,
    this.lyricsPosition,
    this.lyricsOffsetY,
    this.fontFamily,
    this.fontSize,
    this.textColor,
    this.isSermon = false,
  });

  /// 이 항목의 배경 색. 이미지가 없거나 파일이 사라졌을 때 그대로 보인다.
  final Color color;

  /// 이 항목의 배경 이미지 경로. null 이면 [color] 단색 배경.
  final String? imagePath;

  /// 헌금송 배경이면 [imagePath] 를 구워 낸 디자인(이 항목의 높낮이 포함).
  /// 다시 열어 높낮이만 고치거나, PNG 가 사라졌을 때 다시 굽는 데 쓴다.
  /// 렌더러는 이 값을 보지 않는다 — 그들에겐 그냥 배경 이미지 한 장이다.
  final OfferingDesign? offering;

  bool get isOffering => offering != null;

  /// 이 항목만 가사 세로 위치를 바꾼다(찬양 가사·빈 페이지 문구. 성경은 해당 없음).
  /// 헌금송에서 "가사는 헌금 띠 위쪽"을 만들 때 쓴다. null 이면 전역 설정 그대로.
  ///
  /// 발표 창·미리보기는 [SlideBackgroundOverride.withBackground] 가 만든 스타일을 받으므로
  /// 따로 할 일이 없고, PPTX 는 `ppt_tool.py` 가 배경 JSON 의 같은 키를 읽어 덮어쓴다.
  final VerticalTextPosition? lyricsPosition;
  final double? lyricsOffsetY;

  bool get hasLyricsOverride => lyricsPosition != null || lyricsOffsetY != null;

  /// 이 항목만 글꼴·크기·글자 색을 바꾼다(가사·빈 페이지 문구. 성경은 해당 없음).
  /// 설교 제목 페이지가 찬양 디자인과 따로 놀게 하려고 쓴다. null 이면 전역 설정 그대로.
  /// 가사 위치처럼 [SlideBackgroundOverride.withBackground]·`ppt_tool.py _style_for_item` 이 덮어쓴다.
  final String? fontFamily;
  final double? fontSize;
  final Color? textColor;

  /// 설교 제목 페이지. 렌더러는 보지 않고, 콘티 목록 표시와 "배경 수정" 이 어느
  /// 다이얼로그를 열지만 가른다.
  final bool isSermon;

  /// 설교 제목 페이지 기본 디자인.
  factory SlideBackground.sermonDefault(ExportStyle style) => SlideBackground(
    color: style.backgroundColor,
    imagePath: style.backgroundImagePath,
    fontFamily: style.fontFamily,
    fontSize: 54,
    textColor: style.textColor,
    lyricsPosition: VerticalTextPosition.middle,
    lyricsOffsetY: 0,
    isSermon: true,
  );

  /// 전역 스타일의 배경을 그대로 복사한 오버라이드 시작값.
  factory SlideBackground.fromStyle(ExportStyle style) => SlideBackground(
    color: style.backgroundColor,
    imagePath: style.backgroundImagePath,
  );

  bool get hasImage => imagePath != null && imagePath!.isNotEmpty;

  SlideBackground copyWith({
    Color? color,
    Object? imagePath = _sentinel,
    Object? offering = _sentinel,
    Object? lyricsPosition = _sentinel,
    Object? lyricsOffsetY = _sentinel,
    Object? fontFamily = _sentinel,
    Object? fontSize = _sentinel,
    Object? textColor = _sentinel,
    bool? isSermon,
  }) {
    return SlideBackground(
      color: color ?? this.color,
      imagePath: identical(imagePath, _sentinel)
          ? this.imagePath
          : imagePath as String?,
      offering: identical(offering, _sentinel)
          ? this.offering
          : offering as OfferingDesign?,
      lyricsPosition: identical(lyricsPosition, _sentinel)
          ? this.lyricsPosition
          : lyricsPosition as VerticalTextPosition?,
      lyricsOffsetY: identical(lyricsOffsetY, _sentinel)
          ? this.lyricsOffsetY
          : lyricsOffsetY as double?,
      fontFamily: identical(fontFamily, _sentinel)
          ? this.fontFamily
          : fontFamily as String?,
      fontSize: identical(fontSize, _sentinel)
          ? this.fontSize
          : (fontSize as num?)?.toDouble(),
      textColor: identical(textColor, _sentinel)
          ? this.textColor
          : textColor as Color?,
      isSermon: isSermon ?? this.isSermon,
    );
  }

  Map<String, dynamic> toJson() => {
    'color': colorToHex(color),
    if (hasImage) 'image_path': imagePath,
    if (offering != null) 'offering': offering!.toJson(),
    if (lyricsPosition != null) 'text_position': lyricsPosition!.name,
    if (lyricsOffsetY != null) 'text_offset_y': lyricsOffsetY,
    if (fontFamily != null) 'font_family': fontFamily,
    if (fontSize != null) 'font_size': fontSize,
    if (textColor != null) 'text_color': colorToHex(textColor!),
    if (isSermon) 'sermon': true,
  };

  static SlideBackground? fromJson(Map<String, dynamic> json) {
    final color = tryParseHexColor(json['color'] as String?);
    if (color == null) return null;
    final path = json['image_path'] as String?;
    final offering = json['offering'];
    final position = json['text_position'] as String?;
    final offsetY = (json['text_offset_y'] as num?)?.toDouble();
    final fontSize = (json['font_size'] as num?)?.toDouble();
    return SlideBackground(
      color: color,
      imagePath: (path == null || path.isEmpty) ? null : path,
      offering: offering is Map
          ? OfferingDesign.fromJson(offering.cast<String, dynamic>())
          : null,
      lyricsPosition: VerticalTextPosition.values
          .where((v) => v.name == position)
          .firstOrNull,
      lyricsOffsetY: offsetY == null ? null : clampTextOffsetY(offsetY),
      fontFamily: json['font_family'] as String?,
      fontSize: fontSize == null || fontSize <= 0 ? null : fontSize,
      textColor: tryParseHexColor(json['text_color'] as String?),
      isSermon: json['sermon'] == true,
    );
  }

  /// DB 한 칸(TEXT)에 담기 위한 인코딩. 오버라이드가 없으면 null.
  static String? encode(SlideBackground? background) =>
      background == null ? null : jsonEncode(background.toJson());

  /// [encode] 의 역변환. 값이 깨져 있어도 콘티 전체를 못 불러오면 안 되므로 null 로 삼킨다.
  static SlideBackground? decode(Object? stored) {
    if (stored is! String || stored.isEmpty) return null;
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map) return null;
      return fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SlideBackground &&
      other.color == color &&
      other.imagePath == imagePath &&
      other.offering == offering &&
      other.lyricsPosition == lyricsPosition &&
      other.lyricsOffsetY == lyricsOffsetY &&
      other.fontFamily == fontFamily &&
      other.fontSize == fontSize &&
      other.textColor == textColor &&
      other.isSermon == isSermon;

  @override
  int get hashCode => Object.hash(
    color,
    imagePath,
    offering,
    lyricsPosition,
    lyricsOffsetY,
    fontFamily,
    fontSize,
    textColor,
    isSermon,
  );

  static const Object _sentinel = Object();
}

extension SlideBackgroundOverride on ExportStyle {
  /// 배경(과 항목별 가사 위치)을 [background] 로 갈아끼운 스타일. null 이면 전역 그대로.
  ExportStyle withBackground(SlideBackground? background) {
    if (background == null) return this;
    return copyWith(
      backgroundColor: background.color,
      backgroundImagePath: background.imagePath,
      textPosition: background.lyricsPosition,
      textOffsetY: background.lyricsOffsetY,
      fontFamily: background.fontFamily,
      fontSize: background.fontSize,
      textColor: background.textColor,
    );
  }
}
