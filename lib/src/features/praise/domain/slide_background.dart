import 'dart:convert';

import 'package:flutter/material.dart';

import 'export_style.dart';

/// 콘티 항목 하나에만 적용되는 배경.
///
/// 전역 [ExportStyle]의 배경(색 + 이미지)을 통째로 대체한다. "헌금송만 다른 배경"처럼
/// 콘티의 일부 항목만 배경을 다르게 하고 싶을 때 쓴다. 배경 외의 디자인(글자 색·크기·
/// 위치 등)은 전역 설정을 그대로 따른다.
///
/// 오버라이드가 없는 항목은 이 객체 자체가 `null` 이고, 전역 배경이 그대로 쓰인다.
@immutable
class SlideBackground {
  const SlideBackground({required this.color, this.imagePath});

  /// 이 항목의 배경 색. 이미지가 없거나 파일이 사라졌을 때 그대로 보인다.
  final Color color;

  /// 이 항목의 배경 이미지 경로. null 이면 [color] 단색 배경.
  final String? imagePath;

  /// 전역 스타일의 배경을 그대로 복사한 오버라이드 시작값.
  factory SlideBackground.fromStyle(ExportStyle style) => SlideBackground(
    color: style.backgroundColor,
    imagePath: style.backgroundImagePath,
  );

  bool get hasImage => imagePath != null && imagePath!.isNotEmpty;

  SlideBackground copyWith({Color? color, Object? imagePath = _sentinel}) {
    return SlideBackground(
      color: color ?? this.color,
      imagePath: identical(imagePath, _sentinel)
          ? this.imagePath
          : imagePath as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'color': colorToHex(color),
    if (hasImage) 'image_path': imagePath,
  };

  static SlideBackground? fromJson(Map<String, dynamic> json) {
    final color = tryParseHexColor(json['color'] as String?);
    if (color == null) return null;
    final path = json['image_path'] as String?;
    return SlideBackground(
      color: color,
      imagePath: (path == null || path.isEmpty) ? null : path,
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
      other.imagePath == imagePath;

  @override
  int get hashCode => Object.hash(color, imagePath);

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
