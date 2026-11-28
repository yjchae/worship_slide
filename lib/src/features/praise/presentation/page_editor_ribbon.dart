import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/page_element.dart';
import 'page_canvas.dart';
import 'page_rich_text.dart';
import 'style_fields.dart';

// 슬라이드 편집 창의 위쪽 리본 두 줄과 오른쪽 패널의 위치·크기 칸.
// 상태는 편집 창(page_editor_dialog.dart)이 갖고, 여기는 보여 주고 누른 것을 알리기만 한다.

/// 리본 한 줄 높이. 두 줄 다 늘 자리를 차지한다(고르기를 바꿔도 캔버스가 튀지 않게).
const double pageRibbonRowHeight = 42;

Widget _divider(ColorScheme cs) => SizedBox(
  height: 22,
  child: VerticalDivider(width: 13, color: cs.outlineVariant),
);

/// 맞춤 6가지(하나면 슬라이드 기준, 여럿이면 고른 범위 기준).
enum PageAlign {
  left('왼쪽 맞춤', Icons.align_horizontal_left_rounded),
  center('가운데 맞춤', Icons.align_horizontal_center_rounded),
  right('오른쪽 맞춤', Icons.align_horizontal_right_rounded),
  top('위쪽 맞춤', Icons.align_vertical_top_rounded),
  middle('중간 맞춤', Icons.align_vertical_center_rounded),
  bottom('아래쪽 맞춤', Icons.align_vertical_bottom_rounded);

  const PageAlign(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// 리본 '도형 ▾' 메뉴 아이콘.
IconData pageShapeIcon(PageShapeKind kind) => switch (kind) {
  PageShapeKind.rect => Icons.crop_square_rounded,
  PageShapeKind.roundRect => Icons.check_box_outline_blank_rounded,
  PageShapeKind.ellipse => Icons.circle_outlined,
  PageShapeKind.line => Icons.horizontal_rule_rounded,
  PageShapeKind.arrow => Icons.arrow_right_alt_rounded,
};

/// 글자 라벨 + ▾ 메뉴 버튼(도형·맞춤). 비활성이면 [onSelected] 가 null.
Widget _menuButton<T>({
  required ColorScheme cs,
  required IconData icon,
  required String label,
  required String tooltip,
  required String header,
  required List<(T, IconData, String)?> items,
  required ValueChanged<T>? onSelected,
}) {
  final enabled = onSelected != null;
  final ink = enabled ? cs.onSurface : cs.onSurface.withValues(alpha: 0.38);
  return PopupMenuButton<T>(
    tooltip: tooltip,
    enabled: enabled,
    onSelected: onSelected,
    itemBuilder: (_) => [
      PopupMenuItem<T>(
        enabled: false,
        height: 32,
        child: Text(
          header,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      ),
      for (final item in items)
        if (item case (final value, final icon, final text))
          PopupMenuItem<T>(
            value: value,
            child: Row(
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 10),
                Text(text),
              ],
            ),
          )
        else
          const PopupMenuDivider(),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: ink),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: ink)),
          Icon(Icons.arrow_drop_down_rounded, size: 18, color: ink),
        ],
      ),
    ),
  );
}

/// 줄 1 '삽입·정렬': 그림 · 붙여 넣기 · 글 상자 · 도형 ▾ | 복제 · 삭제 | 순서 4개 | 맞춤 ▾ | 되돌리기 · 다시 하기.
/// 누를 수 없으면 콜백이 null.
class PageInsertRow extends StatelessWidget {
  const PageInsertRow({
    super.key,
    required this.isMac,
    required this.pasting,
    required this.onPickImage,
    required this.onPaste,
    required this.onAddText,
    required this.onAddShape,
    this.alignCount = 0,
    this.onAlign,
    this.onDuplicate,
    this.onDelete,
    this.onToFront,
    this.onForward,
    this.onBackward,
    this.onToBack,
    this.onUndo,
    this.onRedo,
  });

  final bool isMac;
  final bool pasting;
  final VoidCallback onPickImage;
  final VoidCallback onPaste;
  final VoidCallback onAddText;
  final ValueChanged<PageShapeKind> onAddShape;

  /// 고른 요소 수(맞춤 메뉴 머리 — 1 이면 '슬라이드 기준').
  final int alignCount;
  final ValueChanged<PageAlign>? onAlign;
  final VoidCallback? onDuplicate;
  final VoidCallback? onDelete;
  final VoidCallback? onToFront;
  final VoidCallback? onForward;
  final VoidCallback? onBackward;
  final VoidCallback? onToBack;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mod = isMac ? '⌘' : 'Ctrl+';
    final shift = isMac ? '⇧' : 'Shift+';
    Widget labeled(
      IconData icon,
      String label,
      String tooltip,
      VoidCallback? onPressed,
    ) => Tooltip(
      message: tooltip,
      child: TextButton.icon(
        icon: Icon(icon, size: 18),
        label: Text(label),
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: cs.onSurface,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
    );
    Widget icon(IconData icon, String tooltip, VoidCallback? onPressed) =>
        IconButton(
          icon: Icon(icon, size: 20),
          tooltip: tooltip,
          onPressed: onPressed,
        );
    return SizedBox(
      height:
          pageRibbonRowHeight +
          (MediaQuery.textScalerOf(context).scale(14) - 14).clamp(0, 14),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            labeled(
              Icons.add_photo_alternate_outlined,
              '그림',
              '그림 추가 (파일)',
              onPickImage,
            ),
            pasting
                ? const SizedBox(
                    width: 96,
                    child: Center(
                      child: SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : labeled(
                    Icons.content_paste_rounded,
                    '붙여 넣기',
                    '붙여 넣기 (⌘V / Ctrl+V)',
                    onPaste,
                  ),
            labeled(
              Icons.text_fields_rounded,
              '글 상자',
              '글 상자 추가 (고른 글 상자와 같은 글꼴·색)',
              onAddText,
            ),
            _menuButton<PageShapeKind>(
              cs: cs,
              icon: Icons.category_outlined,
              label: '도형',
              tooltip: '도형 넣기',
              header: '도형 넣기',
              items: [
                for (final k in PageShapeKind.values) ...[
                  if (k == PageShapeKind.line) null,
                  (k, pageShapeIcon(k), k.label),
                ],
              ],
              onSelected: onAddShape,
            ),
            _divider(cs),
            labeled(Icons.copy_all_outlined, '복제', '복제 (${mod}D)', onDuplicate),
            labeled(
              Icons.delete_outline_rounded,
              '삭제',
              '삭제 (Delete)',
              onDelete,
            ),
            _divider(cs),
            icon(
              Icons.flip_to_front_outlined,
              '맨 앞으로 ($mod$shift])',
              onToFront,
            ),
            icon(Icons.arrow_upward_rounded, '앞으로 ($mod])', onForward),
            icon(Icons.arrow_downward_rounded, '뒤로 ($mod[)', onBackward),
            icon(Icons.flip_to_back_outlined, '맨 뒤로 ($mod$shift[)', onToBack),
            _menuButton<PageAlign>(
              cs: cs,
              icon: Icons.align_horizontal_center_rounded,
              label: '맞춤',
              tooltip: '맞춤',
              header: alignCount > 1 ? '고른 요소 $alignCount개 기준' : '슬라이드 기준',
              items: [
                for (final a in PageAlign.values) ...[
                  if (a == PageAlign.top) null,
                  (a, a.icon, a.label),
                ],
              ],
              onSelected: onAlign,
            ),
            _divider(cs),
            icon(Icons.undo_rounded, '되돌리기 (${mod}Z)', onUndo),
            icon(
              Icons.redo_rounded,
              isMac ? '다시 하기 (⌘⇧Z)' : '다시 하기 (Ctrl+Y)',
              onRedo,
            ),
          ],
        ),
      ),
    );
  }
}

/// 줄 2 '도형 서식' 앞부분에 보일 값(고른 첫 도형). [holdsText] = 고른 도형 중 글을 담는 것이 있음(선·화살표뿐이면 false).
typedef PageShapeFormat = ({
  Color? fill,
  double fillAlpha,
  Color? stroke,
  double strokeWidth,
  PageVAlign valign,
  bool holdsText,
});

/// 테두리 두께 목록(pt, 540pt 기준).
const pageStrokeWidths = <double>[1, 2, 3, 4, 6, 8, 12, 16, 24];

/// 줄 2 '글자 서식'(글 상자) / '도형 서식'([shape] 가 있으면 앞에 채우기·투명도·테두리·두께·세로 맞춤).
/// [format] 이 null 이면 글자 칸이 비활성, 둘 다 null 이면 모든 칸이 비활성(자리는 그대로).
/// 누르면 [onFormat](키, 값): font(String) · size(double) · step(+1/-1) · bold/italic/underline/strike(bool)
/// · color(Color) · align(TextAlign) · list('bullet'|'ordered'|null) · clear(null).
class PageFormatRow extends StatefulWidget {
  const PageFormatRow({
    super.key,
    required this.isMac,
    required this.format,
    required this.colors,
    required this.onFormat,
    this.shape,
    this.onShape,
  });

  final bool isMac;
  final PageTextFormat? format;

  /// 도형 서식(고른 것이 도형일 때). 누르면 [onShape](키, 값): fill(Color?) · fill_alpha(double, 끌기 시작에
  /// 'begin') · stroke(Color?) · stroke_width(double) · valign(PageVAlign).
  final PageShapeFormat? shape;
  final void Function(String key, Object? value)? onShape;

  /// 글자 색 창의 견본.
  final List<Color> colors;
  final void Function(String key, Object? value) onFormat;

  @override
  State<PageFormatRow> createState() => _PageFormatRowState();
}

class _PageFormatRowState extends State<PageFormatRow> {
  final _size = TextEditingController();
  final _sizeFocus = FocusNode(debugLabel: 'page-ribbon-size');

  @override
  void initState() {
    super.initState();
    _syncSize();
    _sizeFocus.addListener(() {
      if (!_sizeFocus.hasFocus) _syncSize();
    });
  }

  @override
  void didUpdateWidget(PageFormatRow old) {
    super.didUpdateWidget(old);
    if (!_sizeFocus.hasFocus) _syncSize();
  }

  void _syncSize() {
    final size = widget.format?.size;
    _size.text = size == null ? '' : _sizeText(size);
  }

  static String _sizeText(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

  @override
  void dispose() {
    _size.dispose();
    _sizeFocus.dispose();
    super.dispose();
  }

  void _submitSize(String v) {
    final n = double.tryParse(v.trim());
    if (n == null || !n.isFinite || n <= 0) {
      _syncSize();
      return;
    }
    widget.onFormat(
      'size',
      n.clamp(PageTextElement.minFontSize, PageTextElement.maxFontSize),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final f = widget.format;
    final on = f != null;
    final sh = widget.shape;
    final mod = widget.isMac ? '⌘' : 'Ctrl+';
    void send(String key, Object? value) => widget.onFormat(key, value);
    void shape(String key, Object? value) => widget.onShape?.call(key, value);
    final body = sh != null && sh.holdsText;

    Widget toggleOn(
      IconData icon,
      String tooltip,
      bool selected,
      VoidCallback? onPressed,
    ) => IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      isSelected: selected,
      style: IconButton.styleFrom(
        backgroundColor: selected ? cs.secondaryContainer : null,
        foregroundColor: selected ? cs.onSecondaryContainer : null,
      ),
      onPressed: onPressed,
    );
    Widget toggle(
      IconData icon,
      String tooltip,
      bool selected,
      VoidCallback? onPressed,
    ) => toggleOn(icon, tooltip, selected && on, onPressed);

    return Container(
      height:
          pageRibbonRowHeight +
          (MediaQuery.textScalerOf(context).scale(14) - 14).clamp(0, 14),
      color: cs.surfaceContainerLow,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Text(
              sh != null ? '도형 서식' : '글자 서식',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: on || sh != null ? cs.onSurface : cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            if (sh != null) ...[
              _ColorButton(
                tooltip: '채우기 색',
                icon: Icons.format_color_fill_rounded,
                noneLabel: '채우기 없음',
                color: sh.fill,
                enabled: body,
                colors: widget.colors,
                onSelected: (c) => shape('fill', c),
              ),
              Tooltip(
                message: '투명도',
                child: Semantics(
                  label: '투명도',
                  value: '${((1 - sh.fillAlpha) * 100).round()}%',
                  child: SizedBox(
                    width: 96,
                    child: Slider(
                      value: 1 - sh.fillAlpha,
                      onChangeStart: body && sh.fill != null
                          ? (_) => shape('begin', null)
                          : null,
                      onChanged: body && sh.fill != null
                          ? (v) => shape('fill_alpha', 1 - v)
                          : null,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  '${((1 - sh.fillAlpha) * 100).round()}%',
                  style: TextStyle(
                    fontSize: 12,
                    color: body ? cs.onSurface : cs.onSurfaceVariant,
                  ),
                ),
              ),
              _ColorButton(
                tooltip: '테두리 색',
                icon: Icons.border_color_outlined,
                noneLabel: '테두리 없음',
                color: sh.stroke,
                enabled: true,
                colors: widget.colors,
                onSelected: (c) => shape('stroke', c),
              ),
              PopupMenuButton<double>(
                tooltip: '테두리 두께',
                enabled: sh.stroke != null,
                onSelected: (v) => shape('stroke_width', v),
                itemBuilder: (_) => [
                  for (final w in pageStrokeWidths)
                    PopupMenuItem(value: w, child: Text('${_sizeText(w)}pt')),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    '${_sizeText(sh.strokeWidth)}pt ▾',
                    style: TextStyle(
                      fontSize: 13,
                      color: sh.stroke != null
                          ? cs.onSurface
                          : cs.onSurface.withValues(alpha: 0.38),
                    ),
                  ),
                ),
              ),
              _divider(cs),
              for (final (v, icon, label) in const [
                (PageVAlign.top, Icons.vertical_align_top_rounded, '위에 맞춤'),
                (
                  PageVAlign.middle,
                  Icons.vertical_align_center_rounded,
                  '가운데에 맞춤',
                ),
                (
                  PageVAlign.bottom,
                  Icons.vertical_align_bottom_rounded,
                  '아래에 맞춤',
                ),
              ])
                toggleOn(
                  icon,
                  label,
                  body && sh.valign == v,
                  body ? () => shape('valign', v) : null,
                ),
              _divider(cs),
            ],
            SizedBox(
              width: 170,
              child: FontFamilyPicker(
                selected: f?.font,
                onChanged: on ? (v) => send('font', v) : null,
              ),
            ),
            const SizedBox(width: 6),
            Semantics(
              label: '글자 크기',
              value: on && f.size == null ? '여러 값' : null,
              child: SizedBox(
                width: 52,
                child: TextField(
                  controller: _size,
                  focusNode: _sizeFocus,
                  enabled: on,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 8,
                    ),
                  ),
                  onSubmitted: _submitSize,
                  onTapOutside: (_) => _sizeFocus.unfocus(),
                ),
              ),
            ),
            PopupMenuButton<double>(
              enabled: on,
              tooltip: '글자 크기 목록',
              icon: const Icon(Icons.arrow_drop_down_rounded),
              onSelected: (v) => send('size', v),
              itemBuilder: (_) => [
                for (final s in pageFontSizes)
                  PopupMenuItem(value: s, child: Text(_sizeText(s))),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.text_increase_rounded, size: 20),
              tooltip: '한 단계 크게',
              onPressed: on ? () => send('step', 1) : null,
            ),
            IconButton(
              icon: const Icon(Icons.text_decrease_rounded, size: 20),
              tooltip: '한 단계 작게',
              onPressed: on ? () => send('step', -1) : null,
            ),
            _divider(cs),
            toggle(
              Icons.format_bold_rounded,
              '굵게 (${mod}B)',
              f?.bold ?? false,
              on ? () => send('bold', !f.bold) : null,
            ),
            toggle(
              Icons.format_italic_rounded,
              '기울임 (${mod}I)',
              f?.italic ?? false,
              on ? () => send('italic', !f.italic) : null,
            ),
            toggle(
              Icons.format_underlined_rounded,
              '밑줄 (${mod}U)',
              f?.underline ?? false,
              on ? () => send('underline', !f.underline) : null,
            ),
            toggle(
              Icons.format_strikethrough_rounded,
              '취소선',
              f?.strike ?? false,
              on ? () => send('strike', !f.strike) : null,
            ),
            _ColorButton(
              tooltip: '글자 색',
              color: f?.color,
              enabled: on,
              colors: widget.colors,
              onSelected: (c) => send('color', c),
            ),
            _divider(cs),
            for (final (align, icon, label) in const [
              (TextAlign.left, Icons.format_align_left_rounded, '왼쪽 정렬'),
              (TextAlign.center, Icons.format_align_center_rounded, '가운데 정렬'),
              (TextAlign.right, Icons.format_align_right_rounded, '오른쪽 정렬'),
            ])
              toggle(
                icon,
                label,
                f?.align == align,
                on ? () => send('align', align) : null,
              ),
            _divider(cs),
            toggle(
              Icons.format_list_bulleted_rounded,
              '글머리 기호',
              f?.list == 'bullet',
              on
                  ? () => send('list', f.list == 'bullet' ? null : 'bullet')
                  : null,
            ),
            toggle(
              Icons.format_list_numbered_rounded,
              '번호 매기기',
              f?.list == 'ordered',
              on
                  ? () => send('list', f.list == 'ordered' ? null : 'ordered')
                  : null,
            ),
            _divider(cs),
            Tooltip(
              message: '서식 지우기',
              child: TextButton.icon(
                icon: const Icon(Icons.format_clear_rounded, size: 18),
                label: const Text('서식 지우기'),
                onPressed: on ? () => send('clear', null) : null,
              ),
            ),
            if (!on && sh == null) ...[
              const SizedBox(width: 8),
              Text(
                '글 상자나 도형을 고르면 쓸 수 있습니다.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// '가'(또는 [icon]) + 지금 색 막대. 색이 섞였거나 없음이면 막대가 테두리만.
/// [noneLabel] 이 있으면 누를 때 '없음 / 색 고르기…' 메뉴부터(없음 = null).
class _ColorButton extends StatelessWidget {
  const _ColorButton({
    required this.tooltip,
    required this.color,
    required this.enabled,
    required this.colors,
    required this.onSelected,
    this.icon,
    this.noneLabel,
  });

  final String tooltip;
  final IconData? icon;
  final String? noneLabel;
  final Color? color;
  final bool enabled;
  final List<Color> colors;
  final ValueChanged<Color?> onSelected;

  Future<void> _pick(BuildContext context) async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (_) => HexColorDialog(
        title: tooltip,
        initialColor: color ?? colors.first,
        colors: colors,
        inputFormatter: hexInputFormatter,
      ),
    );
    if (picked != null) onSelected(picked);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ink = enabled ? cs.onSurface : cs.onSurface.withValues(alpha: 0.38);
    final face = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon case final icon?)
          Icon(icon, size: 16, color: ink)
        else
          Text(
            '가',
            style: TextStyle(
              fontSize: 14,
              height: 1.1,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
          ),
        Container(
          width: 18,
          height: 4,
          decoration: BoxDecoration(
            color: enabled ? color : null,
            border: Border.all(color: cs.outline, width: 0.5),
          ),
        ),
      ],
    );
    final none = noneLabel;
    if (none == null) {
      return IconButton(
        tooltip: tooltip,
        onPressed: enabled ? () => _pick(context) : null,
        icon: face,
      );
    }
    return PopupMenuButton<bool>(
      tooltip: tooltip,
      enabled: enabled,
      onSelected: (pick) => pick ? _pick(context) : onSelected(null),
      itemBuilder: (_) => [
        PopupMenuItem(value: false, child: Text(none)),
        const PopupMenuItem(value: true, child: Text('색 고르기…')),
      ],
      child: Padding(padding: const EdgeInsets.all(8), child: face),
    );
  }
}

/// 오른쪽 패널의 위치·크기 칸(1920x1080 기준 px). 칸을 떠나거나 Enter 면 [onChanged].
class PageRectFields extends StatefulWidget {
  const PageRectFields({
    super.key,
    required this.rect,
    required this.onChanged,
    this.clamp = PageElement.clampRect,
  });

  final Rect rect;
  final ValueChanged<Rect> onChanged;

  /// 요소 규칙대로 맞추기(선·화살표는 높이 0 허용 — [PageElement.fitRect]).
  final Rect Function(Rect) clamp;

  @override
  State<PageRectFields> createState() => _PageRectFieldsState();
}

class _PageRectFieldsState extends State<PageRectFields> {
  late final _fields = [
    for (var i = 0; i < 4; i++) (TextEditingController(), FocusNode()),
  ];

  List<double> get _values => [
    widget.rect.left * PageCanvas.width,
    widget.rect.top * PageCanvas.height,
    widget.rect.width * PageCanvas.width,
    widget.rect.height * PageCanvas.height,
  ];

  @override
  void initState() {
    super.initState();
    _sync();
    for (final (_, focus) in _fields) {
      focus.addListener(() {
        if (!focus.hasFocus) _submit();
      });
    }
  }

  @override
  void didUpdateWidget(PageRectFields old) {
    super.didUpdateWidget(old);
    if (old.rect != widget.rect) _sync();
  }

  void _sync() {
    final values = _values;
    for (var i = 0; i < 4; i++) {
      if (!_fields[i].$2.hasFocus) {
        _fields[i].$1.text = values[i].round().toString();
      }
    }
  }

  void _submit() {
    final v = [
      for (var i = 0; i < 4; i++)
        double.tryParse(_fields[i].$1.text.trim()) ?? _values[i],
    ];
    final next = widget.clamp(
      Rect.fromLTWH(
        v[0] / PageCanvas.width,
        v[1] / PageCanvas.height,
        v[2] / PageCanvas.width,
        v[3] / PageCanvas.height,
      ),
    );
    if (next != widget.rect) {
      widget.onChanged(next);
    } else {
      _sync();
    }
  }

  @override
  void dispose() {
    for (final (c, f) in _fields) {
      c.dispose();
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget field(int i, String label) => Expanded(
      child: TextField(
        controller: _fields[i].$1,
        focusNode: _fields[i].$2,
        keyboardType: const TextInputType.numberWithOptions(signed: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-0-9]'))],
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
    );
    return Column(
      children: [
        Row(children: [field(0, 'X'), const SizedBox(width: 8), field(1, 'Y')]),
        const SizedBox(height: 8),
        Row(
          children: [field(2, '폭'), const SizedBox(width: 8), field(3, '높이')],
        ),
      ],
    );
  }
}
