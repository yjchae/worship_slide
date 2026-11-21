import 'dart:convert';

import 'package:flutter/painting.dart';

import '../data/fnv_hash.dart';
import 'export_style.dart';
import 'staging_item.dart';

/// 콘티 항목 안 페이지별 글자 서식(1단계: 페이지 전체 색·크기).
///
/// 글은 가사·성경 본문 그대로 두고 서식만 옆 칸(`worship_conti_items.page_format`)에 둔다.
/// 키 = 페이지 본문 글의 FNV([pageKey]) — 글이 바뀌면 키가 어긋나 서식이 안 보일 뿐 지우지는 않는다.
/// 크기는 전역 글자 크기 대비 비율이다.
/// JSON: `{"v":1,"pages":{"<키>":{"main":{"c":"#RRGGBB","s":1.2},"sub":{..},"extra":{..}}}}`.
const kMinPageScale = 0.5;
const kMaxPageScale = 2.0;

/// 페이지 본문 글의 서식 키. 비어 있으면 null(빈 페이지는 서식을 안 둔다).
String? pageKey(String mainText) {
  final t = mainText.trim();
  return t.isEmpty ? null : fnvHex(utf8.encode(t));
}

/// 한 줄(본문·보조·추가 보조)의 색·크기 비율. 둘 다 null 이면 전역값.
class PageTextFormat {
  PageTextFormat({this.color, double? scale})
    : scale = scale == null || !scale.isFinite
          ? null
          : scale.clamp(kMinPageScale, kMaxPageScale).toDouble();

  final Color? color;
  final double? scale;

  bool get isEmpty => color == null && scale == null;

  Map<String, dynamic> toJson() => {
    if (color != null) 'c': colorToHex(color!),
    if (scale != null) 's': scale,
  };

  static PageTextFormat? fromJson(Object? json) {
    if (json is! Map) return null;
    final s = json['s'];
    final f = PageTextFormat(
      color: tryParseHexColor(json['c'] is String ? json['c'] as String : null),
      scale: s is num ? s.toDouble() : null,
    );
    return f.isEmpty ? null : f;
  }

  @override
  bool operator ==(Object other) =>
      other is PageTextFormat && other.color == color && other.scale == scale;

  @override
  int get hashCode => Object.hash(color, scale);
}

/// 한 페이지의 서식.
class PageEntry {
  const PageEntry({this.main, this.sub, this.extra});

  final PageTextFormat? main;
  final PageTextFormat? sub;
  final PageTextFormat? extra;

  bool get isEmpty =>
      (main?.isEmpty ?? true) &&
      (sub?.isEmpty ?? true) &&
      (extra?.isEmpty ?? true);

  Map<String, dynamic> toJson() => {
    if (main != null && !main!.isEmpty) 'main': main!.toJson(),
    if (sub != null && !sub!.isEmpty) 'sub': sub!.toJson(),
    if (extra != null && !extra!.isEmpty) 'extra': extra!.toJson(),
  };

  static PageEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final e = PageEntry(
      main: PageTextFormat.fromJson(json['main']),
      sub: PageTextFormat.fromJson(json['sub']),
      extra: PageTextFormat.fromJson(json['extra']),
    );
    return e.isEmpty ? null : e;
  }

  @override
  bool operator ==(Object other) =>
      other is PageEntry &&
      other.main == main &&
      other.sub == sub &&
      other.extra == extra;

  @override
  int get hashCode => Object.hash(main, sub, extra);
}

/// 콘티 항목 하나의 페이지 서식 모음. 불변 — 바꾸면 새 객체.
class PageFormat {
  const PageFormat(this.pages);

  /// 키 = [pageKey].
  final Map<String, PageEntry> pages;

  bool get isEmpty => pages.isEmpty;

  PageEntry? forText(String mainText) {
    final k = pageKey(mainText);
    return k == null ? null : pages[k];
  }

  /// [key] 의 서식을 바꾼다(null·빈 서식 = 지움).
  PageFormat withEntry(String key, PageEntry? entry) {
    final next = {...pages};
    if (entry == null || entry.isEmpty) {
      next.remove(key);
    } else {
      next[key] = entry;
    }
    return PageFormat(next);
  }

  /// 지금 있는 페이지 키([liveKeys])만 남긴다.
  PageFormat pruneTo(Set<String> liveKeys) => PageFormat({
    for (final e in pages.entries)
      if (liveKeys.contains(e.key)) e.key: e.value,
  });

  Map<String, dynamic> toJson() => {
    'v': 1,
    'pages': {for (final e in pages.entries) e.key: e.value.toJson()},
  };

  /// 저장 문자열 → 서식. 비었거나 깨졌거나 모르는 버전이면 null(서식 없음). 예외를 던지지 않는다.
  static PageFormat? parse(Object? stored) {
    if (stored is! String || stored.isEmpty) return null;
    try {
      final json = jsonDecode(stored);
      if (json is! Map || json['v'] != 1 || json['pages'] is! Map) return null;
      final pages = <String, PageEntry>{};
      for (final e in (json['pages'] as Map).entries) {
        final entry = PageEntry.fromJson(e.value);
        if (e.key is String && entry != null) pages[e.key as String] = entry;
      }
      return pages.isEmpty ? null : PageFormat(pages);
    } catch (_) {
      return null;
    }
  }

  /// 저장 문자열. 서식이 없으면 null(DB 칸 NULL).
  static String? encode(PageFormat? format) =>
      format == null || format.isEmpty ? null : jsonEncode(format.toJson());

  @override
  bool operator ==(Object other) =>
      other is PageFormat && _mapEq(other.pages, pages);

  @override
  int get hashCode =>
      Object.hashAll(pages.entries.map((e) => Object.hash(e.key, e.value)));

  static bool _mapEq(Map<String, PageEntry> a, Map<String, PageEntry> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
}

extension PageFormatStyle on ExportStyle {
  /// 한 페이지 서식을 덮어쓴 스타일. 찬양은 `text_*`·`font_size`, 성경은 `bible_*` 키를 바꾼다.
  /// 보조·추가 보조 크기는 본문 크기와 상관없이 **전역 크기 × 그 줄의 비율**이다
  /// (비율 칸이 [kMaxFontRatio] 에서 잘리는 극단값은 ponytail: 그대로 둔다).
  ExportStyle withPageFormat(PageEntry? entry, {required bool isBible}) {
    if (entry == null || entry.isEmpty) return this;
    var style = copyWith(
      textColor: isBible ? null : entry.main?.color,
      bibleTextColor: isBible ? entry.main?.color : null,
      englishTextColor: entry.sub?.color,
      extraTextColor: entry.extra?.color,
    );
    if (entry.main?.scale == null &&
        entry.sub?.scale == null &&
        entry.extra?.scale == null) {
      return style;
    }
    final body =
        (isBible ? bibleFontSize : fontSize) * (entry.main?.scale ?? 1);
    final sub = subFontSizeFor(isBible: isBible) * (entry.sub?.scale ?? 1);
    final extra =
        extraFontSizeFor(isBible: isBible) * (entry.extra?.scale ?? 1);
    style = style.copyWith(
      fontSize: isBible ? null : body,
      bibleFontSize: isBible ? body : null,
      englishFontSize: sub,
      extraFontRatio: isBible ? null : extra / body,
      bibleExtraFontRatio: isBible ? extra / body : null,
    );
    return style;
  }
}

/// 항목의 페이지별(페이지 순서) 본문 글. 곡은 `pairedPages`, 성경은 본문을 빈 줄로 가른 것.
/// 곡·성경이 아니면 null.
List<String>? _mainPages(StagingItem item) => switch (item) {
  SongStagingItem(:final song) => song.pages,
  BibleStagingItem(:final text) => _splitPages(text),
  _ => null,
};

List<String> _splitPages(String text) {
  if (text.isEmpty) return [];
  final pages = [for (final p in text.split(RegExp(r'\n[ \t]*\n'))) p.trim()];
  while (pages.isNotEmpty && pages.last.isEmpty) {
    pages.removeLast();
  }
  return pages;
}

/// 항목에 지금 있는 페이지 서식 키들(없는 서식을 지울 때 [PageFormat.pruneTo] 에 쓴다).
Set<String> livePageKeys(StagingItem item) => {
  for (final t in _mainPages(item) ?? const <String>[]) ?pageKey(t),
};

/// PPTX 내보내기용: 페이지 순서대로 "전역 style 위에 덮어쓸 키 → 값" 또는 null.
/// 서식이 하나도 안 걸리면 null(payload 에 `page_styles` 를 싣지 않는다).
/// [base] 는 항목 배경까지 입힌 스타일(`style.withBackground(background)`)이다.
List<Map<String, dynamic>?>? pageStylesFor(
  StagingItem item,
  PageFormat? format,
  ExportStyle base,
) {
  final pages = _mainPages(item);
  if (pages == null || format == null || format.isEmpty) return null;
  final isBible = item is BibleStagingItem;
  final baseJson = base.toJson();
  var any = false;
  final result = <Map<String, dynamic>?>[];
  for (final text in pages) {
    final entry = format.forText(text);
    final changed = <String, dynamic>{};
    if (entry != null) {
      final json = base.withPageFormat(entry, isBible: isBible).toJson();
      for (final e in json.entries) {
        if (baseJson[e.key] != e.value) changed[e.key] = e.value;
      }
    }
    if (changed.isEmpty) {
      result.add(null);
    } else {
      any = true;
      result.add(changed);
    }
  }
  return any ? result : null;
}
