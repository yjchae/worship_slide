import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/presentation/auto_advance_box.dart';
import 'package:worship_slides/src/features/praise/presentation/auto_advance_timer.dart';

// testWidgets 는 Timer 를 가짜 시간으로 돌린다. DateTime.now 는 안 따라가므로
// pump 한 만큼 같이 미는 가짜 시계를 넣는다.
class _Clock {
  DateTime t = DateTime(2026, 11, 20, 10);
  DateTime now() => t;
}

Future<void> _advance(WidgetTester tester, _Clock clock, Duration d) async {
  // 1초씩 밀어야 Timer 가 시계와 같은 순간에 터진다.
  for (var i = 0; i < d.inSeconds; i++) {
    clock.t = clock.t.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }
}

void main() {
  testWidgets('반복: 5분마다 넘긴다 (2→3→4)', (tester) async {
    final clock = _Clock();
    final timer = AutoAdvanceTimer(now: clock.now);
    var page = 2;
    timer.onElapsed = () => page++;
    timer.start();

    await _advance(tester, clock, const Duration(minutes: 4, seconds: 59));
    expect(page, 2);
    expect(timer.remaining, const Duration(seconds: 1));
    await _advance(tester, clock, const Duration(seconds: 1));
    expect(page, 3);
    await _advance(tester, clock, const Duration(minutes: 5));
    expect(page, 4);
    expect(timer.isRunning, isTrue);
    timer.dispose();
  });

  testWidgets('한 번: 넘기고 멈춘다', (tester) async {
    final clock = _Clock();
    final timer = AutoAdvanceTimer(now: clock.now)
      ..setRepeat(false)
      ..setInterval(const Duration(seconds: 30));
    var fired = 0;
    timer.onElapsed = () => fired++;
    timer.start();
    await _advance(tester, clock, const Duration(seconds: 90));
    expect(fired, 1);
    expect(timer.isRunning, isFalse);
    timer.dispose();
  });

  testWidgets('멈추면 더 넘기지 않고, 콜백 안에서 멈춰도 다시 켜지지 않는다', (tester) async {
    final clock = _Clock();
    final timer = AutoAdvanceTimer(now: clock.now)
      ..setInterval(const Duration(seconds: 10));
    var fired = 0;
    timer.onElapsed = () {
      fired++;
      timer.stop(); // 마지막 페이지
    };
    timer.start();
    await _advance(tester, clock, const Duration(seconds: 35));
    expect(fired, 1);
    expect(timer.isRunning, isFalse);

    timer.onElapsed = () => fired++;
    timer.start();
    await _advance(tester, clock, const Duration(seconds: 5));
    timer.stop();
    await _advance(tester, clock, const Duration(seconds: 30));
    expect(fired, 1);
    timer.dispose();
  });

  test('1초보다 짧은 간격은 받지 않는다', () {
    final timer = AutoAdvanceTimer()..setInterval(Duration.zero);
    expect(timer.interval, const Duration(minutes: 5));
    timer.dispose();
  });

  testWidgets('자동 넘기기 칸: 발표 전엔 시작 못 하고, 시작·반복·멈춤이 된다', (tester) async {
    final clock = _Clock();
    final timer = AutoAdvanceTimer(now: clock.now);
    Widget box(bool presenting) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          child: AutoAdvanceBox(timer: timer, presenting: presenting),
        ),
      ),
    );

    await tester.pumpWidget(box(false));
    final start = find.byKey(const ValueKey('auto-advance-start'));
    expect(tester.widget<ButtonStyleButton>(start).onPressed, isNull);

    await tester.pumpWidget(box(true));
    await tester.enterText(find.byKey(const ValueKey('auto-advance-min')), '0');
    await tester.enterText(
      find.byKey(const ValueKey('auto-advance-sec')),
      '20',
    );
    expect(timer.interval, const Duration(seconds: 20));

    await tester.tap(find.byKey(const ValueKey('auto-advance-repeat')));
    await tester.pump();
    expect(timer.repeat, isFalse);
    expect(find.text('한 번'), findsOneWidget);

    await tester.tap(start);
    await tester.pump();
    expect(timer.isRunning, isTrue);
    expect(find.text('다음 넘김 00:20'), findsOneWidget);

    await _advance(tester, clock, const Duration(seconds: 5));
    expect(find.text('다음 넘김 00:15'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('auto-advance-stop')));
    await tester.pump();
    expect(timer.isRunning, isFalse);
    expect(start, findsOneWidget);
    timer.dispose();
  });
}
