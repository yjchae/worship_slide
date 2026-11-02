import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/worship_conti_repository.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/page_element.dart';
import 'package:worship_slides/src/features/praise/domain/slide_background.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';
import 'package:worship_slides/src/features/praise/presentation/lyrics_overlay_renderer.dart';
import 'package:worship_slides/src/features/praise/presentation/page_canvas.dart';

Future<ui.Image> _solid(int w, int h, Color color) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = color,
  );
  return recorder.endRecording().toImage(w, h);
}

Future<Color> _pixelAt(ui.Image image, int x, int y) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final b = data!.buffer.asUint8List();
  final o = (y * image.width + x) * 4;
  return Color.fromARGB(b[o + 3], b[o], b[o + 1], b[o + 2]);
}

void main() {
  const image = PageImageElement(
    id: 'a1',
    rect: Rect.fromLTWH(0.5, 0.5, 0.25, 0.25),
    path: '/p/cat.png',
  );
  const text = PageTextElement(
    id: 'b2',
    rect: Rect.fromLTWH(0.05, 0.06, 0.9, 0.15),
    text: '광고',
    fontSize: 48,
    color: Color(0xFF112233),
    bold: true,
    align: TextAlign.left,
    fontFamily: 'NanumGothic',
  );
  const page = SlideBackground(
    color: Color(0xFF000000),
    pageElements: [image, text],
  );

  test('이미지 항목 제목엔 [PPT] 없음', () {
    const item = ImageStagingItem(sourceName: '광고', imagePaths: ['a.png']);
    expect(item.displayTitle, '광고');
  });

  test('요소 JSON 왕복·순서 유지', () {
    final json = jsonDecode(jsonEncode([image.toJson(), text.toJson()]));
    expect(PageElement.listFromJson(json), [image, text]);
    expect(text.toJson()['align'], 'left');
    expect(text.toJson()['color'], '#112233');
  });

  test('틀린 요소는 버리고 나머지는 남긴다', () {
    final list = PageElement.listFromJson([
      {
        'type': 'image',
        'rect': [0, 0, 1, 1],
      }, // 경로 없음
      {
        'type': 'video',
        'rect': [0, 0, 1, 1],
        'path': '/v.mp4',
      },
      {
        'type': 'text',
        'rect': [0, 0, 0, 1],
      }, // 너비 0
      {
        'type': 'text',
        'rect': ['a', 0, 1, 1],
      },
      'oops',
      {
        'type': 'text',
        'rect': [0.1, 0.1, 0.5, 0.2],
        'font_size': -3,
      },
    ]);
    expect(list, hasLength(1));
    final t = list.single as PageTextElement;
    expect(t.fontSize, PageTextElement.defaultFontSize);
    expect(t.color, Colors.white);
    expect(t.align, TextAlign.center);
    expect(t.id, hasLength(16)); // id 없으면 새로
    expect(PageElement.listFromJson('x'), isEmpty);
  });

  test('clampRect: 최소 크기·슬라이드 안에 5% 남김', () {
    final r = PageElement.clampRect(const Rect.fromLTWH(2, -3, 0.001, 0.5));
    expect(r.width, closeTo(PageElement.minSize, 1e-9));
    expect(r.left, closeTo(0.95, 1e-9));
    expect(r.top, closeTo(-0.45, 1e-9)); // 아래 5% 가 슬라이드 안
    final big = PageElement.clampRect(const Rect.fromLTWH(0, 0, 9, 1));
    expect(big.width, closeTo(PageElement.maxSize, 1e-9));
  });

  test('배경 JSON page_elements 왕복·isFreePage·==', () {
    final back = SlideBackground.decode(SlideBackground.encode(page))!;
    expect(back, page);
    expect(back.hashCode, page.hashCode);
    expect(back.isFreePage, isTrue);
    expect(const SlideBackground(color: Color(0xFF000000)).isFreePage, isFalse);
    // 빈 목록도 편집 페이지다.
    expect(
      SlideBackground.fromJson({
        'color': '#000000',
        'page_elements': [],
      })!.isFreePage,
      isTrue,
    );
    // 2차 키는 더 이상 JSON 에 안 실린다.
    final json = page.toJson();
    expect(json.containsKey('image_rect'), isFalse);
    expect(json.containsKey('show_song_title'), isFalse);
  });

  test('withPageElementsOf 는 요소만 옮기고, 배경은 요소를 모른다', () {
    const other = SlideBackground(
      color: Color(0xFFFFFFFF),
      imagePath: '/x.png',
    );
    final moved = other.withPageElementsOf(page);
    expect(moved.color, other.color);
    expect(moved.imagePath, '/x.png');
    expect(moved.pageElements, page.pageElements);
    expect(other.withPageElementsOf(null).isFreePage, isFalse);

    final global = ExportStyle.fromJson(const {
      'font_size': 30,
      'bible_font_size': 20,
      'show_song_title': false,
    });
    expect(global.withBackground(page).showSongTitle, isFalse);
  });

  test('.wsconti 경로 바꾸기가 그림 요소 경로도 바꾸고, 못 실은 그림은 빠진다', () {
    final mapped = WorshipContiRepository.mapBackgroundPaths(
      SlideBackground.encode(page),
      (p) => p == '/p/cat.png' ? 'file0.png' : p,
    );
    final elements = SlideBackground.decode(mapped)!.pageElements!;
    expect((elements.first as PageImageElement).path, 'file0.png');
    expect(elements.last, text);

    final dropped = WorshipContiRepository.mapBackgroundPaths(
      SlideBackground.encode(page),
      (p) => null,
    );
    expect(SlideBackground.decode(dropped)!.pageElements, [text]);
  });

  testWidgets('PageCanvas 를 화면 밖에서 구우면 배경·그림 요소가 그 자리에 찍힌다', (tester) async {
    await tester.runAsync(() async {
      const red = Color(0xFFFF0000);
      const navy = Color(0xFF0B132B);
      final redImage = await _solid(4, 4, red);
      final shot = await renderWidgetToImage(
        PageCanvas(
          elements: const [image],
          backgroundColor: navy,
          images: {image.path: redImage},
        ),
        const Size(PageCanvas.width, PageCanvas.height),
      );
      expect(shot.width, 1920);
      expect(shot.height, 1080);
      // 그림 자리 (0.5, 0.5, 0.25, 0.25) → x 960~1440, y 540~810
      expect(await _pixelAt(shot, 1200, 675), red);
      expect(await _pixelAt(shot, 900, 675), navy);
      expect(await _pixelAt(shot, 5, 5), navy);
      shot.dispose();
      redImage.dispose();
    });
  });

  testWidgets('loadImages: 긴 변을 2560 으로 줄이고 없는 파일은 뺀다', (tester) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('page_image_test');
      try {
        final big = await _solid(3000, 100, Colors.green);
        final png = await big.toByteData(format: ui.ImageByteFormat.png);
        big.dispose();
        final path = '${dir.path}/big.png';
        await File(path).writeAsBytes(png!.buffer.asUint8List());
        final images = await PageComposer.loadImages([
          path,
          '${dir.path}/none.png',
        ]);
        expect(images.keys, [path]);
        expect(images[path]!.width, PageComposer.maxDecodeSide);
        expect(images[path]!.height, 85);
        for (final i in images.values) {
          i.dispose();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  test('구운 PNG 가 없어도 편집 페이지는 불러오고, 일반 PPT 항목은 빠진다', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(db.close);
    await createPraiseSchema(db);
    final repository = WorshipContiRepository(
      database: PraiseDatabase.forTesting(db),
      supportDirectory: () async => Directory.systemTemp,
    );
    const gone = '/no/such/render_x.png';
    final contiId = await repository.saveConti(
      '편집 페이지',
      [
        (
          uid: 1,
          item: const ImageStagingItem(sourceName: '광고', imagePaths: [gone]),
        ),
        (
          uid: 2,
          item: const ImageStagingItem(sourceName: 'PPT', imagePaths: [gone]),
        ),
      ],
      backgrounds: {1: page},
    );
    final loaded = await repository.loadConti(contiId, 10);
    expect(loaded.items, hasLength(1));
    expect((loaded.items.single.item as ImageStagingItem).imagePaths, [gone]);
    expect(loaded.backgrounds[loaded.items.single.uid]?.pageElements, [
      image,
      text,
    ]);
    expect(loaded.missingCount, 1);
  });
}
