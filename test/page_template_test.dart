import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/page_template_store.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/offering_design.dart';
import 'package:worship_slides/src/features/praise/domain/page_element.dart';
import 'package:worship_slides/src/features/praise/domain/slide_background.dart';

void main() {
  final style = ExportStyle.fromJson(const {
    'font_size': 30,
    'bible_font_size': 20,
  });
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('page_template_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('기본 틀 3개: 이름·요소 수·전역 배경 색, 내용 상자는 빈 글', () {
    final list = defaultPageTemplates(style);
    expect(list.map((t) => t.name), ['예배 시작 화면', '주일 광고', '생일자']);
    expect(list.map((t) => t.design.pageElements!.length), [0, 2, 2]);
    expect(list.every((t) => t.design.color == style.backgroundColor), isTrue);
    expect(list.every((t) => t.id.length == 16), isTrue);
    final ad = list[1].design.pageElements!.cast<PageTextElement>();
    expect(ad[0].text, '주일 광고');
    expect(ad[0].bold, isTrue);
    expect(ad[1].text, '');
    expect(ad[1].align, TextAlign.left);
  });

  test('JSON 왕복 + 색·그림·요소 말고는 빼고 저장', () {
    final t = defaultPageTemplates(style)[1];
    final dirty = (
      id: t.id,
      name: t.name,
      design: t.design.copyWith(
        imagePath: '/x.png',
        videoPath: '/v.mp4',
        offering: const OfferingDesign(),
        fontSize: 70.0,
        isSermon: true,
      ),
      previewPath: '/p.png',
    );
    final back = pageTemplatesFromJson(
      jsonDecode(jsonEncode(pageTemplatesToJson([dirty]))),
    ).single;
    expect(back.id, t.id);
    expect(back.name, '주일 광고');
    expect(back.previewPath, '/p.png');
    expect(
      back.design,
      SlideBackground(
        color: t.design.color,
        imagePath: '/x.png',
        pageElements: t.design.pageElements,
      ),
    );
  });

  test('깨진 항목은 버리고 page_elements 가 없으면 []', () {
    final list = pageTemplatesFromJson({
      'templates': [
        'x',
        {
          'id': '',
          'name': 'a',
          'design': {'color': '#000000'},
        },
        {
          'id': 'b',
          'design': {'color': '#000000'},
        },
        {
          'id': 'c',
          'name': 'c',
          'design': {'color': 'zz'},
        },
        {
          'id': 'd',
          'name': '좋음',
          'design': {'color': '#FF0000'},
        },
      ],
    });
    expect(list.single.name, '좋음');
    expect(list.single.design.pageElements, isEmpty);
    expect(list.single.previewPath, isNull);
    expect(pageTemplatesFromJson('nope'), isEmpty);
  });

  test('그림 파일이 없으면 색만, 배경만 입힐 때 요소 유지', () {
    final img = File('${dir.path}/bg.png')..writeAsBytesSync([0]);
    final t = (
      id: 'a',
      name: 't',
      design: SlideBackground(color: Colors.red, imagePath: img.path),
      previewPath: null,
    );
    expect(usableTemplateDesign(t.design).imagePath, img.path);

    final elements = defaultPageTemplates(style)[2].design.pageElements!;
    final page = SlideBackground(
      color: Colors.blue,
      offering: const OfferingDesign(),
      pageElements: elements,
    );
    final applied = applyTemplateBackground(page, t);
    expect(applied.color, Colors.red);
    expect(applied.imagePath, img.path);
    expect(applied.pageElements, elements);
    expect(applied.isOffering, isFalse);
    expect(applyTemplateBackground(null, t).pageElements, isNull);

    img.deleteSync();
    expect(usableTemplateDesign(t.design).imagePath, isNull);
    expect(usableTemplateDesign(t.design).color, Colors.red);
    expect(applyTemplateBackground(page, t).imagePath, isNull);
  });

  test('load: 파일이 없으면 기본 3개를 만들어 저장', () async {
    final store = PageTemplateStore(dir: dir);
    final r = await store.load(style);
    expect(r.broken, isFalse);
    expect(r.templates, hasLength(3));
    final file = File('${dir.path}/page_templates.json');
    expect(file.existsSync(), isTrue);
    final again = await store.load(style);
    expect(again.templates.map((t) => t.id), r.templates.map((t) => t.id));
  });

  test('load: 깨진 파일은 기본 3개 + broken, 파일은 그대로', () async {
    final file = File('${dir.path}/page_templates.json')
      ..writeAsStringSync('{깨짐');
    final r = await PageTemplateStore(dir: dir).load(style);
    expect(r.broken, isTrue);
    expect(r.templates, hasLength(3));
    expect(file.readAsStringSync(), '{깨짐');
  });

  test('save 뒤 load 하면 같은 목록', () async {
    final store = PageTemplateStore(dir: dir);
    final list = defaultPageTemplates(style).sublist(1);
    await store.save(list);
    final r = await store.load(style);
    expect(r.templates.map((t) => t.name), ['주일 광고', '생일자']);
    expect(r.templates[0].design, list[0].design);
  });

  test('배경만 입힐 때 대상의 배경 영상은 남긴다', () {
    final t = (
      id: 'a',
      name: 't',
      design: const SlideBackground(color: Colors.red),
      previewPath: null,
    );
    final applied = applyTemplateBackground(
      const SlideBackground(
        color: Colors.blue,
        videoPath: '/v.mp4',
        videoDim: 0.6,
        isSermon: true,
      ),
      t,
    );
    expect(applied.color, Colors.red);
    expect(applied.videoPath, '/v.mp4');
    expect(applied.videoDim, 0.6);
    expect(applied.isSermon, isFalse);
    expect(
      applyTemplateBackground(null, t).videoDim,
      SlideBackground.defaultVideoDim,
    );
  });

  test('load: 폴더를 못 열어도 던지지 않고 기본 3개', () async {
    // dir 없음 = Application Support → 테스트에선 path_provider 플러그인이 없어 던진다.
    final r = await PageTemplateStore().load(style);
    expect(r.broken, isFalse);
    expect(r.templates, hasLength(3));
  });

  test('save: 깨진 파일은 .broken.bak 으로 남기고 쓴다(이미 있으면 그대로)', () async {
    final file = File('${dir.path}/page_templates.json')
      ..writeAsStringSync('{깨짐');
    final bak = File('${file.path}.broken.bak');
    final store = PageTemplateStore(dir: dir);
    await store.save(defaultPageTemplates(style));
    expect(bak.readAsStringSync(), '{깨짐');
    expect((await store.load(style)).templates, hasLength(3));

    file.writeAsStringSync('또 깨짐');
    await store.save(defaultPageTemplates(style));
    expect(bak.readAsStringSync(), '{깨짐');

    bak.deleteSync();
    await store.save(defaultPageTemplates(style)); // 멀쩡한 파일은 백업 안 함
    expect(bak.existsSync(), isFalse);
  });
}
