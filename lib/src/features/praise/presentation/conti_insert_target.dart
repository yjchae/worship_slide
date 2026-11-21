import 'package:flutter/material.dart';

import '../domain/conti_tree.dart';
import '../domain/praise_song.dart';
import '../domain/staging_item.dart';

/// 성경 검색 탭 절 손잡이를 끌 때 실리는 데이터.
/// 놓는 순간 [build] 를 불러 항목을 만든다(보조 역본을 DB 에서 읽느라 비동기).
/// 어떤 절을 담을지는 [build] 가 불리는 순간에 정한다 — 고른 절이 있고 그중 하나를 끌었으면 고른 전부.
class BibleVerseDrag {
  const BibleVerseDrag(this.build);

  final Future<List<BibleStagingItem>> Function() build;
}

/// 콘티 목록 안에서 항목 하나([isGroup] 면 그룹 블록)를 끌 때 실리는 데이터. [uid] 는 항목 uid,
/// 그룹이면 그 그룹 첫 항목 uid.
class ContiRowDrag {
  const ContiRowDrag(this.uid, {this.isGroup = false, this.uids});
  final int uid;
  final bool isGroup;

  /// 여러 항목을 고른 채 그중 하나를 끌었을 때 고른 전부(목록 순서). null = 이 항목 하나.
  final List<int>? uids;
}

/// 그룹째 끄는 데이터(빈 그룹은 [startUid] -1). 하위 그룹은 상위와 첫 항목 uid 가 같을 수 있어 경로로 가른다.
class ContiGroupDrag extends ContiRowDrag {
  const ContiGroupDrag(this.path, int startUid)
    : super(startUid, isGroup: true);
  final String path;
}

/// 행의 위쪽 절반이면 앞([false]), 아래쪽 절반이면 뒤([true]).
bool dropAfterHalf(double dy, double height) => dy > height / 2;

/// [uids] 중 [anchorUid] 행의 앞/뒤에 해당하는 삽입 위치.
/// 기준이 없거나(null) 그 사이 사라졌으면 맨 끝.
int insertIndexFor(List<int> uids, int? anchorUid, bool after) {
  final i = anchorUid == null ? -1 : uids.indexOf(anchorUid);
  if (i < 0) return uids.length;
  return after ? i + 1 : i;
}

/// 끄는 중 놓을 자리 안내(머리줄·행·고스트가 같이 본다). [sourcePath] = 끄는 그룹 경로(없으면 항목·곡·성경),
/// [kind] = 지금 마우스 아래 구역(null = 놓을 곳을 찾는 중), [targetPath] = 놓으면 들어갈 그룹(블록 배경용).
enum ContiHintKind { line, into, reject }

class ContiDropHint {
  const ContiDropHint({
    this.sourcePath,
    this.kind,
    this.message = '',
    this.targetPath,
  });
  final String? sourcePath;
  final ContiHintKind? kind;
  final String message;
  final String? targetPath;

  /// 구역에서 벗어났다: 끄는 그룹이 없으면 안내 자체가 없다.
  ContiDropHint? get cleared =>
      sourcePath == null ? null : ContiDropHint(sourcePath: sourcePath);

  @override
  bool operator ==(Object other) =>
      other is ContiDropHint &&
      other.sourcePath == sourcePath &&
      other.kind == kind &&
      other.message == message &&
      other.targetPath == targetPath;

  @override
  int get hashCode => Object.hash(sourcePath, kind, message, targetPath);
}

/// [ContiTreeList] 가 내려 주는 안내 값. 없으면(단독 사용) 안내 없이 선·테두리만 그린다.
class ContiDropHintScope extends InheritedWidget {
  const ContiDropHintScope({
    super.key,
    required this.hint,
    required super.child,
  });
  final ValueNotifier<ContiDropHint?> hint;

  static ValueNotifier<ContiDropHint?>? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ContiDropHintScope>()?.hint;

  @override
  bool updateShouldNotify(ContiDropHintScope old) => hint != old.hint;
}

/// 콘티 행을 감싸 찬양(`PraiseSong`)·성경 절([BibleVerseDrag])·콘티 항목·그룹을 끌어 놓을 자리를 알려 준다.
/// 항목·곡·성경은 행 위쪽 절반 = 앞, 아래쪽 절반 = 뒤(그룹 머리줄이면 아래 절반 = 안으로).
/// 그룹을 끌 때 머리줄은 [groupDropZone] 3구역(앞/안으로/뒤), 빈 그룹 머리줄은 무엇이든 안으로.
/// [onDrop] 은 (끈 데이터, 구역). 가장 안쪽 DragTarget 이 이기므로 패널 전체 '맨 끝에 놓기'는 행 밖에서만 일한다.
class ContiInsertTarget extends StatefulWidget {
  const ContiInsertTarget({
    super.key,
    required this.onDrop,
    required this.child,
    this.groupPath,
    this.isHeader = false,
    this.collapsed = false,
    this.empty = false,
    this.label,
    this.rejectOf,
  });

  final void Function(Object data, ContiDropZone zone) onDrop;
  final Widget child;

  /// 이 행이 든 그룹(머리줄이면 그 그룹 자신). 블록 배경·안내에 쓴다.
  final String? groupPath;
  final bool isHeader;
  final bool collapsed;
  final bool empty;

  /// 머리줄 안내 문구에 들어갈 그룹 이름.
  final String? label;

  /// 놓을 수 없는 자리인지(그룹 끌기만 뜻이 있다). noChange 는 아무 표시도 안 한다.
  final ContiDropReject? Function(Object data, ContiDropZone zone)? rejectOf;

  static bool accepts(Object? data) =>
      data is PraiseSong || data is BibleVerseDrag || data is ContiRowDrag;

  @override
  State<ContiInsertTarget> createState() => _ContiInsertTargetState();
}

class _ContiInsertTargetState extends State<ContiInsertTarget> {
  ContiDropZone? _zone; // null = 위에 없음
  ContiDropReject? _reject;
  bool _group = false;

  ContiDropZone _zoneFor(Object data, Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return ContiDropZone.after;
    final dy = box.globalToLocal(global).dy;
    if (widget.isHeader && widget.empty) return ContiDropZone.into;
    if (widget.isHeader && data is ContiGroupDrag) {
      return groupDropZone(
        dy,
        box.size.height,
        collapsed: widget.collapsed,
        empty: widget.empty,
      );
    }
    return dropAfterHalf(dy, box.size.height)
        ? ContiDropZone.after
        : ContiDropZone.before;
  }

  // 머리줄 아래 절반(그룹이 아닌 것) 또는 into 구역 = 안으로 들어간다.
  bool _isInto(ContiDropZone z) =>
      widget.isHeader &&
      (z == ContiDropZone.into || (!_group && z == ContiDropZone.after));

  void _update(Object data, ContiDropZone? zone) {
    if (zone == null) {
      if (_zone == null) return;
      setState(() => _zone = _reject = null);
      final hint = ContiDropHintScope.maybeOf(context);
      if (hint != null) hint.value = hint.value?.cleared;
      return;
    }
    final reject = widget.rejectOf?.call(data, zone);
    final group = data is ContiGroupDrag;
    if (_zone == zone && _reject == reject && _group == group) return;
    setState(() {
      _zone = zone;
      _reject = reject;
      _group = group;
    });
    final hint = ContiDropHintScope.maybeOf(context);
    if (hint == null) return;
    final name = widget.label ?? '';
    final into = _isInto(zone);
    final ContiHintKind? kind = reject == ContiDropReject.noChange
        ? null
        : reject != null
        ? ContiHintKind.reject
        : into
        ? ContiHintKind.into
        : ContiHintKind.line;
    hint.value = ContiDropHint(
      sourcePath: hint.value?.sourcePath,
      kind: kind,
      message: switch (reject) {
        ContiDropReject.self => '자기 안에는 못 넣어요',
        ContiDropReject.tooDeep => '3단까지만',
        _ when !group => '',
        _ when !widget.isHeader => '여기에 놓기',
        _ when zone == ContiDropZone.before => "'$name' 앞에 놓기",
        _ when into && widget.collapsed => "'$name' 맨 끝에",
        _ when into => "'$name' 안으로",
        _ => "'$name' 뒤에 놓기",
      },
      targetPath: kind == null
          ? null
          : (into || !widget.isHeader ? widget.groupPath : null),
    );
  }

  Widget _chip(ColorScheme cs, String text, {required bool error}) =>
      Positioned(
        right: 80,
        top: 0,
        bottom: 0,
        child: IgnorePointer(
          child: Center(
            child: Container(
              height: 20,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: error ? cs.error : cs.primary,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (error)
                    Icon(Icons.block_rounded, size: 12, color: cs.onError),
                  if (error) const SizedBox(width: 3),
                  Text(
                    text,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: error ? cs.onError : cs.onPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DragTarget<Object>(
      onWillAcceptWithDetails: (d) => ContiInsertTarget.accepts(d.data),
      onMove: (d) => _update(d.data, _zoneFor(d.data, d.offset)),
      onLeave: (_) => _update(Object(), null),
      onAcceptWithDetails: (d) {
        final zone = _zoneFor(d.data, d.offset);
        _update(d.data, null);
        widget.onDrop(d.data, zone);
      },
      builder: (context, candidates, _) {
        final zone = candidates.isEmpty ? null : _zone;
        final reject = _reject;
        final shown = reject != ContiDropReject.noChange;
        final isReject = zone != null && reject != null && shown;
        final into = zone != null && shown && !isReject && _isInto(zone);
        // 선이 없을 때도 같은 Stack 이라 행 안 위젯 상태가 끌 때마다 새로 만들어지지 않는다.
        return MouseRegion(
          cursor: isReject ? SystemMouseCursors.forbidden : MouseCursor.defer,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              widget.child,
              if ((into || isReject) && widget.isHeader) ...[
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: isReject ? cs.error : cs.primary,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                ),
                _chip(
                  cs,
                  isReject
                      ? (reject == ContiDropReject.self
                            ? '자기 안에는 못 넣어요'
                            : '3단까지만')
                      : widget.collapsed
                      ? "'${widget.label}' 맨 끝에"
                      : "'${widget.label}' 안으로",
                  error: isReject,
                ),
              ] else if (zone != null && shown)
                Positioned(
                  left: 0,
                  right: 0,
                  top: zone == ContiDropZone.before ? 0 : null,
                  bottom: zone == ContiDropZone.before ? null : 0,
                  child: IgnorePointer(
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: isReject ? cs.error : cs.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
