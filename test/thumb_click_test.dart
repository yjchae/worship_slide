import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/presentation/thumb_select.dart';

// 발표 보기 썸네일과 같은 겹침(빈 곳 탭 > 스크롤 > Draggable > 탭·더블탭)에서
// 원클릭 = 고르기, 더블클릭 = 이동, 끌기 = 끌기가 서로 안 막는지 본다.
void main() {
  testWidgets('원클릭·더블클릭·끌기·빈 곳 클릭', (tester) async {
    final log = <String>[];
    var thumbDown = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Listener(
          onPointerDown: (_) {
            if (!thumbDown) log.add('empty');
            thumbDown = false;
          },
          child: ListView(
            children: [
              Listener(
                onPointerDown: (_) => thumbDown = true,
                child: Draggable<int>(
                  data: 1,
                  feedback: const SizedBox(width: 10, height: 10),
                  onDragStarted: () => log.add('drag'),
                  child: GestureDetector(
                    onTap: () => log.add('tap'),
                    onDoubleTap: () => log.add('double'),
                    child: const ColoredBox(
                      color: Colors.red,
                      child: SizedBox(width: 100, height: 100),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final thumb = find.byType(Draggable<int>);

    await tester.tap(thumb);
    await tester.pump(const Duration(milliseconds: 400));
    expect(log, ['tap']);

    log.clear();
    await tester.tap(thumb);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(thumb);
    await tester.pump(const Duration(milliseconds: 400));
    expect(log, ['double']);

    log.clear();
    final g = await tester.startGesture(
      tester.getCenter(thumb),
      kind: PointerDeviceKind.mouse,
    );
    await g.moveBy(const Offset(40, 0));
    await g.moveBy(const Offset(40, 0));
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(log, ['drag']);

    log.clear();
    await tester.tapAt(const Offset(700, 500));
    await tester.pump(const Duration(milliseconds: 400));
    expect(log, ['empty']);
  });

  // 수정키는 누른 순간 기록한 값을 쓴다 — onTap 이 더블클릭 대기로 늦어져도(키를 일찍 뗀 뒤여도) 같은 결과.
  testWidgets('수정키를 50ms 뒤 떼도 토글·범위 유지', (tester) async {
    var shift = false, toggle = false;
    var marked = <int>{2};
    int? anchor = 2;
    await tester.pumpWidget(
      MaterialApp(
        home: Listener(
          onPointerDown: (_) {
            shift = HardwareKeyboard.instance.isShiftPressed;
            toggle =
                HardwareKeyboard.instance.isMetaPressed ||
                HardwareKeyboard.instance.isControlPressed;
          },
          child: GestureDetector(
            onTap: () {
              final r = applyThumbSelect(
                marked: marked,
                anchor: anchor,
                currentIndex: 0,
                i: 5,
                shift: shift,
                toggle: toggle,
              );
              marked = r.marked;
              anchor = r.anchor;
            },
            onDoubleTap: () {},
            child: const ColoredBox(
              color: Colors.red,
              child: SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final g = await tester.startGesture(const Offset(400, 300));
    await g.up();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(milliseconds: 400));
    expect(marked, {2, 3, 4, 5});

    marked = {2};
    anchor = 2;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final g2 = await tester.startGesture(const Offset(400, 300));
    await g2.up();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 400));
    expect(marked, {2, 5});
  });

  test('applyThumbSelect 기본 규칙', () {
    final r = applyThumbSelect(
      marked: {1, 2},
      anchor: 2,
      currentIndex: 0,
      i: 7,
      shift: false,
      toggle: false,
    );
    expect(r.marked, {7});
    expect(r.anchor, 7);
  });
}
