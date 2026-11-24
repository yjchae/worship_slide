import 'dart:ui' show Color;

import 'package:path/path.dart' as p;

import '../data/worship_conti_repository.dart' show normalizeItemGroup;
import 'conti_tree.dart' show uniqueGroupName;
import 'page_element.dart';
import 'slide_background.dart';

/// `ppt_tool layout` 결과(계약: planning/ppt-style-editor/shapes-contract.md).
/// 요소는 아직 JSON 그대로 — 그림 경로를 `page_images/` 복사본으로 바꾼 뒤에 [pptLayoutPages] 가 읽는다.
class PptLayout {
  const PptLayout({
    required this.sourceName,
    required this.slides,
    this.letterboxed = false,
    this.fontsMissing = const [],
  });

  factory PptLayout.fromJson(Map<String, dynamic> json) => PptLayout(
    sourceName: json['source_name'] as String? ?? '',
    letterboxed: json['letterboxed'] == true,
    fontsMissing: [
      for (final f in json['fonts_missing'] as List? ?? const [])
        if (f is String) f,
    ],
    slides: [
      for (final s in json['slides'] as List? ?? const [])
        if (s is Map<String, dynamic>) PptLayoutSlide.fromJson(s),
    ],
  );

  final String sourceName;
  final List<PptLayoutSlide> slides;

  /// 16:9 가 아니라 가운데에 놓고 여백을 둔 파일(4:3 등).
  final bool letterboxed;
  final List<String> fontsMissing;

  /// 숨긴 슬라이드는 건너뛴다(기획 결정 8).
  List<PptLayoutSlide> get editable => [
    for (final s in slides)
      if (!s.hidden) s,
  ];

  List<PptLayoutSlide> get hidden => [
    for (final s in slides)
      if (s.hidden) s,
  ];

  /// 확장자를 뗀 파일 이름. 그룹·페이지 이름에 쓴다.
  String get baseName => p.basenameWithoutExtension(sourceName);
}

class PptLayoutSlide {
  const PptLayoutSlide({
    required this.index,
    this.hidden = false,
    this.title,
    this.backgroundPng,
    this.elements = const [],
    this.droppedCount = 0,
    this.effectsLost = 0,
  });

  factory PptLayoutSlide.fromJson(Map<String, dynamic> json) {
    final dropped = json['dropped'];
    final title = (json['title'] as String?)?.trim();
    return PptLayoutSlide(
      index: (json['index'] as num?)?.toInt() ?? 0,
      hidden: json['hidden'] == true,
      title: title == null || title.isEmpty ? null : title,
      backgroundPng: json['background_png'] as String?,
      elements: json['elements'] as List? ?? const [],
      droppedCount: dropped is Map
          ? dropped.values.whereType<num>().fold(0, (a, b) => a + b.toInt())
          : 0,
      effectsLost: (json['effects_lost'] as num?)?.toInt() ?? 0,
    );
  }

  /// 원본 슬라이드 번호(1부터).
  final int index;
  final bool hidden;
  final String? title;
  final String? backgroundPng;

  /// `page_elements` JSON 그대로(그림 `path` 는 작업 폴더 경로).
  final List elements;

  /// 배경 그림으로 둔 요소 수(까닭 합).
  final int droppedCount;
  final int effectsLost;
}

/// 작업 폴더에서 `page_images/` 로 복사할 파일(배경 PNG·그림 요소). 숨긴 장은 뺀다.
Set<String> pptLayoutFiles(PptLayout layout) => {
  for (final s in layout.editable) ...[
    ?s.backgroundPng,
    for (final e in s.elements)
      if (e is Map && e['type'] == 'image' && e['path'] is String)
        e['path'] as String,
  ],
};

/// 숨기지 않은 슬라이드마다 편집 페이지 이름 + 배경(요소 포함). 경로는 [copied](작업 폴더 → 복사본)로 바꾸고,
/// 복사하지 못한 그림 요소는 뺀다(작업 폴더는 지워지므로). 배경 PNG 를 못 옮겼으면 검정 배경만.
List<({String name, SlideBackground background})> pptLayoutPages(
  PptLayout layout,
  Map<String, String> copied,
) => [
  for (final s in layout.editable)
    (
      name: s.title ?? '${layout.baseName} ${s.index}',
      background: SlideBackground(
        // 배경 PNG 가 검정 여백까지 그린 1920x1080 이라 색은 PNG 가 없을 때만 보인다.
        color: const Color(0xFF000000),
        imagePath: copied[s.backgroundPng],
        pageElements: PageElement.listFromJson([
          for (final e in s.elements)
            if (e is! Map || e['type'] != 'image')
              e
            else if (copied[e['path']] case final path?)
              {...e, 'path': path},
        ]),
      ),
    ),
];

/// 가져온 PPT 의 콘티 그룹 이름: 파일 이름(정리·12자) — 이미 있으면 ' (2)'. [used] = 맨 위 그룹 이름들.
String pptImportGroupName(PptLayout layout, Iterable<String> used) =>
    uniqueGroupName(
      normalizeItemGroup(layout.baseName.replaceAll('/', '／')) ?? 'PPT',
      used,
    );
