import 'dart:convert';
import 'dart:io';
import 'dart:ui' show loadFontFromList;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 내장 무료 폰트 한 벌(같은 family 의 Regular/Bold 파일들).
class CustomFont {
  const CustomFont({
    required this.family,
    required this.displayName,
    required this.files,
  });

  /// 폰트 파일 안의 family 이름(name ID 1, 영어). Windows GDI·PowerPoint 가
  /// 이 이름으로 폰트를 찾으므로 Flutter FontLoader 이름도 이걸로 맞춘다.
  final String family;

  /// 화면에 보일 이름. 한국어 이름이 박혀 있으면 그것.
  final String displayName;
  final List<({String path, int weight})> files;
}

/// 앱에 같이 넣은 무료(OFL) 폰트(`assets/fonts/free/`) 모음.
///
/// 파일은 Application Support/fonts/ 로 복사한다. 사용자가 폰트를 직접 추가하는
/// 기능은 라이선스 책임 문제로 일부러 넣지 않았다. 렌더러 네 곳이 같은 파일을 쓴다:
/// 미리보기는 FontLoader, 발표 창·PPTX 는 style JSON 의 `font_files` 경로.
class FontLibrary {
  FontLibrary._();

  static const _extensions = ['ttf', 'otf'];
  static const _builtInPrefix = 'assets/fonts/free/';
  // 한국어 이름이 파일에 안 박힌 내장 폰트.
  static const _koreanNames = {'Jua': '주아', 'Do Hyeon': '도현'};

  static List<CustomFont> fonts = const [];
  static final Set<String> _loadedPaths = {};

  static Future<Directory> _dir() async {
    final appDir = await getApplicationSupportDirectory();
    return Directory(p.join(appDir.path, 'fonts'));
  }

  /// 앱 시작 시 한 번. 내장 무료 폰트를 복사하고 전부 Flutter 에 올린다.
  static Future<void> load() async {
    final dir = await _dir();
    await dir.create(recursive: true);
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest
        .listAssets()
        .where((a) => a.startsWith(_builtInPrefix) && _isAllowed(a));
    for (final asset in assets) {
      final target = File(p.join(dir.path, p.basename(asset)));
      if (await target.exists()) continue;
      final data = await rootBundle.load(asset);
      await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    await _rescan();
  }

  /// 발표 창·PPTX 에 넘길 파일 목록. 내장 3종(Pretendard 등)이면 빈 목록.
  static List<Map<String, Object>> filesFor(String family) => [
    for (final font in fonts)
      if (font.family == family)
        for (final f in font.files) {'path': f.path, 'weight': f.weight},
  ];

  static Future<void> _rescan() async {
    final dir = await _dir();
    final byFamily = <String, List<({String path, int weight})>>{};
    final names = <String, String>{};
    await for (final entity in dir.list()) {
      if (entity is! File || !_isAllowed(entity.path)) continue;
      final bytes = await entity.readAsBytes();
      final info = readFontInfo(bytes);
      if (info == null) continue;
      byFamily
          .putIfAbsent(info.family, () => [])
          .add((path: entity.path, weight: info.weight));
      names[info.family] = _koreanNames[info.family] ?? info.displayName;
      if (_loadedPaths.add(entity.path)) {
        await loadFontFromList(bytes, fontFamily: info.family);
      }
    }
    fonts = [
      for (final e in byFamily.entries)
        CustomFont(
          family: e.key,
          displayName: names[e.key]!,
          files: e.value..sort((a, b) => a.weight.compareTo(b.weight)),
        ),
    ]..sort((a, b) => a.displayName.compareTo(b.displayName));
  }

  static bool _isAllowed(String path) => _extensions.contains(
    p.extension(path).toLowerCase().replaceFirst('.', ''),
  );
}

/// TTF/OTF 의 name·OS/2 테이블에서 family 이름과 굵기를 읽는다. 폰트가 아니면 null.
({String family, String displayName, int weight})? readFontInfo(
  Uint8List bytes,
) {
  try {
    final d = ByteData.sublistView(bytes);
    final numTables = d.getUint16(4);
    int? nameOff, os2Off;
    for (var i = 0; i < numTables; i++) {
      final rec = 12 + i * 16;
      final tag = ascii.decode(bytes.sublist(rec, rec + 4));
      if (tag == 'name') nameOff = d.getUint32(rec + 8);
      if (tag == 'OS/2') os2Off = d.getUint32(rec + 8);
    }
    if (nameOff == null) return null;

    final count = d.getUint16(nameOff + 2);
    final strings = nameOff + d.getUint16(nameOff + 4);
    String? english, korean, mac;
    for (var i = 0; i < count; i++) {
      final r = nameOff + 6 + i * 12;
      final platform = d.getUint16(r);
      final lang = d.getUint16(r + 4);
      if (d.getUint16(r + 6) != 1) continue; // name ID 1 = family
      final start = strings + d.getUint16(r + 10);
      final raw = bytes.sublist(start, start + d.getUint16(r + 8));
      if (platform == 3) {
        final units = [
          for (var j = 0; j + 1 < raw.length; j += 2) raw[j] << 8 | raw[j + 1],
        ];
        final s = String.fromCharCodes(units);
        if (lang == 0x0409) english ??= s;
        if (lang == 0x0412) korean ??= s;
      } else if (platform == 1 && lang == 0) {
        mac ??= latin1.decode(raw);
      }
    }
    final family = english ?? mac;
    if (family == null || family.isEmpty) return null;
    final weight = os2Off == null ? 400 : d.getUint16(os2Off + 4);
    return (family: family, displayName: korean ?? family, weight: weight);
  } catch (_) {
    return null;
  }
}
