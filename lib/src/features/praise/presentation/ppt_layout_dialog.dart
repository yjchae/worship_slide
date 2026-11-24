import 'package:flutter/material.dart';

import '../domain/ppt_layout.dart';

/// 'PPT 를 편집 페이지로 가져오기' 결과 창(design s6). 콘티에 담기 전에 보여 주고
/// '콘티에 담기'면 true, '담지 않기'·'닫기'·바깥 누름이면 null.
class PptLayoutResultDialog extends StatelessWidget {
  const PptLayoutResultDialog({
    super.key,
    required this.layout,
    required this.groupName,
  });

  final PptLayout layout;

  /// 담길 콘티 그룹 이름(안내 줄에 보인다).
  final String groupName;

  static Future<bool?> show(
    BuildContext context,
    PptLayout layout,
    String groupName,
  ) => showDialog<bool>(
    context: context,
    builder: (_) => PptLayoutResultDialog(layout: layout, groupName: groupName),
  );

  /// 처음부터 보이게 둔 애니메이션의 까닭 이름(`anim_lost` 키).
  static const _animLostLabels = {
    'exit': '사라짐',
    'paragraph': '문단 단위',
    'group_child': '그룹 안 도형',
    'overlap': '겹침',
    'too_many': '30단계 넘음',
  };

  static String _numbers(Iterable<PptLayoutSlide> slides) =>
      slides.map((s) => s.index).join(', ');

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final editable = layout.editable;
    final hidden = layout.hidden;
    final m = editable.length;
    final dropped = editable.fold(0, (a, s) => a + s.droppedCount);
    final droppedSlides = editable.where((s) => s.droppedCount > 0);
    final effects = editable.fold(0, (a, s) => a + s.effectsLost);
    final animated = editable.where((s) => s.steps > 1);
    final animSteps = animated.fold(0, (a, s) => a + s.steps);
    final animLost = <String, int>{};
    for (final s in editable) {
      s.animLost.forEach((k, v) => animLost[k] = (animLost[k] ?? 0) + v);
    }
    final animLostCount = animLost.values.fold(0, (a, b) => a + b);
    final muted = TextStyle(fontSize: 13, color: cs.onSurfaceVariant);

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('편집 페이지로 가져올 준비가 됐습니다'),
          const SizedBox(height: 4),
          Text(layout.sourceName, style: muted),
        ],
      ),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: m == 0
                    ? Text(
                        '편집 페이지로 만들 수 있는 장이 없습니다',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      )
                    : Text.rich(
                        TextSpan(
                          style: muted,
                          children: [
                            TextSpan(text: '슬라이드 ${layout.slides.length}장 중  '),
                            TextSpan(
                              text: '$m장',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                color: cs.onSurface,
                              ),
                            ),
                            const TextSpan(text: '  을 편집 페이지로 만듭니다'),
                          ],
                        ),
                      ),
              ),
              const SizedBox(height: 8),
              if (dropped > 0)
                _row(
                  context,
                  Icons.image_outlined,
                  '그림으로 둔 요소',
                  '표·차트·회전한 도형처럼 고칠 수 없는 것은 페이지 배경 그림에 들어갔습니다.\n'
                      '${_numbers(droppedSlides)}번째 장',
                  '$dropped개',
                ),
              if (effects > 0)
                _row(
                  context,
                  Icons.auto_awesome_outlined,
                  '빠진 꾸밈',
                  '글 그림자·윤곽선을 빼고 글만 가져왔습니다. 사진 배경 위에서 글이 잘 안 보일 수 있습니다.',
                  '$effects곳',
                ),
              if (animated.isNotEmpty)
                _row(
                  context,
                  Icons.animation_rounded,
                  '애니메이션',
                  '${animated.length}장 → 클릭 단계 $animSteps장으로 나눔. '
                      '발표에서 넘길 때마다 원본 순서대로 하나씩 나타납니다(움직이는 효과는 빠집니다).\n'
                      '${_numbers(animated)}번째 장',
                  '$animSteps장',
                ),
              if (animLostCount > 0)
                _row(
                  context,
                  Icons.info_outline_rounded,
                  '처음부터 보이게 둔 애니메이션',
                  '${[for (final MapEntry(:key) in animLost.entries) _animLostLabels[key] ?? key].join('·')} — 클릭 단계로 옮기지 못해 처음부터 보입니다.',
                  '$animLostCount곳',
                ),
              if (layout.fontsMissing.isNotEmpty)
                _row(
                  context,
                  Icons.error_outline_rounded,
                  '없는 글꼴',
                  '${layout.fontsMissing.join(', ')}\n'
                      '이 PC 에 없어 다른 글꼴로 보입니다. 글꼴 이름은 그대로 남습니다.',
                  '${layout.fontsMissing.length}개',
                ),
              if (layout.letterboxed && m > 0)
                _row(
                  context,
                  Icons.aspect_ratio_rounded,
                  '16:9 가 아님',
                  '화면 비율이 달라 가운데에 놓고 남는 자리는 검정으로 비웠습니다.',
                  '$m장',
                ),
              if (hidden.isNotEmpty)
                _row(
                  context,
                  Icons.visibility_off_outlined,
                  '숨긴 슬라이드',
                  '${_numbers(hidden)}번째 장은 건너뛰었습니다.',
                  '${hidden.length}장',
                ),
              if (m > 0) ...[
                const SizedBox(height: 12),
                Text(
                  "글자 크기·색은 원본 PowerPoint 와 조금 다를 수 있습니다. "
                  "콘티 끝에 '$groupName' 그룹으로 담깁니다.",
                  style: muted,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: m == 0
          ? [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('닫기'),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('담지 않기'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('콘티에 담기 ($m장)'),
              ),
            ],
    );
  }

  Widget _row(
    BuildContext context,
    IconData icon,
    String title,
    String detail,
    String count,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: cs.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            count,
            style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurface),
          ),
        ],
      ),
    );
  }
}
