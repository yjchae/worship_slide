import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/worship_conti_repository.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/slide_background.dart';
import 'package:worship_slides/src/features/praise/domain/slide_media.dart';
import 'package:worship_slides/src/features/praise/presentation/lyrics_overlay_renderer.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_backdrop.dart';
import 'package:worship_slides/src/features/praise/presentation/slide_page_data.dart';

const _style = ExportStyle(
  fontSize: 30,
  bibleFontSize: 30,
  backgroundColor: Color(0xFF1B1B1B),
  textColor: Colors.white,
  bibleTextColor: Colors.white,
  textPosition: VerticalTextPosition.bottom,
  bibleTextPosition: VerticalTextPosition.middle,
  lyricsTextAlign: HorizontalPosition.center,
  bibleTextAlign: HorizontalPosition.center,
  includeEnglishLyrics: true,
  englishTextColor: Color(0xFFFFF176),
  showSongTitle: true,
  showBibleTitle: false,
  titleFontSize: 14,
  bibleTitleFontSize: 14,
  titleTextColor: Colors.white,
  bibleTitleTextColor: Colors.white,
  titleHorizontalPosition: HorizontalPosition.right,
  titleVerticalPosition: VerticalTextPosition.bottom,
  bibleTitleHorizontalPosition: HorizontalPosition.right,
  bibleTitleVerticalPosition: VerticalTextPosition.bottom,
);

SlidePageData _page(String text, {SlideBackdrop? backdrop, SlideMedia? media}) =>
    SlidePageData(
      mainText: text,
      englishText: '',
      title: '불을 내려주소서',
      isBible: false,
      pageIndex: 0,
      totalPages: 3,
      style: _style,
      media: media,
      mediaGroup: 7,
      backdrop: backdrop,
    );

void main() {
  test('배경 영상은 JSON 에 저장되고 .wsconti 로는 나가지 않는다', () {
    const bg = SlideBackground(
      color: Color(0xFF101010),
      imagePath: '/bg/fire.png',
      videoPath: '/videos/fire.mp4',
      videoDim: 0.45,
    );
    final round = SlideBackground.decode(SlideBackground.encode(bg));
    expect(round, bg);
    expect(round!.hasVideo, isTrue);

    final packed = WorshipContiRepository.mapBackgroundPaths(
      SlideBackground.encode(bg),
      (path) => path == null ? null : 'file0.png',
    );
    final json = jsonDecode(packed! as String) as Map;
    expect(json.containsKey('video_path'), isFalse);
    expect(json.containsKey('video_dim'), isFalse);
    // 영상 대신 대체 배경 이미지는 그대로 실린다.
    expect(json['image_path'], 'file0.png');
  });

  test('깨진 어둡기 값은 범위 안으로', () {
    final bg = SlideBackground.fromJson({
      'color': '#000000',
      'video_path': '/v.mp4',
      'video_dim': 3,
    });
    expect(bg!.videoDim, SlideBackground.maxVideoDim);
  });

  test('배경 영상 key 는 항목·페이지와 상관없다 — 넘겨도·곡을 나눠도 이어서 튼다', () {
    const backdrop = SlideBackdrop(
      videoPath: '/videos/fire.mp4',
      dim: 0.3,
      overlayPath: '/tmp/ov_a.png',
    );
    final a = _page('1절', backdrop: backdrop);
    final b = _page('2절', backdrop: backdrop.withOverlay('/tmp/ov_b.png'));
    expect(a.mediaKey, isNotNull);
    expect(a.mediaKey, b.mediaKey);

    final media = a.toJson()['media'] as Map<String, dynamic>;
    expect(media['backdrop'], isTrue);
    expect(media['kind'], 'video');
    expect(media['overlay_js'], contains('setOverlay('));
    expect(media['overlay_js'], contains('ov_a.png'));
    expect(media['html'], contains('ov_a.png'));
    expect(
      (b.toJson()['media'] as Map)['overlay_js'],
      isNot(media['overlay_js']),
    );
  });

  test('가사 PNG 를 굽기 전이거나 페이지 미디어가 있으면 배경 영상을 보내지 않는다', () {
    const unbaked = SlideBackdrop(videoPath: '/v.mp4', dim: 0.3);
    expect(_page('가사', backdrop: unbaked).toJson()['media'], isNull);
    expect(_page('가사', backdrop: unbaked).mediaKey, isNull);

    const media = SlideMedia(kind: MediaKind.video, source: '/clip.mp4');
    final page = _page(
      '',
      media: media,
      backdrop: unbaked.withOverlay('/tmp/ov.png'),
    );
    expect((page.toJson()['media'] as Map)['source'], '/clip.mp4');
    expect((page.toJson()['media'] as Map).containsKey('backdrop'), isFalse);
  });

  testWidgets('가사만 그린 투명 PNG 를 굽고, 같은 페이지는 다시 굽지 않는다', (tester) async {
    final dir = Directory.systemTemp.createTempSync('overlay_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final renderer = LyricsOverlayRenderer(directory: () async => dir);

    final path = await tester.runAsync(() => renderer.render(_page('주의 영광')));
    expect(path, isNotNull);
    final file = File(path!);
    expect(file.existsSync(), isTrue);

    final image = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
      return (await codec.getNextFrame()).image;
    });
    expect(image!.width, LyricsOverlayRenderer.width);
    expect(image.height, LyricsOverlayRenderer.height);
    final pixels = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    // 모서리는 투명(배경을 안 그린다), 가사 자리엔 글자가 그려져 있다.
    expect(pixels.getUint8(3), 0);
    var drawn = 0;
    for (var i = 3; i < pixels.lengthInBytes; i += 4) {
      if (pixels.getUint8(i) > 0) drawn++;
    }
    expect(drawn, greaterThan(100));

    final modified = file.lastModifiedSync();
    final again = await tester.runAsync(() => renderer.render(_page('주의 영광')));
    expect(again, path);
    expect(File(again!).lastModifiedSync(), modified);

    final other = await tester.runAsync(() => renderer.render(_page('다른 가사')));
    expect(other, isNot(path));
  });
}
