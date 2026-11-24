import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/page_element.dart';
import 'package:worship_slides/src/features/praise/domain/ppt_layout.dart';
import 'package:worship_slides/src/features/praise/presentation/ppt_layout_dialog.dart';

// PPT 를 편집 페이지로 가져오기: `ppt_tool layout` 계약 JSON(가짜) → 페이지·배경·요소·그룹, 결과 창(s6).
void main() {
  Map<String, dynamic> contract({
    bool letterboxed = false,
    List<String> fontsMissing = const ['맑은 고딕'],
    bool allHidden = false,
  }) => {
    'source_name': '2026 성탄 예배.pptx',
    'slide_size': {'width': 12192000, 'height': 6858000},
    'aspect': 1.7778,
    'letterboxed': letterboxed,
    'fonts': ['맑은 고딕', 'Pretendard'],
    'fonts_missing': fontsMissing,
    'slides': [
      {
        'index': 1,
        'hidden': allHidden,
        'title': '  성탄 축하 ',
        'background_png': '/work/bg_001.png',
        'elements': [
          {
            'type': 'text',
            'id': 'a' * 16,
            'rect': [0.1, 0.1, 0.5, 0.2],
            'text': '기쁘다 구주 오셨네',
            'font_size': 44,
            'color': '#FFFFFF',
            'bold': true,
            'align': 'center',
            'font_family': '맑은 고딕',
            'valign': 'middle',
          },
          {
            'type': 'image',
            'id': 'b' * 16,
            'rect': [0.6, 0.3, 0.3, 0.4],
            'path': '/work/s001_2.png',
          },
          {
            'type': 'image',
            'id': 'c' * 16,
            'rect': [0.1, 0.5, 0.2, 0.2],
            'path': '/work/s001_3.jpg',
          },
          {
            'type': 'shape',
            'id': 'd' * 16,
            'rect': [0.1, 0.8, 0.8, 0],
            'shape': 'line',
            'stroke': '#FF0000',
            'stroke_width': 2,
          },
        ],
        'dropped': {'rotated': 1, 'table': 2},
        'effects_lost': 3,
      },
      {
        'index': 2,
        'hidden': true,
        'title': null,
        'background_png': null,
        'elements': [],
        'dropped': {},
        'effects_lost': 0,
      },
      {
        'index': 3,
        'hidden': allHidden,
        'title': null,
        'background_png': '/work/bg_003.png',
        'elements': [],
        'dropped': {},
        'effects_lost': 0,
      },
    ],
  };

  test('복사할 파일 = 숨기지 않은 장의 배경 PNG·그림 요소', () {
    final layout = PptLayout.fromJson(contract());
    expect(pptLayoutFiles(layout), {
      '/work/bg_001.png',
      '/work/s001_2.png',
      '/work/s001_3.jpg',
      '/work/bg_003.png',
    });
  });

  test('숨긴 장은 건너뛰고, 경로는 복사본으로·못 옮긴 그림은 빼고 요소를 읽는다', () {
    final layout = PptLayout.fromJson(contract());
    final pages = pptLayoutPages(layout, {
      '/work/bg_001.png': '/app/page_images/1_bg_001.png',
      '/work/s001_2.png': '/app/page_images/1_s001_2.png',
      // s001_3.jpg 는 복사 실패, bg_003 도 실패.
    });
    expect(pages, hasLength(2));

    final first = pages[0];
    expect(first.name, '성탄 축하');
    expect(first.background.color, const Color(0xFF000000));
    expect(first.background.imagePath, '/app/page_images/1_bg_001.png');
    expect(first.background.isFreePage, isTrue);
    final elements = first.background.pageElements!;
    expect(elements.map((e) => e.runtimeType), [
      PageTextElement,
      PageImageElement,
      PageShapeElement,
    ]);
    final text = elements[0] as PageTextElement;
    expect(text.text, '기쁘다 구주 오셨네');
    expect(text.fontFamily, '맑은 고딕');
    expect(text.bold, isTrue);
    expect(text.rect, const Rect.fromLTWH(0.1, 0.1, 0.5, 0.2));
    expect(
      (elements[1] as PageImageElement).path,
      '/app/page_images/1_s001_2.png',
    );
    expect((elements[2] as PageShapeElement).rect.height, 0); // 가로선

    // 제목 없는 장 = '파일 이름 N'(원본 번호), 배경을 못 옮겼으면 색만.
    expect(pages[1].name, '2026 성탄 예배 3');
    expect(pages[1].background.imagePath, isNull);
    expect(pages[1].background.pageElements, isEmpty);
  });

  test('그룹 이름 = 파일 이름(12자), 겹치면 (2)', () {
    final layout = PptLayout.fromJson(contract());
    expect(pptImportGroupName(layout, const []), '2026 성탄 예배');
    // uniqueGroupName 은 12자에 맞춰 자른 뒤 끝 공백을 다듬는다.
    expect(pptImportGroupName(layout, const ['2026 성탄 예배']), '2026 성탄 (2)');
    final long = PptLayout.fromJson({
      ...contract(),
      'source_name': '주일 오후 찬양 예배 (청년부)/x.pptx',
    });
    expect(
      pptImportGroupName(long, const []).runes.length,
      lessThanOrEqualTo(12),
    );
    expect(pptImportGroupName(long, const []), isNot(contains('/')));
  });

  group('결과 창', () {
    Future<ValueNotifier<Object?>> open(
      WidgetTester tester,
      PptLayout layout,
    ) async {
      final result = ValueNotifier<Object?>('열림');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result.value =
                  await PptLayoutResultDialog.show(context, layout, '성탄'),
              child: const Text('열기'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('개수는 계약 합과 같고 0 인 줄은 숨긴다 · 콘티에 담기 = true', (tester) async {
      final result = await open(tester, PptLayout.fromJson(contract()));
      expect(find.text('3개'), findsOneWidget); // dropped 1 + 2
      expect(find.text('3곳'), findsOneWidget); // effects_lost
      expect(find.text('1개'), findsOneWidget); // 없는 글꼴
      expect(find.textContaining('맑은 고딕'), findsOneWidget);
      expect(find.text('숨긴 슬라이드'), findsOneWidget);
      expect(find.textContaining('2번째 장은 건너뛰었습니다'), findsOneWidget);
      expect(find.text('16:9 가 아님'), findsNothing); // letterboxed false
      await tester.tap(find.text('콘티에 담기 (2장)'));
      await tester.pumpAndSettle();
      expect(result.value, isTrue);
    });

    testWidgets('0 인 줄은 모두 숨기고 16:9 아님은 보인다 · 담지 않기 = null', (tester) async {
      final json = contract(letterboxed: true, fontsMissing: const []);
      for (final s in json['slides'] as List) {
        s['hidden'] = false;
        s['dropped'] = {};
        s['effects_lost'] = 0;
      }
      final result = await open(tester, PptLayout.fromJson(json));
      for (final label in ['그림으로 둔 요소', '빠진 꾸밈', '없는 글꼴', '숨긴 슬라이드']) {
        expect(find.text(label), findsNothing);
      }
      expect(find.text('16:9 가 아님'), findsOneWidget);
      await tester.tap(find.text('담지 않기'));
      await tester.pumpAndSettle();
      expect(result.value, isNull);
    });

    testWidgets('편집 가능 0장이면 닫기만', (tester) async {
      final result = await open(
        tester,
        PptLayout.fromJson(contract(allHidden: true)),
      );
      expect(find.text('편집 페이지로 만들 수 있는 장이 없습니다'), findsOneWidget);
      expect(find.textContaining('콘티에 담기'), findsNothing);
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      expect(result.value, isNull);
    });
  });
}
