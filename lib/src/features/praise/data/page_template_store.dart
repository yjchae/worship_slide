import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/export_style.dart';
import '../domain/page_element.dart';
import '../domain/slide_background.dart';
import 'app_logger.dart';
import 'atomic_file.dart';

/// 페이지 틀(예배 시작 화면·주일 광고·생일자 등): 이름 + 배경(색·그림) + 기본 요소.
/// 넣을 때 [design] 을 복사해 슬라이드 편집 페이지로 만든다(틀과 이어지지 않는다).
/// [previewPath] 는 관리 창 썸네일용으로 구운 PNG(없어도 된다).
typedef PageTemplate = ({
  String id,
  String name,
  SlideBackground design,
  String? previewPath,
});

/// 틀에 남기는 값만 — 색·그림·요소(없으면 []). 영상·헌금송·설교·글꼴은 뺀다.
SlideBackground templateDesign(SlideBackground design) => SlideBackground(
  color: design.color,
  imagePath: design.imagePath,
  pageElements: design.pageElements ?? const [],
);

/// 틀을 쓸 때의 배경. 그림 파일이 없으면(모음에서 지움) 색만 남긴다.
SlideBackground usableTemplateDesign(SlideBackground design) =>
    design.hasImage && !File(design.imagePath!).existsSync()
    ? design.copyWith(imagePath: null)
    : design;

/// [target] 에 틀 배경(색·그림)만 입힌다. 요소([SlideBackground.pageElements])와
/// 배경 영상([SlideBackground.videoPath]·[SlideBackground.videoDim])은 그대로.
/// 헌금송·설교·가사 위치 등 다른 값은 [target] 에서 떨어져 나간다(일반 배경이 된다).
SlideBackground applyTemplateBackground(
  SlideBackground? target,
  PageTemplate template,
) {
  final d = usableTemplateDesign(template.design);
  return SlideBackground(
    color: d.color,
    imagePath: d.imagePath,
    videoPath: target?.videoPath,
    videoDim: target?.videoDim ?? SlideBackground.defaultVideoDim,
    pageElements: target?.pageElements,
  );
}

/// JSON → 틀 목록. 깨진 항목(id·이름·배경이 없음)은 버린다.
List<PageTemplate> pageTemplatesFromJson(Object? json) {
  final raw = json is Map ? json['templates'] : null;
  if (raw is! List) return [];
  return [
    for (final t in raw)
      if (t is Map &&
          t['id'] is String &&
          (t['id'] as String).isNotEmpty &&
          t['name'] is String &&
          t['design'] is Map)
        if (SlideBackground.fromJson(
              (t['design'] as Map).cast<String, dynamic>(),
            )
            case final design?)
          (
            id: t['id'] as String,
            name: t['name'] as String,
            design: templateDesign(design),
            previewPath: t['preview_path'] is String
                ? t['preview_path'] as String
                : null,
          ),
  ];
}

Map<String, dynamic> pageTemplatesToJson(List<PageTemplate> templates) => {
  'templates': [
    for (final t in templates)
      {
        'id': t.id,
        'name': t.name,
        'design': templateDesign(t.design).toJson(),
        if (t.previewPath != null) 'preview_path': t.previewPath,
      },
  ],
};

/// 새 틀 id(16자리 hex).
String newPageTemplateId() => PageElement.newId();

/// 처음 켤 때 만드는 틀 3개. 배경 = 그때 전역 배경. 내용 상자는 빈 글 —
/// 편집 창이 빈 글 상자를 점선 + '글 상자' 로 보여 준다(구운 PNG 에는 안 나온다).
List<PageTemplate> defaultPageTemplates(ExportStyle style) {
  PageTemplate make(String name, List<PageElement> elements) => (
    id: newPageTemplateId(),
    name: name,
    design: SlideBackground(
      color: style.backgroundColor,
      imagePath: style.backgroundImagePath,
      pageElements: elements,
    ),
    previewPath: null,
  );
  PageTextElement title(String text) => PageTextElement(
    id: PageElement.newId(),
    rect: const Rect.fromLTWH(0.05, 0.06, 0.9, 0.15),
    text: text,
    fontSize: 48,
    bold: true,
  );
  return [
    make('예배 시작 화면', const []),
    make('주일 광고', [
      title('주일 광고'),
      PageTextElement(
        id: PageElement.newId(),
        rect: const Rect.fromLTWH(0.08, 0.25, 0.84, 0.65),
        fontSize: 32,
        align: TextAlign.left,
      ),
    ]),
    make('생일자', [
      title('생일을 축하합니다'),
      PageTextElement(
        id: PageElement.newId(),
        rect: const Rect.fromLTWH(0.1, 0.3, 0.8, 0.6),
        fontSize: 40,
      ),
    ]),
  ];
}

/// 페이지 틀 목록을 Application Support/page_templates.json 에 보관한다.
/// [dir] 는 테스트용(없으면 Application Support).
class PageTemplateStore {
  PageTemplateStore({this.dir});

  final Directory? dir;

  /// 파일이 없으면 기본 3개를 만들어 저장한다. 깨졌으면 기본 3개를 돌려주되
  /// 파일은 덮어쓰지 않는다([broken] = true, 관리 창이 알린다). 처음 [save] 때
  /// 깨진 파일을 `.broken.bak` 으로 남기고 덮어쓴다. 폴더를 못 열면 기본 3개(저장 안 함).
  /// 어떤 경우에도 던지지 않는다.
  Future<({List<PageTemplate> templates, bool broken})> load(
    ExportStyle style,
  ) async {
    final File file;
    final bool exists;
    try {
      file = await _file();
      exists = await file.exists();
    } catch (e, st) {
      AppLogger.instance.error('[template] 틀 폴더를 열지 못해 기본 틀로 시작', e, st);
      return (templates: defaultPageTemplates(style), broken: false);
    }
    if (!exists) {
      final defaults = defaultPageTemplates(style);
      try {
        await save(defaults);
      } catch (e, st) {
        AppLogger.instance.error('[template] 기본 틀 저장 실패', e, st);
      }
      return (templates: defaults, broken: false);
    }
    try {
      return (
        templates: pageTemplatesFromJson(_decode(await file.readAsString())),
        broken: false,
      );
    } catch (e, st) {
      AppLogger.instance.error('[template] 틀 파일을 읽지 못해 기본 틀로 시작', e, st);
      return (templates: defaultPageTemplates(style), broken: true);
    }
  }

  /// 쓰기 전에 지금 파일이 깨졌으면 `page_templates.json.broken.bak` 으로 남긴다
  /// (이미 있으면 그대로 — 처음 깨진 것을 지킨다). 백업을 못 하면 쓰지 않고 던진다.
  Future<void> save(List<PageTemplate> templates) async {
    final file = await _file();
    if (await file.exists()) {
      try {
        _decode(await file.readAsString());
      } catch (_) {
        final bak = File('${file.path}.broken.bak');
        if (!await bak.exists()) await file.copy(bak.path);
      }
    }
    await atomicWriteString(file, jsonEncode(pageTemplatesToJson(templates)));
  }

  static Object _decode(String text) {
    final json = jsonDecode(text);
    if (json is! Map || json['templates'] is! List) {
      throw const FormatException('templates 목록 없음');
    }
    return json;
  }

  Future<File> _file() async {
    final base = dir ?? await getApplicationSupportDirectory();
    return File(p.join(base.path, 'page_templates.json'));
  }
}
