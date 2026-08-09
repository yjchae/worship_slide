import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/export_style.dart';
import 'slide_page_data.dart';

/// 슬라이드 한 장을 렌더링하는 공유 위젯.
/// 발표 팝업과 컨트롤러 썸네일 모두 이 위젯을 사용한다.
class SlideRenderView extends StatelessWidget {
  const SlideRenderView({super.key, required this.data});
  final SlidePageData data;

  // ppt_tool render가 굽는 이미지 가로 픽셀 (RENDER_IMAGE_WIDTH와 동일)
  static const int _imageMaxWidth = 1920;
  static const double _slideW = 13.333;
  static const double _slideH = 7.5;
  static const double _lyricsBoxT = 0.6;
  static const double _lyricsBoxH = 5.4;
  static const double _lyricsBoxBottom = _slideH - _lyricsBoxT - _lyricsBoxH;
  static const double _lyricsBoxW = _slideW * 0.9;
  static const double _lyricsBoxL = (_slideW - _lyricsBoxW) / 2;
  static const double _titleBoxH = 0.55;
  static const double _titlePad = 0.2;
  static const double _titleBoxWSide = _slideW - (_titlePad * 2);
  static const double _titleBoxWCenter = 10.0;

  @override
  Widget build(BuildContext context) {
    final style = data.style;
    final isBible = data.isBible;

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
            child: Image.file(
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
          );
        },
      );
    }

    final bodyTextPosition =
        isBible ? style.bibleTextPosition : style.textPosition;
    final titleHPos = isBible
        ? style.bibleTitleHorizontalPosition
        : style.titleHorizontalPosition;
    final titleVPos = isBible
        ? style.bibleTitleVerticalPosition
        : style.titleVerticalPosition;
    final bodyFontSize = isBible ? style.bibleFontSize : style.fontSize;
    final bodyBoxTop = (isBible ? style.bibleTextBoxTop : style.textBoxTop)
        .clamp(0.0, _slideH - _lyricsBoxBottom)
        .toDouble();
    final bodyBoxHeight = math.max(
      0.01,
      _slideH - bodyBoxTop - _lyricsBoxBottom,
    );
    final showTitle = isBible ? style.showBibleTitle : style.showSongTitle;
    final titleFontSize =
        isBible ? style.bibleTitleFontSize : style.titleFontSize;
    final titleTextColor =
        isBible ? style.bibleTitleTextColor : style.titleTextColor;
    final bodyTextColor = isBible ? style.bibleTextColor : style.textColor;
    final bodyTextAlign =
        isBible ? style.bibleTextAlign : style.lyricsTextAlign;

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
        final double titleTop = switch (titleVPos) {
          VerticalTextPosition.top => _titlePad,
          VerticalTextPosition.middle => (_slideH - _titleBoxH) / 2,
          VerticalTextPosition.bottom => _slideH - _titlePad - _titleBoxH,
        };

        final bgImagePath = style.backgroundImagePath;
        final bgImageFile =
            bgImagePath != null ? File(bgImagePath) : null;
        final hasImage =
            bgImageFile != null && bgImageFile.existsSync();

        return Container(
          color: style.backgroundColor,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              if (hasImage)
                Positioned.fill(
                  child: Image.file(
                    bgImageFile!,
                    fit: BoxFit.cover,
                  ),
                ),
              Positioned(
                left: w * _lyricsBoxL / _slideW,
                top: h * bodyBoxTop / _slideH,
                width: w * _lyricsBoxW / _slideW,
                height: h * bodyBoxHeight / _slideH,
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
                                    fontSize: style.fontSize * 0.8 * fontScale,
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
