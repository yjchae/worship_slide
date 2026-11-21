import 'package:flutter/material.dart';

import '../domain/export_style.dart';
import '../domain/page_format.dart';
import 'style_fields.dart';

/// 수정 창의 '이 페이지 글자 모양' 줄: 원본·보조·추가 보조 각각의 색과 크기(전역 대비 %).
/// 값은 부모가 들고 있다 — 바뀔 때마다 [onChanged] 로 새 서식(없으면 null)을 돌려준다.
class PageFormatEditor extends StatelessWidget {
  const PageFormatEditor({
    super.key,
    required this.entry,
    required this.style,
    required this.isBible,
    required this.swatches,
    required this.onChanged,
  });

  final PageEntry? entry;

  /// 전역(항목 배경까지 입힌) 스타일 — 서식이 없을 때 보여 줄 기본 색.
  final ExportStyle style;
  final bool isBible;
  final List<Color> swatches;
  final ValueChanged<PageEntry?> onChanged;

  void _set({
    PageTextFormat? main,
    PageTextFormat? sub,
    PageTextFormat? extra,
    bool setMain = false,
    bool setSub = false,
    bool setExtra = false,
  }) {
    final e = PageEntry(
      main: setMain ? main : entry?.main,
      sub: setSub ? sub : entry?.sub,
      extra: setExtra ? extra : entry?.extra,
    );
    onChanged(e.isEmpty ? null : e);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '이 페이지 글자 모양',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: entry == null ? null : () => onChanged(null),
              child: const Text('기본값으로'),
            ),
          ],
        ),
        _line(
          context,
          key: 'main',
          label: '원본',
          format: entry?.main,
          defaultColor: isBible ? style.bibleTextColor : style.textColor,
          onFormat: (f) => _set(main: f, setMain: true),
        ),
        _line(
          context,
          key: 'sub',
          label: '보조',
          format: entry?.sub,
          defaultColor: style.englishTextColor,
          onFormat: (f) => _set(sub: f, setSub: true),
        ),
        _line(
          context,
          key: 'extra',
          label: '추가 보조',
          format: entry?.extra,
          defaultColor: style.extraTextColor,
          onFormat: (f) => _set(extra: f, setExtra: true),
        ),
      ],
    );
  }

  Widget _line(
    BuildContext context, {
    required String key,
    required String label,
    required PageTextFormat? format,
    required Color defaultColor,
    required ValueChanged<PageTextFormat?> onFormat,
  }) {
    final scale = format?.scale ?? 1.0;
    // 색·크기가 둘 다 기본값이면 서식 자체를 비운다.
    void emit(Color? color, double? scale) {
      final next = PageTextFormat(color: color, scale: scale);
      onFormat(next.isEmpty ? null : next);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          SizedBox(width: 62, child: Text(label)),
          SizedBox(
            width: 112,
            child: ColorField(
              key: ValueKey('format-color-$key'),
              dialogTitle: '$label 글자 색',
              color: format?.color ?? defaultColor,
              colors: swatches,
              onSelected: (c) => emit(c, format?.scale),
            ),
          ),
          Expanded(
            child: Slider(
              key: ValueKey('format-scale-$key'),
              value: scale,
              min: kMinPageScale,
              max: kMaxPageScale,
              divisions: 30,
              // 100% 근처는 기본값(null)으로 본다.
              onChanged: (v) =>
                  emit(format?.color, (v - 1).abs() < 0.025 ? null : v),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text('${(scale * 100).round()}%', textAlign: TextAlign.end),
          ),
          IconButton(
            key: ValueKey('format-reset-$key'),
            tooltip: '$label 기본값',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            onPressed: format == null ? null : () => onFormat(null),
            icon: const Icon(Icons.restart_alt_rounded),
          ),
        ],
      ),
    );
  }
}
