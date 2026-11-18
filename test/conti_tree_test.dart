import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/conti_tree.dart';
import 'package:worship_slides/src/features/praise/presentation/conti_insert_target.dart';
import 'package:worship_slides/src/features/praise/presentation/conti_tree_widgets.dart';

ContiLayout layout(
  List<int> uids, [
  Map<int, String> groups = const {},
  Set<int> noSpacer = const {},
]) => ContiLayout(uids, Map.of(groups), Set.of(noSpacer));

/// 그룹마다 항목이 목록에서 이어져 있는지(불변식).
bool contiguous(ContiLayout l) {
  final seen = <String>{};
  String? prev;
  for (final u in l.uids) {
    final g = l.groups[u];
    if (g != prev && g != null && !seen.add(g)) return false;
    prev = g;
  }
  return true;
}

void main() {
  group('행 계산', () {
    test('그룹 없음 = 항목 행만', () {
      final rows = contiRows([1, 2, 3], {});
      expect(rows.whereType<ContiHeaderRow>(), isEmpty);
      expect(rows.length, 3);
    });

    test('그룹은 머리 행 + 항목 행, 그룹 밖 항목은 그대로', () {
      final rows = contiRows([1, 2, 3, 4], {2: 'a', 3: 'a'});
      expect(rows.length, 5);
      expect((rows[1] as ContiHeaderRow).name, 'a');
      expect((rows[1] as ContiHeaderRow).count, 2);
      expect((rows[2] as ContiItemRow).group, 'a');
      expect((rows[4] as ContiItemRow).group, isNull);
      expect((rows[4] as ContiItemRow).index, 3);
    });

    test('떨어진 같은 이름은 별개 그룹(키가 다르다)', () {
      final rows = contiRows([1, 2, 3], {1: 'a', 3: 'a'});
      final headers = rows.whereType<ContiHeaderRow>().toList();
      expect(headers.length, 2);
      expect(headers[0].key, isNot(headers[1].key));
    });

    test('접힌 그룹은 항목 행이 빠지고 수는 남는다', () {
      final key = groupKey('a', 1);
      final rows = contiRows([1, 2, 3], {1: 'a', 2: 'a'}, collapsed: {key});
      expect(rows.length, 2);
      expect((rows[0] as ContiHeaderRow).collapsed, isTrue);
      expect((rows[0] as ContiHeaderRow).count, 2);
    });

    test('빈 그룹은 맨 끝에 머리 행만, 항목 0개여도 보인다', () {
      final rows = contiRows([], {}, emptyGroups: ['x']);
      expect(rows.length, 1);
      expect((rows.single as ContiHeaderRow).empty, isTrue);
    });
  });

  group('놓을 자리', () {
    // 0:a(1) 1:a(2) 2:(3)  → 행: H(a) 1 2 3
    final uids = [1, 2, 3];
    final groups = {1: 'a', 2: 'a'};
    final rows = contiRows(uids, groups);

    test('항목 행: 위 절반 = 앞, 아래 절반 = 뒤, 그 항목의 그룹', () {
      expect(resolveDrop(rows, 1, false, 3), (index: 0, group: 'a'));
      expect(resolveDrop(rows, 2, true, 3), (index: 2, group: 'a')); // 그룹 끝
      expect(resolveDrop(rows, 3, false, 3), (index: 2, group: null)); // 그룹 밖
    });

    test('머리 행: 위 절반 = 그룹 밖 앞, 아래 절반 = 그룹 맨 앞', () {
      expect(resolveDrop(rows, 0, false, 3), (index: 0, group: null));
      expect(resolveDrop(rows, 0, true, 3), (index: 0, group: 'a'));
    });

    test('접힌 그룹 머리 아래 절반 = 그룹 맨 끝', () {
      final c = contiRows(uids, groups, collapsed: {groupKey('a', 1)});
      expect(resolveDrop(c, 0, true, 3), (index: 2, group: 'a'));
    });

    test('빈 그룹 머리 아래 절반 = 목록 끝에서 그 그룹 시작', () {
      final e = contiRows(uids, groups, emptyGroups: ['x']);
      expect(resolveDrop(e, 4, true, 3), (index: 3, group: 'x'));
      expect(resolveDrop(e, 4, false, 3), (index: 3, group: null));
    });
  });

  group('항목 옮기기', () {
    test('그룹 밖 항목을 그룹 머리에 끌어 넣으면 그 그룹 맨 앞에 든다', () {
      final l = layout([1, 2, 3], {1: 'a'});
      final rows = contiRows(l.uids, l.groups);
      final spot = resolveDrop(rows, 0, true, 3);
      final r = moveItemTo(l, 3, spot);
      expect(r.uids, [3, 1, 2]);
      expect(r.groups, {3: 'a', 1: 'a'});
      expect(contiguous(r), isTrue);
    });

    test('그룹 마지막 항목 아래 절반 = 그룹 끝에 든다', () {
      final l = layout([1, 2, 3, 4], {1: 'a', 2: 'a'});
      final rows = contiRows(l.uids, l.groups);
      final r = moveItemTo(l, 4, resolveDrop(rows, 2, true, 4));
      expect(r.uids, [1, 2, 4, 3]);
      expect(r.groups[4], 'a');
    });

    test('그룹 밖 행에 놓으면 빠진다, 마지막 항목이 빠지면 그룹이 사라진다', () {
      final l = layout([1, 2], {1: 'a'});
      final rows = contiRows(l.uids, l.groups);
      final r = moveItemTo(l, 1, resolveDrop(rows, 2, true, 2));
      expect(r.uids, [2, 1]);
      expect(r.groups, isEmpty);
      expect(groupRuns(r.uids, r.groups), isEmpty);
    });

    test('그룹 가운데 항목을 머리 위로 빼내면 그룹이 갈라지지 않는다', () {
      final l = layout([1, 2, 3], {1: 'a', 2: 'a', 3: 'a'});
      final rows = contiRows(l.uids, l.groups);
      final r = moveItemTo(l, 2, resolveDrop(rows, 0, false, 3));
      expect(r.uids, [2, 1, 3]);
      expect(r.groups, {1: 'a', 3: 'a'});
      expect(contiguous(r), isTrue);
    });

    test('접힌 그룹에 놓으면 그 그룹 맨 끝에 든다', () {
      final l = layout([1, 2, 3], {1: 'a', 2: 'a'});
      final rows = contiRows(l.uids, l.groups, collapsed: {groupKey('a', 1)});
      final r = moveItemTo(l, 3, resolveDrop(rows, 0, true, 3));
      expect(r.groups[3], 'a');
      expect(r.uids, [1, 2, 3]);
    });

    test('여백 없음 표시: 옮긴 항목 끝 표시는 지우고 놓은 자리 앞 항목과는 여백을 둔다', () {
      // 1~2 는 여백 없이 이어짐(1 표시), 3 도 4 와 이어짐(3 표시)
      final l = layout([1, 2, 3, 4], {}, {1, 3});
      final r = moveItemTo(l, 2, (index: 4, group: null));
      expect(r.uids, [1, 3, 4, 2]);
      // 2 의 앞 항목 1 은 2 와 이어져 있었다 → 2 가 빠졌으니 1 은 3 과 이어지지 않는다(여백)
      expect(r.noSpacer.contains(1), isFalse);
      // 놓은 자리 앞(4)과는 여백
      expect(r.noSpacer.contains(4), isFalse);
      expect(r.noSpacer.contains(3), isTrue);
    });

    test('제자리에 놓으면 순서가 안 바뀐다', () {
      final l = layout([1, 2, 3], {}, {1});
      final r = moveItemTo(l, 2, (index: 1, group: null));
      expect(r.uids, [1, 2, 3]);
      expect(r.noSpacer, {1});
    });
  });

  group('그룹째 옮기기', () {
    test('순서를 유지한 채 항목 앞으로, 다른 그룹 안에는 못 들어간다', () {
      final l = layout([1, 2, 3, 4, 5], {1: 'a', 2: 'a', 4: 'b', 5: 'b'});
      final rows = contiRows(l.uids, l.groups);
      final run = groupRuns(l.uids, l.groups).first;
      // b 그룹의 항목 5 위 절반에 놓아도 b 블록 앞
      final at = resolveGroupDrop(rows, 5, false, run, l.uids, l.groups)!;
      expect(at, 3);
      final r = moveGroupTo(l, run, at);
      expect(r.uids, [3, 1, 2, 4, 5]);
      expect(r.groups, l.groups);
      expect(contiguous(r), isTrue);
    });

    test('자기 블록 위에 놓으면 제자리(null)', () {
      final l = layout([1, 2, 3], {1: 'a', 2: 'a'});
      final rows = contiRows(l.uids, l.groups);
      final run = groupRuns(l.uids, l.groups).first;
      expect(resolveGroupDrop(rows, 1, true, run, l.uids, l.groups), isNull);
    });

    test('위·아래 한 칸: 이웃 그룹 블록 또는 항목 하나를 건너뛴다', () {
      final l = layout([1, 2, 3, 4], {2: 'a', 3: 'a'});
      final run = groupRuns(l.uids, l.groups).single;
      expect(groupStepIndex(l, run, -1), 0);
      expect(groupStepIndex(l, run, 1), 4);
      expect(moveGroupTo(l, run, 4).uids, [1, 4, 2, 3]);
      final top = layout([1, 2], {1: 'a'});
      expect(
        groupStepIndex(top, groupRuns(top.uids, top.groups).single, -1),
        isNull,
      );
    });
  });

  group('만들기·풀기·이름', () {
    test('고른 항목이 있으면 그 자리에서 그룹이 된다', () {
      final r = createGroupWith(layout([1, 2, 3]), 2, 'x');
      expect(r.uids, [1, 2, 3]);
      expect(r.groups, {2: 'x'});
    });

    test('이미 다른 그룹 안의 항목은 그 그룹 끝 뒤로 나와 새 그룹이 된다(중첩 없음)', () {
      final l = layout([1, 2, 3], {1: 'a', 2: 'a', 3: 'a'});
      final r = createGroupWith(l, 1, 'x');
      expect(r.uids, [2, 3, 1]);
      expect(r.groups, {2: 'a', 3: 'a', 1: 'x'});
      expect(contiguous(r), isTrue);
    });

    test('풀기는 항목을 남기고, 이름 바꾸기는 그 구간만', () {
      final l = layout([1, 2, 3, 4], {1: 'a', 2: 'a', 4: 'a'});
      final runs = groupRuns(l.uids, l.groups);
      expect(runs.length, 2); // 떨어진 같은 이름
      final r = renameGroup(l, runs.last, 'b');
      expect(r.groups, {1: 'a', 2: 'a', 4: 'b'});
      final u = ungroup(l, runs.first);
      expect(u.uids, l.uids);
      expect(u.groups, {4: 'a'});
    });

    test('uniqueGroupName 은 12자 안에서 (2) 를 단다', () {
      expect(uniqueGroupName('a', {'b'}), 'a');
      expect(uniqueGroupName('a', {'a'}), 'a (2)');
      expect(uniqueGroupName('a', {'a', 'a (2)'}), 'a (3)');
      final long = uniqueGroupName('가나다라마바사아자차카타', {'가나다라마바사아자차카타'});
      expect(long.length, lessThanOrEqualTo(12));
      expect(long.endsWith(' (2)'), isTrue);
    });

    test('validGroupAt: 놓을 자리가 그 그룹에 안 닿으면 그룹 밖', () {
      final groups = {1: 'a', 2: 'a'};
      expect(validGroupAt([1, 2, 3], groups, 1, 'a', []), 'a');
      expect(validGroupAt([1, 2, 3], groups, 2, 'a', []), 'a'); // 그룹 끝 뒤
      expect(validGroupAt([1, 2, 3], groups, 3, 'a', []), isNull);
      expect(validGroupAt([3, 4], {}, 1, 'a', []), isNull);
      expect(validGroupAt([3], {}, 1, 'x', ['x']), 'x'); // 빈 그룹 시작
    });
  });

  test('아무렇게나 끌어 놓아도 그룹 항목은 늘 이어진다(불변식)', () {
    final rnd = Random(7);
    var l = layout(List.generate(10, (i) => i + 1), {
      2: 'a',
      3: 'a',
      4: 'a',
      7: 'b',
      8: 'b',
    });
    final collapsed = <String>{};
    for (var n = 0; n < 400; n++) {
      if (rnd.nextInt(5) == 0) {
        final runs = groupRuns(l.uids, l.groups);
        if (runs.isNotEmpty) {
          final k = groupKey(
            runs[rnd.nextInt(runs.length)].name,
            runs.first.startUid,
          );
          if (!collapsed.remove(k)) collapsed.add(k);
        }
      }
      final rows = contiRows(l.uids, l.groups, collapsed: collapsed);
      final i = rnd.nextInt(rows.length);
      final after = rnd.nextBool();
      if (rnd.nextInt(4) == 0) {
        final runs = groupRuns(l.uids, l.groups);
        if (runs.isEmpty) continue;
        final run = runs[rnd.nextInt(runs.length)];
        final at = resolveGroupDrop(rows, i, after, run, l.uids, l.groups);
        if (at != null) l = moveGroupTo(l, run, at);
      } else {
        final uid = l.uids[rnd.nextInt(l.uids.length)];
        l = moveItemTo(l, uid, resolveDrop(rows, i, after, l.uids.length));
      }
      expect(contiguous(l), isTrue, reason: 'step $n');
      expect(l.uids.toSet().length, 10);
    }
  });

  // 실제 목록 위젯(ContiTreeList·ContiGroupHeader·ContiDragHandle·ContiInsertTarget)에
  // 순수 함수를 물려 끌어 놓기를 끝까지 해 본다.
  group('목록 위젯', () {
    late ContiLayout state;
    final collapsed = <String>{};
    final log = <String>[];

    Widget app() => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          height: 600,
          child: StatefulBuilder(
            builder: (context, set) {
              final rows = contiRows(
                state.uids,
                state.groups,
                collapsed: collapsed,
              );
              void drop(Object data, int rowIndex, bool after) {
                if (data is! ContiRowDrag) return;
                if (data.isGroup) {
                  final run = groupRuns(
                    state.uids,
                    state.groups,
                  ).firstWhere((r) => r.startUid == data.uid);
                  final at = resolveGroupDrop(
                    rows,
                    rowIndex,
                    after,
                    run,
                    state.uids,
                    state.groups,
                  );
                  if (at != null) {
                    set(() => state = moveGroupTo(state, run, at));
                  }
                } else {
                  final spot = resolveDrop(
                    rows,
                    rowIndex,
                    after,
                    state.uids.length,
                  );
                  set(() => state = moveItemTo(state, data.uid, spot));
                }
              }

              return ContiTreeList(
                itemCount: rows.length,
                onEndDrop: (data) {
                  log.add('end');
                  if (data is ContiRowDrag && !data.isGroup) {
                    set(
                      () => state = moveItemTo(state, data.uid, (
                        index: state.uids.length,
                        group: null,
                      )),
                    );
                  }
                },
                itemBuilder: (context, i, dragging) {
                  final row = rows[i];
                  if (row is ContiHeaderRow) {
                    return ContiGroupHeader(
                      key: ValueKey('g${row.name}'),
                      header: row,
                      holdsSelected: false,
                      canMoveUp: true,
                      canMoveDown: true,
                      dragging: dragging,
                      onDrop: (d, a) => drop(d, i, a),
                      onToggle: () => set(() {
                        if (!collapsed.remove(row.key)) collapsed.add(row.key);
                      }),
                      onRename: () {},
                      onMove: (_) {},
                      onUngroup: () {},
                      onDelete: () {},
                    );
                  }
                  final item = row as ContiItemRow;
                  return ContiInsertTarget(
                    key: ValueKey(item.uid),
                    onDrop: (d, a) => drop(d, i, a),
                    child: Container(
                      height: 48,
                      margin: EdgeInsets.only(
                        left: item.group == null ? 0 : 20,
                      ),
                      child: Row(
                        children: [
                          Expanded(child: Text('항목 ${item.uid}')),
                          ContiDragHandle(
                            key: Key('h${item.uid}'),
                            data: ContiRowDrag(item.uid),
                            title: '항목 ${item.uid}',
                            dragging: dragging,
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
    );

    Future<void> drag(WidgetTester tester, Finder from, Offset to) async {
      final g = await tester.startGesture(
        tester.getCenter(from),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(tester.getCenter(from) + const Offset(0, 6));
      await g.moveTo(to);
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
    }

    Offset lower(WidgetTester tester, Finder f) {
      final r = tester.getRect(f);
      return Offset(r.center.dx, r.bottom - 4);
    }

    Offset upper(WidgetTester tester, Finder f) {
      final r = tester.getRect(f);
      return Offset(r.center.dx, r.top + 4);
    }

    setUp(() {
      state = layout([1, 2, 3], {1: 'a'});
      collapsed.clear();
      log.clear();
    });

    testWidgets('항목을 그룹 머리에 끌어 넣고, 그룹 밖 행으로 끌어 뺀다', (tester) async {
      await tester.pumpWidget(app());
      final header = find.byKey(const ValueKey('ga'));
      await drag(tester, find.byKey(const Key('h3')), lower(tester, header));
      expect(state.groups, {1: 'a', 3: 'a'});
      expect(state.uids, [3, 1, 2]);

      // 항목 2 는 그룹 밖. 그룹 안 항목 3 을 그룹 밖 항목 2 의 아래 절반으로 → 빠진다
      final row2 = find.byKey(const ValueKey(2));
      await drag(tester, find.byKey(const Key('h3')), lower(tester, row2));
      expect(state.groups, {1: 'a'});
      expect(state.uids, [1, 2, 3]);
    });

    testWidgets('머리줄을 끌면 그룹째 옮겨진다', (tester) async {
      state = layout([1, 2, 3, 4], {1: 'a', 2: 'a'});
      await tester.pumpWidget(app());
      final header = find.byKey(const ValueKey('ga'));
      // 머리줄 이름 글자를 잡아 항목 4 아래 절반으로
      await drag(
        tester,
        find.descendant(of: header, matching: find.text('a')),
        lower(tester, find.byKey(const ValueKey(4))),
      );
      expect(state.uids, [3, 4, 1, 2]);
      expect(state.groups, {1: 'a', 2: 'a'});
    });

    testWidgets('머리줄을 누르면 접히고 항목 행이 사라진다, 접힌 그룹에 놓으면 맨 끝', (tester) async {
      state = layout([1, 2, 3], {1: 'a', 2: 'a'});
      await tester.pumpWidget(app());
      expect(find.text('항목 1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ga')));
      await tester.pumpAndSettle();
      expect(find.text('항목 1'), findsNothing);
      expect(find.text('항목 2'), findsNothing);

      final header = find.byKey(const ValueKey('ga'));
      await drag(tester, find.byKey(const Key('h3')), lower(tester, header));
      expect(state.uids, [1, 2, 3]);
      expect(state.groups, {1: 'a', 2: 'a', 3: 'a'});
    });

    testWidgets('목록 아래 빈 곳에 놓으면 맨 끝·그룹 밖', (tester) async {
      state = layout([1, 2, 3], {1: 'a', 2: 'a'});
      await tester.pumpWidget(app());
      await drag(tester, find.byKey(const Key('h1')), const Offset(150, 560));
      expect(log, ['end']);
      expect(state.uids.last, 1);
      expect(state.groups, {2: 'a'});
    });

    testWidgets('머리줄 위쪽 절반에 놓으면 그룹 밖 앞에 놓인다', (tester) async {
      state = layout([1, 2, 3], {2: 'a'});
      await tester.pumpWidget(app());
      final header = find.byKey(const ValueKey('ga'));
      await drag(tester, find.byKey(const Key('h3')), upper(tester, header));
      expect(state.uids, [1, 3, 2]);
      expect(state.groups, {2: 'a'});
    });
  });

  group('다중 선택', () {
    final vis = [1, 2, 3, 4, 5];
    ({Set<int> selected, int? anchor}) sel(
      Set<int> selected,
      int? anchor,
      int uid, {
      bool shift = false,
      bool toggle = false,
      List<int>? visible,
    }) => applyContiSelect(
      visible: visible ?? vis,
      selected: selected,
      anchor: anchor,
      uid: uid,
      shift: shift,
      toggle: toggle,
    );

    test('클릭 = 하나만, 앵커 = 그 항목', () {
      final r = sel({1, 2}, 1, 4);
      expect(r.selected, {4});
      expect(r.anchor, 4);
    });

    test('Shift = 앵커~클릭 범위(위로도), 앵커 유지', () {
      var r = sel({2}, 2, 4, shift: true);
      expect(r.selected, {2, 3, 4});
      expect(r.anchor, 2);
      r = sel({4}, 4, 2, shift: true);
      expect(r.selected, {2, 3, 4});
    });

    test('Shift 범위는 보이는 항목만(접힌 그룹 안 3 은 빠진다)', () {
      final r = sel({2}, 2, 4, shift: true, visible: [1, 2, 4, 5]);
      expect(r.selected, {2, 4});
    });

    test('앵커가 안 보이면 Shift 도 그 항목 하나', () {
      final r = sel({3}, 3, 5, shift: true, visible: [1, 2, 4, 5]);
      expect(r.selected, {5});
      expect(r.anchor, 5);
      expect(sel({}, null, 2, shift: true).selected, {2});
    });

    test('Shift+toggle = 기존 선택에 범위 더하기', () {
      final r = sel({1, 2}, 2, 5, shift: true, toggle: true);
      expect(r.selected, {1, 2, 3, 4, 5});
    });

    test('toggle = 하나씩 더하기·빼기', () {
      var r = sel({1}, 1, 3, toggle: true);
      expect(r.selected, {1, 3});
      expect(r.anchor, 3);
      r = sel(r.selected, r.anchor, 1, toggle: true);
      expect(r.selected, {3});
    });
  });

  group('여러 항목 옮기기', () {
    test('떨어진 항목들이 순서를 지키며 한 덩어리로 모인다', () {
      final l = moveItemsTo(
        layout([1, 2, 3, 4, 5]),
        [4, 1],
        (index: 3, group: null),
      );
      expect(l.uids, [2, 3, 1, 4, 5]); // 목록 순서(1, 4)대로
    });

    test('끝으로, 앞으로', () {
      expect(
        moveItemsTo(layout([1, 2, 3, 4]), [1, 3], (index: 4, group: null)).uids,
        [2, 4, 1, 3],
      );
      expect(
        moveItemsTo(layout([1, 2, 3, 4]), [2, 4], (index: 0, group: null)).uids,
        [2, 4, 1, 3],
      );
    });

    test('그룹에 넣고 빼고, 그룹 항목은 이어진다', () {
      var l = moveItemsTo(
        layout([1, 2, 3, 4], {3: 'a', 4: 'a'}),
        [1, 2],
        (index: 3, group: 'a'),
      );
      expect(l.uids, [3, 1, 2, 4]);
      expect(l.groups, {1: 'a', 2: 'a', 3: 'a', 4: 'a'});
      expect(contiguous(l), isTrue);
      l = moveItemsTo(l, [1, 4], (index: 4, group: null));
      expect(l.uids, [3, 2, 1, 4]);
      expect(l.groups, {2: 'a', 3: 'a'});
    });

    test('이어진 항목은 여백 없음 표시를 그대로 갖고 간다', () {
      final l = moveItemsTo(
        layout([1, 2, 3, 4], {}, {1}),
        [1, 2],
        (index: 4, group: null),
      );
      expect(l.uids, [3, 4, 1, 2]);
      expect(l.noSpacer, contains(1));
    });

    test('제자리에 놓아도 안 깨진다', () {
      final l = moveItemsTo(layout([1, 2, 3]), [1, 2], (index: 1, group: null));
      expect(l.uids, [1, 2, 3]);
    });

    test('그룹 만들기에 여러 항목 넣기: 가장 앞 항목 자리에 모인다', () {
      final l = createGroupWithItems(layout([1, 2, 3, 4]), [4, 2], 'x');
      expect(l.uids, [1, 2, 4, 3]);
      expect(l.groups, {2: 'x', 4: 'x'});
      expect(contiguous(l), isTrue);
    });

    test('다른 그룹 안 항목이 앞이면 그 그룹 뒤에서 만든다', () {
      final l = createGroupWithItems(
        layout([1, 2, 3, 4], {1: 'a', 2: 'a'}),
        [1, 4],
        'x',
      );
      expect(l.uids, [2, 1, 4, 3]);
      expect(contiguous(l), isTrue);
      expect(l.groups[1], 'x');
      expect(l.groups[4], 'x');
      expect(l.groups[2], 'a');
    });
  });
}
