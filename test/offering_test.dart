import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/offering_background_composer.dart';
import 'package:worship_slides/src/features/praise/domain/export_style.dart';
import 'package:worship_slides/src/features/praise/domain/offering_design.dart';
import 'package:worship_slides/src/features/praise/domain/slide_background.dart';
import 'package:worship_slides/src/features/praise/presentation/offering_overlay_painter.dart';

/// PNG 를 디코딩해 (x, y) 픽셀 색을 돌려준다.
Future<Color> _pixelAt(List<int> png, int x, int y) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(png));
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final offset = (y * image.width + x) * 4;
  final bytes = data!.buffer.asUint8List();
  final color = Color.fromARGB(
    bytes[offset + 3],
    bytes[offset],
    bytes[offset + 1],
    bytes[offset + 2],
  );
  image.dispose();
  codec.dispose();
  return color;
}

void main() {
  test('헌금송 디자인은 JSON 으로 저장했다 읽어도 같다', () {
    const design = OfferingDesign(
      backgroundImagePath: '/tmp/church.jpg',
      bankName: '농협',
      accountNumber: '02-325-0691-9',
      bandCenterY: 2.4,
      showLines: false,
    );

    expect(OfferingDesign.fromJson(design.toJson()), design);
    expect(design.accountLine, '농협 02-325-0691-9');
  });

  test('예전(키가 빠진) 헌금송 설정은 기본값으로 채워진다', () {
    final design = OfferingDesign.fromJson({'bank_name': '국민'});

    expect(design.label, '헌금');
    expect(design.bankName, '국민');
    expect(design.bandCenterY, OfferingDesign.defaultBandCenterY);
    expect(design.showLines, isTrue);
    expect(design.lyricsAboveBand, isFalse);
  });

  test('높낮이는 화면 밖으로 나가지 않게 잘린다', () {
    const design = OfferingDesign();

    expect(
      design.copyWith(bandCenterY: -3).bandCenterY,
      OfferingDesign.minBandCenterY,
    );
    expect(
      design.copyWith(bandCenterY: 99).bandCenterY,
      OfferingDesign.maxBandCenterY,
    );
  });

  test('항목 배경은 헌금송 디자인까지 함께 저장·복원된다', () {
    const background = SlideBackground(
      color: Color(0xFF0B132B),
      imagePath: '/tmp/offering_x.png',
      offering: OfferingDesign(accountNumber: '123', bandCenterY: 5),
    );

    final decoded = SlideBackground.decode(SlideBackground.encode(background));
    expect(decoded, background);
    expect(decoded!.isOffering, isTrue);
    expect(decoded.offering!.bandCenterY, 5);
  });

  test('헌금송 정보가 없는 예전 항목 배경도 그대로 읽힌다', () {
    final decoded = SlideBackground.decode('{"color":"#112233"}');

    expect(decoded, isNotNull);
    expect(decoded!.isOffering, isFalse);
  });

  test('가사는 띠 윗선 바로 위에서 끝난다(하단 기준 + 위로 민 값)', () {
    const design = OfferingDesign(
      bankName: '농협',
      accountNumber: '02-325',
      lyricsAboveBand: true,
    );
    final band = OfferingOverlayPainter.bandBounds(design);
    final placement = OfferingOverlayPainter.lyricsPlacement(design);

    expect(placement.position, VerticalTextPosition.bottom);
    // 가사 상자 아래쪽 = 0.6 + 5.4 + 미세 조정
    final lyricsBottom = 6.0 + placement.offsetY!;
    expect(lyricsBottom, lessThan(band.top));
    expect(band.top - lyricsBottom, closeTo(design.lyricsGap, 0.02));

    // 간격을 넓히면 가사가 그만큼 더 위로 올라간다
    final wider = OfferingOverlayPainter.lyricsPlacement(
      design.copyWith(lyricsGap: design.lyricsGap + 0.3),
    );
    expect(placement.offsetY! - wider.offsetY!, closeTo(0.3, 0.02));
    expect(OfferingOverlayPainter.fitsLyricsAbove(design), isTrue);

    // 띠를 내리면 가사도 같이 내려온다
    final lower = OfferingOverlayPainter.lyricsPlacement(
      design.copyWith(bandCenterY: design.bandCenterY + 0.5),
    );
    expect(lower.offsetY! - placement.offsetY!, closeTo(0.5, 0.02));
  });

  test('띠가 너무 위면 가사를 다 올릴 수 없다고 알려 준다', () {
    const design = OfferingDesign(bandCenterY: 1.0, lyricsAboveBand: true);

    expect(OfferingOverlayPainter.fitsLyricsAbove(design), isFalse);
    // 미세 조정 허용 범위(±2.0)를 넘지 않는다 — 네 렌더러가 모두 같은 범위로 자른다
    expect(
      OfferingOverlayPainter.lyricsPlacement(design).offsetY,
      kMinTextOffsetY,
    );
  });

  test('"가사는 띠 위쪽"을 끄면 가사 위치를 건드리지 않는다', () {
    const design = OfferingDesign(lyricsAboveBand: false);
    final placement = OfferingOverlayPainter.lyricsPlacement(design);

    expect(placement.position, isNull);
    expect(placement.offsetY, isNull);
  });

  test('항목 가사 위치는 찬양 가사에만 적용되고 성경은 그대로다', () {
    const global = ExportStyle(
      fontSize: 30,
      bibleFontSize: 30,
      backgroundColor: Color(0xFF1B1B1B),
      textColor: Colors.white,
      bibleTextColor: Colors.white,
      textPosition: VerticalTextPosition.middle,
      bibleTextPosition: VerticalTextPosition.middle,
      lyricsTextAlign: HorizontalPosition.center,
      bibleTextAlign: HorizontalPosition.center,
      includeEnglishLyrics: true,
      englishTextColor: Color(0xFFFFF176),
      showSongTitle: false,
      showBibleTitle: false,
      titleFontSize: 14,
      bibleTitleFontSize: 14,
      titleTextColor: Color(0xB3FFFFFF),
      bibleTitleTextColor: Color(0xB3FFFFFF),
      titleHorizontalPosition: HorizontalPosition.right,
      titleVerticalPosition: VerticalTextPosition.bottom,
      bibleTitleHorizontalPosition: HorizontalPosition.right,
      bibleTitleVerticalPosition: VerticalTextPosition.bottom,
    );
    const background = SlideBackground(
      color: Color(0xFF0B132B),
      lyricsPosition: VerticalTextPosition.bottom,
      lyricsOffsetY: -1.2,
    );

    final style = global.withBackground(background);
    expect(style.textPosition, VerticalTextPosition.bottom);
    expect(style.textOffsetY, -1.2);
    expect(style.bibleTextPosition, VerticalTextPosition.middle);
    expect(style.bibleTextOffsetY, 0);
    // 발표 창·PPTX 로 나가는 JSON 에도 실린다
    expect(style.toJson()['text_position'], 'bottom');
    expect(background.toJson()['text_offset_y'], -1.2);

    // 가사 위치 없는 배경은 전역 위치 그대로
    final plain = global.withBackground(
      const SlideBackground(color: Color(0xFF000000)),
    );
    expect(plain.textPosition, VerticalTextPosition.middle);
    expect(plain.textOffsetY, 0);

    final decoded = SlideBackground.decode(SlideBackground.encode(background));
    expect(decoded, background);
  });

  testWidgets('구운 배경에 라인이 높낮이대로 그려진다', (tester) async {
    const yellow = Color(0xFFFFE600);
    const navy = Color(0xFF0B132B);
    // 글씨를 비우면 띠 높이가 0 이라 라인이 정확히 중심 ± 간격에 놓인다.
    const design = OfferingDesign(
      label: '',
      bandCenterY: OfferingDesign.slideHeight / 2,
      backgroundColor: navy,
      lineColor: yellow,
      lineThickness: 3, // 1080px 기준 6px
      linePadding: 0.2, // 1080 / 7.5 * 0.2 = 28.8px
    );
    final composer = OfferingBackgroundComposer();

    await tester.runAsync(() async {
      // 가운데(540px) → 라인은 511px, 569px 근처
      final middle = await composer.renderPng(design);
      expect(await _pixelAt(middle, 960, 511), yellow);
      expect(await _pixelAt(middle, 960, 569), yellow);
      expect(await _pixelAt(middle, 960, 540), navy);
      expect(await _pixelAt(middle, 5, 5), navy);
      // 라인 길이(5.6in = 806px) 밖은 배경색
      expect(await _pixelAt(middle, 100, 511), navy);

      // 위로 올리면(2.0in = 288px) 라인도 같이 올라간다
      final raised = await composer.renderPng(
        design.copyWith(bandCenterY: 2.0),
      );
      expect(await _pixelAt(raised, 960, 259), yellow);
      expect(await _pixelAt(raised, 960, 511), navy);

      // 라인을 끄면 그리지 않는다
      final noLines = await composer.renderPng(
        design.copyWith(showLines: false),
      );
      expect(await _pixelAt(noLines, 960, 511), navy);
    });
  });
}
