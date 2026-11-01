import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/b_screen_store.dart';
import '../data/screen_choice_store.dart';

/// 통역 화면 설정. 저장하면 새 설정, 취소하면 null.
/// [blocked] = 고를 수 없는 모니터 번호 → 사유('메인 창' 등).
class BScreenSettingsDialog extends StatefulWidget {
  const BScreenSettingsDialog({
    super.key,
    required this.config,
    required this.screens,
    required this.blocked,
  });

  final BScreenConfig config;
  final List<ScreenInfo> screens;
  final Map<int, String> blocked;

  static Future<BScreenConfig?> show(
    BuildContext context, {
    required BScreenConfig config,
    required List<ScreenInfo> screens,
    required Map<int, String> blocked,
  }) => showDialog<BScreenConfig>(
    context: context,
    builder: (_) => BScreenSettingsDialog(
      config: config,
      screens: screens,
      blocked: blocked,
    ),
  );

  @override
  State<BScreenSettingsDialog> createState() => _BScreenSettingsDialogState();
}

class _BScreenSettingsDialogState extends State<BScreenSettingsDialog> {
  late final int _initialScreen = ScreenChoice.resolve(
    widget.config.screen,
    widget.screens,
  );
  late int _screen = _initialScreen; // -1 = 고르지 않음
  late BSide _side = widget.config.side;
  late double _share = widget.config.share;
  late final _url = TextEditingController(text: widget.config.subtitleUrl);
  String? _urlError;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _save() {
    final url = _url.text.trim();
    if (!isValidBSubtitleUrl(url)) {
      setState(() => _urlError = 'http:// 또는 https:// 로 시작하는 올바른 주소를 넣어 주세요.');
      return;
    }
    // 안 건드렸으면 그대로 둔다 — 모니터가 잠깐 빠진 사이 저장해도 선택이 지워지지 않게.
    final next = widget.config.copyWith(
      side: _side,
      share: _share,
      subtitleUrl: url,
    );
    if (_screen == _initialScreen) {
      Navigator.of(context).pop(next);
    } else if (_screen < 0) {
      Navigator.of(context).pop(next.copyWith(clearScreen: true));
    } else {
      final screen = widget.screens[_screen];
      Navigator.of(
        context,
      ).pop(next.copyWith(screen: ScreenChoice(screen.index, screen.name)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelLarge;
    final hasSubtitle = _url.text.trim().isNotEmpty;
    final usable = widget.screens.any(
      (s) => !widget.blocked.containsKey(s.index),
    );
    final monitor = _screen >= 0 ? widget.screens[_screen] : null;
    final width = monitor?.width ?? 1920, height = monitor?.height ?? 1080;
    final rects = bSplitRects(width, height, _side, _share, hasSubtitle);
    String size(Rect r) =>
        '${(r.width * width).round()}×${(r.height * height).round()}';

    return AlertDialog(
      title: const Text('통역 화면 설정'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('모니터', style: labelStyle),
              const SizedBox(height: 6),
              DropdownButton<int>(
                isExpanded: true,
                value: _screen,
                onChanged: (v) => setState(() => _screen = v ?? -1),
                items: [
                  const DropdownMenuItem(value: -1, child: Text('고르지 않음')),
                  for (final s in widget.screens)
                    DropdownMenuItem(
                      value: s.index,
                      enabled: !widget.blocked.containsKey(s.index),
                      child: Text(
                        widget.blocked[s.index] == null || s.isMain
                            ? s.label
                            : '${s.label} · ${widget.blocked[s.index]}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
              if (!usable)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '쓸 수 있는 모니터가 없습니다. 메인 창·관객 화면 외에 모니터가 하나 더 필요합니다.',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 16),
              Text('슬라이드 위치', style: labelStyle),
              const SizedBox(height: 6),
              SegmentedButton<BSide>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: BSide.top, label: Text('위')),
                  ButtonSegment(value: BSide.bottom, label: Text('아래')),
                  ButtonSegment(value: BSide.left, label: Text('왼쪽')),
                  ButtonSegment(value: BSide.right, label: Text('오른쪽')),
                ],
                selected: {_side},
                onSelectionChanged: (v) => setState(() => _side = v.first),
              ),
              const SizedBox(height: 16),
              Text('슬라이드 크기  ${(_share * 100).round()}%', style: labelStyle),
              Slider(
                min: minBShare,
                max: maxBShare,
                divisions: 8,
                value: _share,
                label: '${(_share * 100).round()}%',
                onChanged: hasSubtitle
                    ? (v) => setState(() => _share = (v * 20).round() / 20)
                    : null,
              ),
              AspectRatio(
                aspectRatio: width / height,
                child: LayoutBuilder(
                  builder: (context, box) => Container(
                    color: cs.surfaceContainerHighest,
                    child: Stack(
                      children: [
                        _previewCell(cs, box.biggest, rects.slide, '슬라이드'),
                        if (rects.sub case final sub?)
                          _previewCell(cs, box.biggest, sub, '자막'),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                rects.sub == null
                    ? '슬라이드 ${size(rects.slide)}'
                    : '슬라이드 ${size(rects.slide)} · 자막 ${size(rects.sub!)}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Text('자막 주소', style: labelStyle),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _url,
                      onChanged: (_) => setState(() => _urlError = null),
                      decoration: InputDecoration(
                        isDense: true,
                        errorText: _urlError,
                        helperText:
                            '비우면 자막 없이 슬라이드만 나옵니다. '
                            '자막 언어·글자 크기는 통역 프로그램의 OBS 설정을 따릅니다.',
                        helperMaxLines: 3,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _url.text = defaultBSubtitleUrl;
                      _urlError = null;
                    }),
                    child: const Text('기본값'),
                  ),
                ],
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
        FilledButton(onPressed: _save, child: const Text('저장')),
      ],
    );
  }

  Widget _previewCell(ColorScheme cs, Size box, Rect r, String label) =>
      Positioned(
        left: r.left * box.width,
        top: r.top * box.height,
        width: r.width * box.width,
        height: r.height * box.height,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
      );
}

/// 쪽 수가 다를 때 대조 창이 띄우는 경고.
String bCountWarning(int aCount, int bCount, {required bool animated}) {
  final base = '쪽 수가 다릅니다 (원본 $aCount장 / 외국어 $bCount장). 없는 쪽은 통역 화면에 원본이 나옵니다.';
  return animated ? '$base 애니메이션 단계 차이일 수 있습니다.' : base;
}

/// 외국어 PPT 대조 창. '연결'을 누르면 true.
/// 장수는 항목이 아니라 폴더 전체 기준이다 — 나눈 항목도 원본 전체로 비교한다.
Future<bool> showBPairDialog(
  BuildContext context, {
  required String aName,
  required String bName,
  required String aDir,
  required String bDir,
  required int aCount,
  required int bCount,
  required bool animated,
}) async {
  final cs = Theme.of(context).colorScheme;
  final last = math.min(aCount, bCount);
  String page(String dir, int n) =>
      p.join(dir, '${n.toString().padLeft(4, '0')}.png');

  Widget header(String label, String name, int count) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        Tooltip(
          message: name,
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        Text('$count장', style: TextStyle(color: cs.onSurfaceVariant)),
      ],
    ),
  );

  Widget thumb(String label, String path) => Expanded(
    child: Semantics(
      image: true,
      label: label,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Image.file(
            File(path),
            cacheWidth: 480,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );

  Widget row(int n) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$n쪽'),
        const SizedBox(height: 4),
        Row(
          children: [
            thumb('원본 $n쪽', page(aDir, n)),
            const SizedBox(width: 12),
            thumb('외국어 $n쪽', page(bDir, n)),
          ],
        ),
      ],
    ),
  );

  final linked = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('외국어 PPT 확인'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (aCount != bCount)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(10),
                  color: cs.errorContainer,
                  child: Text(
                    bCountWarning(aCount, bCount, animated: animated),
                    style: TextStyle(color: cs.onErrorContainer),
                  ),
                ),
              Row(
                children: [
                  header('원본', aName, aCount),
                  const SizedBox(width: 12),
                  header('외국어', bName, bCount),
                ],
              ),
              row(1),
              if (last > 1) row(last),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('연결'),
        ),
      ],
    ),
  );
  return linked ?? false;
}
