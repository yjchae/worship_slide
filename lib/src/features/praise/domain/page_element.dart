import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import 'export_style.dart';

/// 글의 세로 맞춤(상자 안 위·가운데·아래). JSON 은 이름 그대로.
enum PageVAlign { top, middle, bottom }

/// 도형 모양. [json] = JSON `shape` 값.
enum PageShapeKind {
  rect('rect', '사각형'),
  roundRect('round_rect', '둥근 사각형'),
  ellipse('ellipse', '타원'),
  line('line', '선'),
  arrow('arrow', '화살표');

  const PageShapeKind(this.json, this.label);

  final String json;
  final String label;

  /// 선·화살표: rect 의 대각선(방향은 flip), 글 없음, 높이·너비 0 허용.
  bool get isLine => this == line || this == arrow;
}

/// 슬라이드 편집 페이지에 올린 요소 하나(그림·글 상자·도형).
///
/// [rect] 는 슬라이드 비율(0~1, x·y·w·h). 목록에서 뒤 요소가 위에 그려진다.
/// 저장은 `SlideBackground.pageElements` → 배경 JSON `page_elements`.
@immutable
sealed class PageElement {
  const PageElement({
    required this.id,
    required this.rect,
    this.appear = 0,
    this.disappear = 0,
  }) : assert(disappear == 0 || disappear > appear);

  final String id;
  final Rect rect;

  /// 몇 번째 클릭에 나타나는지(0 = 처음부터, 1..[maxAppear]). 편집 페이지는 단계마다 PNG 한 장을 굽는다
  /// ([pageSteps]). JSON `appear`, 0 이면 키를 안 쓴다(옛 페이지 JSON·굽기 캐시 키 그대로).
  final int appear;

  /// 몇 번째 클릭에 사라지는지(0 = 끝까지 보임, 아니면 [appear] 보다 크다, 상한 [maxAppear]).
  /// 단계 s 에서 보임 = `appear ≤ s` 이고 (`disappear` 가 0 이거나 `s < disappear`). JSON `disappear`, 0 이면 키 없음.
  final int disappear;

  static const int maxAppear = 30;

  /// 단계 [s] 에서 보이는지.
  bool visibleAt(int s) => appear <= s && (disappear == 0 || s < disappear);

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

  /// 선·화살표용: 너비·높이 0 을 허용하고 긴 쪽만 [minSize] 이상.
  static Rect clampFlatRect(Rect r) {
    double fin(double v) => v.isFinite ? v : 0;
    var w = fin(r.width).clamp(0.0, maxSize);
    var h = fin(r.height).clamp(0.0, maxSize);
    if (max(w, h) < minSize) {
      if (w >= h) {
        w = minSize;
      } else {
        h = minSize;
      }
    }
    return Rect.fromLTWH(
      fin(r.left).clamp(minVisible - w, 1 - minVisible),
      fin(r.top).clamp(minVisible - h, 1 - minVisible),
      w,
      h,
    );
  }

  /// 이 요소에 맞는 규칙으로 자리를 맞춘다(선·화살표만 [clampFlatRect]).
  Rect fitRect(Rect r) => clampRect(r);

  /// 새 요소 id(16자리 hex). 한 페이지 안에서만 겹치지 않으면 된다.
  static String newId() {
    final random = Random();
    return List.generate(
      16,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
  }

  PageElement copyWith({String? id, Rect? rect, int? appear, int? disappear});

  Map<String, dynamic> toJson();

  List<double> get _rectJson => [rect.left, rect.top, rect.width, rect.height];

  Map<String, dynamic> get _appearJson => {
    if (appear > 0) 'appear': appear,
    if (disappear > 0) 'disappear': disappear,
  };

  /// 모양이 틀린 요소(종류·자리·경로가 없거나 숫자가 아님)는 null. 틀린 숫자는 범위 안으로, 모르는 `shape` 는 사각형.
  /// 이 판이 모르는 종류(`type` 이 글자)는 [PageUnknownElement] 로 그대로 보존한다.
  static PageElement? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'] is String && (raw['id'] as String).isNotEmpty
        ? raw['id'] as String
        : newId();
    final type = raw['type'];
    if (type is String &&
        type.isNotEmpty &&
        type != 'image' &&
        type != 'text' &&
        type != 'shape') {
      // 새 판이 정한 rect 규칙을 모르니 rect 도 날 값 그대로 둔다.
      return PageUnknownElement(
        id: id,
        rect: _parseRect(raw['rect']) ?? Rect.zero,
        raw: {...raw.cast<String, dynamic>(), 'id': id},
      );
    }
    final kind = type == 'shape'
        ? PageShapeKind.values
                  .where((k) => k.json == raw['shape'])
                  .firstOrNull ??
              PageShapeKind.rect
        : null;
    final rect = _parseRect(raw['rect'], flat: kind?.isLine ?? false);
    if (rect == null) return null;
    int step(Object? v) =>
        v is num && v.isFinite ? v.toInt().clamp(0, maxAppear) : 0;
    final appear = step(raw['appear']);
    final gone = step(raw['disappear']);
    final disappear = gone > appear ? gone : 0;
    if (type == 'image') {
      final path = raw['path'];
      if (path is! String || path.isEmpty) return null;
      return PageImageElement(
        id: id,
        rect: rect,
        path: path,
        appear: appear,
        disappear: disappear,
      );
    }
    if (type != 'text' && kind == null) return null;
    double num01(Object? v, double fallback, double max) =>
        v is num && v.isFinite ? v.toDouble().clamp(0.0, max) : fallback;
    final size = raw['font_size'];
    final family = raw['font_family'];
    final text = PageTextElement(
      id: id,
      rect: rect,
      appear: appear,
      disappear: disappear,
      text: raw['text'] is String ? raw['text'] as String : '',
      fontSize: size is num && size.isFinite && size > 0
          ? size.toDouble().clamp(
              PageTextElement.minFontSize,
              PageTextElement.maxFontSize,
            )
          : PageTextElement.defaultFontSize,
      color:
          tryParseHexColor(
            raw['color'] is String ? raw['color'] as String : null,
          ) ??
          (kind == null ? Colors.white : Colors.black),
      bold: raw['bold'] == true,
      align: switch (raw['align']) {
        'left' => TextAlign.left,
        'right' => TextAlign.right,
        _ => TextAlign.center,
      },
      fontFamily: family is String && family.isNotEmpty
          ? family
          : PageTextElement.defaultFontFamily,
      rich: raw['rich'] is String && (raw['rich'] as String).isNotEmpty
          ? raw['rich'] as String
          : null,
      valign:
          PageVAlign.values.where((v) => v.name == raw['valign']).firstOrNull ??
          (kind == null ? PageVAlign.top : PageVAlign.middle),
    );
    if (kind == null) return text;
    // 키가 없거나 틀린 색 = 기본값, 명시한 null = 없음.
    Color? color(String key, Color? fallback) => !raw.containsKey(key)
        ? fallback
        : raw[key] == null
        ? null
        : tryParseHexColor(raw[key] is String ? raw[key] as String : null) ??
              fallback;
    return PageShapeElement.withText(
      text,
      kind: kind,
      fill: color('fill', Colors.white),
      fillAlpha: num01(raw['fill_alpha'], 1, 1),
      stroke: color('stroke', null),
      strokeWidth: num01(
        raw['stroke_width'],
        PageShapeElement.defaultStrokeWidth,
        PageShapeElement.maxStrokeWidth,
      ),
      radius: num01(raw['radius'], PageShapeElement.defaultRadius, 0.5),
      flipH: raw['flip_h'] == true,
      flipV: raw['flip_v'] == true,
    );
  }

  /// 목록에서 틀린 요소만 버린다. 목록이 아니면 빈 목록.
  static List<PageElement> listFromJson(Object? raw) => [
    if (raw is List)
      for (final e in raw) ?fromJson(e),
  ];

  /// [flat] = 선·화살표(너비·높이 0 허용, 음수·둘 다 0 은 틀림).
  static Rect? _parseRect(Object? raw, {bool flat = false}) {
    if (raw is! List || raw.length != 4) return null;
    final v = <double>[];
    for (final n in raw) {
      if (n is! num || !n.isFinite) return null;
      v.add(n.toDouble());
    }
    final r = Rect.fromLTWH(v[0], v[1], v[2], v[3]);
    if (flat) {
      if (v[2] < 0 || v[3] < 0 || v[2] + v[3] <= 0) return null;
      return clampFlatRect(r);
    }
    if (v[2] <= 0 || v[3] <= 0) return null;
    return clampRect(r);
  }
}

/// 그림 요소. [path] 는 `page_images/` 에 복사해 둔 원본. 상자를 꽉 채워 그린다(비율은 편집 창이 지킨다).
final class PageImageElement extends PageElement {
  const PageImageElement({
    required super.id,
    required super.rect,
    required this.path,
    super.appear,
    super.disappear,
  });

  final String path;

  @override
  PageImageElement copyWith({
    String? id,
    Rect? rect,
    String? path,
    int? appear,
    int? disappear,
  }) => PageImageElement(
    id: id ?? this.id,
    rect: rect ?? this.rect,
    path: path ?? this.path,
    appear: appear ?? this.appear,
    disappear: disappear ?? this.disappear,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'image',
    'id': id,
    'rect': _rectJson,
    'path': path,
    ..._appearJson,
  };

  @override
  bool operator ==(Object other) =>
      other is PageImageElement &&
      other.id == id &&
      other.rect == rect &&
      other.path == path &&
      other.appear == appear &&
      other.disappear == disappear;

  @override
  int get hashCode => Object.hash(id, rect, path, appear, disappear);
}

/// 글 상자. 글은 상자 너비에서 줄을 바꾸고 [valign] 대로 놓인다(넘치면 위아래로 삐져나온다).
/// 도형([PageShapeElement])이 이 글 칸을 물려받아 편집기·리본·굽기·넘침 측정을 같이 쓴다.
base class PageTextElement extends PageElement {
  const PageTextElement({
    required super.id,
    required super.rect,
    this.text = '',
    this.fontSize = defaultFontSize,
    this.color = Colors.white,
    this.bold = false,
    this.align = TextAlign.center,
    this.fontFamily = defaultFontFamily,
    this.rich,
    this.valign = PageVAlign.top,
    super.appear,
    super.disappear,
  });

  /// 글 전체(서식 뺀 평문). 비었는지·넘침·페이지 이름은 이걸로 본다.
  final String text;

  /// 부분 서식이 든 글: flutter_quill Delta ops 의 JSON 문자열(null = 서식 없는 평문).
  /// 렌더는 `PageTextBlock`(page_rich_text.dart). [text] 는 늘 이 글의 평문과 같게 둔다.
  final String? rich;

  /// 슬라이드 높이 540pt 기준(1920x1080 에서는 ×2 px).
  final double fontSize;
  final Color color;
  final bool bold;

  /// left·center·right 만.
  final TextAlign align;
  final String fontFamily;

  /// 세로 맞춤. 글 상자 기본 top(키 없는 옛 페이지 그대로), 도형 기본 middle.
  final PageVAlign valign;

  /// 안에 글을 쓸 수 있는지(선·화살표만 아님).
  bool get holdsText => true;

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
    Object? rich = _keep,
    PageVAlign? valign,
    int? appear,
    int? disappear,
  }) => PageTextElement(
    id: id ?? this.id,
    rect: rect ?? this.rect,
    appear: appear ?? this.appear,
    disappear: disappear ?? this.disappear,
    text: text ?? this.text,
    fontSize: fontSize ?? this.fontSize,
    color: color ?? this.color,
    bold: bold ?? this.bold,
    align: align ?? this.align,
    fontFamily: fontFamily ?? this.fontFamily,
    rich: identical(rich, _keep) ? this.rich : rich as String?,
    valign: valign ?? this.valign,
  );

  static const Object _keep = Object();

  Map<String, dynamic> get _textJson => {
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
    'rich': ?rich,
  };

  @override
  Map<String, dynamic> toJson() => {
    'type': 'text',
    'id': id,
    'rect': _rectJson,
    ..._textJson,
    // top 은 안 쓴다 — 옛 페이지 JSON(굽기 캐시 키)이 그대로다.
    if (valign != PageVAlign.top) 'valign': valign.name,
    ..._appearJson,
  };

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is PageTextElement &&
      other.id == id &&
      other.rect == rect &&
      other.text == text &&
      other.fontSize == fontSize &&
      other.color == color &&
      other.bold == bold &&
      other.align == align &&
      other.fontFamily == fontFamily &&
      other.rich == rich &&
      other.valign == valign &&
      other.appear == appear &&
      other.disappear == disappear;

  @override
  int get hashCode => Object.hash(
    id,
    rect,
    text,
    fontSize,
    color,
    bold,
    align,
    fontFamily,
    rich,
    valign,
    appear,
    disappear,
  );
}

/// 도형(사각형·둥근 사각형·타원·선·화살표). 채우기 → 테두리 위에 글 칸(글 상자와 같은 것)을
/// 안쪽 여백([textInsetH]·[textInsetV]) 안에 [valign] 대로 놓는다. 선·화살표는 rect 의 대각선이고
/// 글이 없다 — 시작 모서리는 [flipH](오른쪽)·[flipV](아래), 화살표 머리는 끝점이다.
final class PageShapeElement extends PageTextElement {
  const PageShapeElement({
    required super.id,
    required super.rect,
    required this.kind,
    this.fill = Colors.white,
    this.fillAlpha = 1,
    this.stroke,
    this.strokeWidth = defaultStrokeWidth,
    this.radius = defaultRadius,
    this.flipH = false,
    this.flipV = false,
    super.text,
    super.fontSize,
    super.color = Colors.black,
    super.bold,
    super.align,
    super.fontFamily,
    super.rich,
    super.valign = PageVAlign.middle,
    super.appear,
    super.disappear,
  });

  /// [t] 의 id·자리·글 칸 그대로.
  PageShapeElement.withText(
    PageTextElement t, {
    required this.kind,
    this.fill = Colors.white,
    this.fillAlpha = 1,
    this.stroke,
    this.strokeWidth = defaultStrokeWidth,
    this.radius = defaultRadius,
    this.flipH = false,
    this.flipV = false,
  }) : super(
         id: t.id,
         rect: t.rect,
         text: t.text,
         fontSize: t.fontSize,
         color: t.color,
         bold: t.bold,
         align: t.align,
         fontFamily: t.fontFamily,
         rich: t.rich,
         valign: t.valign,
         appear: t.appear,
         disappear: t.disappear,
       );

  final PageShapeKind kind;

  /// null = 채우기 없음. 색은 6자리, 투명도는 [fillAlpha](0~1, 1 = 불투명).
  final Color? fill;
  final double fillAlpha;

  /// null = 테두리 없음(선·화살표는 안 보인다).
  final Color? stroke;

  /// 540pt 기준 pt(0~[maxStrokeWidth]).
  final double strokeWidth;

  /// 둥근 사각형 모서리 반지름(짧은 변 대비 0~0.5).
  final double radius;
  final bool flipH;
  final bool flipV;

  static const double defaultStrokeWidth = 3;
  static const double maxStrokeWidth = 40;
  static const double defaultRadius = 0.1667;

  /// 글 안쪽 여백(540pt 기준 pt) — PPTX 기본 좌우 0.1in·위아래 0.05in.
  static const double textInsetH = 7.2;
  static const double textInsetV = 3.6;

  @override
  bool get holdsText => !kind.isLine;

  @override
  Rect fitRect(Rect r) =>
      kind.isLine ? PageElement.clampFlatRect(r) : PageElement.clampRect(r);

  /// 선의 (시작, 끝) 점(슬라이드 비율).
  (Offset, Offset) get linePoints {
    final a = Offset(
      flipH ? rect.right : rect.left,
      flipV ? rect.bottom : rect.top,
    );
    final b = Offset(
      flipH ? rect.left : rect.right,
      flipV ? rect.top : rect.bottom,
    );
    return (a, b);
  }

  /// 두 점(시작 → 끝)을 잇는 선으로 자리·방향을 바꾼다.
  PageShapeElement withLinePoints(Offset a, Offset b) => copyWith(
    rect: fitRect(Rect.fromPoints(a, b)),
    flipH: a.dx > b.dx,
    flipV: a.dy > b.dy,
  );

  @override
  PageShapeElement copyWith({
    String? id,
    Rect? rect,
    String? text,
    double? fontSize,
    Color? color,
    bool? bold,
    TextAlign? align,
    String? fontFamily,
    Object? rich = PageTextElement._keep,
    PageVAlign? valign,
    int? appear,
    int? disappear,
    PageShapeKind? kind,
    Object? fill = PageTextElement._keep,
    double? fillAlpha,
    Object? stroke = PageTextElement._keep,
    double? strokeWidth,
    double? radius,
    bool? flipH,
    bool? flipV,
  }) => PageShapeElement.withText(
    super.copyWith(
      id: id,
      rect: rect,
      text: text,
      fontSize: fontSize,
      color: color,
      bold: bold,
      align: align,
      fontFamily: fontFamily,
      rich: rich,
      valign: valign,
      appear: appear,
      disappear: disappear,
    ),
    kind: kind ?? this.kind,
    fill: identical(fill, PageTextElement._keep) ? this.fill : fill as Color?,
    fillAlpha: fillAlpha ?? this.fillAlpha,
    stroke: identical(stroke, PageTextElement._keep)
        ? this.stroke
        : stroke as Color?,
    strokeWidth: strokeWidth ?? this.strokeWidth,
    radius: radius ?? this.radius,
    flipH: flipH ?? this.flipH,
    flipV: flipV ?? this.flipV,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'shape',
    'id': id,
    'rect': _rectJson,
    'shape': kind.json,
    'fill': fill == null ? null : colorToHex(fill!),
    'fill_alpha': fillAlpha,
    'stroke': stroke == null ? null : colorToHex(stroke!),
    'stroke_width': strokeWidth,
    'radius': radius,
    'flip_h': flipH,
    'flip_v': flipV,
    ..._textJson,
    'valign': valign.name,
    ..._appearJson,
  };

  @override
  bool operator ==(Object other) =>
      super == other &&
      other is PageShapeElement &&
      other.kind == kind &&
      other.fill == fill &&
      other.fillAlpha == fillAlpha &&
      other.stroke == stroke &&
      other.strokeWidth == strokeWidth &&
      other.radius == radius &&
      other.flipH == flipH &&
      other.flipV == flipV;

  @override
  int get hashCode => Object.hash(
    super.hashCode,
    kind,
    fill,
    fillAlpha,
    stroke,
    strokeWidth,
    radius,
    flipH,
    flipV,
  );
}

/// 이 판이 모르는 종류의 요소(새 판이 만든 도형 등). 캔버스·굽기에 그리지 않고 고를 수도 없지만
/// JSON 을 [raw] 그대로 들고 있다가 저장할 때 되돌려 놓는다(옛 판에서 고쳐도 사라지지 않게).
final class PageUnknownElement extends PageElement {
  const PageUnknownElement({
    required super.id,
    required super.rect,
    required this.raw,
  });

  /// 읽은 JSON 그대로(`id` 만 채워 둠).
  final Map<String, dynamic> raw;

  String get type => raw['type'] as String;

  /// 고를 수 없으니 자리·id 를 바꿀 일이 없다 — 복제 같은 경로가 불러도 날 JSON 은 그대로 둔다.
  @override
  PageUnknownElement copyWith({
    String? id,
    Rect? rect,
    int? appear,
    int? disappear,
  }) => PageUnknownElement(
    id: id ?? this.id,
    rect: rect ?? this.rect,
    raw: {...raw, 'id': id ?? this.id},
  );

  @override
  Map<String, dynamic> toJson() => raw;

  @override
  bool operator ==(Object other) =>
      other is PageUnknownElement &&
      other.id == id &&
      jsonEncode(other.raw) == jsonEncode(raw);

  @override
  int get hashCode => Object.hash(id, jsonEncode(raw));
}

/// 편집 페이지의 클릭 단계마다 보이는 요소 목록(앞 = 처음 화면).
/// 쓰인 `appear`·`disappear` 값마다 한 장이고 0단계는 늘 있다 — appear {0,1,1,3} 이면 3장(0 / 0·1·1 / 전부).
/// 사라지는 요소가 있으면 마지막 장이 '전부'가 아니다. 애니메이션이 없으면 [elements] 그대로 한 장.
List<List<PageElement>> pageSteps(List<PageElement> elements) => [
  for (final k in _stepLevels(elements)) elementsAtStep(elements, k),
];

/// 구울 PNG 장 수([pageSteps] 길이).
int pageStepCount(List<PageElement> elements) => _stepLevels(elements).length;

/// [k] 번째 클릭 뒤 보이는 요소([PageElement.visibleAt]). 순서는 그대로.
List<PageElement> elementsAtStep(List<PageElement> elements, int k) => [
  for (final e in elements)
    if (e.visibleAt(k)) e,
];

List<int> _stepLevels(List<PageElement> elements) => {
  0,
  for (final e in elements) ...[e.appear, e.disappear],
}.toList()..sort();

/// 쓰인 단계(appear·disappear 합쳐)만 1..n 으로 다시 매긴다(빈 단계 = 같은 그림 두 장이 생기지 않게).
/// appear {0,1,1,3} → {0,1,1,2}. disappear 0(없음)은 0 그대로.
List<PageElement> normalizeAppear(List<PageElement> elements) {
  final levels = _stepLevels(elements);
  final rank = {for (var i = 0; i < levels.length; i++) levels[i]: i};
  return [
    for (final e in elements)
      rank[e.appear] == e.appear && rank[e.disappear] == e.disappear
          ? e
          : e.copyWith(appear: rank[e.appear], disappear: rank[e.disappear]),
  ];
}
