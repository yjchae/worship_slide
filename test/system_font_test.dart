import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/font_library.dart';
import 'package:worship_slides/src/features/praise/presentation/lyrics_overlay_renderer.dart';

// PPT 가져오기 '이 PC 글꼴': name 테이블(모든 언어·TTC)·TTC 한 글꼴 떼기·시스템 폴더에서 이름으로 찾아 올리기.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, int> namesOf(Uint8List bytes) =>
      fontFaceNames((offset, length) => bytes.sublist(offset, offset + length));

  test('name 테이블: 내장 폰트의 영어 이름·한글 이름을 모두 읽는다', () {
    final names = namesOf(
      File('assets/fonts/free/GothicA1-Bold.ttf').readAsBytesSync(),
    );
    expect(names.keys, contains('Gothic A1'));
    // GothicA1 은 한국어 이름(name ID 1, 0x0412)이 박혀 있다 — readFontInfo 의 displayName 과 같아야 한다.
    final info = readFontInfo(
      File('assets/fonts/free/GothicA1-Bold.ttf').readAsBytesSync(),
    )!;
    expect(names.keys, contains(info.displayName));
  });

  test('TTC: 글꼴마다 번호, 떼어 낸 글꼴은 그 글꼴 이름만 가진 TTF', () {
    const ttc = '/System/Library/Fonts/AppleSDGothicNeo.ttc';
    if (!File(ttc).existsSync()) {
      markTestSkipped('이 PC 에 $ttc 가 없다');
      return;
    }
    final bytes = File(ttc).readAsBytesSync();
    final names = namesOf(bytes);
    final bold = names.entries.firstWhere((e) => e.value > 0).value;
    final single = singleFontBytes(bytes, bold)!;
    final singleNames = namesOf(single);
    expect(singleNames.values.toSet(), {0});
    // 같은 이름(공통 family)은 첫 글꼴 번호로 잡히므로, 그 번호로 잡힌 고유 이름(굵기 이름)이 다 들어 있으면 된다.
    expect(
      singleNames.keys,
      containsAll([
        for (final e in names.entries)
          if (e.value == bold) e.key,
      ]),
    );
    expect(singleFontBytes(bytes, 999), isNull);
    // TTC 가 아니면 그대로.
    final ttf = File('assets/fonts/free/GothicA1-Bold.ttf').readAsBytesSync();
    expect(identical(singleFontBytes(ttf, 0), ttf), isTrue);
  });

  test('시스템 글꼴을 한글 이름으로 찾아 올리면 그 글꼴로 그린다', () async {
    const family = 'Apple SD 산돌고딕 Neo'; // TTC 안, 한글 이름
    final dirs = systemFontDirs();
    if (dirs.isEmpty || indexFontFiles(dirs)[family] == null) {
      markTestSkipped('이 PC 에 $family 가 없다');
      return;
    }
    Future<Uint8List> shot(String fontFamily) async {
      final image = await renderWidgetToImage(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Container(
            color: Colors.white,
            alignment: Alignment.center,
            child: Text(
              '주 은혜 감사',
              style: TextStyle(
                fontFamily: fontFamily,
                fontSize: 40,
                color: Colors.black,
              ),
            ),
          ),
        ),
        const Size(400, 100),
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List();
    }

    final before = await shot(family);
    expect(FontLibrary.isAppFont(family), isFalse);
    await FontLibrary.ensureFamilies([family, '정말없는글꼴_xyz']);
    expect(FontLibrary.systemFamilies, contains(family));
    expect(FontLibrary.systemFamilies, isNot(contains('정말없는글꼴_xyz')));
    final after = await shot(family);
    expect(after, isNot(equals(before)));
  });
}
