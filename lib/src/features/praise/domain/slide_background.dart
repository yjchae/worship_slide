import 'dart:convert';

import 'package:flutter/material.dart';

import 'export_style.dart';
import 'offering_design.dart';

/// 콘티 항목 하나에만 적용되는 배경.
///
/// 전역 [ExportStyle]의 배경(색 + 이미지)을 통째로 대체한다. "헌금송만 다른 배경"처럼
/// 콘티의 일부 항목만 배경을 다르게 하고 싶을 때 쓴다. 배경 외의 디자인(글자 색·크기·
/// 위치 등)은 전역 설정을 그대로 따른다.
///
/// 오버라이드가 없는 항목은 이 객체 자체가 `null` 이고, 전역 배경이 그대로 쓰인다.
@immutable
class SlideBackground {
  const SlideBackground({required this.color, this.imagePath, this.offering});

  /// 이 항목의 배경 색. 이미지가 없거나 파일이 사라졌을 때 그대로 보인다.
  final Color color;

  /// 이 항목의 배경 이미지 경로. null 이면 [color] 단색 배경.
  final String? imagePath;

  /// 헌금송 배경이면 [imagePath] 를 구워 낸 디자인(이 항목의 높낮이 포함).
  /// 다시 열어 높낮이만 고치거나, PNG 가 사라졌을 때 다시 굽는 데 쓴다.
  /// 렌더러는 이 값을 보지 않는다 — 그들에겐 그냥 배경 이미지 한 장이다.
  final OfferingDesign? offering;

  bool get isOffering => offering != null;

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
  }) {
    return SlideBackground(
      color: color ?? this.color,
      imagePath: identical(imagePath, _sentinel)
          ? this.imagePath
          : imagePath as String?,
      offering: identical(offering, _sentinel)
          ? this.offering
          : offering as OfferingDesign?,
    );
  }

  Map<String, dynamic> toJson() => {
    'color': colorToHex(color),
    if (hasImage) 'image_path': imagePath,
    if (offering != null) 'offering': offering!.toJson(),
  };

  static SlideBackground? fromJson(Map<String, dynamic> json) {
    final color = tryParseHexColor(json['color'] as String?);
    if (color == null) return null;
    final path = json['image_path'] as String?;
    final offering = json['offering'];
    return SlideBackground(
      color: color,
      imagePath: (path == null || path.isEmpty) ? null : path,
      offering: offering is Map
          ? OfferingDesign.fromJson(offering.cast<String, dynamic>())
          : null,
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
      other.offering == offering;

  @override
  int get hashCode => Object.hash(color, imagePath, offering);

  static const Object _sentinel = Object();
}

extension SlideBackgroundOverride on ExportStyle {
  /// 배경만 [background] 로 갈아끼운 스타일. null 이면 전역 배경 그대로.
  ExportStyle withBackground(SlideBackground? background) {
    if (background == null) return this;
    return copyWith(
      backgroundColor: background.color,
      backgroundImagePath: background.imagePath,
    );
  }
}
