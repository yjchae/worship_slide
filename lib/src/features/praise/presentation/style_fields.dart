import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_colors.dart';
import '../data/font_library.dart';
import '../domain/export_style.dart';

// 디자인 리본·설교 페이지·슬라이드 편집 페이지가 같이 쓰는 입력 부품.

final TextInputFormatter hexInputFormatter = FilteringTextInputFormatter.allow(
  RegExp(r'[0-9a-fA-F#]'),
);

/// 테두리 있는 한 줄짜리 입력 칸 모양. 색·폰트·이미지 선택기가 같이 쓴다.
class FieldBox extends StatelessWidget {
  const FieldBox({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppRadius.control);
    return Material(
      color: cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: SizedBox(
          height: 30,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 색 견본 + hex. 누르면 hex 입력 다이얼로그를 연다.
class ColorField extends StatelessWidget {
  const ColorField({
    super.key,
    required this.dialogTitle,
    required this.color,
    required this.colors,
    required this.onSelected,
    this.caption,
  });

  final String dialogTitle;

  /// 있으면 hex 대신 이 짧은 이름을 보여 준다(한 줄에 색 두 개를 놓을 때). hex 는 툴팁으로.
  final String? caption;
  final Color color;
  final List<Color> colors;
  final ValueChanged<Color> onSelected;

  Future<void> _open(BuildContext context) async {
    final selected = await showDialog<Color>(
      context: context,
      builder: (context) => HexColorDialog(
        title: dialogTitle,
        initialColor: color,
        colors: colors,
        inputFormatter: hexInputFormatter,
      ),
    );
    if (selected != null) onSelected(selected);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final field = FieldBox(
      onTap: () => _open(context),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(AppRadius.control),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              caption ?? colorToHex(color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (caption == null)
            Icon(Icons.palette_outlined, size: 15, color: cs.onSurfaceVariant),
        ],
      ),
    );
    if (caption == null) return field;
    return Tooltip(message: '$dialogTitle ${colorToHex(color)}', child: field);
  }
}

class HexColorDialog extends StatefulWidget {
  const HexColorDialog({
    super.key,
    required this.title,
    required this.initialColor,
    required this.colors,
    required this.inputFormatter,
  });

  final String title;
  final Color initialColor;
  final List<Color> colors;
  final TextInputFormatter inputFormatter;

  @override
  State<HexColorDialog> createState() => _HexColorDialogState();
}

class _HexColorDialogState extends State<HexColorDialog> {
  late final TextEditingController _controller;
  bool _hasError = false;

  static final List<Color> _fullPalette = _buildFullPalette();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: colorToHex(widget.initialColor));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final color = tryParseHexColor(_controller.text);
    if (color == null) {
      setState(() => _hasError = true);
      return;
    }
    Navigator.of(context).pop(color);
  }

  void _selectColor(Color color) {
    _controller.text = colorToHex(color);
    Navigator.of(context).pop(color);
  }

  static List<Color> _buildFullPalette() {
    const hues = <double>[
      0,
      15,
      30,
      45,
      60,
      90,
      120,
      150,
      180,
      210,
      240,
      270,
      300,
      330,
    ];
    const values = <double>[0.95, 0.78, 0.62, 0.46];
    const saturations = <double>[0.28, 0.52, 0.76, 1.0];
    final colors = <Color>[
      const Color(0xFFFFFFFF),
      const Color(0xFFEDEDED),
      const Color(0xFFC8C8C8),
      const Color(0xFF8A8A8A),
      const Color(0xFF4A4A4A),
      const Color(0xFF000000),
    ];

    for (final hue in hues) {
      for (final value in values) {
        for (final saturation in saturations) {
          colors.add(HSVColor.fromAHSV(1, hue, saturation, value).toColor());
        }
      }
    }
    return colors;
  }

  Widget _paletteGrid(
    BuildContext context, {
    required List<Color> colors,
    required double size,
    required double spacing,
  }) {
    return Wrap(
      spacing: spacing,
      runSpacing: spacing,
      children: colors.map((color) {
        final selected = color.toARGB32() == widget.initialColor.toARGB32();
        return Tooltip(
          message: colorToHex(color),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => _selectColor(color),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).dividerColor,
                  width: selected ? 3 : 1,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _paletteGrid(
                context,
                colors: widget.colors,
                size: 34,
                spacing: 10,
              ),
              const SizedBox(height: 18),
              Text('전체 색상', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 10),
              _paletteGrid(context, colors: _fullPalette, size: 18, spacing: 5),
              const SizedBox(height: 18),
              TextField(
                controller: _controller,
                autofocus: false,
                decoration: InputDecoration(
                  labelText: 'HEX 색상',
                  hintText: '#FFFFFF',
                  errorText: _hasError ? '#RRGGBB 형식으로 입력해 주세요.' : null,
                  border: const OutlineInputBorder(),
                ),
                inputFormatters: [
                  widget.inputFormatter,
                  LengthLimitingTextInputFormatter(7),
                ],
                onChanged: (_) {
                  if (_hasError) setState(() => _hasError = false);
                },
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _submit, child: const Text('적용')),
      ],
    );
  }
}

class FontFamilyPicker extends StatelessWidget {
  const FontFamilyPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final String selected;
  final ValueChanged<String> onChanged;

  static const _bundled = [
    ('Pretendard', 'Pretendard'),
    ('NanumGothic', '나눔고딕'),
    ('NanumMyeongjo', '나눔명조'),
  ];

  List<(String, String)> get _fonts => [
    ..._bundled,
    for (final f in FontLibrary.fonts) (f.family, f.displayName),
  ];

  String get _displayName =>
      _fonts.firstWhere((f) => f.$1 == selected, orElse: () => _fonts.first).$2;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      offset: const Offset(0, 4),
      onSelected: onChanged,
      itemBuilder: (_) => _fonts
          .map(
            (f) => PopupMenuItem(
              value: f.$1,
              child: Row(
                children: [
                  Expanded(
                    child: Text(f.$2, style: TextStyle(fontFamily: f.$1)),
                  ),
                  if (f.$1 == selected)
                    Icon(Icons.check_rounded, size: 16, color: cs.primary),
                ],
              ),
            ),
          )
          .toList(),
      child: FieldBox(
        child: Row(
          children: [
            Expanded(
              child: Text(
                _displayName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: selected,
                  fontSize: 13,
                  color: cs.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              Icons.expand_more_rounded,
              size: 16,
              color: cs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
