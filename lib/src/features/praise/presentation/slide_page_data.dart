import 'dart:convert';

import '../domain/export_style.dart';

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
  });

  final String mainText;
  final String englishText;
  final String? title;
  final bool isBible;
  /// 외부 PPT에서 구운 페이지 이미지. 지정되면 텍스트 대신 이 이미지만 표시된다.
  final String? imagePath;
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
    'style': style.toJson(),
    'image_path': imagePath,
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
    );
  }

  String toJsonString() => jsonEncode(toJson());
}
