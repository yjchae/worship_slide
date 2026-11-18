import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';
import 'package:worship_slides/src/features/praise/presentation/conti_insert_target.dart';

const _song = PraiseSong(
  id: 1,
  fileName: 'a.pptx',
  title: '곡',
  lyrics: '가사',
  englishLyrics: '',
);

void main() {
  test('dropAfterHalf: 위 절반 = 앞, 아래 절반 = 뒤', () {
    expect(dropAfterHalf(5, 40), isFalse);
    expect(dropAfterHalf(20, 40), isFalse); // 정확히 가운데는 앞
    expect(dropAfterHalf(21, 40), isTrue);
  });

  test('insertIndexFor: 기준 앞/뒤, 기준이 없거나 사라졌으면 맨 끝', () {
    const uids = [10, 11, 12];
    expect(insertIndexFor(uids, 11, false), 1);
    expect(insertIndexFor(uids, 11, true), 2);
    expect(insertIndexFor(uids, 12, true), 3);
    expect(insertIndexFor(uids, 10, false), 0);
    expect(insertIndexFor(uids, 99, false), 3);
    expect(insertIndexFor(uids, null, true), 3);
    expect(insertIndexFor(const [], 1, false), 0);
  });

  // 실제 콘티 패널과 같은 겹침: 패널 전체 DragTarget<PraiseSong> 안의
  // ReorderableListView(손잡이로 순서 바꾸기) + 행마다 ContiInsertTarget.
  testWidgets('행 사이 놓기·빈 곳 놓기·순서 바꾸기가 서로 안 막는다', (tester) async {
    final log = <String>[];
    var order = [1, 2, 3];
    late StateSetter setOrder;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Draggable<PraiseSong>(
                data: _song,
                dragAnchorStrategy: pointerDragAnchorStrategy,
                feedback: const SizedBox(width: 10, height: 10),
                child: const ColoredBox(
                  key: Key('src'),
                  color: Colors.grey,
                  child: SizedBox(width: 80, height: 40),
                ),
              ),
              Draggable<BibleVerseDrag>(
                data: BibleVerseDrag(
                  () async => [BibleStagingItem(reference: 'r', text: 't')],
                ),
                dragAnchorStrategy: pointerDragAnchorStrategy,
                feedback: const SizedBox(width: 10, height: 10),
                child: const ColoredBox(
                  key: Key('bible'),
                  color: Colors.grey,
                  child: SizedBox(width: 80, height: 40),
                ),
              ),
              Draggable<int>(
                data: 7,
                dragAnchorStrategy: pointerDragAnchorStrategy,
                feedback: const SizedBox(width: 10, height: 10),
                child: const ColoredBox(
                  key: Key('other'),
                  color: Colors.grey,
                  child: SizedBox(width: 80, height: 40),
                ),
              ),
              Expanded(
                child: DragTarget<PraiseSong>(
                  onAcceptWithDetails: (d) => log.add('end'),
                  builder: (context, _, _) => StatefulBuilder(
                    builder: (context, set) {
                      setOrder = set;
                      return ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        itemCount: order.length,
                        onReorderItem: (o, n) {
                          log.add('reorder $o->$n');
                          final e = order.removeAt(o);
                          order.insert(n, e);
                          setOrder(() {});
                        },
                        itemBuilder: (context, i) {
                          final uid = order[i];
                          return ContiInsertTarget(
                            key: ValueKey(uid),
                            onDrop: (data, after) => log.add(
                              '${data.runtimeType} $uid ${after ? 'after' : 'before'}',
                            ),
                            child: SizedBox(
                              height: 60,
                              child: Row(
                                children: [
                                  Expanded(child: Text('row $uid')),
                                  ReorderableDragStartListener(
                                    index: i,
                                    child: Icon(
                                      Icons.drag_handle,
                                      key: Key('h$uid'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    Future<void> drag(Key from, Offset to) async {
      final g = await tester.startGesture(
        tester.getCenter(find.byKey(from)),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(to + const Offset(0, 3));
      await g.moveTo(to);
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
    }

    final row2 = tester.getRect(find.text('row 2')).center; // 행 높이 60
    final top = tester.getTopLeft(find.byKey(const ValueKey(2)));
    // 곡: 행 아래 절반 = 뒤, 위 절반 = 앞 (바깥 '맨 끝' 은 불리지 않는다)
    await drag(const Key('src'), Offset(row2.dx, top.dy + 50));
    expect(log, ['PraiseSong 2 after']);
    log.clear();
    await drag(const Key('src'), Offset(row2.dx, top.dy + 8));
    expect(log, ['PraiseSong 2 before']);

    // 성경 절 데이터도 같은 행에 놓인다
    log.clear();
    await drag(const Key('bible'), Offset(row2.dx, top.dy + 50));
    expect(log, ['BibleVerseDrag 2 after']);

    // 행 밖 빈 곳 = 패널 전체 타깃(맨 끝)
    log.clear();
    await drag(const Key('src'), Offset(row2.dx, 560));
    expect(log, ['end']);

    // 다른 종류 데이터는 행이 받지 않는다
    log.clear();
    await drag(const Key('other'), Offset(row2.dx, top.dy + 50));
    expect(log, isEmpty);

    // 손잡이로 순서 바꾸기는 그대로 된다
    log.clear();
    final h1 = tester.getCenter(find.byKey(const Key('h1')));
    final g = await tester.startGesture(h1, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 100));
    await g.moveTo(h1 + const Offset(0, 70));
    await g.moveTo(h1 + const Offset(0, 130));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(log.single, startsWith('reorder 0->'));
    expect(order, isNot([1, 2, 3]));
  });
}
