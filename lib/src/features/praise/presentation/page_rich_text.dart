import 'dart:convert';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' show TextBlockUtils;

import '../domain/export_style.dart';
import '../domain/page_element.dart';

// 글 상자 글(`rich` = flutter_quill Delta JSON)을 줄 단위로 다룬다.
//
// 굽기([PageTextBlock])·넘침 측정([measurePageText])·편집 창 캔버스 안 편집기(Quill, page_text_editor.dart)가
// 같은 규칙으로 줄을 놓는다: 줄마다 따로 RichText, 줄 높이 strut = 상자 기본 서식, 줄 간격 0,
// 글머리·번호는 왼쪽 기호 칸(폭은 flutter_quill 공식) + 본문 내어쓰기. 정렬은 상자 하나(`align`).

/// 글자 단위로 받는 서식 키. 그 밖(제목·코드·들여쓰기 등)은 읽을 때 버린다.
const pageInlineKeys = {
  'bold',
  'italic',
  'underline',
  'strike',
  'color',
  'size',
  'font',
};

/// 글자 한 덩어리(같은 서식).
typedef PageSpan = ({String text, Map<String, Object> attrs});

/// 한 줄(문단). [list] = 'bullet' | 'ordered' | null.
@immutable
class PageRichLine {
  const PageRichLine(this.spans, {this.list});

  final List<PageSpan> spans;
  final String? list;

  String get text => spans.map((s) => s.text).join();
}

/// 요소의 글을 줄 목록으로. 서식이 없거나 rich 가 깨졌으면 평문(`text`) 그대로.
List<PageRichLine> pageRichLines(PageTextElement e) {
  final rich = e.rich;
  if (rich != null) {
    try {
      final ops = jsonDecode(rich);
      if (ops is List) return pageRichLinesFromOps(ops);
    } catch (_) {
      // 깨진 JSON 은 평문으로 — 글이 사라지지 않게.
    }
  }
  return [
    for (final line in e.text.split('\n'))
      PageRichLine([if (line.isNotEmpty) (text: line, attrs: const {})]),
  ];
}

/// Delta ops → 줄 목록. 줄 서식은 그 줄 끝 `\n` 의 attributes 에 있다.
List<PageRichLine> pageRichLinesFromOps(List ops) {
  final lines = <PageRichLine>[];
  var spans = <PageSpan>[];
  for (final op in ops) {
    if (op is! Map || op['insert'] is! String) continue;
    final raw = op['attributes'] is Map ? op['attributes'] as Map : const {};
    final attrs = pageInlineAttrs(raw);
    final parts = (op['insert'] as String).split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isNotEmpty) _addSpan(spans, parts[i], attrs);
      if (i < parts.length - 1) {
        final list = raw['list'];
        lines.add(
          PageRichLine(
            spans,
            list: list == 'bullet' || list == 'ordered' ? list as String : null,
          ),
        );
        spans = [];
      }
    }
  }
  if (spans.isNotEmpty || lines.isEmpty) lines.add(PageRichLine(spans));
  return lines;
}

void _addSpan(List<PageSpan> spans, String text, Map<String, Object> attrs) {
  if (spans.isNotEmpty && mapEquals(spans.last.attrs, attrs)) {
    spans.last = (text: spans.last.text + text, attrs: attrs);
  } else {
    spans.add((text: text, attrs: attrs));
  }
}

Map<String, Object> pageInlineAttrs(Map raw) => {
  for (final MapEntry(:key, :value) in raw.entries)
    if (pageInlineKeys.contains(key) &&
        value != null &&
        // 기울임·밑줄·취소선은 켬만 뜻이 있다(굵게는 false = 상자 굵게를 끔).
        (value != false || key == 'bold'))
      key as String: value as Object,
};

/// 줄 목록 → Delta ops(같은 서식 덩어리는 합친다). [align] 을 주면 줄마다 넣는다(편집기용).
List<Map<String, Object>> pageRichOps(
  List<PageRichLine> lines, {
  String? align,
}) {
  final ops = <Map<String, Object>>[];
  void add(String text, Map<String, Object> attrs) {
    final last = ops.lastOrNull;
    if (last != null &&
        mapEquals(last['attributes'] as Map? ?? const {}, attrs)) {
      last['insert'] = (last['insert'] as String) + text;
    } else {
      ops.add({'insert': text, if (attrs.isNotEmpty) 'attributes': attrs});
    }
  }

  for (final line in lines) {
    for (final s in line.spans) {
      add(s.text, s.attrs);
    }
    add('\n', {'list': ?line.list, 'align': ?align});
  }
  return ops;
}

/// 요소의 `rich` 칸 값: 서식이 하나도 없으면 null(평문 상자와 같은 기준).
String? encodePageRich(List<PageRichLine> lines) {
  final ops = pageRichOps(lines);
  return ops.any((op) => op.containsKey('attributes')) ? jsonEncode(ops) : null;
}

/// 상자 기본 서식(줄 높이 strut 도 이것). [fontScale] = 540pt → 캔버스 px.
TextStyle pageBaseStyle(PageTextElement e, double fontScale) => TextStyle(
  fontFamily: e.fontFamily,
  fontSize: e.fontSize * fontScale,
  color: e.color,
  fontWeight: e.bold ? FontWeight.w700 : FontWeight.w400,
);

/// 글자 서식 → TextStyle(상자 기본 위에 덮는다).
TextStyle? pageInlineStyle(Map<String, Object> a, double fontScale) {
  if (a.isEmpty) return null;
  final size = pageAttrSize(a);
  final decorations = [
    if (a['underline'] == true) TextDecoration.underline,
    if (a['strike'] == true) TextDecoration.lineThrough,
  ];
  return TextStyle(
    fontWeight: a['bold'] == true
        ? FontWeight.w700
        : a['bold'] == false
        ? FontWeight.w400
        : null,
    fontStyle: a['italic'] == true ? FontStyle.italic : null,
    decoration: decorations.isEmpty
        ? null
        : TextDecoration.combine(decorations),
    color: pageAttrColor(a),
    fontSize: size == null ? null : size * fontScale,
    fontFamily: a['font'] is String ? a['font'] as String : null,
  );
}

/// 글자 크기 서식(pt, 범위 안으로). 없거나 틀리면 null.
double? pageAttrSize(Map a) {
  final size = double.tryParse('${a['size'] ?? ''}');
  return size != null && size.isFinite && size > 0
      ? size.clamp(PageTextElement.minFontSize, PageTextElement.maxFontSize)
      : null;
}

/// Quill 색은 `#RRGGBB` 또는 `#AARRGGBB`(옛 색 선택기) — 앞의 알파는 무시하고 불투명으로.
Color? pageAttrColor(Map a) {
  final v = a['color'];
  if (v is! String) return null;
  final hex = v.trim().replaceFirst('#', '');
  return tryParseHexColor(hex.length == 8 ? hex.substring(2) : hex);
}

/// 목록 기호 칸 폭(px) — flutter_quill 과 같은 공식. [base] = 상자 기본 글자 px.
double pageListIndent(String list, int count, double base) => list == 'ordered'
    ? TextBlockUtils.defaultNumberPointWidthBuilder(base, count)
    : base * 2;

/// 목록 기호. 크기·색은 그 줄 첫 글자를 따르고 글머리는 굵게(flutter_quill 과 같다).
/// 굽기와 편집기(`customLeadingBlockBuilder`)가 같이 쓴다.
Widget pageListMarker({
  required PageTextElement element,
  required double fontScale,
  required String list,
  required int index,
  required Map<String, Object> firstAttrs,
}) {
  final base = pageBaseStyle(element, fontScale);
  final size = pageAttrSize(firstAttrs);
  return Align(
    alignment: Alignment.topRight,
    child: Padding(
      padding: EdgeInsets.only(right: base.fontSize! / 2),
      child: RichText(
        textScaler: TextScaler.noScaling,
        text: TextSpan(
          text: list == 'bullet' ? '•' : '$index.',
          style: base.copyWith(
            fontWeight: list == 'bullet' ? FontWeight.w700 : null,
            fontSize: size == null ? null : size * fontScale,
            color: pageAttrColor(firstAttrs),
          ),
        ),
      ),
    ),
  );
}

/// 줄마다 놓을 것(굽기·측정 공용).
class _LaidLine {
  _LaidLine(this.line, this.span, this.indent, this.index);

  final PageRichLine line;
  final TextSpan span;
  final double indent;

  /// 목록 묶음 안 순번(1부터).
  final int index;
}

List<_LaidLine> _layLines(PageTextElement e, double fontScale) {
  final base = pageBaseStyle(e, fontScale);
  final lines = pageRichLines(e);
  final out = <_LaidLine>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final list = line.list;
    var indent = 0.0, index = 0;
    if (list != null) {
      // 같은 목록이 이어지는 줄들이 한 묶음(flutter_quill 의 Block). 번호 폭은 묶음 줄 수로 정한다.
      var start = i, end = i;
      while (start > 0 && lines[start - 1].list == list) {
        start--;
      }
      while (end < lines.length - 1 && lines[end + 1].list == list) {
        end++;
      }
      index = i - start + 1;
      indent = pageListIndent(list, end - start + 1, base.fontSize!);
    }
    out.add(
      _LaidLine(
        line,
        TextSpan(
          style: base,
          children: [
            for (final s in line.spans)
              TextSpan(
                text: s.text,
                style: pageInlineStyle(s.attrs, fontScale),
              ),
          ],
        ),
        indent,
        index,
      ),
    );
  }
  return out;
}

/// 글 상자 글을 그린다(캔버스·굽기). 폭은 받은 칸, 높이는 글만큼.
class PageTextBlock extends StatelessWidget {
  const PageTextBlock({super.key, required this.element, this.fontScale = 1});

  final PageTextElement element;
  final double fontScale;

  @override
  Widget build(BuildContext context) {
    final strut = StrutStyle.fromTextStyle(pageBaseStyle(element, fontScale));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final l in _layLines(element, fontScale))
          Stack(
            // 칸 폭을 그대로 넘긴다(느슨하면 짧은 가운데 줄이 왼쪽에 붙는다).
            fit: StackFit.passthrough,
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: EdgeInsets.only(left: l.indent),
                child: RichText(
                  text: l.span,
                  textAlign: element.align,
                  strutStyle: strut,
                  textScaler: TextScaler.noScaling,
                ),
              ),
              if (l.line.list case final list?)
                Positioned(
                  left: 0,
                  top: 0,
                  width: l.indent,
                  child: pageListMarker(
                    element: element,
                    fontScale: fontScale,
                    list: list,
                    index: l.index,
                    firstAttrs: l.line.spans.firstOrNull?.attrs ?? const {},
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// [PageTextBlock] 이 [width] 칸에서 차지할 높이.
double measurePageText(PageTextElement e, double fontScale, double width) {
  final strut = StrutStyle.fromTextStyle(pageBaseStyle(e, fontScale));
  var height = 0.0;
  for (final l in _layLines(e, fontScale)) {
    final painter = TextPainter(
      text: l.span,
      textAlign: e.align,
      textDirection: TextDirection.ltr,
      strutStyle: strut,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: (width - l.indent).clamp(0, double.infinity));
    height += painter.height;
    painter.dispose();
  }
  return height;
}

// ── 상자째 서식(편집 중이 아닐 때 리본) ─────────────────────────────────

/// 글자 크기 목록(pt, 540pt 기준).
const pageFontSizes = <double>[
  12,
  14,
  16,
  18,
  20,
  24,
  28,
  32,
  36,
  40,
  48,
  54,
  60,
  72,
  80,
  96,
  120,
  150,
  200,
];

/// '한 단계 크게/작게': 목록에서 다음 값. 목록 밖이면 10% 씩.
double pageSizeStep(double size, int direction) {
  final next = direction > 0
      ? pageFontSizes.where((s) => s > size + 0.01).firstOrNull ?? size * 1.1
      : pageFontSizes.lastWhere(
          (s) => s < size - 0.01,
          orElse: () => size / 1.1,
        );
  return next
      .clamp(PageTextElement.minFontSize, PageTextElement.maxFontSize)
      .roundToDouble();
}

/// 리본에 보일 지금 서식. 값이 섞이면 null(빈칸).
typedef PageTextFormat = ({
  String? font,
  double? size,
  Color? color,
  bool bold,
  bool italic,
  bool underline,
  bool strike,
  TextAlign? align,
  String? list,
});

/// 글자 덩어리들의 서식을 모은다. [runs] = (상자, 그 글자의 서식). 줄 목록은 [lists].
PageTextFormat pageTextFormatOf(
  Iterable<(PageTextElement, Map<String, Object>)> runs,
  Iterable<String?> lists,
) {
  T? same<T>(Iterable<T> values) {
    final set = values.toSet();
    return set.length == 1 ? set.first : null;
  }

  final r = runs.toList();
  bool all(bool Function(PageTextElement, Map<String, Object>) test) =>
      r.isNotEmpty && r.every((x) => test(x.$1, x.$2));
  final argb = same(
    r.map((x) => (pageAttrColor(x.$2) ?? x.$1.color).toARGB32()),
  );
  return (
    font: same(r.map((x) => x.$2['font'] as String? ?? x.$1.fontFamily)),
    size: same(r.map((x) => pageAttrSize(x.$2) ?? x.$1.fontSize)),
    color: argb == null ? null : Color(argb),
    bold: all((e, a) => a['bold'] as bool? ?? e.bold),
    italic: all((_, a) => a['italic'] == true),
    underline: all((_, a) => a['underline'] == true),
    strike: all((_, a) => a['strike'] == true),
    align: same(r.map((x) => x.$1.align)),
    list: same<String?>(lists),
  );
}

/// 상자들(편집 중 아님)의 서식.
PageTextFormat pageBoxFormat(Iterable<PageTextElement> boxes) {
  final runs = <(PageTextElement, Map<String, Object>)>[];
  final lists = <String?>[];
  for (final e in boxes) {
    final lines = pageRichLines(e);
    final spans = lines.expand((l) => l.spans).toList();
    // 빈 상자도 상자 기본값으로 센다.
    if (spans.isEmpty) runs.add((e, const {}));
    for (final s in spans) {
      runs.add((e, s.attrs));
    }
    lists.addAll(lines.map((l) => l.list));
  }
  return pageTextFormatOf(runs, lists);
}

/// 상자만 고른 상태의 서식 = 글 전체(PowerPoint 와 같다).
/// 글꼴·크기·색·굵게는 상자 기본값을 바꾸고 글자마다 직접 지정한 같은 속성을 지운다.
/// 기울임·밑줄·취소선은 모든 글자에 켜거나 끄고([value] = bool), 목록은 모든 줄에(null = 끔).
/// 'step'(+1/-1)은 상자 크기와 글자마다 지정한 크기를 각각 한 단계씩 옮긴다(크기 차이 유지).
/// 'clear' 는 글자 서식을 모두 지운다(목록은 둔다).
PageTextElement applyBoxFormat(PageTextElement e, String key, Object? value) {
  final box = switch (key) {
    'font' => e.copyWith(fontFamily: value as String),
    'size' => e.copyWith(
      fontSize: (value as double).clamp(
        PageTextElement.minFontSize,
        PageTextElement.maxFontSize,
      ),
    ),
    'color' => e.copyWith(color: value as Color),
    'bold' => e.copyWith(bold: value as bool),
    'step' => e.copyWith(fontSize: pageSizeStep(e.fontSize, value as int)),
    'align' => e.copyWith(align: value as TextAlign),
    _ => e,
  };
  if (key == 'align') return box;
  final lines = [
    for (final line in pageRichLines(e))
      PageRichLine([
        for (final s in line.spans)
          (
            text: s.text,
            attrs: switch (key) {
              'clear' => const <String, Object>{},
              'italic' ||
              'underline' ||
              'strike' when value == true => {...s.attrs, key: true},
              'list' => s.attrs,
              'step' => {
                ...s.attrs,
                if (pageAttrSize(s.attrs) case final size?)
                  'size': '${pageSizeStep(size, value as int).round()}',
              },
              _ => {...s.attrs}..remove(key),
            },
          ),
      ], list: key == 'list' ? value as String? : line.list),
  ];
  return box.copyWith(rich: encodePageRich(lines));
}
