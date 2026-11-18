/// 콘티 폴더 트리(순수 함수). 데이터는 평면 목록 + 항목 uid → 그룹 이름 그대로이고(DB·`.wsconti` 불변),
/// 화면만 트리로 그린다. 불변식: 한 그룹의 항목은 목록에서 이어진다 — 옮길 때 실제로 재배치한다.
/// 그룹 식별 = (이름, 구간 시작 uid). 옛 콘티에서 떨어진 같은 이름은 별개 그룹이다.
library;

/// 같은 이름이 이어진 구간. [start] 는 목록 번호, [startUid] 는 그 첫 항목 uid.
class ContiGroupRun {
  const ContiGroupRun(this.name, this.start, this.count, this.startUid);
  final String name;
  final int start;
  final int count;
  final int startUid;
  int get end => start + count; // 끝 번호(포함 안 함)
}

List<ContiGroupRun> groupRuns(List<int> uids, Map<int, String> groups) {
  final out = <ContiGroupRun>[];
  var i = 0;
  while (i < uids.length) {
    final name = groups[uids[i]];
    if (name == null) {
      i++;
      continue;
    }
    var j = i + 1;
    while (j < uids.length && groups[uids[j]] == name) {
      j++;
    }
    out.add(ContiGroupRun(name, i, j - i, uids[i]));
    i = j;
  }
  return out;
}

/// 접기 상태 키. 빈 그룹은 [startUid] = -1.
String groupKey(String name, int startUid) => '$startUid\u0000$name';

sealed class ContiRow {
  const ContiRow();
}

class ContiHeaderRow extends ContiRow {
  const ContiHeaderRow({
    required this.name,
    required this.startUid,
    required this.start,
    required this.count,
    required this.collapsed,
  });
  final String name;

  /// 첫 항목 uid. 빈 그룹은 -1.
  final int startUid;

  /// 항목 번호(빈 그룹은 목록 길이).
  final int start;
  final int count;
  final bool collapsed;
  bool get empty => count == 0;
  String get key => groupKey(name, startUid);
}

class ContiItemRow extends ContiRow {
  const ContiItemRow(this.index, this.uid, this.group);
  final int index;
  final int uid;
  final String? group;
}

/// 화면 행 목록: 그룹마다 머리 행 + (접히지 않았으면) 소속 항목 행. 빈 그룹은 맨 끝에 머리 행만.
List<ContiRow> contiRows(
  List<int> uids,
  Map<int, String> groups, {
  Set<String> collapsed = const {},
  List<String> emptyGroups = const [],
}) {
  final rows = <ContiRow>[];
  final runs = {for (final r in groupRuns(uids, groups)) r.start: r};
  var i = 0;
  while (i < uids.length) {
    final run = runs[i];
    if (run == null) {
      rows.add(ContiItemRow(i, uids[i], null));
      i++;
      continue;
    }
    final key = groupKey(run.name, run.startUid);
    final isCollapsed = collapsed.contains(key);
    rows.add(
      ContiHeaderRow(
        name: run.name,
        startUid: run.startUid,
        start: run.start,
        count: run.count,
        collapsed: isCollapsed,
      ),
    );
    if (!isCollapsed) {
      for (var k = run.start; k < run.end; k++) {
        rows.add(ContiItemRow(k, uids[k], run.name));
      }
    }
    i = run.end;
  }
  for (final name in emptyGroups) {
    rows.add(
      ContiHeaderRow(
        name: name,
        startUid: -1,
        start: uids.length,
        count: 0,
        collapsed: collapsed.contains(groupKey(name, -1)),
      ),
    );
  }
  return rows;
}

/// 놓을 자리: [index] 는 (옮기기 전) 목록 번호 앞, [group] 은 그 항목이 들 그룹(null = 그룹 밖).
typedef ContiSpot = ({int index, String? group});

/// 항목·찬양·성경 절을 [rows] 의 [rowIndex] 행 위/아래 절반([after])에 놓았을 때의 자리.
/// - 항목 행: 그 항목 앞/뒤, 그 항목의 그룹(그룹 마지막 항목 아래 절반 = 그룹 끝).
/// - 머리 행 위 절반: 머리 앞, 그룹 밖(빠져나오는 길). 아래 절반: 그룹 맨 앞(접힌 그룹은 맨 끝).
/// - 빈 그룹 머리 아래 절반: 목록 끝에서 그 그룹을 시작한다.
ContiSpot resolveDrop(
  List<ContiRow> rows,
  int rowIndex,
  bool after,
  int length,
) {
  final row = rows[rowIndex];
  switch (row) {
    case ContiItemRow():
      return (index: after ? row.index + 1 : row.index, group: row.group);
    case ContiHeaderRow():
      if (row.empty) {
        return (index: length, group: after ? row.name : null);
      }
      if (!after) return (index: row.start, group: null);
      return (
        index: row.collapsed ? row.start + row.count : row.start,
        group: row.name,
      );
  }
}

/// 그룹 블록 [run] 을 [rows] 의 [rowIndex] 행 위/아래에 놓을 때의 목록 번호. 중첩이 안 되므로
/// 다른 그룹 안 행이면 그 그룹 블록 앞/뒤다. 자기 블록 위면 null(제자리).
int? resolveGroupDrop(
  List<ContiRow> rows,
  int rowIndex,
  bool after,
  ContiGroupRun run,
  List<int> uids,
  Map<int, String> groups,
) {
  final row = rows[rowIndex];
  int? at;
  switch (row) {
    case ContiItemRow():
      final name = row.group;
      if (name == null) {
        at = after ? row.index + 1 : row.index;
      } else {
        final r = groupRuns(
          uids,
          groups,
        ).firstWhere((r) => row.index >= r.start && row.index < r.end);
        at = after ? r.end : r.start;
      }
    case ContiHeaderRow():
      at = row.empty
          ? uids.length
          : after
          ? row.start + row.count
          : row.start;
  }
  if (at >= run.start && at <= run.end) return null;
  return at;
}

/// 콘티 배치 한 벌(목록·그룹·'여백 없음' 표시). 이동 함수가 새 것을 돌려준다.
class ContiLayout {
  ContiLayout(this.uids, this.groups, this.noSpacer);
  final List<int> uids;
  final Map<int, String> groups;

  /// 이 항목은 뒤 항목과 여백 없이 이어진다는 표시(`_noSpacerUids`).
  final Set<int> noSpacer;

  ContiLayout copy() =>
      ContiLayout(List.of(uids), Map.of(groups), Set.of(noSpacer));
}

/// [moved] (목록에서 이어진 항목들)를 (옮기기 전 번호) [insertIndex] 앞으로 옮긴다.
/// [setGroup] 이면 한 항목을 [group] 에 넣는다(null = 그룹 밖). 그룹째 옮길 때는 false.
/// '여백 없음' 은 `_onStagingReorder` 와 같은 규칙: 블록 끝이 뒤와 이어져 있었으면 앞 항목이 그 뒤와
/// 이어지게 두고, 아니면 앞 항목 표시를 지운다. 놓은 자리 앞 항목과는 여백을 둔다.
ContiLayout moveBlock(
  ContiLayout layout,
  List<int> moved,
  int insertIndex, {
  bool setGroup = false,
  String? group,
}) {
  final out = layout.copy();
  if (moved.isEmpty) return out;
  if (setGroup) {
    if (group == null) {
      out.groups.remove(moved.first);
    } else {
      out.groups[moved.first] = group;
    }
  }
  final first = layout.uids.indexOf(moved.first);
  if (first < 0) return out;
  final last = first + moved.length - 1;
  // 제자리(블록 안·바로 앞뒤)면 순서는 그대로다.
  if (insertIndex >= first && insertIndex <= last + 1) return out;

  final joined = out.noSpacer.remove(moved.last);
  if (!joined && first > 0) out.noSpacer.remove(layout.uids[first - 1]);
  out.uids.removeRange(first, last + 1);
  final at = insertIndex > last ? insertIndex - moved.length : insertIndex;
  out.uids.insertAll(at, moved);
  if (at > 0) out.noSpacer.remove(out.uids[at - 1]);
  return out;
}

/// 항목 하나를 [spot] 으로 옮긴다(그룹 안으로·밖으로 포함).
ContiLayout moveItemTo(ContiLayout layout, int uid, ContiSpot spot) =>
    moveBlock(layout, [uid], spot.index, setGroup: true, group: spot.group);

/// 항목 여러 개 [uids] 를 [spot] 으로 한 덩어리로 옮긴다(목록 순서 유지, 그룹 안으로·밖으로 포함).
/// 목록에서 이어진 것끼리는 한 블록으로 옮겨 '여백 없음' 표시가 그대로 따라가고, 떨어진 것은 블록마다 차례로 모은다.
ContiLayout moveItemsTo(
  ContiLayout layout,
  Iterable<int> uids,
  ContiSpot spot,
) {
  final order = [
    for (final u in layout.uids)
      if (uids.contains(u)) u,
  ];
  if (order.isEmpty) return layout.copy();
  final runs = <List<int>>[];
  for (final u in order) {
    if (runs.isNotEmpty &&
        layout.uids.indexOf(u) == layout.uids.indexOf(runs.last.last) + 1) {
      runs.last.add(u);
    } else {
      runs.add([u]);
    }
  }
  var cur = layout;
  var target = spot.index;
  for (final run in runs) {
    cur = moveBlock(cur, run, target);
    target = cur.uids.indexOf(run.first) + run.length;
  }
  for (final u in order) {
    if (spot.group == null) {
      cur.groups.remove(u);
    } else {
      cur.groups[u] = spot.group!;
    }
  }
  return cur;
}

/// 그룹 블록 [run] 을 [insertIndex] 앞으로 옮긴다(순서 유지, 다른 그룹과 안 섞임).
ContiLayout moveGroupTo(
  ContiLayout layout,
  ContiGroupRun run,
  int insertIndex,
) => moveBlock(layout, layout.uids.sublist(run.start, run.end), insertIndex);

/// 위([delta] < 0)·아래로 한 칸: 앞·뒤의 그룹 블록 또는 그룹 없는 항목 하나를 건너뛴다. 못 가면 null.
int? groupStepIndex(ContiLayout layout, ContiGroupRun run, int delta) {
  if (delta < 0) {
    if (run.start == 0) return null;
    final prev = groupRuns(
      layout.uids,
      layout.groups,
    ).where((r) => r.end == run.start).firstOrNull;
    return prev?.start ?? run.start - 1;
  }
  if (run.end >= layout.uids.length) return null;
  final next = groupRuns(
    layout.uids,
    layout.groups,
  ).where((r) => r.start == run.end).firstOrNull;
  return next?.end ?? run.end + 1;
}

/// 새 그룹: 고른 항목 [uid] 가 있으면 그 항목이 든다. 이미 다른 그룹 안이면(중첩 불가) 그 그룹 끝 바로 뒤로 나온다.
ContiLayout createGroupWith(ContiLayout layout, int uid, String name) {
  final i = layout.uids.indexOf(uid);
  if (i < 0) return layout.copy();
  final run = groupRuns(
    layout.uids,
    layout.groups,
  ).where((r) => i >= r.start && i < r.end).firstOrNull;
  return moveItemTo(layout, uid, (index: run?.end ?? i, group: name));
}

/// 새 그룹에 항목 여러 개 [uids] 를 넣는다. 자리는 그중 목록에서 가장 앞 항목 자리 —
/// 그 항목이 다른 그룹 안이면(중첩 불가) 그 그룹 끝 바로 뒤.
ContiLayout createGroupWithItems(
  ContiLayout layout,
  Iterable<int> uids,
  String name,
) {
  final first = layout.uids.indexWhere(uids.contains);
  if (first < 0) return layout.copy();
  final run = groupRuns(
    layout.uids,
    layout.groups,
  ).where((r) => first >= r.start && first < r.end).firstOrNull;
  return moveItemsTo(layout, uids, (index: run?.end ?? first, group: name));
}

/// 그룹 풀기(항목은 남는다).
ContiLayout ungroup(ContiLayout layout, ContiGroupRun run) {
  final out = layout.copy();
  for (var k = run.start; k < run.end; k++) {
    out.groups.remove(layout.uids[k]);
  }
  return out;
}

/// 그룹 이름 바꾸기(그 구간만).
ContiLayout renameGroup(ContiLayout layout, ContiGroupRun run, String name) {
  final out = layout.copy();
  for (var k = run.start; k < run.end; k++) {
    out.groups[layout.uids[k]] = name;
  }
  return out;
}

/// 이미 있는 그룹 이름(빈 그룹 포함)과 안 겹치게 '이름 (2)' 꼴로 만든다. [max] 자 안.
String uniqueGroupName(String name, Iterable<String> used, {int max = 12}) {
  final taken = used.toSet();
  if (!taken.contains(name)) return name;
  for (var n = 2; ; n++) {
    final tail = ' ($n)';
    final base = name.length + tail.length > max
        ? name.substring(0, max - tail.length)
        : name;
    if (!taken.contains('$base$tail')) return '$base$tail';
  }
}

/// 비동기(읽는 사이 콘티가 바뀔 수 있음) 뒤에 놓을 자리가 아직 [group] 에 닿아 있는지.
/// 닿아 있지 않으면 그룹 밖으로 둔다(이어진 구간이 갈라지지 않게). [emptyGroups] 의 이름은 끝에서 시작할 수 있다.
String? validGroupAt(
  List<int> uids,
  Map<int, String> groups,
  int index,
  String? group,
  List<String> emptyGroups,
) {
  if (group == null) return null;
  final prev = index > 0 && index <= uids.length
      ? groups[uids[index - 1]]
      : null;
  final next = index < uids.length ? groups[uids[index]] : null;
  if (prev == group || next == group) return group;
  if (index == uids.length && emptyGroups.contains(group)) return group;
  return null;
}

/// 콘티 목록 항목 클릭의 고르기 규칙(순수 함수). [visible] = 지금 보이는 항목 uid(트리 표시 순서, 접힌 그룹 안 항목 제외).
/// Shift = [anchor] 부터 [uid] 까지 보이는 항목만(그룹 머리줄·접힌 항목은 범위에 안 든다. 앵커가 안 보이면 그 항목 하나),
/// Shift+toggle = 기존 선택에 범위 더하기, toggle(⌘/Ctrl) = 하나씩 추가·해제, 아무것도 아니면 그 하나만.
({Set<int> selected, int? anchor}) applyContiSelect({
  required List<int> visible,
  required Set<int> selected,
  required int? anchor,
  required int uid,
  required bool shift,
  required bool toggle,
}) {
  if (shift) {
    final a = anchor == null ? -1 : visible.indexOf(anchor);
    final b = visible.indexOf(uid);
    if (a >= 0 && b >= 0) {
      final range = visible.sublist(a < b ? a : b, (a < b ? b : a) + 1);
      return (selected: {if (toggle) ...selected, ...range}, anchor: anchor);
    }
  }
  if (toggle) {
    final next = {...selected};
    if (!next.remove(uid)) next.add(uid);
    return (selected: next, anchor: uid);
  }
  return (selected: {uid}, anchor: uid);
}
