import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/presentation/presenter_pin_dialog.dart';

void main() {
  Future<String?> Function() openDialog(WidgetTester tester) {
    return () async {
      String? result = 'not closed';
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<String>(
                  context: context,
                  builder: (_) => const PresenterPinDialog(initial: '1234'),
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
    };
  }

  testWidgets('바꾸기·취소·Enter 로 닫아도 오류가 없다 (닫히는 동안 컨트롤러 사용)', (tester) async {
    String? last;
    Future<void> open() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                last = await showDialog<String>(
                  context: context,
                  builder: (_) => const PresenterPinDialog(initial: '1234'),
                );
              },
              child: const Text('열기'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
    }

    await open();
    await tester.enterText(find.byType(TextField), '5678');
    await tester.tap(find.text('바꾸기'));
    await tester.pumpAndSettle();
    expect(last, '5678');
    expect(tester.takeException(), isNull);

    await open();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(last, isNull);
    expect(tester.takeException(), isNull);

    await open();
    await tester.enterText(find.byType(TextField), '0042');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(last, '0042');
    expect(tester.takeException(), isNull);
  });

  testWidgets('4자리가 아니면 닫지 않고 알린다, 무작위는 4자리', (tester) async {
    await openDialog(tester)();
    await tester.enterText(find.byType(TextField), '12');
    await tester.tap(find.text('바꾸기'));
    await tester.pump();
    expect(find.text('숫자 4자리를 넣어 주세요.'), findsOneWidget);
    expect(find.byType(PresenterPinDialog), findsOneWidget);

    await tester.tap(find.text('무작위로 정하기'));
    await tester.pump();
    final text = tester
        .widget<TextField>(find.byType(TextField))
        .controller!
        .text;
    expect(RegExp(r'^\d{4}$').hasMatch(text), isTrue);
    expect(find.text('숫자 4자리를 넣어 주세요.'), findsNothing);
  });

  testWidgets('PIN 줄은 PIN 과 바꾸기 버튼을 보인다', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PresenterPinRow(pin: '0731', onChange: () => pressed++),
        ),
      ),
    );
    expect(find.text('0731'), findsOneWidget);
    await tester.tap(find.text('바꾸기'));
    expect(pressed, 1);
  });
}
