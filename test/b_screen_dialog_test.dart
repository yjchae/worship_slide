import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/b_screen_store.dart';
import 'package:worship_slides/src/features/praise/data/screen_choice_store.dart';
import 'package:worship_slides/src/features/praise/presentation/b_screen_dialogs.dart';

const _screens = [
  ScreenInfo(index: 0, name: '내장', width: 1920, height: 1080, isMain: true),
  ScreenInfo(index: 1, name: '프로젝터', width: 1920, height: 1080, isMain: false),
  ScreenInfo(index: 2, name: '통역', width: 1920, height: 1080, isMain: false),
];

void main() {
  BScreenConfig? result;

  Future<void> open(WidgetTester tester, BScreenConfig config) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    result = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await BScreenSettingsDialog.show(
              context,
              config: config,
              screens: _screens,
              blocked: const {0: '메인 창', 1: '관객 화면(자동)'},
            ),
            child: const Text('열기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
  }

  testWidgets('http 가 아닌 주소는 저장되지 않는다', (tester) async {
    await open(tester, const BScreenConfig());
    await tester.enterText(find.byType(TextField), 'ftp://x');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(find.text('http:// 또는 https:// 로 시작하는 올바른 주소를 넣어 주세요.'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('주소를 비우면 슬라이더가 꺼지고 해상도 글이 슬라이드 전체가 된다', (tester) async {
    await open(tester, const BScreenConfig());
    expect(find.text('슬라이드 1248×702 · 자막 1920×378'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(find.text('슬라이드 1920×1080'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
  });

  testWidgets('고를 수 없는 모니터는 사유와 함께 비활성, 없는 모니터 선택은 저장해도 남는다', (tester) async {
    const missing = ScreenChoice(5, '빠진 모니터');
    await open(tester, const BScreenConfig(screen: missing));
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    final item = tester.widget<DropdownMenuItem<int>>(
      find
          .ancestor(
            of: find.textContaining('관객 화면(자동)').last,
            matching: find.byType(DropdownMenuItem<int>),
          )
          .last,
    );
    expect(item.enabled, isFalse);
    await tester.tap(find.text('고르지 않음').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(result?.screen?.name, '빠진 모니터');
  });

  test('쪽 수 경고 문구', () {
    expect(
      bCountWarning(24, 22, animated: true),
      '쪽 수가 다릅니다 (원본 24장 / 외국어 22장). 없는 쪽은 통역 화면에 원본이 나옵니다. '
      '애니메이션 단계 차이일 수 있습니다.',
    );
  });
}
