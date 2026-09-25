import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/offering_design.dart';
import '../presentation/offering_overlay_painter.dart';

/// 헌금송 디자인을 1920x1080 PNG 한 장으로 굽는다.
///
/// 구운 PNG 는 콘티 항목의 배경 이미지로 들어간다. 렌더러 네 곳(미리보기·macOS·
/// Windows·PPTX)이 이미 "항목별 배경 이미지"를 그릴 줄 알기 때문에 헌금송을 위해
/// 렌더링 코드를 하나도 고치지 않아도 된다.
///
/// 저장 위치는 Application Support/offering_backgrounds/ — Caches 가 아닌 이유는 PPT
/// 렌더 캐시와 같다(저장한 콘티가 나중에 배경 유실로 깨지면 안 된다). 같은 디자인이면
/// 파일 이름이 같아서 다시 굽지 않고, 예전 파일은 콘티가 참조할 수 있으므로 지우지 않는다.
class OfferingBackgroundComposer {
  static const int width = 1920;
  static const int height = 1080;

  /// 그리는 방식이 바뀌면 올린다. 키가 달라져 새로 굽는다.
  static const int _renderVersion = 1;

  Future<String> compose(OfferingDesign design) async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appDir.path, 'offering_backgrounds'));
    final file = File(
      p.join(dir.path, 'offering_${await _cacheKey(design)}.png'),
    );
    if (await file.exists()) return file.path;

    await dir.create(recursive: true);
    final bytes = await renderPng(design);
    // 굽다가 앱이 꺼져도 반쪽짜리 파일이 캐시로 남지 않게 임시 파일에 쓰고 바꾼다.
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
    return file.path;
  }

  /// 파일로 쓰지 않고 PNG 바이트만. 테스트에서도 쓴다.
  Future<List<int>> renderPng(OfferingDesign design) async {
    const size = Size(width + 0.0, height + 0.0);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = design.backgroundColor,
    );
    final background = await _loadImage(design.backgroundImagePath);
    if (background != null) {
      // 발표 창(CSS background-size:cover)·PPTX 배경과 같은 cover 규칙.
      paintImage(
        canvas: canvas,
        rect: Offset.zero & size,
        image: background,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
      );
      background.dispose();
    }
    OfferingOverlayPainter(design).paint(canvas, size);

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('헌금송 배경 PNG 인코딩 실패');
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// 배경 이미지를 읽는다. 경로가 없거나 파일이 사라졌거나 못 읽으면 null(단색 배경).
  Future<ui.Image?> _loadImage(String? path) async {
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  /// 디자인 + 배경 이미지 파일 상태로 만든 키. 같은 경로에 다른 그림을 덮어써도
  /// 수정 시각·크기가 바뀌므로 새로 굽는다.
  Future<String> _cacheKey(OfferingDesign design) async {
    final buffer = StringBuffer('v$_renderVersion|')
      ..write(jsonEncode(design.toJson()));
    final path = design.backgroundImagePath;
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (await file.exists()) {
        final stat = await file.stat();
        buffer.write('|${stat.modified.millisecondsSinceEpoch}|${stat.size}');
      }
    }
    final bytes = utf8.encode(buffer.toString());
    // 32비트 FNV-1a 두 개(정방향·역방향)를 이어 16자리. 파일 이름용이라 이 정도면 충분하다.
    return _fnv1a(bytes).toRadixString(16).padLeft(8, '0') +
        _fnv1a(bytes.reversed).toRadixString(16).padLeft(8, '0');
  }

  static int _fnv1a(Iterable<int> bytes) {
    var hash = 0x811c9dc5;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }
}
