import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/slide_media.dart';
import 'package:worship_slides/src/features/praise/presentation/praise_home_page.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_page_data.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_render_view.dart';

// 발표 보기에서 동영상·음악·유튜브 페이지를 알아보게 하는 표시.
void main() {
  Future<void> pump(WidgetTester tester, SlidePageData data) =>
      tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 160,
              height: 90,
              child: ConsoleSlideView(data: data),
            ),
          ),
        ),
      );

  SlidePageData page({SlideMedia? media, String? imagePath}) => SlidePageData(
    mainText: '',
    englishText: '',
    isBible: false,
    pageIndex: 0,
    totalPages: 1,
    style: ExportStyle.fromJson(const {'font_size': 30, 'bible_font_size': 20}),
    imagePath: imagePath,
    media: media,
  );

  const video = SlideMedia(kind: MediaKind.video, source: '/a/광고.mp4');
  const audio = SlideMedia(kind: MediaKind.audio, source: r'C:\a\반주.mp3');

  testWidgets('동영상 페이지는 종류와 이름을 앱 표시로만 보인다', (tester) async {
    await pump(tester, page(media: video));
    expect(find.text('[동영상] 광고.mp4'), findsOneWidget);
    expect(find.byType(SlideRenderView), findsNothing);
  });

  testWidgets('음악 페이지는 슬라이드 위에 표시를 얹는다', (tester) async {
    await pump(tester, page(media: audio));
    expect(find.byType(SlideRenderView), findsOneWidget);
    // 렌더러의 작은 표시 + 앱 표시.
    expect(find.text('[음악] 반주.mp3'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('일반 빈 페이지·PPT 안 동영상은 예전과 같다', (tester) async {
    await pump(tester, page());
    expect(find.byIcon(Icons.movie_outlined), findsNothing);
    await pump(tester, page(media: video, imagePath: '/없는/파일.png'));
    expect(find.byType(SlideRenderView), findsOneWidget);
    expect(find.text('[동영상] 광고.mp4'), findsOneWidget); // 렌더러 표시 하나뿐
  });
}
