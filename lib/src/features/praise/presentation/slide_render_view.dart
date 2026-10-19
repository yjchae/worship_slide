import 'dart:io';

import 'package:flutter/material.dart';

import '../domain/export_style.dart';
import '../domain/slide_media.dart';
import 'slide_page_data.dart';

/// 슬라이드 한 장을 렌더링하는 공유 위젯.
/// 발표 팝업과 컨트롤러 썸네일 모두 이 위젯을 사용한다.
class SlideRenderView extends StatelessWidget {
  const SlideRenderView({super.key, required this.data, this.textOnly = false});
  final SlidePageData data;

  /// 배경(색·이미지)과 미디어 표시 없이 글자만 — 배경 영상 위에 얹을 가사 PNG 를 굽는 데 쓴다.
  final bool textOnly;

  // ppt_tool render가 굽는 이미지 가로 픽셀 (RENDER_IMAGE_WIDTH와 동일)
  static const int _imageMaxWidth = 1920;
  static const double _slideW = 13.333;
  static const double _slideH = 7.5;
  static const double _lyricsBoxT = 0.6;
  static const double _lyricsBoxH = 5.4;
  static const double _lyricsBoxW = _slideW * 0.9;
  static const double _lyricsBoxL = (_slideW - _lyricsBoxW) / 2;
  static const double _titleBoxH = 0.55;
  static const double _titlePad = 0.2;
  static const double _titleBoxWSide = _slideW - (_titlePad * 2);
  static const double _titleBoxWCenter = 10.0;

  /// 존재하는 배경 이미지 파일. 경로가 없거나 파일이 사라졌으면 null.
  static File? _backgroundImageFile(ExportStyle style) {
    final path = style.backgroundImagePath;
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    return file.existsSync() ? file : null;
  }

  @override
  Widget build(BuildContext context) {
    if (textOnly) return _buildSlide(context);
    final media = data.media;
    final backdrop = data.backdrop;
    if (media == null && backdrop != null) {
      // 미리보기는 영상을 틀지 않는다. 대체 배경(이미지·색) 위 가사 + 작은 표시.
      return Stack(
        fit: StackFit.expand,
        children: [
          _buildSlide(context),
          _mediaBadge(
            Icons.movie_filter_outlined,
            '배경 영상',
            covers: false,
          ),
        ],
      );
    }
    if (media == null) return _buildSlide(context);
    // 미리보기는 재생하지 않는다 — 무엇이 나갈지만 표시한다. 화면 전체 동영상·유튜브는
    // 발표 창에서도 페이지를 덮으므로 검은 바탕, 음악·PPT 안 동영상은 페이지 위 작은 표시.
    final covers = media.kind != MediaKind.audio && media.rect == null;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (covers) const ColoredBox(color: Colors.black) else _buildSlide(context),
        _mediaBadge(mediaIcon(media.kind), media.label, covers: covers),
      ],
    );
  }

  static Widget _mediaBadge(IconData icon, String label, {required bool covers}) {
    return Align(
      alignment: covers ? Alignment.center : Alignment.topRight,
      child: FractionallySizedBox(
        widthFactor: covers ? 0.8 : 0.4,
        heightFactor: covers ? 0.3 : 0.14,
        child: FittedBox(
          alignment: covers ? Alignment.center : Alignment.topRight,
          child: Container(
            margin: const EdgeInsets.all(6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 18),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData mediaIcon(MediaKind kind) => switch (kind) {
    MediaKind.video => Icons.movie_outlined,
    MediaKind.audio => Icons.music_note_outlined,
    MediaKind.youtube => Icons.smart_display_outlined,
  };

  Widget _buildSlide(BuildContext context) {
    final style = data.style;
    final isBible = data.isBible;
    final backgroundImage = textOnly ? null : _backgroundImageFile(style);

    // 외부 PPT 이미지 슬라이드는 디자인 설정을 타지 않고 원본 그대로 보여준다.
    final imagePath = data.imagePath;
    if (imagePath != null) {
      return LayoutBuilder(
        builder: (context, constraints) {
          // 썸네일이 1920px 원본을 그대로 디코딩하지 않도록 표시 크기로 제한한다.
          final dpr = MediaQuery.devicePixelRatioOf(context);
          final cacheWidth = constraints.maxWidth.isFinite
              ? (constraints.maxWidth * dpr).round().clamp(1, _imageMaxWidth)
              : _imageMaxWidth;
          return Container(
            color: style.backgroundColor,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 원본 이미지가 꽉 차지 않을 때 남는 여백. PPTX 내보내기와 같게
                // 슬라이드 배경(이미지가 있으면 이미지)이 보여야 한다.
                if (backgroundImage != null)
                  Image.file(backgroundImage, fit: BoxFit.cover),
                Image.file(
                  File(imagePath),
                  fit: BoxFit.contain,
                  width: double.infinity,
                  height: double.infinity,
                  cacheWidth: cacheWidth,
                  errorBuilder: (_, _, _) => const Center(
                    child: Text(
                      '이미지를 찾을 수 없습니다',
                      style: TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    final bodyTextPosition = isBible
        ? style.bibleTextPosition
        : style.textPosition;
    final titleHPos = isBible
        ? style.bibleTitleHorizontalPosition
        : style.titleHorizontalPosition;
    final titleVPos = isBible
        ? style.bibleTitleVerticalPosition
        : style.titleVerticalPosition;
    final bodyFontSize = isBible ? style.bibleFontSize : style.fontSize;
    // 본문 상자는 크기가 고정이고, 미세 조정이 그 상자를 통째로 위아래로 민다.
    // 그래야 상단/중단/하단 어느 기준이든 밀어 준 만큼 똑같이 움직인다.
    final bodyBoxTop =
        _lyricsBoxT +
        clampTextOffsetY(isBible ? style.bibleTextOffsetY : style.textOffsetY);
    final showTitle = isBible ? style.showBibleTitle : style.showSongTitle;
    final titleFontSize = isBible
        ? style.bibleTitleFontSize
        : style.titleFontSize;
    final titleTextColor = isBible
        ? style.bibleTitleTextColor
        : style.titleTextColor;
    final titleOffsetY = clampTextOffsetY(
      isBible ? style.bibleTitleOffsetY : style.titleOffsetY,
    );
    final bodyTextColor = isBible ? style.bibleTextColor : style.textColor;
    final bodyTextAlign = isBible
        ? style.bibleTextAlign
        : style.lyricsTextAlign;

    final bodyAlignment = switch (bodyTextPosition) {
      VerticalTextPosition.top => Alignment.topCenter,
      VerticalTextPosition.middle => Alignment.center,
      VerticalTextPosition.bottom => Alignment.bottomCenter,
    };

    final textAlign = switch (bodyTextAlign) {
      HorizontalPosition.left => TextAlign.left,
      HorizontalPosition.center => TextAlign.center,
      HorizontalPosition.right => TextAlign.right,
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        if (!w.isFinite || !h.isFinite || w <= 0 || h <= 0) {
          return const SizedBox.shrink();
        }
        final fontScale = h / (_slideH * 72);

        final double titleBoxW;
        final double titleLeft;
        final TextAlign titleAlign;
        switch (titleHPos) {
          case HorizontalPosition.left:
            titleBoxW = _titleBoxWSide;
            titleLeft = _titlePad;
            titleAlign = TextAlign.left;
          case HorizontalPosition.center:
            titleBoxW = _titleBoxWCenter;
            titleLeft = (_slideW - _titleBoxWCenter) / 2;
            titleAlign = TextAlign.center;
          case HorizontalPosition.right:
            titleBoxW = _titleBoxWSide;
            titleLeft = _slideW - _titlePad - _titleBoxWSide;
            titleAlign = TextAlign.right;
        }
        // 제목도 본문과 같다. 기준선(상단/중단/하단)에서 미세 조정만큼 더 민다.
        final double titleTop =
            switch (titleVPos) {
              VerticalTextPosition.top => _titlePad,
              VerticalTextPosition.middle => (_slideH - _titleBoxH) / 2,
              VerticalTextPosition.bottom => _slideH - _titlePad - _titleBoxH,
            } +
            titleOffsetY;

        return Container(
          color: textOnly ? null : style.backgroundColor,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              if (backgroundImage != null)
                Positioned.fill(
                  child: Image.file(backgroundImage, fit: BoxFit.cover),
                ),
              Positioned(
                left: w * _lyricsBoxL / _slideW,
                top: h * bodyBoxTop / _slideH,
                width: w * _lyricsBoxW / _slideW,
                height: h * _lyricsBoxH / _slideH,
                child: Align(
                  alignment: bodyAlignment,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: bodyAlignment,
                    child: SizedBox(
                      width: w * _lyricsBoxW / _slideW,
                      child: DefaultTextStyle(
                        style: const TextStyle(),
                        child: RichText(
                          textAlign: textAlign,
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: data.mainText,
                                style: TextStyle(
                                  color: bodyTextColor,
                                  fontSize: bodyFontSize * fontScale,
                                  fontFamily: style.fontFamily,
                                  fontWeight: FontWeight.w700,
                                  height: 1.25,
                                ),
                              ),
                              if (style.includeEnglishLyrics &&
                                  data.englishText.isNotEmpty)
                                TextSpan(
                                  text: '\n${data.englishText}',
                                  style: TextStyle(
                                    color: style.englishTextColor,
                                    fontSize:
                                        style.effectiveEnglishFontSize *
                                        fontScale,
                                    fontFamily: style.fontFamily,
                                    fontWeight: FontWeight.w700,
                                    height: 1.3,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (showTitle && data.title != null)
                Positioned(
                  left: w * titleLeft / _slideW,
                  top: h * titleTop / _slideH,
                  width: w * titleBoxW / _slideW,
                  height: h * _titleBoxH / _slideH,
                  child: Text(
                    data.title!,
                    textAlign: titleAlign,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: titleTextColor,
                      fontSize: titleFontSize * fontScale,
                      fontFamily: style.fontFamily,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
