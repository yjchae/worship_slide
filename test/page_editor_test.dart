import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/page_element.dart';
import 'package:worship_slides/src/features/praise/presentation/page_editor_dialog.dart';

const _style = ExportStyle(
  fontSize: 30,
  bibleFontSize: 30,
  backgroundColor: Color(0xFF1B1B1B),
  textColor: Colors.white,
  bibleTextColor: Colors.white,
  textPosition: VerticalTextPosition.bottom,
  bibleTextPosition: VerticalTextPosition.middle,
  lyricsTextAlign: HorizontalPosition.center,
  bibleTextAlign: HorizontalPosition.center,
  includeEnglishLyrics: true,
  englishTextColor: Color(0xFFFFF176),
  showSongTitle: true,
  showBibleTitle: false,
  titleFontSize: 14,
  bibleTitleFontSize: 14,
  titleTextColor: Colors.white,
  bibleTitleTextColor: Colors.white,
  titleHorizontalPosition: HorizontalPosition.right,
  titleVerticalPosition: VerticalTextPosition.bottom,
  bibleTitleHorizontalPosition: HorizontalPosition.right,
  bibleTitleVerticalPosition: VerticalTextPosition.bottom,
);

void main() {
  const start = Rect.fromLTWH(0.2, 0.2, 0.4, 0.2);

  bool near(Rect a, Rect b) =>
      (a.left - b.left).abs() < 1e-9 &&
      (a.top - b.top).abs() < 1e-9 &&
      (a.width - b.width).abs() < 1e-9 &&
      (a.height - b.height).abs() < 1e-9;

  group('resizePageRect', () {
    test('변 손잡이는 그 변만 움직인다', () {
      final r = resizePageRect(start, PageHandle.right, const Offset(0.1, 0.3));
      expect(near(r, const Rect.fromLTWH(0.2, 0.2, 0.5, 0.2)), isTrue);
      final l = resizePageRect(start, PageHandle.left, const Offset(0.1, 0));
      expect(near(l, const Rect.fromLTWH(0.3, 0.2, 0.3, 0.2)), isTrue);
    });

    test('모서리 비율 유지는 반대쪽 모서리를 붙잡고 비율을 지킨다', () {
      final r = resizePageRect(
        start,
        PageHandle.topLeft,
        const Offset(-0.2, 0),
        keepAspect: true,
      );
      expect(r.width / r.height, closeTo(2, 1e-9));
      expect(r.right, closeTo(start.right, 1e-9));
      expect(r.bottom, closeTo(start.bottom, 1e-9));
      expect(r.width, closeTo(0.6, 1e-9));
    });

    test('비율 풀기(Shift)면 모서리가 두 변을 따로 움직인다', () {
      final r = resizePageRect(
        start,
        PageHandle.bottomRight,
        const Offset(0.1, 0.3),
      );
      expect(near(r, const Rect.fromLTWH(0.2, 0.2, 0.5, 0.5)), isTrue);
    });

    test('반대쪽을 넘겨 끌어도 가장 작은 크기에서 멈춘다', () {
      final r = resizePageRect(start, PageHandle.right, const Offset(-1, 0));
      expect(r.width, closeTo(PageElement.minSize, 1e-9));
      expect(r.left, closeTo(start.left, 1e-9));
    });
  });

  test('새 그림은 원래 비율로 60% 안에 가운데, 다음 장은 3%씩 비킨다', () {
    final r = newImageRect(const Size(3840, 1080), 0);
    expect(r.width, closeTo(0.6, 1e-9));
    expect(r.width * 1920 / (r.height * 1080), closeTo(3840 / 1080, 1e-9));
    expect(r.center.dx, closeTo(0.5, 1e-9));
    final small = newImageRect(const Size(192, 108), 1);
    expect(small.width, closeTo(0.1, 1e-9)); // 키우지 않는다
    expect(small.center.dx, closeTo(0.53, 1e-9));
  });

  test('원래 비율로 = 너비 그대로, 높이를 그림 비율에', () {
    final r = originalAspectRect(start, const Size(1000, 1000));
    expect(r.width, start.width);
    expect(r.width * 1920, closeTo(r.height * 1080, 1e-6));
  });

  test('되돌리기·다시 하기, 새로 바꾸면 다시 하기는 버린다', () {
    final a = <PageElement>[];
    final b = [PageImageElement(id: 'x', rect: start, path: '/a.png')];
    final h = PageEditHistory()..record(a);
    expect(h.undo(b), same(a));
    expect(h.redo(a), same(b));
    h.record(b);
    expect(h.canRedo, isFalse);
    for (var i = 0; i < 60; i++) {
      h.record(a);
    }
    var count = 0;
    while (h.undo(a) != null) {
      count++;
    }
    expect(count, PageEditHistory.limit);
  });

  test('자동 이름 = 첫 글 상자 첫 줄, 없으면 기본 이름', () {
    expect(pageAutoName(const []), '슬라이드 편집 페이지');
    expect(
      pageAutoName([
        PageImageElement(id: 'a', rect: start, path: '/a.png'),
        PageTextElement(id: 'b', rect: start, text: '\n  광고  \n둘째'),
      ]),
      '광고',
    );
  });

  testWidgets('새 페이지: 제목 글 상자를 바로 고치고 확인하면 굽고 돌려준다', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    List<PageElement>? composed;
    PageEditorResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<PageEditorResult>(
                context: context,
                builder: (_) => PageEditorDialog(
                  style: _style,
                  compose: (elements) async {
                    composed = elements;
                    return '/tmp/render.png';
                  },
                  readClipboardImage: () async => null,
                ),
              );
            },
            child: const Text('열기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    // 처음엔 '제목' 글 상자가 골라져 '글' 칸에 들어 있다.
    final field = find.widgetWithText(TextField, '글');
    expect(field, findsOneWidget);
    await tester.enterText(field, '광고');
    await tester.pump();
    // 글 상자 하나 더 → 빈 글 상자는 확인 때 빠진다.
    await tester.tap(find.byTooltip('글 상자 추가'));
    await tester.pump();
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();

    expect(composed, hasLength(1));
    expect((composed!.single as PageTextElement).text, '광고');
    expect(result?.name, '광고');
    expect(result?.imagePath, '/tmp/render.png');
  });

  testWidgets('클립보드 그림 읽기가 실패해도 글자가 있으면 글 상자로 넣는다', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, dynamic>{'text': '  알림  '}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PageEditorDialog(
          style: _style,
          compose: (_) async => '/tmp/render.png',
          readClipboardImage: () async => throw Exception('ppt_tool 실패'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('붙여 넣기 (⌘V / Ctrl+V)'));
    // 로그 쓰기(실제 파일 IO)가 끝나도록 진짜 시간으로 기다린다.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('클립보드 그림을 읽지 못했습니다'), findsNothing);
    expect(find.widgetWithText(TextField, '알림'), findsOneWidget);
  });
}
