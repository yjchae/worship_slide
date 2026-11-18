import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

/// 마이크로 들린 말 한 토막. 2차(싱어 화면 전송)도 이 값을 그대로 읽는다.
/// [seq] 는 새로 올 때마다 늘어난다(같은 글이 또 와도 다른 값).
class HeardBubble {
  const HeardBubble(
    this.text, {
    this.isFinal = false,
    this.isError = false,
    this.seq = 0,
  });
  final String text;
  final bool isFinal;
  final bool isError;
  final int seq;
}

/// 메인 창 맨 위 가운데의 말풍선. Stack 안에 그대로 넣는다.
/// 값이 null = 사라지는 중(페이드 아웃), 글이 빈 값 = 바로 없음.
class HeardBubbleOverlay extends StatefulWidget {
  const HeardBubbleOverlay({super.key, required this.bubble});
  final ValueListenable<HeardBubble?> bubble;

  @override
  State<HeardBubbleOverlay> createState() => _HeardBubbleOverlayState();
}

class _HeardBubbleOverlayState extends State<HeardBubbleOverlay> {
  HeardBubble? _last;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 8,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: ValueListenableBuilder<HeardBubble?>(
          valueListenable: widget.bubble,
          builder: (context, v, _) {
            if (v != null) _last = v.text.isEmpty ? null : v;
            final shown = _last;
            if (shown == null) return const SizedBox.shrink();
            return AnimatedOpacity(
              opacity: v == null ? 0 : 1,
              duration: Duration(milliseconds: v == null ? 300 : 150),
              curve: v == null ? Curves.easeIn : Curves.easeOut,
              child: Center(child: _bubbleBody(context, shown)),
            );
          },
        ),
      ),
    );
  }

  Widget _bubbleBody(BuildContext context, HeardBubble b) {
    final cs = Theme.of(context).colorScheme;
    // 반대 밝기 바탕(밝은 테마 = 짙은 말풍선)에 큰 글씨로 — 어느 슬라이드 위에서도 읽히게.
    final color = b.isError ? cs.errorContainer : cs.onInverseSurface;
    // 길면 앞을 자르고 방금 한 말(뒤)이 보이게.
    final text = b.text.length > 80
        ? '…${b.text.substring(b.text.length - 80)}'
        : b.text;
    return Semantics(
      liveRegion: b.isFinal,
      label: '마이크로 들린 말: ${b.text}',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.7,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cs.inverseSurface.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(22),
            boxShadow: const [
              BoxShadow(color: Color(0x40000000), blurRadius: 12),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  b.isError ? Icons.mic_off_rounded : Icons.mic_rounded,
                  size: 22,
                  color: color,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    text,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: color,
                      fontWeight: b.isFinal ? FontWeight.w700 : FontWeight.w500,
                    ),
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
