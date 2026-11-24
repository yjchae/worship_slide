import 'dart:math' show max;
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
    this.fontsInstalled = const [],
  });

  factory PptLayout.fromJson(Map<String, dynamic> json) => PptLayout(
    sourceName: json['source_name'] as String? ?? '',
    letterboxed: json['letterboxed'] == true,
    fontsMissing: [
      for (final f in json['fonts_missing'] as List? ?? const [])
        if (f is String) f,
    ],
    fontsInstalled: [
      for (final f in json['fonts_installed'] as List? ?? const [])
        if (f case {'family': final String family, 'path': final String path})
          (
            family: family,
            path: path,
            index: (f['index'] as num?)?.toInt() ?? 0,
          ),
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

  /// 앱 목록엔 없지만 이 PC 에 깔린 글꼴 파일([index] = TTC 안 번호). 읽어서 올리기만 한다(복사 안 함).
  final List<({String family, String path, int index})> fontsInstalled;

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
    this.steps = 1,
    this.animLost = const {},
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
      steps: max(1, (json['steps'] as num?)?.toInt() ?? 1),
      animLost: {
        if (json['anim_lost'] case final Map lost)
          for (final MapEntry(:key, :value) in lost.entries)
            if (key is String && value is num && value > 0) key: value.toInt(),
      },
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

  /// 클릭 단계 장 수(1 = 애니메이션 없음). 요소마다 `appear` 가 단계를 정한다.
  final int steps;

  /// 단계로 옮기지 못해 처음부터 보이게 둔 애니메이션 수(까닭 → 수, 0 인 까닭은 없다):
  /// paragraph(문단 단위)·exit(사라짐)·group_child(그룹 안 도형)·overlap(겹침)·too_many(30단계 넘음).
  final Map<String, int> animLost;
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

/// `layout` 진행 줄(stderr `{"progress": …}`) → 진행 창 문구. 모르는 단계면 null(문구 그대로).
String? pptLayoutProgressLabel(Map<String, dynamic> progress) =>
    switch (progress['progress']) {
      'convert' => 'PPT 를 pptx 로 바꾸는 중…',
      'read' => '슬라이드 읽는 중… (${progress['n']} / ${progress['total']})',
      'render' => progress['n'] == 2 ? '애니메이션 배경 굽는 중…' : '배경 굽는 중…',
      'fonts' => '글꼴 확인 중…',
      _ => null,
    };

/// 복사하지 못해 빠진 그림 요소 수 · 배경 PNG 가 없는(못 구웠거나 못 옮긴) 장 수. 숨긴 장은 뺀다.
({int images, int backgrounds}) pptLayoutLost(
  PptLayout layout,
  Map<String, String> copied,
) {
  var images = 0, backgrounds = 0;
  for (final s in layout.editable) {
    if (copied[s.backgroundPng] == null) backgrounds++;
    for (final e in s.elements) {
      if (e is Map && e['type'] == 'image' && copied[e['path']] == null) {
        images++;
      }
    }
  }
  return (images: images, backgrounds: backgrounds);
}

/// 담은 뒤 알릴 문구. 빠진 게 없으면 null.
String? pptImportProblems({
  required int pagesFailed,
  required int imagesLost,
  required int backgroundsLost,
}) {
  final parts = [
    if (pagesFailed > 0) '$pagesFailed장은 만들지 못했습니다',
    if (imagesLost > 0) '그림 $imagesLost개를 옮기지 못했습니다',
    if (backgroundsLost > 0) '$backgroundsLost장은 배경 그림 없이 담았습니다',
  ];
  return parts.isEmpty
      ? null
      : '${parts.join(' · ')}. 자세한 내용은 로그 보기에서 확인해 주세요.';
}
