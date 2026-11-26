import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/data/obs_overlay_store.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('obs_store'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('처음 읽으면 키를 만들어 저장하고, 다시 읽어도 같은 키', () async {
    final store = ObsOverlayStore(directory: dir);
    final first = await store.load();
    expect(first.key, matches(RegExp(r'^[a-z0-9]{16}$')));
    expect(first.enabled, isFalse);
    expect(first.port, defaultObsPort);
    final second = await store.load();
    expect(second.key, first.key);
  });

  test('저장·읽기 왕복', () async {
    final store = ObsOverlayStore(directory: dir);
    final config = (await store.load()).copyWith(
      enabled: true,
      port: 9001,
      allowLan: false,
      fontFamily: 'NanumGothic',
      band: ObsBand.full,
      align: ObsAlign.left,
      anchor: ObsAnchor.top,
      mainColor: '#ABCDEF',
    );
    await store.save(config);
    final back = await store.load();
    expect(back.toJson(), config.toJson());
  });

  test('틀린 값은 범위 안으로·기본값으로', () {
    final c = ObsOverlayConfig.fromJson({
      'port': 80,
      'key': 'BAD KEY!',
      'font_size': 9999,
      'band_opacity': -3,
      'main_color': 'red',
      'band': 'zigzag',
      'max_height': double.nan,
      'enabled': 'yes',
    });
    expect(c.port, defaultObsPort);
    expect(c.key, '');
    expect(c.fontSize, 200);
    expect(c.bandOpacity, 0);
    expect(c.mainColor, '#FFFFFF');
    expect(c.band, ObsBand.none);
    expect(c.maxHeight, const ObsOverlayConfig().maxHeight);
    expect(c.enabled, isFalse);
  });

  test('깨진 파일은 기본값으로 시작하고 사본을 남긴다', () async {
    File('${dir.path}/obs_overlay.json').writeAsStringSync('{깨짐');
    final c = await ObsOverlayStore(directory: dir).load();
    expect(c.key, isNotEmpty);
    expect(
      File('${dir.path}/obs_overlay.json.broken.bak').existsSync(),
      isTrue,
    );
    expect(
      jsonDecode(
        File('${dir.path}/obs_overlay.json').readAsStringSync(),
      )['key'],
      c.key,
    );
  });

  test('디자인 기본값으로 되돌려도 연결 칸은 남는다', () {
    final c = const ObsOverlayConfig(
      enabled: true,
      port: 9100,
      key: 'abcdefgh23456789',
      allowLan: false,
      fontSize: 90,
    ).resetDesign();
    expect(c.enabled, isTrue);
    expect(c.port, 9100);
    expect(c.key, 'abcdefgh23456789');
    expect(c.allowLan, isFalse);
    expect(c.fontSize, const ObsOverlayConfig().fontSize);
  });

  test('designJson 에는 키·포트가 없다(OBS 로 키가 새지 않게)', () {
    final json = const ObsOverlayConfig(key: 'abcdefgh23456789').designJson();
    expect(json.containsKey('key'), isFalse);
    expect(json.containsKey('port'), isFalse);
  });
}
