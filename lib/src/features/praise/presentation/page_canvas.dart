import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/atomic_file.dart';
import '../data/background_image_library.dart';
import '../data/fnv_hash.dart';
import '../domain/export_style.dart';
import '../domain/page_element.dart';
import 'page_rich_text.dart';
import '../domain/slide_background.dart';
import 'lyrics_overlay_renderer.dart';

/// 슬라이드 편집 페이지 한 장을 그린다: 배경 색 → 배경 그림(cover) → 요소(뒤 요소가 위).
///
/// 늘 1920x1080 논리 크기로 배치한 뒤 [FittedBox] 로 받은 칸에 맞춘다. 편집 창(아무 크기)과
/// PNG 굽기([PageComposer.compose])가 같은 위젯을 써서 글자 줄바꿈까지 똑같다.
///
/// 그림은 미리 디코딩한 [images](경로 → [ui.Image], [PageComposer.loadImages])로 그린다 —
/// `Image.file` 은 화면 밖 굽기에서 읽히기 전에 찍혀 빈칸이 된다. 맵에 없는 그림은 안 그린다.
/// 주변 테마·글자 배율을 타지 않는다(편집 창과 굽기가 달라지지 않게).
///
/// 편집 창은 [editingId] 요소의 글 대신 [editor](캔버스 안 편집기)를 같은 자리에 끼운다 — 편집 중 글자 자리와
/// 굽기 자리가 레이아웃부터 같다. 굽기는 둘 다 null. 이 판이 모르는 요소([PageUnknownElement])는 그리지 않는다.
/// 도형은 [PageShapePainter] 위에 같은 글 칸을 안쪽 여백만큼 들여 놓는다. 글은 [PageTextElement.valign] 대로.
class PageCanvas extends StatelessWidget {
  const PageCanvas({
    super.key,
    required this.elements,
    required this.backgroundColor,
    this.backgroundImage,
    this.images = const {},
    this.editingId,
    this.editor,
  });

  static const double width = 1920;
  static const double height = 1080;

  /// 글 크기(540pt 기준) → 1080px 캔버스 픽셀.
  static const double fontScale = height / 540;

  final List<PageElement> elements;
  final Color backgroundColor;
  final ui.Image? backgroundImage;
  final Map<String, ui.Image> images;
  final String? editingId;
  final Widget? editor;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.fill,
      child: SizedBox(
        width: width,
        height: height,
        child: DefaultTextStyle(
          style: const TextStyle(
            fontFamily: PageTextElement.defaultFontFamily,
            color: Colors.white,
            decoration: TextDecoration.none,
          ),
          child: ClipRect(
            child: Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: backgroundColor)),
                if (backgroundImage != null)
                  Positioned.fill(
                    child: RawImage(
                      image: backgroundImage,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                for (final element in elements)
                  Positioned(
                    // 배경 그림이 늦게 읽혀 앞 칸이 늘어도 편집기 상태(커서·한글 조합)가 남게.
                    key: ValueKey(element.id),
                    left: element.rect.left * width,
                    top: element.rect.top * height,
                    width: element.rect.width * width,
                    height: element.rect.height * height,
                    child: switch (element) {
                      PageImageElement(:final path) => RawImage(
                        image: images[path],
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.high,
                      ),
                      PageShapeElement() => _shape(element),
                      PageTextElement() => _text(element),
                      PageUnknownElement() => const SizedBox.shrink(),
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 채우기 → 테두리, 그 위 안쪽 여백 안에 글(선·화살표는 글 없음).
  Widget _shape(PageShapeElement e) => Stack(
    fit: StackFit.expand,
    children: [
      CustomPaint(painter: PageShapePainter(e, fontScale)),
      if (e.holdsText)
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: PageShapeElement.textInsetH * fontScale,
            vertical: PageShapeElement.textInsetV * fontScale,
          ),
          child: _text(e),
        ),
    ],
  );

  Widget _text(PageTextElement e) => OverflowBox(
    alignment: switch (e.valign) {
      PageVAlign.top => Alignment.topCenter,
      PageVAlign.middle => Alignment.center,
      PageVAlign.bottom => Alignment.bottomCenter,
    },
    minHeight: 0,
    maxHeight: double.infinity,
    child: e.id == editingId && editor != null
        ? editor
        : PageTextBlock(element: e, fontScale: fontScale),
  );
}

/// 도형 모양(채우기 → 테두리). 편집 창 캔버스와 굽기가 같이 쓴다. [scale] = 540pt → px.
/// 사각형·타원 테두리는 상자 안쪽으로 그린다(상자 밖으로 안 나가게 — PowerPoint 는 선 가운데 기준이라 반 두께 차이).
class PageShapePainter extends CustomPainter {
  const PageShapePainter(this.shape, this.scale);

  final PageShapeElement shape;
  final double scale;

  /// 화살표 머리 길이·폭 = 두께 × 이 값.
  static const double arrowHead = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final e = shape;
    final width = e.strokeWidth * scale;
    final stroke = e.stroke != null && width > 0
        ? (Paint()
            ..color = e.stroke!
            ..style = PaintingStyle.stroke
            ..strokeWidth = width
            ..isAntiAlias = true)
        : null;
    if (e.kind.isLine) {
      if (stroke == null) return;
      final a = Offset(e.flipH ? size.width : 0, e.flipV ? size.height : 0);
      final b = Offset(e.flipH ? 0 : size.width, e.flipV ? 0 : size.height);
      final length = (b - a).distance;
      if (length == 0) return;
      if (e.kind == PageShapeKind.line) {
        canvas.drawLine(a, b, stroke);
        return;
      }
      final dir = (b - a) / length;
      final head = math.min(width * arrowHead, length);
      final base = b - dir * head;
      canvas.drawLine(a, base, stroke);
      final side = Offset(-dir.dy, dir.dx) * head / 2;
      canvas.drawPath(
        Path()
          ..moveTo(b.dx, b.dy)
          ..lineTo(base.dx + side.dx, base.dy + side.dy)
          ..lineTo(base.dx - side.dx, base.dy - side.dy)
          ..close(),
        Paint()..color = e.stroke!,
      );
      return;
    }
    final box = Offset.zero & size;
    final inset = stroke == null
        ? box
        : box.deflate(math.min(width, size.shortestSide) / 2);
    void draw(Rect r, Paint paint) => switch (e.kind) {
      PageShapeKind.ellipse => canvas.drawOval(r, paint),
      PageShapeKind.roundRect => canvas.drawRRect(
        RRect.fromRectAndRadius(
          r,
          Radius.circular(e.radius * size.shortestSide),
        ),
        paint,
      ),
      _ => canvas.drawRect(r, paint),
    };
    if (e.fill case final fill?) {
      draw(inset, Paint()..color = fill.withValues(alpha: e.fillAlpha));
    }
    if (stroke != null) draw(inset, stroke);
  }

  @override
  bool shouldRepaint(PageShapePainter old) =>
      old.shape != shape || old.scale != scale;
}

/// [PageCanvas] 를 1920x1080 PNG 한 장으로 굽는다. 구운 PNG 는 `ImageStagingItem` 의 이미지가
/// 되어 기존 'PPT 이미지 페이지' 길로 관객 화면·발표 보기·PPTX·싱어 화면에 나간다.
///
/// 파일은 `Application Support/page_images/render_<키>.png`. 키 = 요소 JSON + 배경(색·그림)
/// + 쓰인 그림 파일의 수정 시각·크기 + [_renderVersion] — 같으면 다시 굽지 않는다.
/// 예전 파일은 저장한 콘티가 가리킬 수 있어 지우지 않는다(헌금송 PNG 와 같다).
/// 글꼴(FontLibrary)을 올리기 전에 구우면 틀린 글꼴로 캐시되니 그 뒤에 부른다.
class PageComposer {
  const PageComposer();

  /// 그리는 방식이 바뀌면 올린다. 키가 달라져 새로 굽는다.
  /// 2: 글을 줄 단위(편집기와 같은 strut·목록 내어쓰기)로 그린다.
  static const int _renderVersion = 2;

  /// 디코딩할 때 긴 변을 이만큼으로 줄인다(큰 캡처가 메모리를 다 먹지 않게).
  static const int maxDecodeSide = 2560;

  /// 그림들을 디코딩한다. 없거나 못 읽는 파일은 맵에서 빠진다.
  /// 다 쓰면 값들을 `dispose` 한다(편집 창은 닫을 때).
  static Future<Map<String, ui.Image>> loadImages(
    Iterable<String> paths,
  ) async {
    final images = <String, ui.Image>{};
    for (final path in paths.toSet()) {
      final image = await _decode(path);
      if (image != null) images[path] = image;
    }
    return images;
  }

  static Future<ui.Image?> _decode(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        await file.readAsBytes(),
      );
      // 긴 변이 maxDecodeSide 를 넘을 때만 비율대로 줄인다.
      final codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (w, h) {
          final longest = math.max(w, h);
          if (longest <= maxDecodeSide) {
            return ui.TargetImageSize(width: w, height: h);
          }
          return ui.TargetImageSize(
            width: math.max(1, (w * maxDecodeSide / longest).round()),
            height: math.max(1, (h * maxDecodeSide / longest).round()),
          );
        },
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  /// 이 페이지의 배경: 항목 배경 [background] 가 있으면 그것(색·그림 통째로), 없으면 전역 [style].
  static ({Color color, String? imagePath}) backgroundOf(
    SlideBackground? background,
    ExportStyle style,
  ) => background != null
      ? (color: background.color, imagePath: background.imagePath)
      : (color: style.backgroundColor, imagePath: style.backgroundImagePath);

  /// 구운 PNG 경로. 같은 내용이 이미 있으면 굽지 않고 그 경로를 준다.
  Future<String> compose({
    required List<PageElement> elements,
    SlideBackground? background,
    required ExportStyle style,
  }) async {
    final bg = backgroundOf(background, style);
    final paths = [
      for (final e in elements)
        if (e is PageImageElement) e.path,
      ?bg.imagePath,
    ];
    final appDir = await getApplicationSupportDirectory();
    final file = File(
      p.join(
        appDir.path,
        BackgroundImageLibrary.pageImagesFolder,
        'render_${await _cacheKey(elements, bg.color, bg.imagePath, paths)}.png',
      ),
    );
    if (await file.exists()) return file.path;

    final images = await loadImages(paths);
    try {
      final image = await renderWidgetToImage(
        PageCanvas(
          elements: elements,
          backgroundColor: bg.color,
          backgroundImage: bg.imagePath == null ? null : images[bg.imagePath],
          images: images,
        ),
        const Size(PageCanvas.width, PageCanvas.height),
      );
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw StateError('편집 페이지 PNG 인코딩 실패');
        // 같은 이름 = 같은 내용이라 다른 쪽이 먼저 썼으면 그대로 둔다.
        await atomicWrite(
          file,
          (temp) => temp.writeAsBytes(bytes.buffer.asUint8List(), flush: true),
          overwrite: false,
        );
      } finally {
        image.dispose();
      }
    } finally {
      for (final image in images.values) {
        image.dispose();
      }
    }
    return file.path;
  }

  static Future<String> _cacheKey(
    List<PageElement> elements,
    Color color,
    String? imagePath,
    List<String> paths,
  ) async {
    final buffer = StringBuffer('v$_renderVersion|')
      ..write(
        jsonEncode({
          'elements': [for (final e in elements) e.toJson()],
          'background_color': colorToHex(color),
          'background_image_path': imagePath,
        }),
      );
    for (final path in paths.toSet()) {
      final file = File(path);
      if (await file.exists()) {
        final stat = await file.stat();
        buffer.write('|${stat.modified.millisecondsSinceEpoch}|${stat.size}');
      } else {
        buffer.write('|-');
      }
    }
    return fnvHex(utf8.encode(buffer.toString()));
  }
}
