import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
ContiDropZone zoneOf(bool after) =>
    after ? ContiDropZone.after : ContiDropZone.before;

/// resolveGroupDrop 가 받아들인 자리(거절이면 null).
ContiSpot? okSpot(ContiGroupDrop d) => d.spot;

bool contiguous(ContiLayout l) {
  // 모든 앞부분 경로(상위·하위)가 이어져 있어야 한다.
  final seen = <String>{};
  Set<String> prev = {};
  for (final u in l.uids) {
    final g = l.groups[u];
    final now = {
      if (g != null)
        for (var n = 1; n <= groupDepth(g); n++) pathPrefix(g, n)!,
    };
    for (final p in now) {
      if (!prev.contains(p) && !seen.add(p)) return false;
    }
    prev = now;
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

    test('빈 그룹 머리: 위/아래 구분 없이 안으로(자리 = anchorIndex)', () {
      final e = contiRows(uids, groups, emptyGroups: ['x']);
      expect(resolveDrop(e, 4, true, 3), (index: 3, group: 'x'));
      expect(resolveDrop(e, 4, false, 3), (index: 3, group: 'x'));
      // 빈 하위: 부모 구간 끝, 부모는 쪼개지지 않는다
      final h = contiRows(uids, groups, emptyGroups: ['a/c']);
      final hi = h.indexWhere((r) => r is ContiHeaderRow && r.name == 'a/c');
      expect(resolveDrop(h, hi, false, 3), (index: 2, group: 'a/c'));
      expect(resolveDrop(h, hi, true, 3), (index: 2, group: 'a/c'));
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
    test('그룹 밖 항목 행 아래에 놓으면 순서를 유지한 채 그 뒤로', () {
      final l = layout([1, 2, 3, 4, 5], {1: 'a', 2: 'a', 4: 'b', 5: 'b'});
      final rows = contiRows(l.uids, l.groups);
      final run = groupRuns(l.uids, l.groups).first;
      final at = okSpot(
        resolveGroupDrop(rows, 3, ContiDropZone.after, run, l.uids, l.groups),
      )!;
      expect((at.index, at.group), (3, null));
      final r = moveGroupTo(l, run, at.index);
      expect(r.uids, [3, 1, 2, 4, 5]);
      expect(r.groups, l.groups);
      expect(contiguous(r), isTrue);
    });

    test('다른 그룹 안 항목 행에 놓으면 그 그룹 안으로 들어간다(원래 단계 유지 규칙 폐지)', () {
      final l = layout([1, 2, 3, 4, 5], {1: 'a', 2: 'a', 4: 'b', 5: 'b'});
      final rows = contiRows(l.uids, l.groups);
      final run = groupRuns(l.uids, l.groups).first;
      final at = okSpot(
        resolveGroupDrop(rows, 5, ContiDropZone.before, run, l.uids, l.groups),
      )!;
      expect((at.index, at.group), (3, 'b'));
      final r = moveGroupTo(
        l,
        run,
        at.index,
        setParent: true,
        parent: at.group,
      );
      expect(r.uids, [3, 1, 2, 4, 5]);
      expect(r.groups, {1: 'b/a', 2: 'b/a', 4: 'b', 5: 'b'});
      expect(contiguous(r), isTrue);
    });

    test('자기 블록 위에 놓으면 거절(자기 안), 제자리면 noChange', () {
      final l = layout([1, 2, 3], {1: 'a', 2: 'a'});
      final rows = contiRows(l.uids, l.groups);
      final run = groupRuns(l.uids, l.groups).first;
      expect(
        resolveGroupDrop(
          rows,
          1,
          ContiDropZone.after,
          run,
          l.uids,
          l.groups,
        ).reject,
        ContiDropReject.self,
      );
      expect(
        resolveGroupDrop(
          rows,
          0,
          ContiDropZone.into,
          run,
          l.uids,
          l.groups,
        ).reject,
        ContiDropReject.self,
      );
      // 그룹 밖 앞 경계 = 제자리
      expect(
        resolveGroupDrop(
          rows,
          3,
          ContiDropZone.before,
          run,
          l.uids,
          l.groups,
        ).reject,
        ContiDropReject.noChange,
      );
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
        final at = resolveGroupDrop(
          rows,
          i,
          zoneOf(after),
          run,
          l.uids,
          l.groups,
        ).spot;
        if (at != null) {
          l = moveGroupTo(l, run, at.index, setParent: true, parent: at.group);
        }
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
              void drop(Object data, int rowIndex, ContiDropZone zone) {
                if (data is! ContiRowDrag) return;
                if (data.isGroup) {
                  final run = allGroupRuns(state.uids, state.groups).firstWhere(
                    (r) =>
                        r.startUid == data.uid &&
                        r.name == (data as ContiGroupDrag).path,
                  );
                  final at = resolveGroupDrop(
                    rows,
                    rowIndex,
                    zone,
                    run,
                    state.uids,
                    state.groups,
                  ).spot;
                  if (at != null) {
                    set(
                      () => state = moveGroupTo(
                        state,
                        run,
                        at.index,
                        setParent: true,
                        parent: at.group,
                      ),
                    );
                  }
                } else {
                  final spot = resolveDrop(
                    rows,
                    rowIndex,
                    zone != ContiDropZone.before,
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
                      onDrop: (d, z) => drop(d, i, z),
                      rejectOf: (d, z) {
                        if (d is! ContiGroupDrag) return null;
                        final run = allGroupRuns(state.uids, state.groups)
                            .firstWhere(
                              (r) => r.startUid == d.uid && r.name == d.path,
                            );
                        return resolveGroupDrop(
                          rows,
                          i,
                          z,
                          run,
                          state.uids,
                          state.groups,
                        ).reject;
                      },
                      onToggle: () => set(() {
                        if (!collapsed.remove(row.key)) collapsed.add(row.key);
                      }),
                      onRename: () {},
                      onCreateSub: () {},
                      onMove: (_) {},
                      onUngroup: () {},
                      onDelete: () {},
                    );
                  }
                  final item = row as ContiItemRow;
                  return ContiInsertTarget(
                    key: ValueKey(item.uid),
                    onDrop: (d, z) => drop(d, i, z),
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

    testWidgets('그룹을 머리줄 가운데에 놓으면 그 하위로, 위 1/3 이면 앞 형제로', (tester) async {
      state = layout([1, 2, 3, 4], {1: 'a', 2: 'a', 3: 'b', 4: 'b'});
      await tester.pumpWidget(app());
      final a = find.byKey(const ValueKey('ga'));
      final b = find.byKey(const ValueKey('gb'));
      await drag(
        tester,
        find.descendant(of: a, matching: find.text('a')),
        tester.getCenter(b),
      );
      expect(state.groups, {1: 'b/a', 2: 'b/a', 3: 'b', 4: 'b'});
      expect(state.uids, [1, 2, 3, 4]);

      // 하위 b/a 를 b 머리줄 위 1/3 에 놓으면 b 앞 형제(맨 위 단계)로 나온다.
      state = layout([1, 2, 3], {1: 'b/a', 2: 'b', 3: 'b'});
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await drag(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('gb/a')),
          matching: find.text('a'),
        ),
        upper(tester, find.byKey(const ValueKey('gb'))),
      );
      expect(state.groups, {1: 'a', 2: 'b', 3: 'b'});
    });

    testWidgets('접힌 그룹은 3구역: 가운데 = 안으로(맨 끝)', (tester) async {
      state = layout([1, 2, 3], {1: 'a', 2: 'b', 3: 'b'});
      collapsed.add(groupKey('b', 2));
      await tester.pumpWidget(app());
      final b = find.byKey(const ValueKey('gb'));
      await drag(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('ga')),
          matching: find.text('a'),
        ),
        tester.getCenter(b),
      );
      expect(state.groups, {1: 'b/a', 2: 'b', 3: 'b'});
      expect(state.uids, [2, 3, 1]);
    });

    testWidgets('자기 하위 위에 놓으면 빨간 거부 칩이 뜨고 데이터는 그대로', (tester) async {
      state = layout([1, 2], {1: 'a', 2: 'a/c'});
      await tester.pumpWidget(app());
      final before = Map.of(state.groups);
      final from = find.descendant(
        of: find.byKey(const ValueKey('ga')),
        matching: find.text('a'),
      );
      final g = await tester.startGesture(
        tester.getCenter(from),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(tester.getCenter(from) + const Offset(0, 6));
      await g.moveTo(tester.getCenter(find.byKey(const ValueKey('ga/c'))));
      await tester.pump();
      expect(find.text('자기 안에는 못 넣어요'), findsWidgets);
      await g.up();
      await tester.pumpAndSettle();
      expect(state.groups, before);
    });
  });

  group('머리줄 + · 이름 입력칸', () {
    ContiHeaderRow header(String name, {int count = 1, int startUid = 1}) =>
        ContiHeaderRow(
          name: name,
          startUid: count == 0 ? -1 : startUid,
          start: 0,
          count: count,
          collapsed: false,
        );

    Widget host(
      ContiHeaderRow h, {
      VoidCallback? onAddSub,
      bool editing = false,
      bool editIsNew = false,
      ValueChanged<String>? onSubmit,
      VoidCallback? onCancel,
      void Function(Object, ContiDropZone)? onDrop,
    }) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: ContiGroupHeader(
            header: h,
            holdsSelected: false,
            canMoveUp: false,
            canMoveDown: false,
            dragging: ValueNotifier(false),
            onDrop: onDrop ?? (_, _) {},
            onToggle: () {},
            onRename: () {},
            onCreateSub: () {},
            onAddSub: onAddSub,
            editing: editing,
            editIsNew: editIsNew,
            onSubmitName: onSubmit,
            onCancelEdit: onCancel,
            onMove: (_) {},
            onUngroup: () {},
            onDelete: () {},
          ),
        ),
      ),
    );

    testWidgets('+ 누르면 onAddSub, 깊이 3 그룹은 + 가 없다', (tester) async {
      var n = 0;
      await tester.pumpWidget(host(header('a'), onAddSub: () => n++));
      await tester.tap(find.byIcon(Icons.add_rounded));
      expect(n, 1);
      await tester.pumpWidget(host(header('a/b/c'), onAddSub: () => n++));
      expect(find.byIcon(Icons.add_rounded), findsNothing);
    });

    testWidgets('빈 그룹: 힌트·아웃라인 폴더, 무엇을 놓아도 안으로', (tester) async {
      final zones = <ContiDropZone>[];
      final item = Draggable<ContiRowDrag>(
        data: const ContiRowDrag(9),
        feedback: const SizedBox(width: 10, height: 10),
        child: const SizedBox(width: 40, height: 40, child: Text('x')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                item,
                SizedBox(
                  width: 400,
                  child: ContiGroupHeader(
                    header: header('a', count: 0),
                    holdsSelected: false,
                    canMoveUp: false,
                    canMoveDown: false,
                    dragging: ValueNotifier(false),
                    onDrop: (_, z) => zones.add(z),
                    onToggle: () {},
                    onRename: () {},
                    onCreateSub: () {},
                    onMove: (_) {},
                    onUngroup: () {},
                    onDelete: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('여기에 끌어 놓기'), findsOneWidget);
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
      final h = tester.getRect(find.byType(ContiGroupHeader));
      final g = await tester.startGesture(
        tester.getCenter(find.text('x')),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(0, 6));
      await g.moveTo(Offset(h.center.dx, h.top + 3)); // 위쪽이어도
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(zones, [ContiDropZone.into]);
    });

    testWidgets('이름 편집: 전체 선택·Enter 확정·/ 막기', (tester) async {
      String? got;
      await tester.pumpWidget(
        host(header('새 그룹'), editing: true, onSubmit: (t) => got = t),
      );
      await tester.pump();
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.selection.extentOffset, 4);
      await tester.enterText(find.byType(TextField), '특/송');
      await tester.pump();
      expect(find.text('이름에 / 는 쓸 수 없어요'), findsOneWidget);
      expect(field.controller!.text, '특송');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(got, '특송');
    });

    testWidgets('방금 만든 그룹은 Esc 로 기본 이름 유지(취소 콜백)', (tester) async {
      var cancelled = 0;
      String? got;
      await tester.pumpWidget(
        host(
          header('새 그룹'),
          editing: true,
          editIsNew: true,
          onSubmit: (t) => got = t,
          onCancel: () => cancelled++,
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(cancelled, 1);
      expect(got, isNull);
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
      final l = createGroupWithItems(layout([1, 2, 3, 4], {1: 'a', 2: 'a'}), [
        1,
        4,
      ], 'x');
      expect(l.uids, [2, 1, 4, 3]);
      expect(contiguous(l), isTrue);
      expect(l.groups[1], 'x');
      expect(l.groups[4], 'x');
      expect(l.groups[2], 'a');
    });
  });

  group('하위 그룹', () {
    ContiLayout base() => layout(
      [1, 2, 3, 4, 5, 6],
      {2: 'a', 3: 'a/x', 4: 'a/x', 5: 'a/y', 6: 'b'},
    );

    test('행: 상위 머리 → 직속 항목·하위 머리 → 하위 항목, 접으면 하위도 가려진다', () {
      final rows = contiRows(base().uids, base().groups);
      expect(
        [
          for (final r in rows)
            r is ContiHeaderRow ? 'H${r.name}' : 'I${(r as ContiItemRow).uid}',
        ],
        ['I1', 'Ha', 'I2', 'Ha/x', 'I3', 'I4', 'Ha/y', 'I5', 'Hb', 'I6'],
      );
      expect((rows[3] as ContiHeaderRow).depth, 2);
      expect((rows[3] as ContiHeaderRow).label, 'x');
      expect((rows[4] as ContiItemRow).depth, 2);
      final folded = contiRows(
        base().uids,
        base().groups,
        collapsed: {groupKey('a', 2)},
      );
      expect(folded.whereType<ContiItemRow>().map((r) => r.uid), [1, 6]);
      expect(folded.whereType<ContiHeaderRow>().map((r) => r.name), ['a', 'b']);
    });

    test('하위 그룹 만들기: 고른 항목이 그 상위 아래 하위 그룹이 된다', () {
      final l = layout([1, 2, 3, 4], {2: 'a', 3: 'a', 4: 'a'});
      final a = groupRuns(l.uids, l.groups).single;
      final r = createSubGroupWithItems(l, a, [3, 4], 'x');
      expect(r.groups, {2: 'a', 3: 'a/x', 4: 'a/x'});
      expect(contiguous(r), isTrue);
      // 상위 밖 항목을 골라도 상위 끝에 들어온다
      final out = createSubGroupWithItems(l, a, [1], 'y');
      expect(out.uids, [2, 3, 4, 1]);
      expect(out.groups[1], 'a/y');
      expect(contiguous(out), isTrue);
    });

    test('같은 상위 아래 이름 목록', () {
      final b = base();
      expect(siblingGroupNames(b.groups, [], null), {'a', 'b'});
      expect(siblingGroupNames(b.groups, [], 'a'), {'x', 'y'});
      expect(siblingGroupNames(b.groups, [], 'a/x'), isEmpty);
    });

    test('상위째 이동하면 하위 구조가 그대로 따라간다', () {
      final b = base();
      final a = groupRuns(b.uids, b.groups).first;
      final r = moveGroupTo(b, a, b.uids.length);
      expect(r.uids, [1, 6, 2, 3, 4, 5]);
      expect(r.groups, b.groups);
      expect(contiguous(r), isTrue);
    });

    test('하위 그룹은 상위 안에서만 한 칸씩, 상위 밖으로는 끌어서 옮기며 상위가 바뀐다', () {
      final b = base();
      final x = groupRuns(b.uids, b.groups, depth: 2).first; // a/x
      expect(groupStepIndex(b, x, -1), 1); // 상위 직속 항목 2 를 건너뛴다
      final y = groupRuns(b.uids, b.groups, depth: 2).last; // a/y
      expect(groupStepIndex(b, y, 1), isNull); // 뒤는 상위 밖(b)
      expect(groupStepIndex(b, x, 1), 5); // a/y 블록 뒤
      expect(moveGroupTo(b, x, 5).uids, [1, 2, 5, 3, 4, 6]);
      // b 머리 위 절반 = b 앞, 맨 위로 빠져나온다
      final rows = contiRows(b.uids, b.groups);
      final hb = rows.indexWhere((r) => r is ContiHeaderRow && r.name == 'b');
      final spot = okSpot(
        resolveGroupDrop(rows, hb, ContiDropZone.before, x, b.uids, b.groups),
      )!;
      expect(spot.group, isNull);
      final r = moveGroupTo(
        b,
        x,
        spot.index,
        setParent: true,
        parent: spot.group,
      );
      expect(r.groups[3], 'x');
      expect(r.groups[4], 'x');
      expect(r.groups[5], 'a/y');
      expect(contiguous(r), isTrue);
    });

    test('이름 바꾸기·풀기: 하위는 따라오거나 한 단계 올라온다', () {
      final b = base();
      final a = groupRuns(b.uids, b.groups).first;
      final renamed = renameGroup(b, a, 'z');
      expect(renamed.groups, {2: 'z', 3: 'z/x', 4: 'z/x', 5: 'z/y', 6: 'b'});
      final x = groupRuns(b.uids, b.groups, depth: 2).first;
      expect(renameGroup(b, x, 'q').groups[3], 'a/q');
      // 하위 풀기: 항목은 상위에 남는다
      expect(ungroup(b, x).groups, {2: 'a', 3: 'a', 4: 'a', 5: 'a/y', 6: 'b'});
      // 상위 풀기: 직속 항목은 그룹 밖, 하위는 맨 위로
      expect(ungroup(b, a).groups, {3: 'x', 4: 'x', 5: 'y', 6: 'b'});
    });

    test('validGroupAt: 닿는 데까지의 경로만', () {
      final groups = {1: 'a', 2: 'a/x'};
      expect(validGroupAt([1, 2, 3], groups, 2, 'a/x', []), 'a/x');
      expect(validGroupAt([1, 2, 3], groups, 1, 'a/x', []), 'a/x'); // 다음이 a/x
      expect(validGroupAt([1, 2, 3], groups, 3, 'a/x', []), isNull); // 3 은 그룹 밖
      expect(validGroupAt([1, 3, 2], {1: 'a'}, 1, 'a/x', []), 'a'); // 하위는 안 닿는다
      expect(validGroupAt([3, 4], {}, 1, 'a/x', []), isNull);
      expect(commonGroupPath('a/x', 'a/y'), 'a');
      expect(commonGroupPath('a/x', 'a/x'), 'a/x');
      expect(commonGroupPath('a', 'b'), isNull);
    });

    test('아무렇게나 끌어 놓아도 모든 앞부분 경로가 이어진다(불변식)', () {
      final rnd = Random(11);
      var l = layout(List.generate(12, (i) => i + 1), {
        2: 'a',
        3: 'a/x',
        4: 'a/x',
        5: 'a/x/p',
        6: 'a/y',
        8: 'b',
        9: 'b/z',
        10: 'b/z',
      });
      for (var n = 0; n < 600; n++) {
        final rows = contiRows(l.uids, l.groups);
        final i = rnd.nextInt(rows.length);
        final after = rnd.nextBool();
        final mode = rnd.nextInt(4);
        if (mode == 0) {
          final runs = allGroupRuns(l.uids, l.groups);
          if (runs.isEmpty) continue;
          final run = runs[rnd.nextInt(runs.length)];
          final spot = resolveGroupDrop(
            rows,
            i,
            ContiDropZone.values[rnd.nextInt(3)],
            run,
            l.uids,
            l.groups,
          ).spot;
          if (spot != null) {
            l = moveGroupTo(
              l,
              run,
              spot.index,
              setParent: true,
              parent: spot.group,
            );
          }
        } else if (mode == 1) {
          final runs = allGroupRuns(l.uids, l.groups);
          if (runs.isEmpty) continue;
          final run = runs[rnd.nextInt(runs.length)];
          final at = groupStepIndex(l, run, rnd.nextBool() ? -1 : 1);
          if (at != null) l = moveGroupTo(l, run, at);
        } else if (mode == 2) {
          final uid = l.uids[rnd.nextInt(l.uids.length)];
          l = moveItemTo(l, uid, resolveDrop(rows, i, after, l.uids.length));
        } else {
          final runs = groupRuns(l.uids, l.groups);
          if (runs.isEmpty) continue;
          final run = runs[rnd.nextInt(runs.length)];
          if (run.depth < maxGroupDepth) {
            final pick = [
              for (var k = 0; k < 2; k++) l.uids[rnd.nextInt(l.uids.length)],
            ];
            l = createSubGroupWithItems(l, run, pick, 'n$n');
          }
        }
        expect(contiguous(l), isTrue, reason: 'step $n ${l.uids} ${l.groups}');
        expect(l.uids.toSet().length, 12);
        expect(
          l.groups.values.every((g) => groupDepth(g) <= maxGroupDepth),
          isTrue,
          reason: 'step $n ${l.groups}',
        );
      }
    });
  });

  group('그룹 끌어 놓기: 구역·거절·빈 그룹', () {
    ContiGroupRun runOf(ContiLayout l, String path) =>
        allGroupRuns(l.uids, l.groups).firstWhere((r) => r.name == path);

    int headerRow(List<ContiRow> rows, String name) =>
        rows.indexWhere((r) => r is ContiHeaderRow && r.name == name);

    /// 페이지가 하는 일을 순수 함수로: 그룹 [path] 를 [row] 행 [zone] 에 놓는다. 거절이면 null.
    ({ContiLayout l, List<String> empties, String path, bool renamed})? apply(
      ContiLayout l,
      List<String> empties,
      String path,
      String targetName,
      ContiDropZone zone, {
      Set<String> collapsed = const {},
    }) {
      final rows = contiRows(
        l.uids,
        l.groups,
        collapsed: collapsed,
        emptyGroups: empties,
      );
      final isEmpty = empties.contains(path);
      final run = isEmpty ? null : runOf(l, path);
      final d = resolveGroupDrop(
        rows,
        headerRow(rows, targetName),
        zone,
        run,
        l.uids,
        l.groups,
        emptyPath: isEmpty ? path : null,
        emptyGroups: empties,
      );
      final spot = d.spot;
      if (spot == null) return null;
      if (isEmpty) {
        final m = moveEmptyGroup(l.groups, empties, path, spot.group);
        return (
          l: l,
          empties: normalizeEmptyGroups(l.groups, m.empties),
          path: m.path,
          renamed: groupLeaf(m.path) != groupLeaf(path),
        );
      }
      final m = moveGroupToNamed(
        l,
        run!,
        spot.index,
        setParent: true,
        parent: spot.group,
        emptyGroups: empties,
      );
      return (
        l: m.layout,
        empties: normalizeEmptyGroups(
          m.layout.groups,
          moveEmpties(empties, path, m.path),
        ),
        path: m.path,
        renamed: m.renamed,
      );
    }

    ContiLayout two() =>
        layout([1, 2, 3, 4, 5], {1: 'a', 2: 'a', 4: 'b', 5: 'b'});

    test('구역 판정: 펼침 위 1/3 앞·나머지 안, 접힘 3등분, 빈 그룹 전부 안', () {
      ContiDropZone z(double dy, {bool c = false, bool e = false}) =>
          groupDropZone(dy, 30, collapsed: c, empty: e);
      expect(z(5), ContiDropZone.before);
      expect(z(12), ContiDropZone.into);
      expect(z(29), ContiDropZone.into);
      expect(z(5, c: true), ContiDropZone.before);
      expect(z(15, c: true), ContiDropZone.into);
      expect(z(25, c: true), ContiDropZone.after);
      expect(z(1, e: true), ContiDropZone.into);
    });

    test('펼친 머리줄 안으로 = 대상 구간 맨 앞, 위 1/3 = 앞 형제', () {
      final l = two();
      final r = apply(l, [], 'a', 'b', ContiDropZone.into)!;
      expect(r.l.groups, {1: 'b/a', 2: 'b/a', 4: 'b', 5: 'b'});
      expect(r.l.uids, [3, 1, 2, 4, 5]);
      expect(contiguous(r.l), isTrue);
      // 맨 앞 하위 = b 구간 맨 앞(= a 의 항목이 b 항목 4 앞)
      final rows = contiRows(l.uids, l.groups);
      final d = resolveGroupDrop(
        rows,
        headerRow(rows, 'b'),
        ContiDropZone.before,
        runOf(l, 'a'),
        l.uids,
        l.groups,
      );
      expect((d.spot!.index, d.spot!.group), (3, null)); // b 앞 형제
    });

    test('접힌 그룹 안으로 = 맨 끝 하위', () {
      final l = two();
      final r = apply(
        l,
        [],
        'a',
        'b',
        ContiDropZone.into,
        collapsed: {groupKey('b', 4)},
      )!;
      expect(r.l.uids, [3, 4, 5, 1, 2]);
      expect(r.l.groups, {1: 'b/a', 2: 'b/a', 4: 'b', 5: 'b'});
      expect(contiguous(r.l), isTrue);
    });

    test('접힌 그룹 앞/뒤 형제', () {
      final l = layout([1, 2, 3], {1: 'a', 3: 'b'});
      final c = {groupKey('b', 3)};
      final after = apply(l, [], 'a', 'b', ContiDropZone.after, collapsed: c)!;
      expect(after.l.uids, [2, 3, 1]);
      expect(after.l.groups, {1: 'a', 3: 'b'});
    });

    test('자기 자신·자기 하위 안에는 못 넣는다', () {
      final l = layout([1, 2, 3], {1: 'a', 2: 'a/x', 3: 'a/x'});
      for (final target in ['a', 'a/x']) {
        final rows = contiRows(l.uids, l.groups);
        final d = resolveGroupDrop(
          rows,
          headerRow(rows, target),
          ContiDropZone.into,
          runOf(l, 'a'),
          l.uids,
          l.groups,
        );
        expect(d.reject, ContiDropReject.self, reason: target);
      }
    });

    test('깊이 초과 거절: 높이 3 그룹은 1단 안에도 못 들어간다', () {
      final l = layout([1, 2, 3], {1: 'a/x/p', 2: 'b', 3: 'c/y'});
      final rows = contiRows(l.uids, l.groups);
      ContiGroupDrop go(String from, String to) => resolveGroupDrop(
        rows,
        headerRow(rows, to),
        ContiDropZone.into,
        runOf(l, from),
        l.uids,
        l.groups,
      );
      expect(go('a', 'b').reject, ContiDropReject.tooDeep);
      expect(go('a/x', 'b').spot, isNotNull); // 높이 2 + 깊이 1 = 3
      expect(go('a/x', 'c/y').reject, ContiDropReject.tooDeep);
      expect(go('b', 'c/y').spot, isNotNull); // 1 + 2
      // moveGroupTo 방어: 직접 불러도 4단이 안 생긴다
      final r = moveGroupTo(l, runOf(l, 'a'), 1, setParent: true, parent: 'b');
      expect(r.groups, l.groups);
      // createSubGroupWithItems 방어
      final deep = layout([1, 2], {1: 'a/x/p'});
      final same = createSubGroupWithItems(deep, runOf(deep, 'a/x/p'), [
        2,
      ], 'n');
      expect(same.groups, deep.groups);
    });

    test('제자리 = noChange (같은 부모·같은 자리)', () {
      final l = layout([1, 2, 3], {2: 'a/x', 3: 'a/x'});
      final rows = contiRows(l.uids, l.groups);
      final d = resolveGroupDrop(
        rows,
        headerRow(rows, 'a'),
        ContiDropZone.into,
        runOf(l, 'a/x'),
        l.uids,
        l.groups,
      );
      expect(d.reject, ContiDropReject.noChange);
    });

    test('같은 이름 충돌은 이름 (2) 로 바뀌고 알린다', () {
      final l = layout([1, 2, 3], {1: 'b', 2: 'b/a', 3: 'a'});
      final r = apply(l, [], 'a', 'b', ContiDropZone.into)!;
      expect(r.path, 'b/a (2)');
      expect(r.renamed, isTrue);
      expect(r.l.groups[3], 'b/a (2)');
      expect(contiguous(r.l), isTrue);
    });

    test('빈 하위 그룹은 부모 구간 끝, 부모가 접히면 같이 가려지고 최상위 빈 그룹은 맨 끝', () {
      final l = layout([1, 2, 3], {1: 'a', 2: 'a/x'});
      final rows = contiRows(l.uids, l.groups, emptyGroups: ['a/c', 'e']);
      expect(
        [
          for (final r in rows)
            r is ContiHeaderRow ? 'H${r.name}' : 'I${(r as ContiItemRow).uid}',
        ],
        ['Ha', 'I1', 'Ha/x', 'I2', 'Ha/c', 'I3', 'He'],
      );
      final c = rows.whereType<ContiHeaderRow>().firstWhere(
        (h) => h.name == 'a/c',
      );
      expect(c.anchorIndex, 2);
      expect(c.depth, 2);
      final folded = contiRows(
        l.uids,
        l.groups,
        collapsed: {groupKey('a', 1)},
        emptyGroups: ['a/c'],
      );
      expect(folded.whereType<ContiHeaderRow>().map((h) => h.name), ['a']);
      // 빈 하위의 빈 하위: 둘 다 부모 구간 끝, 자리는 같다
      final deep = contiRows(l.uids, l.groups, emptyGroups: ['a/c', 'a/c/d']);
      final d = deep.whereType<ContiHeaderRow>().firstWhere(
        (h) => h.name == 'a/c/d',
      );
      expect(d.anchorIndex, 2);
      expect(d.depth, 3);
    });

    test('빈 하위에 항목을 놓으면 부모가 쪼개지지 않고 빈 그룹이 정리된다', () {
      final l = layout([1, 2, 3], {1: 'a', 2: 'a/x'});
      final rows = contiRows(l.uids, l.groups, emptyGroups: ['a/c']);
      final spot = resolveDrop(rows, headerRow(rows, 'a/c'), true, 3);
      expect(spot, (index: 2, group: 'a/c'));
      final r = moveItemTo(l, 3, spot);
      expect(r.groups, {1: 'a', 2: 'a/x', 3: 'a/c'});
      expect(contiguous(r), isTrue);
      expect(normalizeEmptyGroups(r.groups, ['a/c', 'a']), isEmpty);
    });

    test('normalizeEmptyGroups: 항목이 생긴 것은 빼고 조상 없는 것은 채운다', () {
      expect(normalizeEmptyGroups({1: 'a/c'}, ['a', 'a/c', 'b/d', 'x/y/z/w']), [
        'b',
        'b/d',
      ]);
    });

    test('빈 그룹 이름 바꾸기·옮기기·풀기·삭제는 하위 경로를 같이 고친다', () {
      expect(renameEmpties(['a/c', 'a/c/d', 'q'], 'a', 'z'), [
        'z/c',
        'z/c/d',
        'q',
      ]);
      expect(renameEmpties(['a/c', 'a/c/d'], 'a/c', 'k'), ['a/k', 'a/k/d']);
      expect(moveEmpties(['a', 'a/c'], 'a', 'b/a'), ['b/a', 'b/a/c']);
      expect(ungroupEmpties(['a', 'a/c'], 'a'), ['c']);
      expect(ungroupEmpties(['a/c', 'a/c/d'], 'a/c'), ['a/d']);
      expect(removeEmpties(['a', 'a/c', 'b'], 'a'), ['b']);
    });

    test('빈 그룹을 끌어 다른 그룹 하위로, 이름이 겹치면 (2)', () {
      final l = layout([1, 2], {1: 'a'});
      final r = apply(l, ['e'], 'e', 'a', ContiDropZone.into)!;
      expect(r.empties, ['a/e']);
      expect(r.l.uids, l.uids);
      final rows = contiRows(l.uids, l.groups, emptyGroups: r.empties);
      expect(headerRow(rows, 'a/e'), greaterThan(headerRow(rows, 'a')));
      // 겹침
      final l2 = layout([1, 2], {1: 'a', 2: 'a/e'});
      final r2 = apply(l2, ['e'], 'e', 'a', ContiDropZone.into)!;
      expect(r2.empties, ['a/e (2)']);
      expect(r2.renamed, isTrue);
      // 자기 안으로는 안 된다
      final r3 = apply(l, ['e', 'e/f'], 'e', 'e/f', ContiDropZone.into);
      expect(r3, isNull);
    });

    test('실제 그룹을 빈 그룹 위에 놓으면 B/A 가 되고 B 는 빈 그룹이 아니다', () {
      final l = layout([1, 2, 3, 4], {1: 'a', 2: 'a', 4: 'z'});
      // 최상위 빈 그룹 B: 목록 끝으로
      final r = apply(l, ['B'], 'z', 'B', ContiDropZone.into)!;
      expect(r.l.groups, {1: 'a', 2: 'a', 4: 'B/z'});
      expect(r.empties, isEmpty);
      expect(contiguous(r.l), isTrue);
      // 빈 하위 a/B: a 구간 끝으로, a 는 쪼개지지 않는다
      final r2 = apply(l, ['a/B'], 'z', 'a/B', ContiDropZone.into)!;
      expect(r2.l.uids, [1, 2, 4, 3]);
      expect(r2.l.groups, {1: 'a', 2: 'a', 4: 'a/B/z'});
      expect(r2.empties, isEmpty);
      expect(contiguous(r2.l), isTrue);
    });

    test('빈 그룹 아래 빈 하위가 있으면 높이에 센다(깊이 거절)', () {
      final l = layout([1, 2], {1: 'a/x'});
      final r = apply(l, ['e', 'e/f', 'e/f/g'], 'e', 'a/x', ContiDropZone.into);
      expect(r, isNull); // e 높이 3 + a/x 깊이 2
    });

    test('validGroupAt: 빈 하위는 부모에 닿아 있을 때만', () {
      expect(validGroupAt([1, 2], {1: 'a'}, 1, 'a/c', ['a/c']), 'a/c');
      expect(validGroupAt([1, 2], {1: 'a'}, 2, 'a/c', ['a/c']), isNull);
      expect(validGroupAt([1, 2], {1: 'a'}, 2, 'e', ['e']), 'e');
      expect(validGroupAt([1, 2], {1: 'a'}, 1, 'e', ['e']), isNull);
    });

    test('무작위: 그룹·빈 그룹을 아무렇게나 끌어도 이어짐·깊이≤3·항목 보존·빈 그룹 정리', () {
      final rnd = Random(5);
      var l = layout(List.generate(10, (i) => i + 1), {
        2: 'a',
        3: 'a/x',
        4: 'a/x',
        6: 'b',
        7: 'b/y',
        8: 'b/y/p',
      });
      var empties = <String>['e', 'a/c'];
      final collapsed = <String>{};
      for (var n = 0; n < 800; n++) {
        if (rnd.nextInt(6) == 0) {
          final runs = allGroupRuns(l.uids, l.groups);
          if (runs.isNotEmpty) {
            final r = runs[rnd.nextInt(runs.length)];
            final k = groupKey(r.name, r.startUid);
            if (!collapsed.remove(k)) collapsed.add(k);
          }
        }
        if (rnd.nextInt(5) == 0) {
          final parents = [
            null,
            ...{
              for (final g in [...l.groups.values, ...empties])
                for (var d = 1; d <= groupDepth(g); d++) pathPrefix(g, d)!,
            },
          ];
          final par = parents[rnd.nextInt(parents.length)];
          if ((par == null ? 0 : groupDepth(par)) < maxGroupDepth) {
            final name = uniqueGroupName(
              'n',
              siblingGroupNames(l.groups, empties, par),
            );
            empties = [...empties, par == null ? name : '$par/$name'];
          }
        }
        final rows = contiRows(
          l.uids,
          l.groups,
          collapsed: collapsed,
          emptyGroups: empties,
        );
        final headers = [
          for (var i = 0; i < rows.length; i++)
            if (rows[i] is ContiHeaderRow) i,
        ];
        if (headers.isEmpty) continue;
        final target = headers[rnd.nextInt(headers.length)];
        final from = [
          ...allGroupRuns(l.uids, l.groups).map((r) => r.name).toSet(),
          ...empties,
        ];
        if (from.isEmpty) continue;
        final path = from[rnd.nextInt(from.length)];
        final isEmpty =
            empties.contains(path) &&
            !l.groups.values.any((g) => isUnder(g, path));
        final run = isEmpty ? null : runOf(l, path);
        final d = resolveGroupDrop(
          rows,
          target,
          ContiDropZone.values[rnd.nextInt(3)],
          run,
          l.uids,
          l.groups,
          emptyPath: isEmpty ? path : null,
          emptyGroups: empties,
        );
        final spot = d.spot;
        if (spot != null) {
          if (isEmpty) {
            final m = moveEmptyGroup(l.groups, empties, path, spot.group);
            empties = normalizeEmptyGroups(l.groups, m.empties);
          } else {
            final m = moveGroupToNamed(
              l,
              run!,
              spot.index,
              setParent: true,
              parent: spot.group,
              emptyGroups: empties,
            );
            l = m.layout;
            empties = normalizeEmptyGroups(
              l.groups,
              moveEmpties(empties, path, m.path),
            );
          }
        }
        empties = normalizeEmptyGroups(l.groups, empties);
        final why = 'step $n ${l.uids} ${l.groups} $empties';
        expect(contiguous(l), isTrue, reason: why);
        expect(l.uids.toSet().length, 10, reason: why);
        expect(
          [
            ...l.groups.values,
            ...empties,
          ].every((g) => groupDepth(g) <= maxGroupDepth),
          isTrue,
          reason: why,
        );
        expect(
          empties.every((e) => !l.groups.values.any((g) => isUnder(g, e))),
          isTrue,
          reason: why,
        );
      }
    });
  });
}
