import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/worship_conti.dart';
import 'package:worship_slides/src/features/praise/presentation/praise_home_page.dart';

// 콘티 저장 창: 상태별 버튼·경고, Enter 동작. 스낵바·올리기 흐름은 실제 앱에서 확인한다.
void main() {
  final saved = WorshipConti(
    id: 1,
    name: '지난주 예배',
    createdAt: DateTime(2026, 10, 25, 9, 30),
    itemCount: 7,
    uid: 'a' * 32,
  );

  Future<ValueNotifier<Object?>> open(
    WidgetTester tester,
    SaveContiDialog dialog,
  ) async {
    final result = ValueNotifier<Object?>('열림');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result.value = await showDialog<({String name, bool overwrite})>(
                context: context,
                builder: (_) => dialog,
              );
            },
            child: const Text('열기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    return result;
  }

  Future<void> pressEnter(WidgetTester tester) async {
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester, Finder button) =>
      tester.widget<ButtonStyleButton>(button).onPressed != null;

  testWidgets('연결 없음: 저장만 있고 Enter 로 새로 저장한다', (tester) async {
    final result = await open(
      tester,
      const SaveContiDialog(initialName: '2026-10-31 예배'),
    );
    expect(find.widgetWithText(FilledButton, '저장'), findsOneWidget);
    expect(find.text('덮어쓰기'), findsNothing);
    expect(find.text('새 콘티로 저장'), findsNothing);

    await pressEnter(tester);
    expect(result.value, (name: '2026-10-31 예배', overwrite: false));
  });

  testWidgets('연결됨: 저장본 정보가 보이고 Enter 는 덮어쓰기다', (tester) async {
    final result = await open(
      tester,
      SaveContiDialog(initialName: saved.name, saved: saved),
    );
    expect(find.widgetWithText(FilledButton, '덮어쓰기'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '새 콘티로 저장'), findsOneWidget);
    expect(find.text('저장본: "지난주 예배" · 2026-10-25 09:30 · 7개'), findsOneWidget);
    // 버튼 세 개가 한 줄에 들어간다.
    expect(
      tester.getCenter(find.text('취소')).dy,
      tester.getCenter(find.text('덮어쓰기')).dy,
    );

    await tester.enterText(find.byType(TextField), '  새 이름 ');
    await pressEnter(tester);
    expect(result.value, (name: '새 이름', overwrite: true));
  });

  testWidgets('경고가 있으면 주 버튼이 없고 Enter 로 닫히지 않는다', (tester) async {
    final result = await open(
      tester,
      SaveContiDialog(
        initialName: saved.name,
        saved: saved,
        savedChanged: true,
        missingCount: 2,
      ),
    );
    expect(find.text('불러온 뒤 저장본이 바뀌었습니다. 덮어쓰면 그 내용이 사라집니다.'), findsOneWidget);
    expect(
      find.text('불러올 때 2개 항목이 빠졌습니다. 덮어쓰면 저장본에서도 영구히 사라집니다.'),
      findsOneWidget,
    );
    expect(find.byType(FilledButton), findsNothing);

    await pressEnter(tester);
    expect(find.byType(SaveContiDialog), findsOneWidget);
    expect(result.value, '열림');

    await tester.tap(find.text('덮어쓰기'));
    await tester.pumpAndSettle();
    expect(result.value, (name: saved.name, overwrite: true));
  });

  testWidgets('저장본이 지워지면 안내와 저장만 있고 경고는 없다', (tester) async {
    final result = await open(
      tester,
      const SaveContiDialog(
        initialName: '지운 콘티',
        savedDeleted: true,
        missingCount: 2,
      ),
    );
    expect(find.text('불러온 저장본이 지워져 덮어쓸 수 없습니다. 새 콘티로 저장합니다.'), findsOneWidget);
    expect(find.textContaining('항목이 빠졌습니다'), findsNothing);
    expect(find.text('덮어쓰기'), findsNothing);

    await pressEnter(tester);
    expect(result.value, (name: '지운 콘티', overwrite: false));
  });

  testWidgets('이름을 비우면 취소만 눌리고 Enter 도 안 된다', (tester) async {
    await open(tester, SaveContiDialog(initialName: saved.name, saved: saved));
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(enabled(tester, find.widgetWithText(FilledButton, '덮어쓰기')), isFalse);
    expect(
      enabled(tester, find.widgetWithText(OutlinedButton, '새 콘티로 저장')),
      isFalse,
    );
    await pressEnter(tester);
    expect(find.byType(SaveContiDialog), findsOneWidget);
  });

  testWidgets('Esc 는 취소다', (tester) async {
    final result = await open(
      tester,
      SaveContiDialog(initialName: saved.name, saved: saved),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(result.value, isNull);
  });

  // 발표 단축키(_handleKeyEvent)는 페이지 FocusScope 에 걸려 있다. 창은 다른 라우트라 위로 올라오지 않는다.
  testWidgets('창 버튼에 포커스가 있어도 페이지 키 핸들러로 가지 않는다', (tester) async {
    final keys = <LogicalKeyboardKey>[];
    await tester.pumpWidget(
      MaterialApp(
        home: FocusScope(
          autofocus: true,
          onKeyEvent: (_, event) {
            keys.add(event.logicalKey);
            return KeyEventResult.ignored;
          },
          child: Builder(
            builder: (context) => TextButton(
              autofocus: true,
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) =>
                    SaveContiDialog(initialName: saved.name, saved: saved),
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(keys, isNotEmpty); // 창이 없으면 받는다

    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    keys.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab); // 입력칸 → 취소 버튼
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(keys, isEmpty);
  });
}
