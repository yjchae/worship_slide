import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/offering_image_library.dart';
import '../domain/export_style.dart';
import '../domain/offering_design.dart';
import 'offering_overlay_painter.dart';
import 'slide_page_data.dart';
import 'slide_render_view.dart';

/// 미리보기에 겹쳐 볼 가사 한 페이지.
typedef OfferingPreviewPage = ({
  String mainText,
  String englishText,
  String? title,
});

/// 헌금송 다이얼로그를 여는 목적.
enum OfferingDialogMode {
  /// 헌금송 기본 디자인 등록(배경·은행·계좌·디자인). 콘티 항목과 무관하다.
  defaults,

  /// 콘티 항목 하나를 헌금송으로 표시. 곡마다 가사 길이가 달라 높낮이를 여기서 맞춘다.
  item,
}

/// 헌금송 디자인 다이얼로그.
///
/// 결과:
/// - `null` — 취소(아무것도 바꾸지 않음)
/// - `(design: 디자인)` — 저장/적용
/// - `(design: null)` — [OfferingDialogMode.item] 에서 "헌금송 해제"
class OfferingDialog extends StatefulWidget {
  const OfferingDialog({
    super.key,
    required this.mode,
    required this.initial,
    required this.globalStyle,
    required this.imageLibrary,
    this.itemTitle,
    this.previewPages = const [],
    this.canRemove = false,
  });

  final OfferingDialogMode mode;
  final OfferingDesign initial;

  /// 가사를 겹쳐 그릴 때 쓰는 전역 디자인(글자 색·크기·위치). 배경은 헌금송 것으로 바꿔 그린다.
  final ExportStyle globalStyle;

  /// 헌금송 배경 이미지 보관소(한 장). 다이얼로그에서 등록·변경한다.
  final OfferingImageLibrary imageLibrary;
  final String? itemTitle;
  final List<OfferingPreviewPage> previewPages;

  /// 이미 헌금송인 항목이면 "헌금송 해제" 버튼을 보인다.
  final bool canRemove;

  @override
  State<OfferingDialog> createState() => _OfferingDialogState();
}

class _OfferingDialogState extends State<OfferingDialog> {
  late OfferingDesign _design = widget.initial;
  late int _pageIndex = _longestPageIndex(widget.previewPages);

  late final TextEditingController _labelController = TextEditingController(
    text: widget.initial.label,
  );
  late final TextEditingController _bankController = TextEditingController(
    text: widget.initial.bankName,
  );
  late final TextEditingController _accountController = TextEditingController(
    text: widget.initial.accountNumber,
  );

  static const double _positionStep = 0.05;

  static const List<Color> _backgroundSwatches = [
    Color(0xFF0B132B),
    Color(0xFF1B1B1B),
    Color(0xFF1A237E),
    Color(0xFF0F4C5C),
    Color(0xFF2D1E2F),
    Color(0xFF445D48),
  ];

  static const List<Color> _accentSwatches = [
    Color(0xFFFFE600),
    Color(0xFFFFD54F),
    Color(0xFFFFB74D),
    Colors.white,
    Color(0xFFB3E5FC),
    Colors.black,
  ];

  /// 가사가 가장 긴 페이지부터 보여준다. 띠를 비켜 놓을 기준이 그 페이지다.
  static int _longestPageIndex(List<OfferingPreviewPage> pages) {
    var best = 0;
    var bestLines = -1;
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      final lines = '${page.mainText}\n${page.englishText}'
          .trim()
          .split('\n')
          .length;
      if (lines > bestLines) {
        best = i;
        bestLines = lines;
      }
    }
    return best;
  }

  @override
  void dispose() {
    _labelController.dispose();
    _bankController.dispose();
    _accountController.dispose();
    super.dispose();
  }

  void _update(OfferingDesign design) => setState(() => _design = design);

  void _moveBand(double deltaInches) =>
      _update(_design.copyWith(bandCenterY: _design.bandCenterY + deltaInches));

  /// 이미지를 골라 등록한다(한 장만). 저장/적용을 눌러야 이전 이미지를 대체한다.
  Future<void> _registerBackgroundImage() async {
    await FilePicker.skipEntitlementsChecks();
    final result = await FilePicker.pickFiles(
      dialogTitle: '헌금송 배경 이미지 등록 (PNG / JPG)',
      type: FileType.custom,
      allowedExtensions: OfferingImageLibrary.allowedExtensions,
      allowMultiple: false,
    );
    final source = result?.files.single.path;
    if (source == null) return;
    try {
      final registered = await widget.imageLibrary.register(source);
      if (mounted) _update(_design.copyWith(backgroundImagePath: registered));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('이미지를 등록하지 못했습니다: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isItemMode = widget.mode == OfferingDialogMode.item;
    final title = isItemMode
        ? '헌금송으로 표시 — ${widget.itemTitle ?? ''}'
        : '헌금송 디자인 등록';

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      title: Row(
        children: [
          Icon(
            Icons.volunteer_activism_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(title, overflow: TextOverflow.ellipsis)),
        ],
      ),
      content: SizedBox(
        width: 940,
        height: 560,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildPreviewColumn(context)),
            const SizedBox(width: 20),
            SizedBox(width: 320, child: _buildSettingsColumn(context)),
          ],
        ),
      ),
      actions: [
        if (widget.canRemove)
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop((design: null)),
            icon: const Icon(Icons.layers_clear_rounded, size: 18),
            label: const Text('헌금송 해제'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((design: _design)),
          child: Text(isItemMode ? '헌금송으로 적용' : '저장'),
        ),
      ],
    );
  }

  // ── 왼쪽: 미리보기 + 높낮이 ──────────────────────────────────────────

  Widget _buildPreviewColumn(BuildContext context) {
    final pages = widget.previewPages;
    final page = pages.isEmpty ? null : pages[_pageIndex];
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: OfferingDesign.slideWidth / OfferingDesign.slideHeight,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                // 미리보기를 위아래로 끌어도 띠가 따라 움직인다.
                onVerticalDragUpdate: (details) => _moveBand(
                  details.delta.dy /
                      constraints.maxHeight *
                      OfferingDesign.slideHeight,
                ),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeUpDown,
                  child: OfferingSlidePreview(
                    design: _design,
                    globalStyle: widget.globalStyle,
                    page: page,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                pages.isEmpty
                    ? '미리보기를 끌어서 띠를 위아래로 옮길 수 있습니다.'
                    : '가사 ${_pageIndex + 1} / ${pages.length} 페이지 · '
                          '미리보기를 끌어서 띠를 옮길 수 있습니다.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            if (pages.length > 1) ...[
              IconButton(
                tooltip: '이전 페이지',
                visualDensity: VisualDensity.compact,
                onPressed: _pageIndex > 0
                    ? () => setState(() => _pageIndex--)
                    : null,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              IconButton(
                tooltip: '다음 페이지',
                visualDensity: VisualDensity.compact,
                onPressed: _pageIndex < pages.length - 1
                    ? () => setState(() => _pageIndex++)
                    : null,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        _buildPositionCard(context),
      ],
    );
  }

  Widget _buildPositionCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fits = OfferingOverlayPainter.fitsLyricsAbove(_design);
    final fromCenter = _design.bandCenterY - OfferingDesign.slideHeight / 2;
    final String positionText;
    if (fromCenter.abs() < 0.005) {
      positionText = '정가운데';
    } else {
      final direction = fromCenter < 0 ? '위' : '아래';
      positionText =
          '가운데보다 ${fromCenter.abs().toStringAsFixed(2)}인치 $direction';
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.height_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              const Text(
                '헌금 · 계좌 띠 높낮이',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              Text(
                positionText,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const Spacer(),
              IconButton(
                tooltip: '위로',
                visualDensity: VisualDensity.compact,
                onPressed: () => _moveBand(-_positionStep * 2),
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
              ),
              IconButton(
                tooltip: '아래로',
                visualDensity: VisualDensity.compact,
                onPressed: () => _moveBand(_positionStep * 2),
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
              ),
              TextButton(
                onPressed: () => _update(
                  _design.copyWith(
                    bandCenterY: OfferingDesign.defaultBandCenterY,
                  ),
                ),
                child: const Text('기본 위치'),
              ),
            ],
          ),
          Row(
            children: [
              Text('위', style: TextStyle(fontSize: 12, color: cs.outline)),
              Expanded(
                child: Slider(
                  value: _design.bandCenterY,
                  min: OfferingDesign.minBandCenterY,
                  max: OfferingDesign.maxBandCenterY,
                  divisions:
                      ((OfferingDesign.maxBandCenterY -
                                  OfferingDesign.minBandCenterY) /
                              _positionStep)
                          .round(),
                  onChanged: (value) =>
                      _update(_design.copyWith(bandCenterY: value)),
                ),
              ),
              Text('아래', style: TextStyle(fontSize: 12, color: cs.outline)),
              const SizedBox(width: 6),
            ],
          ),
          if (_design.lyricsAboveBand && !fits)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 6, 6),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 16, color: cs.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '띠가 너무 위에 있어 가사를 띠 위쪽에 다 놓을 수 없습니다. '
                      '띠를 조금 더 내려 주세요.',
                      style: TextStyle(fontSize: 12, color: cs.error),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ── 오른쪽: 배경 · 문구 · 디자인 ─────────────────────────────────────

  Widget _buildSettingsColumn(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.mode == OfferingDialogMode.item)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '배경·계좌·디자인을 바꾸면 다음 헌금송에도 그대로 쓰입니다. '
                '높낮이는 이 곡에만 적용됩니다.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const _SectionLabel('가사 위치'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _design.lyricsAboveBand,
            title: const Text('가사를 헌금 띠 위쪽에 표시'),
            subtitle: Text(
              _design.lyricsAboveBand
                  ? '가사 마지막 줄이 띠 바로 위에 붙고, 길면 위로 늘어납니다.'
                  : '가사는 디자인 패널의 위치 그대로 띠 위에 겹쳐 나옵니다.',
              style: const TextStyle(fontSize: 12),
            ),
            onChanged: (v) => _update(_design.copyWith(lyricsAboveBand: v)),
          ),
          if (_design.lyricsAboveBand)
            _LabeledSlider(
              label: '띠와 간격',
              value: _design.lyricsGap,
              min: 0,
              max: OfferingDesign.maxLyricsGap,
              format: (v) => '${v.toStringAsFixed(2)}in',
              onChanged: (v) =>
                  _update(_design.copyWith(lyricsGap: (v * 20).round() / 20)),
            ),
          const SizedBox(height: 12),
          const _SectionLabel('배경 이미지'),
          _buildBackgroundImageCard(context),
          const SizedBox(height: 8),
          _SwatchRow(
            label: '배경 색',
            selected: _design.backgroundColor,
            colors: _backgroundSwatches,
            onSelected: (c) => _update(_design.copyWith(backgroundColor: c)),
          ),
          const SizedBox(height: 16),
          const _SectionLabel('문구'),
          _textField(
            controller: _labelController,
            label: '윗줄 (예: 헌금)',
            onChanged: (v) => _update(_design.copyWith(label: v)),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 100,
                child: _textField(
                  controller: _bankController,
                  label: '은행명',
                  onChanged: (v) => _update(_design.copyWith(bankName: v)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _textField(
                  controller: _accountController,
                  label: '계좌번호',
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9\- ]')),
                  ],
                  onChanged: (v) => _update(_design.copyWith(accountNumber: v)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _SectionLabel('글자'),
          _SwatchRow(
            label: '글자 색',
            selected: _design.textColor,
            colors: _accentSwatches,
            onSelected: (c) => _update(_design.copyWith(textColor: c)),
          ),
          _LabeledSlider(
            label: '윗줄 크기',
            value: _design.labelFontSize,
            min: 16,
            max: 72,
            format: (v) => '${v.round()}pt',
            onChanged: (v) =>
                _update(_design.copyWith(labelFontSize: v.roundToDouble())),
          ),
          _LabeledSlider(
            label: '계좌 크기',
            value: _design.accountFontSize,
            min: 16,
            max: 72,
            format: (v) => '${v.round()}pt',
            onChanged: (v) =>
                _update(_design.copyWith(accountFontSize: v.roundToDouble())),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Expanded(child: _SectionLabel('라인')),
              Switch(
                value: _design.showLines,
                onChanged: (v) => _update(_design.copyWith(showLines: v)),
              ),
            ],
          ),
          AnimatedOpacity(
            opacity: _design.showLines ? 1 : 0.4,
            duration: const Duration(milliseconds: 150),
            child: IgnorePointer(
              ignoring: !_design.showLines,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SwatchRow(
                    label: '라인 색',
                    selected: _design.lineColor,
                    colors: _accentSwatches,
                    onSelected: (c) => _update(_design.copyWith(lineColor: c)),
                  ),
                  _LabeledSlider(
                    label: '길이',
                    value: _design.lineWidth,
                    min: 2,
                    max: OfferingDesign.slideWidth - 1,
                    format: (v) => '${v.toStringAsFixed(1)}in',
                    onChanged: (v) => _update(
                      _design.copyWith(lineWidth: (v * 10).round() / 10),
                    ),
                  ),
                  _LabeledSlider(
                    label: '굵기',
                    value: _design.lineThickness,
                    min: 1,
                    max: 8,
                    format: (v) => '${v.toStringAsFixed(1)}pt',
                    onChanged: (v) => _update(
                      _design.copyWith(lineThickness: (v * 2).round() / 2),
                    ),
                  ),
                  _LabeledSlider(
                    label: '글자와 간격',
                    value: _design.linePadding,
                    min: 0,
                    max: 1,
                    format: (v) => '${v.toStringAsFixed(2)}in',
                    onChanged: (v) => _update(
                      _design.copyWith(linePadding: (v * 20).round() / 20),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 등록한 배경 이미지 한 장. 썸네일 + 등록(변경) / 삭제 버튼.
  Widget _buildBackgroundImageCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final path = _design.backgroundImagePath;
    final file = path == null ? null : File(path);
    final hasImage = file != null && file.existsSync();

    return Row(
      children: [
        Container(
          width: 128,
          height: 72,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: _design.backgroundColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          child: hasImage
              ? Image.file(
                  file,
                  fit: BoxFit.cover,
                  cacheWidth: 256,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.broken_image_outlined, size: 18),
                )
              : const Center(
                  child: Text(
                    '이미지 없음',
                    style: TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.tonalIcon(
                onPressed: _registerBackgroundImage,
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                label: Text(hasImage ? '이미지 변경' : '이미지 등록'),
              ),
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: path == null
                    ? null
                    : () =>
                          _update(_design.copyWith(backgroundImagePath: null)),
                icon: Icon(
                  Icons.delete_outline_rounded,
                  size: 18,
                  color: path == null ? null : cs.error,
                ),
                label: Text(
                  '이미지 삭제',
                  style: TextStyle(color: path == null ? null : cs.error),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _textField({
    required TextEditingController controller,
    required String label,
    required ValueChanged<String> onChanged,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onChanged: onChanged,
    );
  }
}

/// 헌금송 배경(이미지 + 띠) 위에 가사 한 페이지를 겹쳐 보여주는 미리보기.
///
/// 띠는 PNG 를 굽는 것과 같은 [OfferingOverlayPainter] 로, 가사는 실제 미리보기와 같은
/// [SlideRenderView] 로 그린다(배경만 투명하게 바꿔서).
class OfferingSlidePreview extends StatelessWidget {
  const OfferingSlidePreview({
    super.key,
    required this.design,
    required this.globalStyle,
    this.page,
  });

  final OfferingDesign design;
  final ExportStyle globalStyle;
  final OfferingPreviewPage? page;

  @override
  Widget build(BuildContext context) {
    final path = design.backgroundImagePath;
    final imageFile = path == null ? null : File(path);
    final page = this.page;
    final placement = OfferingOverlayPainter.lyricsPlacement(design);

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: design.backgroundColor),
        if (imageFile != null && imageFile.existsSync())
          Image.file(imageFile, fit: BoxFit.cover),
        CustomPaint(painter: OfferingOverlayPainter(design)),
        if (page != null)
          SlideRenderView(
            data: SlidePageData(
              mainText: page.mainText,
              englishText: page.englishText,
              title: page.title,
              isBible: false,
              pageIndex: 0,
              totalPages: 1,
              style: globalStyle.copyWith(
                backgroundColor: Colors.transparent,
                backgroundImagePath: null,
                textPosition: placement.position,
                textOffsetY: placement.offsetY,
              ),
            ),
          ),
      ],
    );
  }
}

// ── 작은 부품들 ─────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _SwatchRow extends StatelessWidget {
  const _SwatchRow({
    required this.label,
    required this.selected,
    required this.colors,
    required this.onSelected,
  });

  final String label;
  final Color selected;
  final List<Color> colors;
  final ValueChanged<Color> onSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final color in colors)
                  Tooltip(
                    message: colorToHex(color),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => onSelected(color),
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: color == selected
                                ? cs.primary
                                : Theme.of(context).dividerColor,
                            width: color == selected ? 2.5 : 1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String Function(double value) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            format(value),
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
