import 'dart:convert';

import 'package:flutter/material.dart';

import '../domain/export_style.dart';
import '../domain/page_element.dart';

/// 글 상자 한 개를 [TextSpan] 으로. 편집 창 미리보기·굽기·넘침 측정이 같이 쓴다.
///
/// `rich`(flutter_quill Delta JSON)가 없으면 예전처럼 글 전체에 상자 서식 하나.
/// 있으면 글자마다 굵게·기울임·밑줄·취소선·색·크기(pt, 540pt 기준)를 덧입히고
/// 글머리 기호(bullet)·번호(ordered) 줄은 앞에 기호를 붙인다. 줄 정렬은 상자 하나(`align`)를 따른다.
TextSpan pageTextSpan(PageTextElement e, double fontScale) {
  final base = TextStyle(
    fontFamily: e.fontFamily,
    fontSize: e.fontSize * fontScale,
    color: e.color,
    fontWeight: e.bold ? FontWeight.w700 : FontWeight.w400,
  );
  final rich = e.rich;
  if (rich == null) return TextSpan(text: e.text, style: base);
  try {
    return TextSpan(style: base, children: _richChildren(rich, fontScale));
  } catch (_) {
    // 깨진 JSON 은 평문으로 — 글이 사라지지 않게.
    return TextSpan(text: e.text, style: base);
  }
}

List<InlineSpan> _richChildren(String json, double fontScale) {
  final ops = jsonDecode(json) as List;
  final out = <InlineSpan>[];
  var line = <InlineSpan>[];
  var lineCount = 0;
  var number = 0;

  void endLine(Map? attrs) {
    final list = attrs?['list'];
    number = list == 'ordered' ? number + 1 : 0;
    final marker = switch (list) {
      'bullet' => '• ',
      'ordered' => '$number. ',
      _ => '',
    };
    if (lineCount++ > 0) out.add(const TextSpan(text: '\n'));
    if (marker.isNotEmpty) out.add(TextSpan(text: marker));
    out.addAll(line);
    line = [];
  }

  for (final op in ops) {
    if (op is! Map || op['insert'] is! String) continue;
    final attrs = op['attributes'] is Map ? op['attributes'] as Map : null;
    final parts = (op['insert'] as String).split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isNotEmpty) {
        line.add(
          TextSpan(text: parts[i], style: _inlineStyle(attrs, fontScale)),
        );
      }
      if (i < parts.length - 1) endLine(attrs);
    }
  }
  if (line.isNotEmpty) endLine(null);
  return out;
}

TextStyle? _inlineStyle(Map? a, double fontScale) {
  if (a == null || a.isEmpty) return null;
  final size = double.tryParse('${a['size'] ?? ''}');
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
    color: a['color'] is String ? _quillColor(a['color'] as String) : null,
    fontSize: size != null && size.isFinite && size > 0
        ? size.clamp(PageTextElement.minFontSize, PageTextElement.maxFontSize) *
              fontScale
        : null,
  );
}

/// Quill 색은 `#RRGGBB` 또는 `#AARRGGBB`(색 선택기가 이쪽) — 앞의 알파는 무시하고 불투명으로.
Color? _quillColor(String v) {
  final hex = v.trim().replaceFirst('#', '');
  return tryParseHexColor(hex.length == 8 ? hex.substring(2) : hex);
}
