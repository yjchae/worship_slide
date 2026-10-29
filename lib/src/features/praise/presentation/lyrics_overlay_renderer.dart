import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/app_logger.dart';
import '../data/atomic_file.dart';
import '../data/fnv_hash.dart';
import 'slide_page_data.dart';
import 'slide_render_view.dart';

/// 배경 영상 위에 얹을 가사 PNG 를 굽는다(배경 없이 글자만, 1920x1080 투명).
///
/// 미리보기와 같은 [SlideRenderView] 를 화면 밖에서 그려 찍으므로 위치·크기가 미리보기와 같다.
/// 파일 이름 = 페이지 내용·스타일의 해시라 같은 페이지는 한 번만 굽는다.
/// 발표 중에만 쓰는 파일이라 하루 지난 것은 처음 쓸 때 지운다.
class LyricsOverlayRenderer {
  LyricsOverlayRenderer({Future<Directory> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  static const int width = 1920;
  static const int height = 1080;

  /// 그리는 방식이 바뀌면 올린다(예전 파일을 다시 쓰지 않게).
  static const int _renderVersion = 1;

  final Future<Directory> Function() _directory;
  Directory? _dir;
  final _pending = <String, Future<String?>>{};

  static Future<Directory> _defaultDirectory() async {
    final appDir = await getApplicationSupportDirectory();
    return Directory(p.join(appDir.path, 'lyrics_overlays'));
  }

  Future<Directory> _ensureDir() async {
    if (_dir != null) return _dir!;
    final dir = await _directory();
    await dir.create(recursive: true);
    // 지난 발표에서 구운 것. 지금 발표에 필요하면 다시 굽는다.
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    try {
      await for (final entity in dir.list()) {
        if (entity is File && (await entity.stat()).modified.isBefore(cutoff)) {
          await entity.delete().catchError((_) => entity);
        }
      }
    } catch (_) {}
    return _dir = dir;
  }

  // 이번 실행에서 구운(또는 이미 있던) 페이지 키 → 경로. 넘길 때마다 파일을 stat 하지 않게.
  final _done = <String, String>{};

  /// 이번 실행에서 이미 구운 페이지인지(기다리지 않고 바로 보낼 수 있는지).
  bool isCached(SlidePageData page) => _done.containsKey(_keyOf(page));

  /// [page] 의 가사 PNG 경로. 굽지 못하면 null(발표 창은 평소 슬라이드를 낸다).
  /// 같은 페이지를 동시에 여러 번 불러도 한 번만 굽는다.
  Future<String?> render(SlidePageData page) {
    final key = _keyOf(page);
    final done = _done[key];
    if (done != null) return Future.value(done);
    return _pending.putIfAbsent(key, () async {
      try {
        final path = await _render(page, key);
        if (path != null) _done[key] = path;
        return path;
      } catch (e, st) {
        await AppLogger.instance.error('[overlay] 가사 PNG 굽기 실패', e, st);
        return null;
      } finally {
        _pending.remove(key);
      }
    });
  }

  static String _keyOf(SlidePageData page) => fnvHex(
    utf8.encode(
      jsonEncode({
        'v': _renderVersion,
        'main': page.mainText,
        'sub': page.englishText,
        'extra': page.extraText,
        'title': page.title,
        'bible': page.isBible,
        'style': page.style.toJson(),
      }),
    ),
  );

  Future<String?> _render(SlidePageData page, String key) async {
    final dir = await _ensureDir();
    final file = File(p.join(dir.path, 'ov_$key.png'));
    if (await file.exists()) return file.path;
    final image = await renderWidgetToImage(
      SlideRenderView(data: page, textOnly: true),
      const Size(width + 0.0, height + 0.0),
    );
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return null;
      // 같은 이름 = 같은 내용이라 다른 쪽이 먼저 썼으면 그대로 둔다.
      await atomicWrite(
        file,
        (temp) => temp.writeAsBytes(bytes.buffer.asUint8List(), flush: true),
        overwrite: false,
      );
      return file.path;
    } finally {
      image.dispose();
    }
  }
}

/// [widget] 을 화면에 띄우지 않고 [size](논리 픽셀 = 실제 픽셀) 그림으로 그린다.
/// 글자·도형만 그리는 위젯용 — 이미지처럼 나중에 읽혀 오는 것은 비어 있다.
Future<ui.Image> renderWidgetToImage(Widget widget, Size size) async {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final boundary = RenderRepaintBoundary();
  final renderView = RenderView(
    view: view,
    configuration: ViewConfiguration(
      logicalConstraints: BoxConstraints.tight(size),
      physicalConstraints: BoxConstraints.tight(size),
      devicePixelRatio: 1,
    ),
    child: RenderPositionedBox(alignment: Alignment.center, child: boundary),
  );
  final pipelineOwner = PipelineOwner()..rootNode = renderView;
  renderView.prepareInitialFrame();
  final focusManager = FocusManager();
  final buildOwner = BuildOwner(focusManager: focusManager);
  try {
    final adapter = RenderObjectToWidgetAdapter<RenderBox>(
      container: boundary,
      child: MediaQuery(
        data: MediaQueryData(size: size),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.fromSize(size: size, child: widget),
        ),
      ),
    );
    final root = adapter.attachToRenderTree(buildOwner);
    buildOwner
      ..buildScope(root)
      ..finalizeTree();
    pipelineOwner
      ..flushLayout()
      ..flushCompositingBits()
      ..flushPaint();
    final image = await boundary.toImage(pixelRatio: 1);
    // 위젯 트리를 내려 State 들을 정리한다.
    RenderObjectToWidgetAdapter<RenderBox>(
      container: boundary,
    ).attachToRenderTree(buildOwner, root);
    buildOwner.finalizeTree();
    return image;
  } finally {
    focusManager.dispose();
    pipelineOwner.rootNode = null;
    pipelineOwner.dispose();
  }
}
