import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app_colors.dart';
import '../data/page_template_store.dart';
import '../domain/page_element.dart';
import '../domain/slide_background.dart';
import 'style_fields.dart';

/// 지금 배경([current])이 틀 [t] 의 배경(색·그림)과 같은지. 칩 체크 표시용.
bool _sameBackground(SlideBackground? current, PageTemplate t) {
  if (current == null) return false;
  final d = usableTemplateDesign(t.design);
  return current.color == d.color &&
      (current.imagePath ?? '') == (d.imagePath ?? '');
}

/// '틀 배경' 칩 줄: 누르면 [onSelected] 로 그 틀을 넘긴다(배경만 입히는 건 부른 쪽).
/// 틀이 없으면 아무것도 그리지 않는다.
class PageTemplateChips extends StatelessWidget {
  const PageTemplateChips({
    super.key,
    required this.templates,
    required this.current,
    required this.onSelected,
    required this.hint,
  });

  final List<PageTemplate> templates;

  /// 지금 배경. 같은 틀 칩에 체크를 단다(null 이면 아무 칩도 안 고름).
  final SlideBackground? current;
  final ValueChanged<PageTemplate> onSelected;
  final String hint;

  @override
  Widget build(BuildContext context) {
    if (templates.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('틀 배경', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in templates)
              _chip(cs, t, _sameBackground(current, t)),
          ],
        ),
        const SizedBox(height: 4),
        Text(hint, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      ],
    );
  }

  Widget _chip(ColorScheme cs, PageTemplate t, bool selected) {
    final d = usableTemplateDesign(t.design);
    return ActionChip(
      avatar: ExcludeSemantics(
        child: Container(
          width: 16,
          height: 16,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: d.color,
            shape: BoxShape.circle,
            border: Border.all(color: cs.outlineVariant),
          ),
          child: d.hasImage
              ? Image.file(
                  File(d.imagePath!),
                  fit: BoxFit.cover,
                  cacheWidth: 32,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                )
              : null,
        ),
      ),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(t.name, overflow: TextOverflow.ellipsis),
          ),
          if (selected) ...[
            const SizedBox(width: 4),
            Icon(Icons.check, size: 14, color: cs.primary),
          ],
        ],
      ),
      side: selected ? BorderSide(color: cs.primary) : null,
      onPressed: () => onSelected(t),
    );
  }
}

/// 리본 '공통' 탭의 '페이지 틀' 칸. 틀 이름을 한 줄로 보여 준다.
class PageTemplateField extends StatelessWidget {
  const PageTemplateField({
    super.key,
    required this.templates,
    required this.onPressed,
  });

  final List<PageTemplate> templates;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final empty = templates.isEmpty;
    return Tooltip(
      message: '페이지 틀 관리',
      child: FieldBox(
        onTap: onPressed,
        child: Row(
          children: [
            Icon(Icons.web_stories_outlined, size: 16, color: cs.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                empty
                    ? '등록된 틀 없음 (눌러서 만들기)'
                    : templates.map((t) => t.name).join(' · '),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: empty ? cs.onSurfaceVariant : cs.onSurface,
                  fontWeight: empty ? null : FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.edit_outlined, size: 15, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// 페이지 틀 관리 창: 목록(썸네일·이름·요약) + 새 틀·편집·삭제.
/// 편집은 [edit](슬라이드 편집 창), 저장은 [save](실패하면 false — 알림은 부른 쪽이 띄운다).
class PageTemplateDialog extends StatefulWidget {
  const PageTemplateDialog({
    super.key,
    required this.templates,
    required this.broken,
    required this.edit,
    required this.save,
  });

  final List<PageTemplate> templates;

  /// 틀 파일을 읽지 못해 기본 틀로 시작했는지.
  final bool broken;

  /// null = 새 틀. 취소하면 null.
  final Future<PageTemplate?> Function(PageTemplate? template) edit;
  final Future<bool> Function(List<PageTemplate> templates) save;

  @override
  State<PageTemplateDialog> createState() => _PageTemplateDialogState();
}

class _PageTemplateDialogState extends State<PageTemplateDialog> {
  late List<PageTemplate> _templates = widget.templates;
  late bool _broken = widget.broken;

  Future<void> _store(List<PageTemplate> next) async {
    if (!await widget.save(next) || !mounted) return;
    setState(() {
      _templates = next;
      _broken = false;
    });
  }

  Future<void> _edit(int? index) async {
    final edited = await widget.edit(index == null ? null : _templates[index]);
    if (edited == null || !mounted) return;
    await _store([
      for (final (i, t) in _templates.indexed) i == index ? edited : t,
      if (index == null) edited,
    ]);
  }

  Future<void> _delete(int index) async {
    final t = _templates[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('틀 삭제'),
        content: Text("'${t.name}' 틀을 지울까요? 이미 콘티에 넣은 페이지는 그대로 남습니다."),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _store([
      for (final x in _templates)
        if (x.id != t.id) x,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 12, color: cs.onSurfaceVariant);
    return AlertDialog(
      title: const Text('페이지 틀'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_broken) ...[
              Text(
                '틀 파일을 읽지 못해 기본 틀로 시작했습니다. 원래 파일은 그대로 두었습니다.',
                style: TextStyle(fontSize: 12, color: cs.error),
              ),
              const SizedBox(height: 8),
            ],
            if (_templates.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    Icon(
                      Icons.web_stories_outlined,
                      size: 32,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(height: 8),
                    const Text('등록된 틀이 없습니다.'),
                    const SizedBox(height: 4),
                    Text(
                      "'새 틀 만들기'로 예배 시작·광고·생일자 화면을 만들어 두세요.",
                      style: small,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else ...[
              Text(
                "자주 쓰는 화면의 배경과 글 상자를 저장해 두고 '새 페이지 추가'에서 바로 씁니다. "
                '페이지에 넣을 때 복사되므로 틀을 고쳐도 이미 넣은 페이지는 그대로입니다.',
                style: small,
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.6,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final (i, t) in _templates.indexed) _row(cs, i, t),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton.icon(
          onPressed: () => _edit(null),
          icon: const Icon(Icons.add),
          label: const Text('새 틀 만들기'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }

  Widget _row(ColorScheme cs, int index, PageTemplate t) {
    final elements = t.design.pageElements ?? const <PageElement>[];
    final texts = elements.whereType<PageTextElement>().length;
    final images = elements.length - texts;
    final what = [if (texts > 0) '글 상자 $texts개', if (images > 0) '그림 $images개'];
    final imageMissing =
        t.design.hasImage && !File(t.design.imagePath!).existsSync();
    final background = t.design.hasImage ? '배경 그림' : '배경 색';
    final preview = t.previewPath;
    final fallback = Container(
      color: t.design.color,
      alignment: Alignment.center,
      child: Icon(
        Icons.image_not_supported_outlined,
        size: 20,
        color: cs.onSurfaceVariant,
      ),
    );
    return InkWell(
      onTap: () => _edit(index),
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            Semantics(
              label: '${t.name} 틀 미리보기',
              image: true,
              child: Container(
                width: 128,
                height: 72,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  border: Border.all(color: cs.outlineVariant),
                ),
                child: preview == null
                    ? fallback
                    : Image.file(
                        File(preview),
                        fit: BoxFit.cover,
                        cacheWidth: 256,
                        errorBuilder: (_, _, _) => fallback,
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      what.isEmpty ? '요소 없음' : what.join(' · '),
                      if (!imageMissing) background,
                    ].join(' · '),
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  if (imageMissing)
                    Text(
                      '배경 그림 없음 (색만 사용)',
                      style: TextStyle(fontSize: 12, color: cs.error),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: '틀 편집',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _edit(index),
            ),
            IconButton(
              tooltip: '틀 삭제',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(index),
            ),
          ],
        ),
      ),
    );
  }
}
