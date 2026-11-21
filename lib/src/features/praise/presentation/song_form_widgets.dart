import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_colors.dart';
import '../domain/song_form.dart';

/// 송폼 화면 부품과 편집 규칙. 기획 `.claude-office/work/20261121-1510-song-form/01-디자인.md`.
/// 색은 colorScheme·AppColors 토큰만 쓴다(초록·와인 금지). 관객 화면·PPTX 로는 가지 않는다.

// ── 편집 규칙(순수 함수) ────────────────────────────────────────────────────

enum KindState { none, some, all }

/// 고른 행들 중 [match] 인 라벨을 가진 행이 없음/일부/전부.
KindState selectionState(
  List<List<SectionLabel>> rows,
  bool Function(SectionLabel) match,
) {
  if (rows.isEmpty) return KindState.none;
  final n = rows.where((r) => r.any(match)).length;
  return n == 0
      ? KindState.none
      : n == rows.length
      ? KindState.all
      : KindState.some;
}

/// 종류 칩 한 번. 고른 행 전부가 그 종류를 가졌으면 그 종류 라벨을 모두 빼고,
/// 아니면 [songLabels](곡 전체 라벨)로 새 라벨 **하나**를 정해 없는 행에 붙인다(여러 행 = 같은 라벨).
/// 돌려주는 값 = 행마다 새 라벨 목록(고른 행과 같은 순서)과 새로 붙인 라벨(뺐으면 null).
({List<List<SectionLabel>> rows, SectionLabel? added}) toggleKind(
  List<List<SectionLabel>> rows,
  SectionKind kind,
  Iterable<Iterable<SectionLabel>> songLabels,
) {
  if (selectionState(rows, (l) => l.kind == kind) == KindState.all) {
    return (
      rows: [
        for (final r in rows)
          [
            for (final l in r)
              if (l.kind != kind) l,
          ],
      ],
      added: null,
    );
  }
  final label = autoLabel(kind, songLabels);
  return (
    rows: [
      for (final r in rows)
        r.any((l) => l.kind == kind) ? r : mergeLabels(r, [label]),
    ],
    added: label,
  );
}

/// 같은 라벨 칩(직접 입력) 한 번. 전부 가졌으면 빼고, 아니면 없는 행에 붙인다.
({List<List<SectionLabel>> rows, SectionLabel? added}) toggleLabel(
  List<List<SectionLabel>> rows,
  SectionLabel label,
) {
  if (selectionState(rows, (l) => l == label) == KindState.all) {
    return (
      rows: [
        for (final r in rows)
          [
            for (final l in r)
              if (l != label) l,
          ],
      ],
      added: null,
    );
  }
  return (
    rows: [
      for (final r in rows) r.contains(label) ? r : mergeLabels(r, [label]),
    ],
    added: label,
  );
}

/// 후렴 제안: [from] 행들과 원본 글이 같은데 [label] 이 없는 다른 행 번호들.
List<int> sameTextRowsWithout(
  List<String> originals,
  List<List<SectionLabel>> labels,
  Iterable<int> from,
  SectionLabel label,
) {
  final source = {
    for (final r in from)
      if (originals[r].trim().isNotEmpty) originals[r].trim(),
  };
  final fromSet = from.toSet();
  return [
    for (var i = 0; i < originals.length; i++)
      if (!fromSet.contains(i) &&
          source.contains(originals[i].trim()) &&
          !labels[i].contains(label))
        i,
  ];
}

/// 번호 스텝퍼: 1 에서 − = 번호 없음, 번호 없음에서 ＋ = 1. 범위 밖이면 null.
int? stepLabelNumber(int? num, int delta) {
  if (delta < 0) return num == null ? null : (num <= 1 ? null : num - 1);
  return num == null ? 1 : (num >= kMaxLabelNumber ? num : num + 1);
}

// ── 공용 칩 ────────────────────────────────────────────────────────────────

/// 약어 12px w600 라벨 칩 하나(22px). [filled] = 붙은 라벨, 아니면 테두리만.
class FormLabelChip extends StatelessWidget {
  const FormLabelChip({
    super.key,
    required this.text,
    this.semanticsLabel,
    this.onTap,
    this.filled = true,
  });

  final String text;
  final String? semanticsLabel;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: onTap != null,
      label: semanticsLabel ?? text,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: Container(
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: filled ? cs.onSurface.withValues(alpha: 0.12) : null,
            border: filled ? null : Border.all(color: cs.outlineVariant),
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1,
              color: filled ? cs.onSurface : cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

double _chipWidth(String text) =>
    16 +
    text.runes.fold<double>(0, (w, r) => w + (r > 0x2e80 ? 12.0 : 7.5)) +
    4;

/// 한 행의 라벨 칩 줄: `[V2][PC]` + `+ 송폼`(라벨이 없을 때) / `+`(있을 때). 폭이 모자라면 `+N` 으로 접는다.
/// 칩이나 `+N` 을 누르면 [onLabelTap](그 라벨 번호), `+ 송폼` 을 누르면 [onAdd].
/// [hiddenLabels] 가 있으면(글이 바뀌어 숨긴 라벨) `! 송폼 확인` 칩이 대신 붙는다.
class FormRowLine extends StatelessWidget {
  const FormRowLine({
    super.key,
    required this.labels,
    required this.emphasized,
    required this.onLabelTap,
    required this.onAdd,
    this.hiddenLabels,
    this.onHiddenTap,
  });

  final List<SectionLabel> labels;

  /// 이 행이 골라졌거나 포커스가 있을 때 — `+ 송폼` 을 진하게.
  final bool emphasized;
  final void Function(int index) onLabelTap;
  final VoidCallback onAdd;
  final List<SectionLabel>? hiddenLabels;
  final VoidCallback? onHiddenTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SizedBox(
        height: 22,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final reserve =
                (hiddenLabels != null ? 90.0 : 0.0) +
                (labels.isEmpty ? 70 : 30);
            var room = constraints.maxWidth - reserve;
            var shown = 0;
            for (final l in labels) {
              final w = _chipWidth(l.abbr) + 4;
              if (room < w) break;
              room -= w;
              shown++;
            }
            if (shown == 0 && labels.isNotEmpty) shown = 1;
            final folded = labels.length - shown;
            return Row(
              children: [
                for (var i = 0; i < shown; i++) ...[
                  FormLabelChip(
                    text: labels[i].abbr,
                    semanticsLabel: '송폼 ${labels[i].korean}, 눌러서 고치기',
                    onTap: () => onLabelTap(i),
                  ),
                  const SizedBox(width: 4),
                ],
                if (folded > 0) ...[
                  FormLabelChip(
                    text: '+$folded',
                    semanticsLabel: '숨은 송폼 $folded개 보기',
                    onTap: () => onLabelTap(shown),
                  ),
                  const SizedBox(width: 4),
                ],
                if (labels.isEmpty)
                  FormLabelChip(
                    text: '+ 송폼',
                    semanticsLabel: '송폼 붙이기',
                    filled: false,
                    onTap: onAdd,
                  )
                else
                  Tooltip(
                    message: '송폼 더하기',
                    child: InkWell(
                      onTap: onAdd,
                      borderRadius: BorderRadius.circular(AppRadius.control),
                      child: Icon(
                        Icons.add_rounded,
                        size: 16,
                        color: emphasized ? cs.onSurface : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (hiddenLabels != null) ...[
                  const SizedBox(width: 6),
                  _CheckChip(
                    text: '송폼 확인',
                    semanticsLabel: '송폼 확인 필요, 숨긴 라벨 보기',
                    onTap: onHiddenTap,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// `! 송폼 확인` — 점선 대신 얇은 무채색 테두리(경고색 금지). 코드 `ChordCheckChip` 과 같은 톤.
class _CheckChip extends StatelessWidget {
  const _CheckChip({required this.text, this.semanticsLabel, this.onTap});

  final String text;
  final String? semanticsLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: semanticsLabel ?? text,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: Container(
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: cs.outline),
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          child: Text(
            '! $text',
            style: TextStyle(
              fontSize: 12,
              height: 1,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

// ── 아래 송폼 칩 바 ────────────────────────────────────────────────────────

/// 창 아래 고정 칩 바(44px). 종류마다 `한글 약어` 칩, 폭 [narrowWidth] 미만이면 약어만(툴팁에 한글).
/// 고른 행 전부가 가진 종류 = 선택(2px 테두리), 일부만 = 반선택(1px primary).
class SongFormBar extends StatefulWidget {
  const SongFormBar({
    super.key,
    required this.kindState,
    required this.customLabels,
    required this.labelState,
    required this.selectedCount,
    required this.clearEnabled,
    required this.onKind,
    required this.onCustom,
    required this.onClear,
  });

  static const narrowWidth = 1100.0;
  static const maxCustomChips = 4;

  final KindState Function(SectionKind kind) kindState;

  /// 이 곡에서 쓴 직접 입력 라벨(칩으로 남아 다시 쓴다, 최대 4개).
  final List<SectionLabel> customLabels;
  final KindState Function(SectionLabel label) labelState;
  final int selectedCount;
  final bool clearEnabled;
  final void Function(SectionKind kind) onKind;
  final void Function(SectionLabel label) onCustom;
  final VoidCallback onClear;

  @override
  State<SongFormBar> createState() => _SongFormBarState();
}

class _SongFormBarState extends State<SongFormBar> {
  bool _typing = false;
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startTyping() {
    setState(() => _typing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _stopTyping() {
    _controller.clear();
    setState(() => _typing = false);
  }

  void _submit() {
    final label = SectionLabel.custom(_controller.text);
    _stopTyping();
    if (label != null) widget.onCustom(label); // 빈 값은 무시
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final kinds = [
      for (final k in SectionKind.values)
        if (k != SectionKind.custom) k,
    ];
    return SizedBox(
      height: 44,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < SongFormBar.narrowWidth;
          return Row(
            children: [
              Text(
                '송폼',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FocusTraversalGroup(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final k in kinds) ...[
                          _BarChip(
                            korean: kSectionKinds[k]!.korean,
                            abbr: kSectionKinds[k]!.abbr,
                            narrow: narrow,
                            state: widget.kindState(k),
                            onTap: () => widget.onKind(k),
                          ),
                          const SizedBox(width: 6),
                        ],
                        for (final l in widget.customLabels) ...[
                          _BarChip(
                            korean: l.customText,
                            abbr: '',
                            narrow: false,
                            state: widget.labelState(l),
                            onTap: () => widget.onCustom(l),
                          ),
                          const SizedBox(width: 6),
                        ],
                        if (_typing)
                          SizedBox(
                            width: 120,
                            height: 28,
                            child: Focus(
                              onKeyEvent: (node, event) {
                                if (event is KeyDownEvent &&
                                    event.logicalKey ==
                                        LogicalKeyboardKey.escape) {
                                  _stopTyping();
                                  return KeyEventResult.handled;
                                }
                                return KeyEventResult.ignored;
                              },
                              child: TextField(
                                controller: _controller,
                                focusNode: _focus,
                                maxLength: kMaxCustomLabel,
                                style: const TextStyle(fontSize: 13),
                                onSubmitted: (_) => _submit(),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  counterText: '',
                                  hintText: '이름 (12자)',
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 6,
                                  ),
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                          )
                        else if (widget.customLabels.length <
                            SongFormBar.maxCustomChips)
                          _BarChip(
                            korean: '직접…',
                            abbr: '',
                            narrow: false,
                            state: KindState.none,
                            onTap: _startTyping,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.selectedCount > 0) ...[
                const SizedBox(width: 8),
                Text(
                  '${widget.selectedCount}행 선택됨',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
              const SizedBox(width: 8),
              TextButton(
                onPressed: widget.clearEnabled ? widget.onClear : null,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  textStyle: const TextStyle(fontSize: 12),
                ),
                child: const Text('라벨 지우기'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BarChip extends StatefulWidget {
  const _BarChip({
    required this.korean,
    required this.abbr,
    required this.narrow,
    required this.state,
    required this.onTap,
  });

  final String korean;
  final String abbr;
  final bool narrow;
  final KindState state;
  final VoidCallback onTap;

  @override
  State<_BarChip> createState() => _BarChipState();
}

class _BarChipState extends State<_BarChip> {
  bool _down = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final full = widget.abbr.isEmpty
        ? widget.korean
        : '${widget.korean} ${widget.abbr}';
    final stateText = switch (widget.state) {
      KindState.all => ', 선택됨',
      KindState.some => ', 일부 행에 붙어 있음',
      KindState.none => '',
    };
    final fg = _down ? cs.onPrimary : cs.onSurface;
    final border = switch (widget.state) {
      KindState.all => BorderSide(color: cs.primary, width: 2),
      KindState.some => BorderSide(color: cs.primary),
      KindState.none => BorderSide(color: cs.outlineVariant),
    };
    final showKorean = !(widget.narrow && widget.abbr.isNotEmpty);
    return Tooltip(
      message: full,
      waitDuration: const Duration(milliseconds: 500),
      child: Semantics(
        button: true,
        selected: widget.state == KindState.all,
        label: '송폼 $full$stateText',
        excludeSemantics: true,
        child: InkWell(
          onTap: widget.onTap,
          onHighlightChanged: (v) => setState(() => _down = v),
          onHover: (v) => setState(() => _hover = v),
          borderRadius: BorderRadius.circular(AppRadius.control),
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _down
                  ? cs.primary
                  : _hover
                  ? cs.surfaceContainerHighest
                  : cs.surface,
              border: Border.fromBorderSide(border),
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showKorean)
                  Text(
                    widget.korean,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: fg,
                    ),
                  ),
                if (showKorean && widget.abbr.isNotEmpty)
                  const SizedBox(width: 4),
                if (widget.abbr.isNotEmpty)
                  Text(
                    widget.abbr,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: fg,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── 위 송폼 순서 줄 ────────────────────────────────────────────────────────

/// 제목 아래 한 줄: `송폼  Intro · V1 · PC · C ×2 · V2`. 항목을 누르면 [onStep](그 항목이 처음 나온 행).
/// 라벨이 하나도 없고 확인할 것도 없으면 아무것도 안 그린다.
class SongFormOrderLine extends StatelessWidget {
  const SongFormOrderLine({
    super.key,
    required this.steps,
    required this.onStep,
    this.checkCount = 0,
    this.onCheck,
  });

  final List<FormStep> steps;
  final void Function(FormStep step) onStep;

  /// 글이 바뀌어 숨긴 라벨이 있는 행 수. 누르면 [onCheck].
  final int checkCount;
  final VoidCallback? onCheck;

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty && checkCount == 0) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 32,
      margin: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(
            '송폼',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < steps.length; i++) ...[
                    if (i > 0)
                      Text(
                        '  ·  ',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    _OrderItem(step: steps[i], onTap: () => onStep(steps[i])),
                  ],
                ],
              ),
            ),
          ),
          if (checkCount > 0)
            _CheckChip(
              text: '송폼 확인 $checkCount',
              semanticsLabel: '송폼 확인 $checkCount곳, 첫 페이지로 이동',
              onTap: onCheck,
            ),
        ],
      ),
    );
  }
}

class _OrderItem extends StatefulWidget {
  const _OrderItem({required this.step, required this.onTap});

  final FormStep step;
  final VoidCallback onTap;

  @override
  State<_OrderItem> createState() => _OrderItemState();
}

class _OrderItemState extends State<_OrderItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = widget.step;
    final text = s.count > 1 ? '${s.label.abbr} ×${s.count}' : s.label.abbr;
    return Semantics(
      button: true,
      label:
          '송폼 ${s.label.korean}${s.count > 1 ? ' ${s.count}번' : ''}, '
          '${s.firstPage + 1}페이지로 이동',
      excludeSemantics: true,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (v) => setState(() => _hover = v),
        focusColor: cs.secondary.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
              decoration: _hover ? TextDecoration.underline : null,
            ),
          ),
        ),
      ),
    );
  }
}

// ── 라벨 메뉴 · 숨긴 라벨 안내 ─────────────────────────────────────────────

/// 라벨 칩 메뉴가 편집 창에 요청하는 일. 각 호출은 바로 반영되고 메뉴는 그대로 열려 있다.
class FormLabelMenuActions {
  const FormLabelMenuActions({
    required this.setNumber,
    required this.move,
    required this.remove,
  });

  /// 번호를 바꾼 새 라벨(번호 못 붙이는 종류·중복이면 그대로).
  final SectionLabel Function(SectionLabel current, int? num) setNumber;

  /// 같은 행 안 순서를 [delta] 칸 옮긴 뒤 새 위치.
  final int Function(SectionLabel current, int delta) move;
  final void Function(SectionLabel current) remove;
}

Future<void> showFormLabelMenu(
  BuildContext context, {
  required SectionLabel label,
  required int index,
  required int count,
  required FormLabelMenuActions actions,
}) => showDialog<void>(
  context: context,
  builder: (_) => _FormLabelMenu(
    label: label,
    index: index,
    count: count,
    actions: actions,
  ),
);

class _FormLabelMenu extends StatefulWidget {
  const _FormLabelMenu({
    required this.label,
    required this.index,
    required this.count,
    required this.actions,
  });

  final SectionLabel label;
  final int index;
  final int count;
  final FormLabelMenuActions actions;

  @override
  State<_FormLabelMenu> createState() => _FormLabelMenuState();
}

class _FormLabelMenuState extends State<_FormLabelMenu> {
  late SectionLabel _label = widget.label;
  late int _index = widget.index;

  bool get _numbered => kSectionKinds[_label.kind]!.numbered;

  void _step(int delta) => setState(
    () => _label = widget.actions.setNumber(
      _label,
      stepLabelNumber(_label.num, delta),
    ),
  );

  void _move(int delta) =>
      setState(() => _index = widget.actions.move(_label, delta));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '송폼 ${_label.korean}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              if (_numbered)
                SizedBox(
                  height: 36,
                  child: Row(
                    children: [
                      const Text('번호'),
                      const Spacer(),
                      IconButton(
                        tooltip: '번호 줄이기',
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 28,
                        ),
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.remove_rounded, size: 18),
                        onPressed: _label.num == null ? null : () => _step(-1),
                      ),
                      SizedBox(
                        width: 56,
                        child: Text(
                          _label.num == null ? '없음' : '${_label.num}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: '번호 늘리기',
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 28,
                        ),
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        onPressed: (_label.num ?? 0) >= kMaxLabelNumber
                            ? null
                            : () => _step(1),
                      ),
                    ],
                  ),
                ),
              if (widget.count > 1)
                SizedBox(
                  height: 36,
                  child: Row(
                    children: [
                      const Text('같은 행 안 순서'),
                      const Spacer(),
                      IconButton(
                        tooltip: '앞으로',
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 28,
                        ),
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                        onPressed: _index <= 0 ? null : () => _move(-1),
                      ),
                      IconButton(
                        tooltip: '뒤로',
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 28,
                        ),
                        padding: EdgeInsets.zero,
                        icon: const Icon(
                          Icons.arrow_downward_rounded,
                          size: 18,
                        ),
                        onPressed: _index >= widget.count - 1
                            ? null
                            : () => _move(1),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: () {
                      widget.actions.remove(_label);
                      Navigator.of(context).pop();
                    },
                    style: TextButton.styleFrom(foregroundColor: cs.error),
                    child: const Text('이 라벨 빼기'),
                  ),
                  const Spacer(),
                  FilledButton(
                    autofocus: true,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('닫기'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum HiddenFormChoice { apply, clear }

/// `! 송폼 확인` 칩 안내: 글이 바뀌어 숨긴 라벨을 그대로 적용하거나 지운다.
Future<HiddenFormChoice?> showHiddenFormDialog(
  BuildContext context,
  List<SectionLabel> hidden,
) => showDialog<HiddenFormChoice>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('송폼 확인'),
    content: Text(
      '가사가 바뀌어 이 페이지의 송폼을 숨겼어요.\n'
      '숨긴 라벨: ${hidden.map((l) => l.abbr).join(' · ')}',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(HiddenFormChoice.clear),
        child: const Text('지우기'),
      ),
      FilledButton(
        autofocus: true,
        onPressed: () => Navigator.of(context).pop(HiddenFormChoice.apply),
        child: const Text('이 페이지에 그대로 적용'),
      ),
    ],
  ),
);

// ── 발표 보기 표시 ─────────────────────────────────────────────────────────

/// 발표 보기 현재 칸 머리줄 배지(채움): `V2 · PC`. 툴팁·스크린리더는 한글 전체.
/// 라벨이 없으면 자리도 안 차지한다.
class FormBadge extends StatelessWidget {
  const FormBadge({super.key, required this.labels});

  final List<SectionLabel> labels;

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: labels.map((l) => l.korean).join(', '),
      child: Semantics(
        label: '송폼 ${labels.map((l) => l.korean).join(', ')}',
        excludeSemantics: true,
        child: Container(
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: cs.onSurface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          child: Text(
            labels.map((l) => l.abbr).join(' · '),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              height: 1,
              color: cs.surface,
            ),
          ),
        ),
      ),
    );
  }
}

/// 썸네일 좌하단 배지 글: 약어, 둘 이상 `V2·PC`, 셋 이상은 `V2+1`.
String formThumbText(List<SectionLabel> labels) {
  if (labels.isEmpty) return '';
  if (labels.length <= 2) return labels.map((l) => l.abbr).join('·');
  return '${labels.first.abbr}+${labels.length - 1}';
}

/// 썸네일 좌하단 작은 배지(검정 70% + 흰 10px). 둘러싼 Stack 의 Positioned 로 놓는다.
class FormThumbBadge extends StatelessWidget {
  const FormThumbBadge({super.key, required this.labels});

  final List<SectionLabel> labels;

  @override
  Widget build(BuildContext context) {
    final text = formThumbText(labels);
    if (text.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: labels.map((l) => l.korean).join(', '),
      child: Container(
        height: 16,
        padding: const EdgeInsets.symmetric(horizontal: 5),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            height: 1,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
