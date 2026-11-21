import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
/// [rowPath] 가 행이 든 그룹 경로(머리줄이면 그 그룹)를 알려 주면, 끄는 그룹 블록은 흐리게·놓을 그룹 블록은 옅게 칠한다.
class ContiTreeList extends StatefulWidget {
  const ContiTreeList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.onEndDrop,
    this.rowPath,
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
  final String? Function(int rowIndex)? rowPath;

  @override
  State<ContiTreeList> createState() => _ContiTreeListState();
}

class _ContiTreeListState extends State<ContiTreeList> {
  final _controller = ScrollController();
  final _dragging = ValueNotifier<bool>(false);
  final _hint = ValueNotifier<ContiDropHint?>(null);

  @override
  void dispose() {
    _controller.dispose();
    _dragging.dispose();
    _hint.dispose();
    super.dispose();
  }

  Widget _row(BuildContext context, int i, ColorScheme cs) {
    final child = widget.itemBuilder(context, i, _dragging);
    final path = widget.rowPath?.call(i);
    if (path == null) return child;
    // 행 위젯의 key 를 그대로 물려 받아 행 상태(편집 중 입력칸 등)가 다른 행으로 옮겨 가지 않게 한다.
    return ValueListenableBuilder<ContiDropHint?>(
      key: child.key,
      valueListenable: _hint,
      child: child,
      builder: (context, h, child) {
        final target = h?.targetPath;
        final tinted =
            target != null && h!.kind != null && isUnder(path, target);
        final c = h?.kind == ContiHintKind.reject ? cs.error : cs.primary;
        final source = h?.sourcePath;
        // 안내가 오가도 child 가 다시 만들어지지 않게 늘 같은 위젯 모양으로 감싼다.
        return Opacity(
          opacity: source != null && isUnder(path, source) ? 0.4 : 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tinted
                  ? c.withValues(
                      alpha: h.kind == ContiHintKind.line ? 0.05 : 0.08,
                    )
                  : null,
            ),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ContiDropHintScope(
      hint: _hint,
      child: ValueListenableBuilder<bool>(
        valueListenable: _dragging,
        builder: (context, dragging, _) => EdgeAutoScroll(
          controller: _controller,
          axis: Axis.vertical,
          isActive: dragging,
          onPointerEnd: () {
            _dragging.value = false;
            _hint.value = null;
          },
          child: CustomScrollView(
            controller: _controller,
            slivers: [
              SliverList.builder(
                itemCount: widget.itemCount,
                itemBuilder: (context, i) => _row(context, i, cs),
              ),
              SliverFillRemaining(
                hasScrollBody: false,
                child: DragTarget<Object>(
                  onWillAcceptWithDetails: (d) =>
                      ContiInsertTarget.accepts(d.data),
                  onMove: (d) {
                    final h = _hint.value;
                    if (h?.sourcePath != null) {
                      _hint.value = ContiDropHint(
                        sourcePath: h!.sourcePath,
                        kind: ContiHintKind.line,
                        message: '맨 끝 (그룹 밖)',
                      );
                    }
                  },
                  onLeave: (_) => _hint.value = _hint.value?.cleared,
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

/// 그룹 안 행을 [depth] 단계만큼 들여쓰고 단계마다 왼쪽에 세로 가이드선을 긋는다. 0 이면 그대로.
Widget contiIndent(ColorScheme cs, int depth, Widget child) {
  for (var i = 0; i < depth; i++) {
    child = Container(
      margin: const EdgeInsets.only(left: 14),
      padding: const EdgeInsets.only(left: 6),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: cs.outlineVariant, width: 2)),
      ),
      child: child,
    );
  }
  return child;
}

enum _GroupMenu { rename, sub, moveInto, up, down, ungroup, delete }

/// ⋯ 메뉴 '다른 그룹 안으로 이동'에 뜨는 목적지 하나.
typedef ContiMoveTarget = ({String label, VoidCallback pick});

/// 끄는 그룹의 고스트: 폴더·이름·개수 한 줄 + 놓을 자리 문구 한 줄, 뒤에 한 장 겹친다.
Widget _groupGhost(
  ColorScheme cs,
  String title,
  ValueNotifier<ContiDropHint?>? hint,
) => Transform.translate(
  offset: const Offset(-24, -16),
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 260),
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 4,
          top: 4,
          right: -4,
          bottom: -4,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
          ),
        ),
        Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(AppRadius.control),
          color: cs.surface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.folder_rounded, size: 18),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
                if (hint != null)
                  ValueListenableBuilder<ContiDropHint?>(
                    valueListenable: hint,
                    builder: (context, h, _) => Semantics(
                      liveRegion: true,
                      child: Text(
                        h?.kind == null || h!.message.isEmpty
                            ? '놓을 곳을 찾는 중'
                            : h.message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: h?.kind == ContiHintKind.reject
                              ? cs.error
                              : cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  ),
);

/// 이름 칸에 `/` 를 못 쓰게 막고 알린다(하위 그룹 경로 구분자라서).
class _NoSlash extends TextInputFormatter {
  _NoSlash(this.onReject);
  final VoidCallback onReject;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!newValue.text.contains('/')) return newValue;
    onReject();
    final t = newValue.text.replaceAll('/', '');
    return TextEditingValue(
      text: t,
      selection: TextSelection.collapsed(
        offset: newValue.selection.baseOffset.clamp(0, t.length),
      ),
    );
  }
}

/// 그룹 머리줄(폴더). 누르면 접기·펼치기, 끌면 그룹째 이동, 무엇이든 놓으면 그 그룹에 든다.
/// hover 하면 `+`(빈 하위 그룹 즉시 만들기), [editing] 이면 이름을 그 자리에서 고친다.
/// 빈 그룹([ContiHeaderRow.empty])은 접을 수 없고 힌트를 보인다.
class ContiGroupHeader extends StatefulWidget {
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
    required this.onCreateSub,
    required this.onMove,
    required this.onUngroup,
    required this.onDelete,
    this.rejectOf,
    this.onAddSub,
    this.moveTargets,
    this.editing = false,
    this.editIsNew = false,
    this.onSubmitName,
    this.onCancelEdit,
  });

  final ContiHeaderRow header;

  /// 접힌 그룹 안에 고른 항목이 있다(머리줄을 고른 색으로).
  final bool holdsSelected;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueNotifier<bool> dragging;
  final void Function(Object data, ContiDropZone zone) onDrop;
  final ContiDropReject? Function(Object data, ContiDropZone zone)? rejectOf;
  final VoidCallback onToggle;
  final VoidCallback onRename;
  final VoidCallback onCreateSub;

  /// `+` 버튼: 대화 없이 빈 하위 그룹을 만들고 그 이름을 편집 상태로 연다.
  final VoidCallback? onAddSub;
  final List<ContiMoveTarget> Function()? moveTargets;
  final ValueChanged<int> onMove; // -1 위, 1 아래
  final VoidCallback onUngroup;
  final VoidCallback onDelete;

  /// 이름 인라인 편집 중. [editIsNew] = 방금 만든 그룹(Esc·바깥 클릭이 기본 이름 유지), 아니면 이름 바꾸기
  /// (Esc 취소·바깥 클릭 확정). Enter 는 둘 다 확정.
  final bool editing;
  final bool editIsNew;
  final ValueChanged<String>? onSubmitName;
  final VoidCallback? onCancelEdit;

  @override
  State<ContiGroupHeader> createState() => _ContiGroupHeaderState();
}

class _ContiGroupHeaderState extends State<ContiGroupHeader> {
  final _focus = FocusNode();
  final _text = TextEditingController();
  bool _hover = false;
  bool _plusFocus = false;
  bool _slash = false;
  bool _slashNow = false; // 이번 입력에서 막은 참이면 onChanged 가 경고를 지우지 않는다
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    if (widget.editing) _startEdit();
  }

  @override
  void didUpdateWidget(ContiGroupHeader old) {
    super.didUpdateWidget(old);
    if (widget.editing && !old.editing) _startEdit();
  }

  @override
  void dispose() {
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _startEdit() {
    _done = false;
    _slash = false;
    _text.value = TextEditingValue(
      text: widget.header.label,
      selection: TextSelection(
        baseOffset: 0,
        extentOffset: widget.header.label.length,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.editing) return;
      _focus.requestFocus();
      Scrollable.maybeOf(
        context,
      )?.position.ensureVisible(context.findRenderObject()!);
    });
  }

  void _onFocus() {
    if (!_focus.hasFocus && widget.editing && !_done) {
      _finish(commit: !widget.editIsNew);
    }
  }

  void _finish({required bool commit}) {
    if (_done) return;
    _done = true;
    if (commit) {
      widget.onSubmitName?.call(_text.text);
    } else {
      widget.onCancelEdit?.call();
    }
  }

  Future<void> _openMoveMenu() async {
    final targets = widget.moveTargets?.call() ?? const [];
    final box = context.findRenderObject() as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final at = box.localToGlobal(
      Offset(box.size.width - 40, box.size.height),
      ancestor: overlay,
    );
    final picked = await showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: targets.isEmpty
          ? const [
              PopupMenuItem<int>(
                enabled: false,
                child: Text('옮길 수 있는 그룹이 없어요'),
              ),
            ]
          : [
              for (var i = 0; i < targets.length; i++)
                PopupMenuItem<int>(value: i, child: Text(targets[i].label)),
            ],
    );
    if (picked != null) targets[picked].pick();
  }

  Widget _plus(ColorScheme cs) {
    final h = widget.header;
    if (h.depth >= maxGroupDepth || widget.onAddSub == null) {
      return const SizedBox(width: 28);
    }
    return AnimatedOpacity(
      opacity: (_hover || _plusFocus) && !widget.editing ? 1 : 0,
      duration: const Duration(milliseconds: 120),
      child: Semantics(
        button: true,
        label: "'${h.label}' 안에 하위 그룹 추가",
        excludeSemantics: true,
        child: Tooltip(
          message: '하위 그룹 추가',
          child: InkWell(
            customBorder: const CircleBorder(),
            hoverColor: cs.surfaceContainerHighest,
            focusColor: Colors.transparent,
            onFocusChange: (f) => setState(() => _plusFocus = f),
            onTap: widget.editing ? null : widget.onAddSub,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: _plusFocus
                    ? Border.all(color: cs.secondary, width: 2)
                    : null,
              ),
              child: Icon(
                Icons.add_rounded,
                size: 18,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _nameField(ColorScheme cs) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.control),
      borderSide: BorderSide(color: cs.primary),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Focus(
          onKeyEvent: (_, e) {
            if (e is KeyDownEvent &&
                e.logicalKey == LogicalKeyboardKey.escape) {
              _finish(commit: false);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: SizedBox(
            height: 28,
            child: TextField(
              controller: _text,
              focusNode: _focus,
              maxLength: 12,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              inputFormatters: [
                _NoSlash(() {
                  _slashNow = true;
                  if (!_slash) setState(() => _slash = true);
                }),
              ],
              onChanged: (_) {
                if (_slashNow) {
                  _slashNow = false;
                } else if (_slash) {
                  setState(() => _slash = false);
                }
              },
              onSubmitted: (_) => _finish(commit: true),
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                filled: true,
                fillColor: cs.surface,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                enabledBorder: border,
                focusedBorder: border,
              ),
            ),
          ),
        ),
        if (_slash)
          Text(
            '이름에 / 는 쓸 수 없어요',
            style: TextStyle(fontSize: 11, color: cs.error),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final h = widget.header;
    final editing = widget.editing;
    final hint = ContiDropHintScope.maybeOf(context);
    final range = h.empty ? '비어 있음' : '${h.start + 1}~${h.start + h.count}번';
    final menuDim = editing ? 0.4 : 1.0;
    final body = Material(
      color: widget.holdsSelected ? cs.secondaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.control),
        onTap: h.empty || editing ? null : widget.onToggle,
        child: Semantics(
          label:
              '${groupLabel(h.name)} 그룹, ${h.depth}단계, '
              '${h.empty ? '비어 있음' : '${h.count}개'}'
              '${h.empty
                  ? ''
                  : h.collapsed
                  ? ', 접힘'
                  : ', 펼침'}',
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 4, 0, 4),
            child: LayoutBuilder(
              builder: (context, box) => Row(
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
                    h.empty
                        ? Icons.folder_outlined
                        : h.collapsed
                        ? Icons.folder_rounded
                        : Icons.folder_open_rounded,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: editing
                        ? _nameField(cs)
                        : Text(
                            h.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                  if (h.empty)
                    // 좁으면 힌트는 생략한다.
                    if (box.maxWidth >= 300)
                      Flexible(
                        child: Tooltip(
                          message: '빈 그룹은 저장하지 않아요. 항목을 넣으면 저장돼요.',
                          child: ValueListenableBuilder<bool>(
                            valueListenable: widget.dragging,
                            builder: (context, drag, _) => Text(
                              '여기에 끌어 놓기',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: drag
                                    ? cs.onSurface
                                    : cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      )
                    else
                      const SizedBox.shrink()
                  else
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
                  _plus(cs),
                  Opacity(
                    opacity: menuDim,
                    child: PopupMenuButton<_GroupMenu>(
                      icon: const Icon(Icons.more_horiz_rounded, size: 20),
                      tooltip: '그룹 메뉴',
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(32, 32),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onSelected: (m) => switch (m) {
                        _GroupMenu.rename => widget.onRename(),
                        _GroupMenu.sub => widget.onCreateSub(),
                        _GroupMenu.moveInto => _openMoveMenu(),
                        _GroupMenu.up => widget.onMove(-1),
                        _GroupMenu.down => widget.onMove(1),
                        _GroupMenu.ungroup => widget.onUngroup(),
                        _GroupMenu.delete => widget.onDelete(),
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: _GroupMenu.rename,
                          child: Text('이름 바꾸기'),
                        ),
                        PopupMenuItem(
                          value: _GroupMenu.sub,
                          enabled: h.depth < maxGroupDepth,
                          child: h.depth < maxGroupDepth
                              ? const Text('하위 그룹 만들기')
                              : const Tooltip(
                                  message: '3단까지만 만들 수 있어요',
                                  child: Text('하위 그룹 만들기'),
                                ),
                        ),
                        if (widget.moveTargets != null)
                          const PopupMenuItem(
                            value: _GroupMenu.moveInto,
                            child: Text('다른 그룹 안으로 이동 ▸'),
                          ),
                        if (!h.empty) ...[
                          PopupMenuItem(
                            value: _GroupMenu.up,
                            enabled: widget.canMoveUp,
                            child: const Text('위로 이동'),
                          ),
                          PopupMenuItem(
                            value: _GroupMenu.down,
                            enabled: widget.canMoveDown,
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
                  ),
                  Opacity(
                    opacity: menuDim,
                    child: Tooltip(
                      message: '끌어서 옮기기. 다른 그룹 위에 놓으면 그 안으로 들어가요',
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            Icons.drag_handle_rounded,
                            color: cs.outline,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final outlined = h.empty
        ? ValueListenableBuilder<bool>(
            valueListenable: widget.dragging,
            builder: (context, drag, child) => DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: drag ? cs.outline : cs.outlineVariant,
                ),
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: child,
            ),
            child: body,
          )
        : body;
    return contiIndent(
      cs,
      h.depth - 1,
      ContiInsertTarget(
        isHeader: true,
        groupPath: h.name,
        collapsed: h.collapsed,
        empty: h.empty,
        label: h.label,
        rejectOf: widget.rejectOf,
        onDrop: widget.onDrop,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Draggable<ContiRowDrag>(
            data: ContiGroupDrag(h.name, h.startUid),
            maxSimultaneousDrags: editing ? 0 : 1,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: _groupGhost(
              cs,
              h.empty ? h.label : '${h.label} · ${h.count}개',
              hint,
            ),
            onDragStarted: () {
              widget.dragging.value = true;
              hint?.value = ContiDropHint(sourcePath: h.name);
            },
            onDragEnd: (_) {
              widget.dragging.value = false;
              hint?.value = null;
            },
            child: outlined,
          ),
        ),
      ),
    );
  }
}
