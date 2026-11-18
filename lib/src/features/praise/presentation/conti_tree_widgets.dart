import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../app_colors.dart';
import '../domain/conti_tree.dart';
import 'conti_insert_target.dart';

/// 썸네일을 끄는 동안([isActive]) 마우스가 목록 가장자리에 가면 그쪽으로 저절로 스크롤한다.
/// Draggable 은 스스로 스크롤하지 않아서, 멀리 있는 PPT 중간으로 옮기려면 필요하다.
class EdgeAutoScroll extends StatefulWidget {
  const EdgeAutoScroll({
    super.key,
    required this.controller,
    required this.axis,
    required this.isActive,
    required this.onPointerEnd,
    required this.child,
  });

  final ScrollController controller;
  final Axis axis;
  final bool isActive;
  // 손을 떼면(놓기·취소 어느 쪽이든) 부른다. 끄던 썸네일이 사라져 onDragEnd 가 안 와도 끄기를 끝낸다.
  final VoidCallback onPointerEnd;
  final Widget child;

  @override
  State<EdgeAutoScroll> createState() => EdgeAutoScrollState();
}

class EdgeAutoScrollState extends State<EdgeAutoScroll> {
  static const double _edge = 48;
  static const double _maxStep = 18;
  Timer? _timer;
  double _step = 0;
  PointerMoveEvent? _lastMove;

  @override
  void didUpdateWidget(EdgeAutoScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isActive) _stop();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _step = 0;
    _lastMove = null;
  }

  void _onMove(PointerMoveEvent event) {
    if (!widget.isActive) return;
    _lastMove = event;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final local = box.globalToLocal(event.position);
    final pos = widget.axis == Axis.horizontal ? local.dx : local.dy;
    final size = widget.axis == Axis.horizontal
        ? box.size.width
        : box.size.height;
    // 가장자리에 가까울수록 빠르게.
    if (pos < _edge) {
      _step = -_maxStep * ((_edge - pos) / _edge).clamp(0.2, 1.0);
    } else if (pos > size - _edge) {
      _step = _maxStep * ((pos - (size - _edge)) / _edge).clamp(0.2, 1.0);
    } else {
      _stop();
      return;
    }
    _timer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final c = widget.controller;
      if (!c.hasClients || _step == 0) return;
      final pos = c.position;
      final before = pos.pixels;
      c.jumpTo(
        (pos.pixels + _step).clamp(pos.minScrollExtent, pos.maxScrollExtent),
      );
      // Draggable 은 마우스가 움직일 때만 밑에 있는 썸네일을 다시 찾는다. 마우스를 멈춘 채 목록만
      // 흘러가면 스크롤 전 썸네일에 놓이거나(그게 사라졌으면) 놓기가 없어지므로, 같은 자리에서
      // 움직인 것처럼 알려 다시 찾게 한다.
      final last = _lastMove;
      if (last != null && pos.pixels != before) {
        GestureBinding.instance.handlePointerEvent(
          last.copyWith(delta: Offset.zero, timeStamp: last.timeStamp),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerMove: _onMove,
      onPointerUp: (_) {
        _stop();
        widget.onPointerEnd();
      },
      onPointerCancel: (_) {
        _stop();
        widget.onPointerEnd();
      },
      child: widget.child,
    );
  }
}

/// 콘티 목록 스크롤 영역. 끄는 동안 가장자리 자동 스크롤, 목록 아래 빈 자리는 '맨 끝에 놓기' 칸이다.
class ContiTreeList extends StatefulWidget {
  const ContiTreeList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.onEndDrop,
  });

  final int itemCount;

  /// 행 하나. [dragging] 은 끌기 손잡이·머리줄이 끌기 시작·끝을 알리는 값이다.
  final Widget Function(
    BuildContext context,
    int rowIndex,
    ValueNotifier<bool> dragging,
  )
  itemBuilder;
  final void Function(Object data) onEndDrop;

  @override
  State<ContiTreeList> createState() => _ContiTreeListState();
}

class _ContiTreeListState extends State<ContiTreeList> {
  final _controller = ScrollController();
  final _dragging = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _controller.dispose();
    _dragging.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: _dragging,
      builder: (context, dragging, _) => EdgeAutoScroll(
        controller: _controller,
        axis: Axis.vertical,
        isActive: dragging,
        onPointerEnd: () => _dragging.value = false,
        child: CustomScrollView(
          controller: _controller,
          slivers: [
            SliverList.builder(
              itemCount: widget.itemCount,
              itemBuilder: (context, i) =>
                  widget.itemBuilder(context, i, _dragging),
            ),
            SliverFillRemaining(
              hasScrollBody: false,
              child: DragTarget<Object>(
                onWillAcceptWithDetails: (d) =>
                    ContiInsertTarget.accepts(d.data),
                onAcceptWithDetails: (d) => widget.onEndDrop(d.data),
                builder: (context, candidates, _) => Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  alignment: Alignment.topCenter,
                  child: candidates.isEmpty
                      ? null
                      : Container(
                          height: 3,
                          decoration: BoxDecoration(
                            color: cs.primary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _dragFeedback(ColorScheme cs, Widget child) => Transform.translate(
  offset: const Offset(-24, -16),
  child: Material(
    elevation: 4,
    borderRadius: BorderRadius.circular(AppRadius.control),
    color: cs.surface,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: child,
      ),
    ),
  ),
);

/// 항목 행 끝의 끌기 손잡이. 끄는 동안 목록 가장자리 자동 스크롤이 켜진다([dragging]).
class ContiDragHandle extends StatelessWidget {
  const ContiDragHandle({
    super.key,
    required this.data,
    required this.title,
    required this.dragging,
  });

  final ContiRowDrag data;
  final String title;
  final ValueNotifier<bool> dragging;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Draggable<ContiRowDrag>(
      data: data,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _dragFeedback(
        cs,
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13),
        ),
      ),
      onDragStarted: () => dragging.value = true,
      onDragEnd: (_) => dragging.value = false,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(Icons.drag_handle_rounded, color: cs.outline),
        ),
      ),
    );
  }
}

enum _GroupMenu { rename, up, down, ungroup, delete }

/// 그룹 머리줄(폴더). 누르면 접기·펼치기, 끌면 그룹째 이동, 항목을 놓으면 그 그룹에 든다.
/// 빈 그룹([ContiHeaderRow.empty])은 접거나 끌 수 없다.
class ContiGroupHeader extends StatelessWidget {
  const ContiGroupHeader({
    super.key,
    required this.header,
    required this.holdsSelected,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.dragging,
    required this.onDrop,
    required this.onToggle,
    required this.onRename,
    required this.onMove,
    required this.onUngroup,
    required this.onDelete,
  });

  final ContiHeaderRow header;

  /// 접힌 그룹 안에 고른 항목이 있다(머리줄을 고른 색으로).
  final bool holdsSelected;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueNotifier<bool> dragging;
  final void Function(Object data, bool after) onDrop;
  final VoidCallback onToggle;
  final VoidCallback onRename;
  final ValueChanged<int> onMove; // -1 위, 1 아래
  final VoidCallback onUngroup;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final h = header;
    final range = h.empty ? '비어 있음' : '${h.start + 1}~${h.start + h.count}번';
    final body = Material(
      color: holdsSelected ? cs.secondaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.control),
        onTap: h.empty ? null : onToggle,
        child: Semantics(
          label: '${h.name} 그룹, ${h.count}개, ${h.collapsed ? '접힘' : '펼침'}',
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 4, 0, 4),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: h.empty
                      ? null
                      : Icon(
                          h.collapsed
                              ? Icons.chevron_right_rounded
                              : Icons.expand_more_rounded,
                          size: 20,
                          color: cs.onSurfaceVariant,
                        ),
                ),
                Icon(
                  h.collapsed || h.empty
                      ? Icons.folder_rounded
                      : Icons.folder_open_rounded,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    h.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Tooltip(
                  message: range,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${h.count}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                PopupMenuButton<_GroupMenu>(
                  icon: const Icon(Icons.more_horiz_rounded, size: 20),
                  tooltip: '그룹 메뉴',
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(32, 32),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onSelected: (m) => switch (m) {
                    _GroupMenu.rename => onRename(),
                    _GroupMenu.up => onMove(-1),
                    _GroupMenu.down => onMove(1),
                    _GroupMenu.ungroup => onUngroup(),
                    _GroupMenu.delete => onDelete(),
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: _GroupMenu.rename,
                      child: Text('이름 바꾸기'),
                    ),
                    if (!h.empty) ...[
                      PopupMenuItem(
                        value: _GroupMenu.up,
                        enabled: canMoveUp,
                        child: const Text('위로 이동'),
                      ),
                      PopupMenuItem(
                        value: _GroupMenu.down,
                        enabled: canMoveDown,
                        child: const Text('아래로 이동'),
                      ),
                    ],
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: _GroupMenu.ungroup,
                      child: Text(h.empty ? '그룹 지우기' : '그룹 풀기 (항목 유지)'),
                    ),
                    if (!h.empty)
                      const PopupMenuItem(
                        value: _GroupMenu.delete,
                        child: Text('그룹과 항목 삭제…'),
                      ),
                  ],
                ),
                if (h.empty)
                  const SizedBox(width: 36)
                else
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(Icons.drag_handle_rounded, color: cs.outline),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    return ContiInsertTarget(
      intoOnAfter: true,
      onDrop: onDrop,
      child: h.empty
          ? body
          : Draggable<ContiRowDrag>(
              data: ContiRowDrag(h.startUid, isGroup: true),
              dragAnchorStrategy: pointerDragAnchorStrategy,
              feedback: _dragFeedback(
                cs,
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.folder_rounded, size: 18),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '${h.name} · ${h.count}개',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              onDragStarted: () => dragging.value = true,
              onDragEnd: (_) => dragging.value = false,
              child: body,
            ),
    );
  }
}
