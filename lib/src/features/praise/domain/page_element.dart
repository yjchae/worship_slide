import 'dart:math';

import 'package:flutter/material.dart';

import 'export_style.dart';

/// 슬라이드 편집 페이지에 올린 요소 하나(그림 또는 글 상자).
///
/// [rect] 는 슬라이드 비율(0~1, x·y·w·h). 목록에서 뒤 요소가 위에 그려진다.
/// 저장은 `SlideBackground.pageElements` → 배경 JSON `page_elements`.
@immutable
sealed class PageElement {
  const PageElement({required this.id, required this.rect});

  final String id;
  final Rect rect;

  /// 가장 작은 너비·높이(슬라이드 비율).
  static const double minSize = 0.02;

  /// 가장 큰 너비·높이. 슬라이드보다 크게 키워 일부만 보이게 하는 것까지는 둔다.
  static const double maxSize = 2.0;

  /// 밖으로 끌어도 슬라이드 안에 남는 몫.
  static const double minVisible = 0.05;

  /// w·h 를 [minSize]~[maxSize] 로, 슬라이드 안에 [minVisible] 이상 남게 x·y 를 맞춘다.
  static Rect clampRect(Rect r) {
    double fin(double v, double fallback) => v.isFinite ? v : fallback;
    final w = fin(r.width, minSize).clamp(minSize, maxSize);
    final h = fin(r.height, minSize).clamp(minSize, maxSize);
    return Rect.fromLTWH(
      fin(r.left, 0).clamp(minVisible - w, 1 - minVisible),
      fin(r.top, 0).clamp(minVisible - h, 1 - minVisible),
      w,
      h,
    );
  }

  /// 새 요소 id(16자리 hex). 한 페이지 안에서만 겹치지 않으면 된다.
  static String newId() {
    final random = Random();
    return List.generate(
      16,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
  }

  PageElement copyWith({String? id, Rect? rect});

  Map<String, dynamic> toJson();

  List<double> get _rectJson => [rect.left, rect.top, rect.width, rect.height];

  /// 모양이 틀린 요소(종류·자리·경로가 없거나 숫자가 아님)는 null.
  static PageElement? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final rect = _parseRect(raw['rect']);
    if (rect == null) return null;
    final id = raw['id'] is String && (raw['id'] as String).isNotEmpty
        ? raw['id'] as String
        : newId();
    switch (raw['type']) {
      case 'image':
        final path = raw['path'];
        if (path is! String || path.isEmpty) return null;
        return PageImageElement(id: id, rect: rect, path: path);
      case 'text':
        final text = raw['text'];
        final size = raw['font_size'];
        final family = raw['font_family'];
        return PageTextElement(
          id: id,
          rect: rect,
          text: text is String ? text : '',
          fontSize: size is num && size.isFinite && size > 0
              ? size.toDouble().clamp(
                  PageTextElement.minFontSize,
                  PageTextElement.maxFontSize,
                )
              : PageTextElement.defaultFontSize,
          color: tryParseHexColor(raw['color'] as String?) ?? Colors.white,
          bold: raw['bold'] == true,
          align: switch (raw['align']) {
            'left' => TextAlign.left,
            'right' => TextAlign.right,
            _ => TextAlign.center,
          },
          fontFamily: family is String && family.isNotEmpty
              ? family
              : PageTextElement.defaultFontFamily,
        );
    }
    return null;
  }

  /// 목록에서 틀린 요소만 버린다. 목록이 아니면 빈 목록.
  static List<PageElement> listFromJson(Object? raw) => [
    if (raw is List)
      for (final e in raw) ?fromJson(e),
  ];

  static Rect? _parseRect(Object? raw) {
    if (raw is! List || raw.length != 4) return null;
    final v = <double>[];
    for (final n in raw) {
      if (n is! num || !n.isFinite) return null;
      v.add(n.toDouble());
    }
    if (v[2] <= 0 || v[3] <= 0) return null;
    return clampRect(Rect.fromLTWH(v[0], v[1], v[2], v[3]));
  }
}

/// 그림 요소. [path] 는 `page_images/` 에 복사해 둔 원본. 상자를 꽉 채워 그린다(비율은 편집 창이 지킨다).
final class PageImageElement extends PageElement {
  const PageImageElement({
    required super.id,
    required super.rect,
    required this.path,
  });

  final String path;

  @override
  PageImageElement copyWith({String? id, Rect? rect, String? path}) =>
      PageImageElement(
        id: id ?? this.id,
        rect: rect ?? this.rect,
        path: path ?? this.path,
      );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'image',
    'id': id,
    'rect': _rectJson,
    'path': path,
  };

  @override
  bool operator ==(Object other) =>
      other is PageImageElement &&
      other.id == id &&
      other.rect == rect &&
      other.path == path;

  @override
  int get hashCode => Object.hash(id, rect, path);
}

/// 글 상자. 글은 상자 너비에서 줄을 바꾸고 위에서부터 놓인다(넘치면 아래로 삐져나온다).
final class PageTextElement extends PageElement {
  const PageTextElement({
    required super.id,
    required super.rect,
    this.text = '',
    this.fontSize = defaultFontSize,
    this.color = Colors.white,
    this.bold = false,
    this.align = TextAlign.center,
    this.fontFamily = defaultFontFamily,
  });

  final String text;

  /// 슬라이드 높이 540pt 기준(1920x1080 에서는 ×2 px).
  final double fontSize;
  final Color color;
  final bool bold;

  /// left·center·right 만.
  final TextAlign align;
  final String fontFamily;

  static const double defaultFontSize = 40;
  static const double minFontSize = 8;
  static const double maxFontSize = 300;
  static const String defaultFontFamily = 'Pretendard';

  @override
  PageTextElement copyWith({
    String? id,
    Rect? rect,
    String? text,
    double? fontSize,
    Color? color,
    bool? bold,
    TextAlign? align,
    String? fontFamily,
  }) => PageTextElement(
    id: id ?? this.id,
    rect: rect ?? this.rect,
    text: text ?? this.text,
    fontSize: fontSize ?? this.fontSize,
    color: color ?? this.color,
    bold: bold ?? this.bold,
    align: align ?? this.align,
    fontFamily: fontFamily ?? this.fontFamily,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'text',
    'id': id,
    'rect': _rectJson,
    'text': text,
    'font_size': fontSize,
    'color': colorToHex(color),
    'bold': bold,
    'align': switch (align) {
      TextAlign.left || TextAlign.start => 'left',
      TextAlign.right || TextAlign.end => 'right',
      _ => 'center',
    },
    'font_family': fontFamily,
  };

  @override
  bool operator ==(Object other) =>
      other is PageTextElement &&
      other.id == id &&
      other.rect == rect &&
      other.text == text &&
      other.fontSize == fontSize &&
      other.color == color &&
      other.bold == bold &&
      other.align == align &&
      other.fontFamily == fontFamily;

  @override
  int get hashCode =>
      Object.hash(id, rect, text, fontSize, color, bold, align, fontFamily);
}
