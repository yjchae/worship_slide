import 'package:flutter/material.dart';

import '../domain/export_style.dart';
import 'slide_page_data.dart';

/// 슬라이드 한 장을 렌더링하는 공유 위젯.
/// 발표 팝업과 컨트롤러 썸네일 모두 이 위젯을 사용한다.
class SlideRenderView extends StatelessWidget {
  const SlideRenderView({super.key, required this.data});
  final SlidePageData data;

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

    final bodyTextPosition =
        isBible ? style.bibleTextPosition : style.textPosition;
    final titleHPos = isBible
        ? style.bibleTitleHorizontalPosition
        : style.titleHorizontalPosition;
    final titleVPos = isBible
        ? style.bibleTitleVerticalPosition
        : style.titleVerticalPosition;
    final bodyFontSize = isBible ? style.bibleFontSize : style.fontSize;
    final bodyBoxTop = isBible ? style.bibleTextBoxTop : style.textBoxTop;
    final bodyBoxHeight = _slideH - bodyBoxTop - _lyricsBoxBottom;
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

        return Container(
          color: style.backgroundColor,
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.only(
                  left: w * _lyricsBoxL / _slideW,
                  top: h * bodyBoxTop / _slideH,
                  right: w * (1 - (_lyricsBoxL + _lyricsBoxW) / _slideW),
                  bottom: h * (1 - (bodyBoxTop + bodyBoxHeight) / _slideH),
                ),
                child: Align(
                  alignment: bodyAlignment,
                  // FittedBox: 텍스트가 영역을 초과할 때 자동 축소
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
