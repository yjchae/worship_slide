import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/presentation/heard_bubble.dart';

void main() {
  testWidgets('partial → final → 사라짐, 빈 글은 바로 없음', (tester) async {
    final n = ValueNotifier<HeardBubble?>(null);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(children: [HeardBubbleOverlay(bubble: n)]),
        ),
      ),
    );
    expect(find.byType(Text), findsNothing);

    n.value = const HeardBubble('다니엘 삼', seq: 1);
    await tester.pump();
    final partial = tester.widget<Text>(find.text('다니엘 삼'));
    final cs = Theme.of(tester.element(find.byType(Stack).first)).colorScheme;
    expect(partial.style?.color, cs.onInverseSurface);

    n.value = const HeardBubble('다니엘 3장', isFinal: true, seq: 2);
    await tester.pump();
    expect(
      tester.widget<Text>(find.text('다니엘 3장')).style?.color,
      cs.onInverseSurface,
    );

    n.value = null; // 사라지는 중
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );

    n.value = const HeardBubble('');
    await tester.pump();
    expect(find.byType(Text), findsNothing);
  });
}
