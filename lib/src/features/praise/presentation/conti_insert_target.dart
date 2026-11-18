import 'package:flutter/material.dart';

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

/// 행의 위쪽 절반이면 앞([false]), 아래쪽 절반이면 뒤([true]).
bool dropAfterHalf(double dy, double height) => dy > height / 2;

/// [uids] 중 [anchorUid] 행의 앞/뒤에 해당하는 삽입 위치.
/// 기준이 없거나(null) 그 사이 사라졌으면 맨 끝.
int insertIndexFor(List<int> uids, int? anchorUid, bool after) {
  final i = anchorUid == null ? -1 : uids.indexOf(anchorUid);
  if (i < 0) return uids.length;
  return after ? i + 1 : i;
}

/// 콘티 행을 감싸 찬양(`PraiseSong`)·성경 절([BibleVerseDrag])을 끌어 놓을 자리를 알려 준다.
/// 행 위쪽 절반 = 앞, 아래쪽 절반 = 뒤, 놓을 자리에 선을 그린다. [onDrop] 은 (끈 데이터, 뒤 여부).
/// 가장 안쪽 DragTarget 이 이기므로 패널 전체의 '맨 끝에 놓기'는 행 밖에서만 일한다.
/// 이후 그룹 트리 행에서도 그대로 쓴다.
class ContiInsertTarget extends StatefulWidget {
  const ContiInsertTarget({
    super.key,
    required this.onDrop,
    required this.child,
    this.intoOnAfter = false,
  });

  final void Function(Object data, bool after) onDrop;
  final Widget child;

  /// 그룹 머리 행용: 아래 절반은 '그룹 안으로'라 선 대신 행 전체에 테두리를 그린다(그룹째 끌 때는 선).
  final bool intoOnAfter;

  static bool accepts(Object? data) =>
      data is PraiseSong || data is BibleVerseDrag || data is ContiRowDrag;

  @override
  State<ContiInsertTarget> createState() => _ContiInsertTargetState();
}

class _ContiInsertTargetState extends State<ContiInsertTarget> {
  bool? _after; // null = 위에 없음

  bool _afterFor(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return true;
    return dropAfterHalf(box.globalToLocal(global).dy, box.size.height);
  }

  void _set(bool? after) {
    if (_after != after) setState(() => _after = after);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DragTarget<Object>(
      onWillAcceptWithDetails: (d) => ContiInsertTarget.accepts(d.data),
      onMove: (d) => _set(_afterFor(d.offset)),
      onLeave: (_) => _set(null),
      onAcceptWithDetails: (d) {
        final after = _afterFor(d.offset);
        _set(null);
        widget.onDrop(d.data, after);
      },
      builder: (context, candidates, _) {
        final after = _after;
        final into =
            widget.intoOnAfter &&
            after == true &&
            candidates.isNotEmpty &&
            !(candidates.first is ContiRowDrag &&
                (candidates.first as ContiRowDrag).isGroup);
        // 선이 없을 때도 같은 Stack 이라 행 안 위젯 상태가 끌 때마다 새로 만들어지지 않는다.
        return Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            if (into)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: cs.primary, width: 2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              )
            else if (after != null && candidates.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                top: after ? null : 0,
                bottom: after ? 0 : null,
                child: IgnorePointer(
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
