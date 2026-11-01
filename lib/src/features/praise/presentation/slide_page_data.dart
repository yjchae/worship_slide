import 'dart:convert';
import 'dart:io';

import '../data/font_library.dart';
import '../domain/export_style.dart';
import '../domain/slide_media.dart';
import 'media_player_html.dart';
import 'slide_backdrop.dart';

class SlidePageData {
  const SlidePageData({
    required this.mainText,
    required this.englishText,
    this.extraText = '',
    this.title,
    required this.isBible,
    required this.pageIndex,
    required this.totalPages,
    required this.style,
    this.imagePath,
    this.media,
    this.mediaGroup,
    this.backdrop,
    this.originalOnly = false,
  });

  final String mainText;
  final String englishText;

  /// 추가 보조 줄(관객 화면 세 번째 줄). 싱어 화면에는 보내지 않는다.
  final String extraText;
  final String? title;
  final bool isBible;

  /// 외부 PPT에서 구운 페이지 이미지. 지정되면 텍스트 대신 이 이미지만 표시된다.
  final String? imagePath;

  /// 이 페이지에서 재생할 동영상·음악·유튜브. 발표 창이 슬라이드 위 미디어 레이어로 띄운다.
  final SlideMedia? media;

  /// 미디어가 든 콘티 항목(uid). 같은 항목 안에서만 이어서 재생한다 — PPT 애니메이션 단계는
  /// 이어지고, 같은 동영상을 붙여 넣은 다음 항목은 처음부터 다시 튼다.
  final int? mediaGroup;

  /// 가사 뒤 배경 영상. 페이지 자체 미디어([media])가 있으면 쓰지 않는다.
  /// 발표 창에는 가사 PNG([SlideBackdrop.overlayPath])를 구운 뒤에만 실린다.
  final SlideBackdrop? backdrop;

  /// 원본만 보이기(발표 보기·설교자 화면). 보조·추가 보조 줄은 자리만 차지하고 안 보인다.
  /// 화면에 그릴 때만 쓰고 발표 창 JSON 에는 싣지 않는다.
  final bool originalOnly;

  /// 발표 창에 실제로 보낼 배경 영상(가사 PNG 까지 준비된 것).
  SlideBackdrop? get _sentBackdrop =>
      media == null && backdrop?.overlayPath != null ? backdrop : null;

  /// 발표 창이 "같은 미디어"인지 가리는 값(같으면 이어서 재생). 미디어가 없으면 null.
  /// 배경 영상은 항목을 따지지 않는다 — 곡을 둘로 나눠도, 같은 영상 곡이 이어져도 이어서 튼다.
  String? get mediaKey =>
      media != null ? '${mediaGroup ?? ''}|${media!.key}' : _sentBackdrop?.key;
  final int pageIndex;
  final int totalPages;
  final ExportStyle style;

  Map<String, dynamic> toJson() => {
    'main_text': mainText,
    'english_text': englishText,
    'extra_text': extraText,
    'title': title,
    'is_bible': isBible,
    'page_index': pageIndex,
    'total_pages': totalPages,
    'style': {
      ...style.toJson(),
      // 발표 창은 비율을 모른다 — 이 페이지의 보조·추가 보조 글자 크기(pt)를 계산해 싣는다.
      'english_font_size': style.subFontSizeFor(isBible: isBible),
      'extra_font_size': style.extraFontSizeFor(isBible: isBible),
      'font_files': FontLibrary.filesFor(style.fontFamily),
    },
    'image_path': imagePath,
    'media': media != null
        ? {
            ...media!.toJson(),
            'key': mediaKey,
            'html': mediaPlayerHtml(media!, windows: Platform.isWindows),
          }
        : _sentBackdrop?.toPageJson(style, windows: Platform.isWindows),
  };

  factory SlidePageData.fromJson(Map<String, dynamic> json) {
    return SlidePageData(
      mainText: (json['main_text'] as String?) ?? '',
      englishText: (json['english_text'] as String?) ?? '',
      extraText: (json['extra_text'] as String?) ?? '',
      title: json['title'] as String?,
      isBible: (json['is_bible'] as bool?) ?? false,
      pageIndex: (json['page_index'] as int?) ?? 0,
      totalPages: (json['total_pages'] as int?) ?? 0,
      style: ExportStyle.fromJson(json['style'] as Map<String, dynamic>),
      imagePath: json['image_path'] as String?,
      media: SlideMedia.fromJson(json['media']),
    );
  }

  String toJsonString() => jsonEncode(toJson());

  /// 같은 페이지에 배경 영상만 바꿔 끼운 것(가사 PNG 를 구운 뒤 발표 창에 보낼 때).
  SlidePageData withBackdrop(SlideBackdrop? value) => SlidePageData(
    mainText: mainText,
    englishText: englishText,
    extraText: extraText,
    title: title,
    isBible: isBible,
    pageIndex: pageIndex,
    totalPages: totalPages,
    style: style,
    imagePath: imagePath,
    media: media,
    mediaGroup: mediaGroup,
    backdrop: value,
    originalOnly: originalOnly,
  );

  /// 통역 화면(B)에 보낼 페이지. 소리가 겹치지 않게 미디어·배경 영상은 빼고, 이미지는
  /// [bImage](`bImagePath` 결과)로 바꾸고, 보조 → 추가 보조 순으로 본문으로 올린다.
  /// 둘 다 있으면 추가 보조는 그 아래 보조 줄이 된다. 둘 다 없으면 원본 그대로다.
  /// 설교 제목 페이지([sermon])의 보조 칸은 번역이 아니라 부제라 그대로 둔다.
  SlidePageData forB(String? bImage, {bool sermon = false}) {
    final hasSub = englishText.trim().isNotEmpty;
    final hasExtra = extraText.trim().isNotEmpty;
    final lift = !sermon && (hasSub || hasExtra);
    return SlidePageData(
      mainText: !lift
          ? mainText
          : hasSub
          ? englishText
          : extraText,
      englishText: !lift
          ? englishText
          : hasSub && hasExtra
          ? extraText
          : '',
      extraText: lift ? '' : extraText,
      title: title,
      isBible: isBible,
      pageIndex: pageIndex,
      totalPages: totalPages,
      style: style,
      imagePath: bImage,
    );
  }
}
