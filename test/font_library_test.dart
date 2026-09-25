import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/font_library.dart';

void main() {
  test('폰트 파일에서 family 이름·한국어 이름·굵기를 읽는다', () {
    final bold = readFontInfo(
      File('assets/fonts/free/GothicA1-Bold.ttf').readAsBytesSync(),
    )!;
    expect(bold.family, 'Gothic A1');
    expect(bold.weight, 700);

    final pen = readFontInfo(
      File('assets/fonts/free/NanumPenScript-Regular.ttf').readAsBytesSync(),
    )!;
    expect(pen.family, 'Nanum Pen');
    expect(pen.weight, 400);
  });

  test('폰트가 아니면 null', () {
    expect(readFontInfo(Uint8List.fromList([1, 2, 3])), isNull);
    expect(readFontInfo(Uint8List(64)), isNull);
  });

  test('내장 무료 폰트는 전부 읽힌다', () {
    for (final f in Directory('assets/fonts/free').listSync()) {
      if (!f.path.endsWith('.ttf')) continue;
      final info = readFontInfo(File(f.path).readAsBytesSync());
      expect(info, isNotNull, reason: f.path);
      // ignore: avoid_print
      print('${f.path}: ${info!.family} / ${info.displayName} / ${info.weight}');
    }
  });
}
