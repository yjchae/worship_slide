import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/obs_overlay_server.dart';
import 'package:worship_slides/src/features/praise/data/obs_overlay_store.dart';
import 'package:worship_slides/src/features/praise/domain/obs_caption.dart';
import 'package:worship_slides/src/features/praise/presentation/obs_overlay_dialog.dart';

void main() {
  testWidgets('연결·디자인 탭이 넘치지 않고, 바꾼 값이 onChanged 로 간다', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = ObsOverlayServer();
    final hidden = ValueNotifier(false);
    final changes = <ObsOverlayConfig>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ObsOverlayDialog(
            config: const ObsOverlayConfig(key: 'abcdefgh23456789'),
            server: server,
            hidden: hidden,
            audienceFont: 'Pretendard',
            currentSlide: const ObsSlide(mainText: '지금 가사', subText: 'Now'),
            onChanged: changes.add,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('/obs?k=abcdefgh23456789'), findsWidgets);
    expect(find.text('꺼짐'), findsOneWidget);

    await tester.tap(find.text('OBS 자막 켜기'));
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(changes.last.enabled, isTrue);

    await tester.tap(find.text('OBS 자막 잠시 숨기기'));
    await tester.pump();
    expect(hidden.value, isTrue);

    await tester.tap(find.text('디자인'));
    await tester.pumpAndSettle();
    expect(find.text('지금 가사'), findsOneWidget);
    await tester.tap(find.text('반투명 띠'));
    await tester.pump();
    expect(changes.last.band, ObsBand.text);
    await tester.tap(find.text('성경 예시'));
    await tester.pump();
    expect(find.text('시편 23:1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('앱 바 버튼: 숨김이면 툴팁에 숨김', (tester) async {
    final server = ObsOverlayServer();
    final hidden = ValueNotifier(true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ObsAppBarButton(
            enabled: true,
            port: defaultObsPort,
            server: server,
            hidden: hidden,
            onPressed: () {},
          ),
        ),
      ),
    );
    expect(find.byTooltip('OBS 자막 — 켜는 중… (숨김)'), findsOneWidget);
    hidden.value = false;
    await tester.pump();
    expect(find.byTooltip('OBS 자막 — 켜는 중…'), findsOneWidget);
  });
}
