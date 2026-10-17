import 'dart:convert';
import 'dart:io';

import '../data/font_library.dart';
import '../domain/export_style.dart';
import '../domain/slide_media.dart';
import 'media_player_html.dart';

class SlidePageData {
  const SlidePageData({
    required this.mainText,
    required this.englishText,
    this.title,
    required this.isBible,
    required this.pageIndex,
    required this.totalPages,
    required this.style,
    this.imagePath,
    this.media,
    this.mediaGroup,
  });

  final String mainText;
  final String englishText;
  final String? title;
  final bool isBible;
  /// 외부 PPT에서 구운 페이지 이미지. 지정되면 텍스트 대신 이 이미지만 표시된다.
  final String? imagePath;
  /// 이 페이지에서 재생할 동영상·음악·유튜브. 발표 창이 슬라이드 위 미디어 레이어로 띄운다.
  final SlideMedia? media;

  /// 미디어가 든 콘티 항목(uid). 같은 항목 안에서만 이어서 재생한다 — PPT 애니메이션 단계는
  /// 이어지고, 같은 동영상을 붙여 넣은 다음 항목은 처음부터 다시 튼다.
  final int? mediaGroup;

  /// 발표 창이 "같은 미디어"인지 가리는 값(같으면 이어서 재생). 미디어가 없으면 null.
  String? get mediaKey =>
      media == null ? null : '${mediaGroup ?? ''}|${media!.key}';
  final int pageIndex;
  final int totalPages;
  final ExportStyle style;

  Map<String, dynamic> toJson() => {
    'main_text': mainText,
    'english_text': englishText,
    'title': title,
    'is_bible': isBible,
    'page_index': pageIndex,
    'total_pages': totalPages,
    'style': {
      ...style.toJson(),
      'font_files': FontLibrary.filesFor(style.fontFamily),
    },
    'image_path': imagePath,
    'media': media == null
        ? null
        : {
            ...media!.toJson(),
            'key': mediaKey,
            'html': mediaPlayerHtml(media!, windows: Platform.isWindows),
          },
  };

  factory SlidePageData.fromJson(Map<String, dynamic> json) {
    return SlidePageData(
      mainText: (json['main_text'] as String?) ?? '',
      englishText: (json['english_text'] as String?) ?? '',
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
}
