/// 콘티 폴더 트리(순수 함수). 데이터는 평면 목록 + 항목 uid → 그룹 이름 그대로이고(DB·`.wsconti` 불변),
/// 화면만 트리로 그린다. 불변식: 한 그룹의 항목은 목록에서 이어진다 — 옮길 때 실제로 재배치한다.
/// 그룹 식별 = (이름, 구간 시작 uid). 옛 콘티에서 떨어진 같은 이름은 별개 그룹이다.
library;

/// 그룹 경로: `상위/하위/하위의하위`(최대 [maxGroupDepth] 단). 데이터는 항목 uid → 경로 문자열 하나라
/// DB(`item_group`)·`.wsconti` 형식은 그대로다. 이름 안 `/` 는 입력할 때 `／` 로 바꾼다.
const maxGroupDepth = 3;

int groupDepth(String path) => '/'.allMatches(path).length + 1;

/// 앞에서 [n] 단까지의 경로. n <= 0 이면 null.
String? pathPrefix(String? path, int n) =>
    path == null || n <= 0 ? null : path.split('/').take(n).join('/');

String? groupParent(String path) => pathPrefix(path, groupDepth(path) - 1);

String groupLeaf(String path) => path.substring(path.lastIndexOf('/') + 1);

bool isUnder(String path, String prefix) =>
    path == prefix || path.startsWith('$prefix/');

/// 화면용 이름: `상위 › 하위`.
String groupLabel(String path) => path.replaceAll('/', ' › ');

/// 두 항목 사이에 들어갈 항목이 드는 그룹: 두 경로의 공통 앞부분(없으면 null).
String? commonGroupPath(String? a, String? b) {
  if (a == null || b == null) return null;
  final x = a.split('/'), y = b.split('/');
  var n = 0;
  while (n < x.length && n < y.length && x[n] == y[n]) {
    n++;
  }
  return pathPrefix(a, n);
}

/// [parent] 바로 아래 그룹들의 이름(빈 그룹 포함). parent null = 맨 위 단계.
Set<String> siblingGroupNames(
  Map<int, String> groups,
  Iterable<String> emptyGroups,
  String? parent,
) {
  final n = parent == null ? 0 : groupDepth(parent);
  return {
    for (final g in [...groups.values, ...emptyGroups])
      if (groupDepth(g) > n && (parent == null || isUnder(g, parent)))
        g.split('/')[n],
  };
}

/// 같은 경로가 이어진 구간. [name] 은 이 구간의 경로(맨 위 단계면 그냥 이름), [start] 는 목록 번호,
/// [startUid] 는 그 첫 항목 uid. 하위 그룹은 상위 구간 안에 든다.
class ContiGroupRun {
  const ContiGroupRun(this.name, this.start, this.count, this.startUid);
  final String name;
  final int start;
  final int count;
  final int startUid;
  int get end => start + count; // 끝 번호(포함 안 함)
  int get depth => groupDepth(name);
  String get label => groupLeaf(name);
  String? get parent => groupParent(name);
}

/// [depth] 단계 그룹 구간: 경로 앞 [depth] 단이 같은 이어진 항목들(그보다 얕은 항목은 구간 밖).
List<ContiGroupRun> groupRuns(
  List<int> uids,
  Map<int, String> groups, {
  int depth = 1,
}) {
  String? keyAt(int i) {
    final g = groups[uids[i]];
    return g == null || groupDepth(g) < depth ? null : pathPrefix(g, depth);
  }

  final out = <ContiGroupRun>[];
  var i = 0;
  while (i < uids.length) {
    final name = keyAt(i);
    if (name == null) {
      i++;
      continue;
    }
    var j = i + 1;
    while (j < uids.length && keyAt(j) == name) {
      j++;
    }
    out.add(ContiGroupRun(name, i, j - i, uids[i]));
    i = j;
  }
  return out;
}

/// 모든 단계의 구간(시작 번호 순, 같으면 상위 먼저).
List<ContiGroupRun> allGroupRuns(List<int> uids, Map<int, String> groups) => [
  for (var d = 1; d <= maxGroupDepth; d++) ...groupRuns(uids, groups, depth: d),
]..sort((a, b) => a.start != b.start ? a.start - b.start : a.depth - b.depth);

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

  /// 그룹 경로(맨 위 단계면 이름).
  final String name;

  /// 첫 항목 uid. 빈 그룹은 -1.
  final int startUid;

  /// 항목 번호(빈 그룹은 목록 길이).
  final int start;
  final int count;
  final bool collapsed;
  bool get empty => count == 0;
  String get key => groupKey(name, startUid);
  int get depth => groupDepth(name);
  String get label => groupLeaf(name);
}

class ContiItemRow extends ContiRow {
  const ContiItemRow(this.index, this.uid, this.group);
  final int index;
  final int uid;
  final String? group;

  /// 들여쓰기 단계(그룹 밖 0).
  int get depth => group == null ? 0 : groupDepth(group!);
}

/// 화면 행 목록: 그룹마다 머리 행 + (접히지 않았으면) 소속 항목 행. 빈 그룹은 맨 끝에 머리 행만.
List<ContiRow> contiRows(
  List<int> uids,
  Map<int, String> groups, {
  Set<String> collapsed = const {},
  List<String> emptyGroups = const [],
}) {
  final rows = <ContiRow>[];
  void emit(int from, int to, int depth) {
    var i = from;
    while (i < to) {
      final g = groups[uids[i]];
      if (g == null || groupDepth(g) < depth) {
        rows.add(ContiItemRow(i, uids[i], g));
        i++;
        continue;
      }
      final prefix = pathPrefix(g, depth)!;
      var j = i + 1;
      while (j < to) {
        final h = groups[uids[j]];
        if (h == null ||
            groupDepth(h) < depth ||
            pathPrefix(h, depth) != prefix) {
          break;
        }
        j++;
      }
      final isCollapsed = collapsed.contains(groupKey(prefix, uids[i]));
      rows.add(
        ContiHeaderRow(
          name: prefix,
          startUid: uids[i],
          start: i,
          count: j - i,
          collapsed: isCollapsed,
        ),
      );
      if (!isCollapsed) emit(i, j, depth + 1);
      i = j;
    }
  }

  emit(0, uids.length, 1);
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
/// - 머리 행 위 절반: 머리 앞, 그 그룹의 상위(맨 위 단계면 그룹 밖 — 빠져나오는 길). 아래 절반: 그룹 맨 앞(접힌 그룹은 맨 끝).
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
      if (!after) return (index: row.start, group: groupParent(row.name));
      return (
        index: row.collapsed ? row.start + row.count : row.start,
        group: row.name,
      );
  }
}

/// 그룹 블록 [run] 을 [rows] 의 [rowIndex] 행 위/아래에 놓을 때의 자리: index = 목록 번호, group = 옮긴 뒤
/// 그 그룹의 상위 경로(null = 맨 위 단계). 그룹은 원래 단계(상위 깊이)를 지켜 그 행의 같은 단계 블록 앞/뒤에 놓인다 —
/// 맨 위 그룹은 늘 맨 위 블록 앞/뒤(예전과 같다), 하위 그룹은 놓은 행이 든 그룹의 같은 단계 형제 앞/뒤.
/// 자기 안이거나 제자리(같은 상위, 자기 블록 경계)면 null.
ContiSpot? resolveGroupDrop(
  List<ContiRow> rows,
  int rowIndex,
  bool after,
  ContiGroupRun run,
  List<int> uids,
  Map<int, String> groups,
) {
  final row = rows[rowIndex];
  final level = run.depth - 1; // 옮길 그룹의 상위 깊이
  final all = allGroupRuns(uids, groups);
  int? blockAt(String path, int index) {
    final b = all
        .where((r) => r.name == path && index >= r.start && index < r.end)
        .firstOrNull;
    return b == null ? null : (after ? b.end : b.start);
  }

  String? dest;
  int? at;
  switch (row) {
    case ContiItemRow():
      final g = row.group;
      final len = g == null ? 0 : groupDepth(g);
      if (len <= level) {
        dest = g;
        at = after ? row.index + 1 : row.index;
      } else {
        dest = pathPrefix(g, level);
        at = blockAt(pathPrefix(g, level + 1)!, row.index);
      }
    case ContiHeaderRow():
      if (row.empty) {
        dest = null;
        at = uids.length;
      } else {
        final n = (row.depth - 1).clamp(0, level);
        dest = pathPrefix(row.name, n);
        at = blockAt(pathPrefix(row.name, n + 1)!, row.start);
      }
  }
  if (at == null) return null;
  if (dest != null && isUnder(dest, run.name)) return null;
  if (at > run.start && at < run.end) return null;
  if ((at == run.start || at == run.end) && dest == run.parent) return null;
  return (index: at, group: dest);
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

/// 그룹 블록 [run](하위 그룹까지 통째로)을 [insertIndex] 앞으로 옮긴다(순서 유지, 다른 그룹과 안 섞임).
/// [setParent] 면 옮긴 뒤 상위를 [parent] 로 바꾼다(하위 구조는 그대로 따라간다). 새 상위 아래에 같은 이름이
/// 있으면 이름 뒤에 (2) 를 단다.
ContiLayout moveGroupTo(
  ContiLayout layout,
  ContiGroupRun run,
  int insertIndex, {
  bool setParent = false,
  String? parent,
}) {
  final moved = layout.uids.sublist(run.start, run.end);
  final out = moveBlock(layout, moved, insertIndex);
  if (!setParent || parent == run.parent) return out;
  final rest = {
    for (final u in moved) u: out.groups[u]!.substring(run.name.length),
  };
  final others = Map.of(out.groups)..removeWhere((u, _) => rest.containsKey(u));
  final leaf = uniqueGroupName(
    run.label,
    siblingGroupNames(others, const [], parent),
  );
  final prefix = parent == null ? leaf : '$parent/$leaf';
  for (final e in rest.entries) {
    out.groups[e.key] = '$prefix${e.value}';
  }
  return out;
}

/// 위([delta] < 0)·아래로 한 칸: 같은 상위 안에서 앞·뒤의 같은 단계 그룹 블록 또는 상위 직속 항목 하나를 건너뛴다.
/// 상위 밖으로 나가야 하면(상위의 첫·끝) null — 끌어서 옮긴다.
int? groupStepIndex(ContiLayout layout, ContiGroupRun run, int delta) {
  final n = layout.uids.length;
  final neighbor = delta < 0 ? run.start - 1 : run.end;
  if (neighbor < 0 || neighbor >= n) return null;
  final g = layout.groups[layout.uids[neighbor]];
  final parent = run.parent;
  if (parent != null && (g == null || !isUnder(g, parent))) return null;
  if (g != null && groupDepth(g) >= run.depth) {
    final sib = groupRuns(
      layout.uids,
      layout.groups,
      depth: run.depth,
    ).where((r) => delta < 0 ? r.end == run.start : r.start == run.end).first;
    return delta < 0 ? sib.start : sib.end;
  }
  return delta < 0 ? run.start - 1 : run.end + 1;
}

/// 새 그룹: 고른 항목 [uid] 가 있으면 그 항목이 든다. 이미 다른 그룹 안이면 그 맨 위 그룹 끝 바로 뒤로 나온다.
/// (하위 그룹은 [createSubGroupWithItems].)
ContiLayout createGroupWith(ContiLayout layout, int uid, String name) =>
    createGroupWithItems(layout, [uid], name);

/// 새 그룹에 항목 여러 개 [uids] 를 넣는다. 자리는 그중 목록에서 가장 앞 항목 자리 —
/// 그 항목이 다른 그룹 안이면 그 맨 위 그룹 끝 바로 뒤.
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

/// [parent] 그룹 아래에 하위 그룹 [leaf] 를 만들고 항목 [uids] 를 넣는다. 자리는 그중 [parent] 안에 있는
/// 가장 앞 항목 자리(다른 하위 그룹 안이면 그 하위 그룹 앞), 없으면 [parent] 끝.
ContiLayout createSubGroupWithItems(
  ContiLayout layout,
  ContiGroupRun parent,
  Iterable<int> uids,
  String leaf,
) {
  var at = parent.end;
  for (var k = parent.start; k < parent.end; k++) {
    if (uids.contains(layout.uids[k])) {
      at = k;
      break;
    }
  }
  final sub = groupRuns(
    layout.uids,
    layout.groups,
    depth: parent.depth + 1,
  ).where((r) => at >= r.start && at < r.end).firstOrNull;
  return moveItemsTo(layout, uids, (
    index: sub?.start ?? at,
    group: '${parent.name}/$leaf',
  ));
}

String? _replacePrefix(String path, ContiGroupRun run, String? newPrefix) {
  final rest = path.substring(run.name.length); // '' 또는 '/하위...'
  if (newPrefix == null) return rest.isEmpty ? null : rest.substring(1);
  return '$newPrefix$rest';
}

/// 그룹 풀기(항목은 상위에 남는다 — 맨 위 그룹이면 그룹 밖). 하위 그룹은 한 단계 올라온다.
ContiLayout ungroup(ContiLayout layout, ContiGroupRun run) {
  final out = layout.copy();
  for (var k = run.start; k < run.end; k++) {
    final u = layout.uids[k];
    final g = _replacePrefix(layout.groups[u]!, run, run.parent);
    g == null ? out.groups.remove(u) : out.groups[u] = g;
  }
  return out;
}

/// 그룹 이름 바꾸기(그 구간만, 하위 그룹은 따라온다). [leaf] 는 새 이름 한 마디.
ContiLayout renameGroup(ContiLayout layout, ContiGroupRun run, String leaf) {
  final out = layout.copy();
  final prefix = run.parent == null ? leaf : '${run.parent}/$leaf';
  for (var k = run.start; k < run.end; k++) {
    final u = layout.uids[k];
    out.groups[u] = _replacePrefix(layout.groups[u]!, run, prefix)!;
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
/// 닿아 있지 않으면 그룹 밖으로 둔다(이어진 구간이 갈라지지 않게). 하위 그룹이면 닿는 데까지만 쓴다
/// (모든 앞부분 경로가 이어져야 하므로). [emptyGroups] 의 이름은 끝에서 시작할 수 있다.
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
  for (var n = groupDepth(group); n >= 1; n--) {
    final p = pathPrefix(group, n)!;
    if ((prev != null && isUnder(prev, p)) ||
        (next != null && isUnder(next, p))) {
      return p;
    }
  }
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
