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

  test('steps·anim_lost 읽기(없으면 1·빈 맵, 0·틀린 값은 버림), 요소 appear 는 페이지까지 간다', () {
    final json = contract();
    final slides = json['slides'] as List;
    slides[0]['steps'] = 3;
    slides[0]['anim_lost'] = {'exit': 2, 'overlap': 0, 'paragraph': 'x'};
    (slides[0]['elements'] as List)[0]['appear'] = 2;
    (slides[0]['elements'] as List)[1]['appear'] = 1;
    final layout = PptLayout.fromJson(json);
    expect(layout.slides[0].steps, 3);
    expect(layout.slides[0].animLost, {'exit': 2});
    expect(layout.slides[2].steps, 1);
    expect(layout.slides[2].animLost, isEmpty);

    final all = {for (final f in pptLayoutFiles(layout)) f: '/copy$f'};
    final elements = pptLayoutPages(layout, all).first.background.pageElements!;
    expect(elements.map((e) => e.appear), [2, 1, 0, 0]);
    expect(pageStepCount(elements), layout.slides[0].steps);
  });

  test('요소 disappear 도 페이지까지 간다: 클릭1 나타남 → 클릭2 사라짐 → 클릭3 다른 요소', () {
    final json = contract();
    final slides = json['slides'] as List;
    slides[0]['steps'] = 4;
    final elements0 = slides[0]['elements'] as List;
    elements0[0]['appear'] = 1;
    elements0[0]['disappear'] = 2;
    elements0[1]['appear'] = 3;
    elements0[2]['disappear'] = 2; // 처음부터 보이다가 사라짐
    final layout = PptLayout.fromJson(json);
    final all = {for (final f in pptLayoutFiles(layout)) f: '/copy$f'};
    final elements = pptLayoutPages(layout, all).first.background.pageElements!;
    expect(elements.map((e) => (e.appear, e.disappear)), [
      (1, 2),
      (3, 0),
      (0, 2),
      (0, 0),
    ]);
    expect(pageStepCount(elements), layout.slides[0].steps);
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

  test('진행 줄 → 진행 창 문구, 모르는 단계는 null', () {
    expect(
      pptLayoutProgressLabel({'progress': 'read', 'n': 3, 'total': 15}),
      '슬라이드 읽는 중… (3 / 15)',
    );
    expect(pptLayoutProgressLabel({'progress': 'render'}), '배경 굽는 중…');
    expect(
      pptLayoutProgressLabel({'progress': 'render', 'n': 2}),
      '애니메이션 배경 굽는 중…',
    );
    expect(pptLayoutProgressLabel({'progress': 'later'}), isNull);
  });

  test('빠진 것 세기: 못 옮긴 그림·배경(숨긴 장 제외) → 알림 문구', () {
    final layout = PptLayout.fromJson(contract());
    // 아무것도 못 옮김: 그림 2개, 배경 2장(1·3번, 2번은 숨김)
    expect(pptLayoutLost(layout, const {}), (images: 2, backgrounds: 2));
    final all = {for (final f in pptLayoutFiles(layout)) f: '/copy$f'};
    expect(pptLayoutLost(layout, all), (images: 0, backgrounds: 0));
    final oneImage = {...all}..remove('/work/s001_3.jpg');
    expect(pptLayoutLost(layout, oneImage), (images: 1, backgrounds: 0));

    expect(
      pptImportProblems(pagesFailed: 0, imagesLost: 0, backgroundsLost: 0),
      isNull,
    );
    expect(
      pptImportProblems(pagesFailed: 2, imagesLost: 3, backgroundsLost: 1),
      '2장은 만들지 못했습니다 · 그림 3개를 옮기지 못했습니다 · 1장은 배경 그림 없이 담았습니다. '
      '자세한 내용은 로그 보기에서 확인해 주세요.',
    );
  });

  test('fonts_installed: 이름·경로·TTC 번호, 모양이 틀린 줄은 버린다', () {
    final layout = PptLayout.fromJson({
      ...contract(),
      'fonts_installed': [
        {'family': '애플 고딕', 'path': '/f/a.ttc', 'index': 2},
        {'family': 'B', 'path': '/f/b.ttf'},
        {'family': 'C'},
      ],
    });
    expect(layout.fontsInstalled, [
      (family: '애플 고딕', path: '/f/a.ttc', index: 2),
      (family: 'B', path: '/f/b.ttf', index: 0),
    ]);
    expect(PptLayout.fromJson(contract()).fontsInstalled, isEmpty);
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
      for (final label in [
        '그림으로 둔 요소',
        '빠진 꾸밈',
        '없는 글꼴',
        '숨긴 슬라이드',
        '애니메이션',
        '처음부터 보이게 둔 애니메이션',
      ]) {
        expect(find.text(label), findsNothing);
      }
      expect(find.text('16:9 가 아님'), findsOneWidget);
      await tester.tap(find.text('담지 않기'));
      await tester.pumpAndSettle();
      expect(result.value, isNull);
    });

    testWidgets('애니메이션: 장 수 → 클릭 단계 합, 처음부터 보이게 둔 것 까닭·합', (tester) async {
      final json = contract();
      final slides = json['slides'] as List;
      slides[0]['steps'] = 3;
      slides[0]['anim_lost'] = {'exit': 1, 'paragraph': 2};
      slides[2]['steps'] = 2;
      slides[2]['anim_lost'] = {'overlap': 1};
      await open(tester, PptLayout.fromJson(json));
      expect(find.text('애니메이션'), findsOneWidget);
      expect(find.textContaining('2장 → 클릭 단계 5장으로 나눔'), findsOneWidget);
      expect(find.text('5장'), findsOneWidget);
      expect(find.text('처음부터 보이게 둔 애니메이션'), findsOneWidget);
      expect(find.text('4곳'), findsOneWidget);
      expect(find.textContaining('다시 나타남·문단 단위·겹침'), findsOneWidget);
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
