import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/offering_background_composer.dart';
import 'package:worship_slides/src/features/praise/domain/offering_design.dart';
import 'package:worship_slides/src/features/praise/domain/slide_background.dart';

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
    expect(design.bandCenterY, OfferingDesign.slideHeight / 2);
    expect(design.showLines, isTrue);
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

  testWidgets('구운 배경에 라인이 높낮이대로 그려진다', (tester) async {
    const yellow = Color(0xFFFFE600);
    const navy = Color(0xFF0B132B);
    // 글씨를 비우면 띠 높이가 0 이라 라인이 정확히 중심 ± 간격에 놓인다.
    const design = OfferingDesign(
      label: '',
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
