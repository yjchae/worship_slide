import 'package:flutter/material.dart';

final RegExp _hexColorPattern = RegExp(r'^[0-9A-F]{6}$');

String colorToHex(Color color) =>
    '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}';

Color? tryParseHexColor(String? value) {
  if (value == null) return null;
  final normalized = value.trim().replaceFirst('#', '').toUpperCase();
  if (!_hexColorPattern.hasMatch(normalized)) return null;
  return Color(int.parse('FF$normalized', radix: 16));
}

Color parseHexColor(String? value, Color fallback) {
  return tryParseHexColor(value) ?? fallback;
}

enum VerticalTextPosition {
  top('상단'),
  middle('중단'),
  bottom('하단');

  const VerticalTextPosition(this.label);
  final String label;
}

enum HorizontalPosition {
  left('좌측'),
  center('중앙'),
  right('우측');

  const HorizontalPosition(this.label);
  final String label;
}

class ExportStyle {
  const ExportStyle({
    required this.fontSize,
    required this.bibleFontSize,
    required this.textBoxTop,
    required this.bibleTextBoxTop,
    required this.backgroundColor,
    required this.textColor,
    required this.bibleTextColor,
    required this.textPosition,
    required this.bibleTextPosition,
    required this.lyricsTextAlign,
    required this.bibleTextAlign,
    required this.includeEnglishLyrics,
    required this.englishTextColor,
    required this.showSongTitle,
    required this.showBibleTitle,
    required this.titleFontSize,
    required this.bibleTitleFontSize,
    required this.titleTextColor,
    required this.bibleTitleTextColor,
    required this.titleHorizontalPosition,
    required this.titleVerticalPosition,
    required this.bibleTitleHorizontalPosition,
    required this.bibleTitleVerticalPosition,
    this.fontFamily = 'Pretendard',
    this.backgroundImagePath,
  });

  final double fontSize;
  final double bibleFontSize;
  final double textBoxTop;
  final double bibleTextBoxTop;
  final Color backgroundColor;
  final Color textColor;
  final Color bibleTextColor;
  final VerticalTextPosition textPosition;
  final VerticalTextPosition bibleTextPosition;
  final HorizontalPosition lyricsTextAlign;
  final HorizontalPosition bibleTextAlign;
  final bool includeEnglishLyrics;
  final Color englishTextColor;
  final bool showSongTitle;
  final bool showBibleTitle;
  final double titleFontSize;
  final double bibleTitleFontSize;
  final Color titleTextColor;
  final Color bibleTitleTextColor;
  final HorizontalPosition titleHorizontalPosition;
  final VerticalTextPosition titleVerticalPosition;
  final HorizontalPosition bibleTitleHorizontalPosition;
  final VerticalTextPosition bibleTitleVerticalPosition;
  final String fontFamily;
  final String? backgroundImagePath;

  Map<String, dynamic> toJson() {
    return {
      'font_size': fontSize,
      'bible_font_size': bibleFontSize,
      'text_box_top': textBoxTop,
      'bible_text_box_top': bibleTextBoxTop,
      'background_color': colorToHex(backgroundColor),
      'text_color': colorToHex(textColor),
      'bible_text_color': colorToHex(bibleTextColor),
      'text_position': textPosition.name,
      'bible_text_position': bibleTextPosition.name,
      'lyrics_text_align': lyricsTextAlign.name,
      'bible_text_align': bibleTextAlign.name,
      'include_english_lyrics': includeEnglishLyrics,
      'english_text_color': colorToHex(englishTextColor),
      'show_song_title': showSongTitle,
      'show_bible_title': showBibleTitle,
      'title_font_size': titleFontSize,
      'bible_title_font_size': bibleTitleFontSize,
      'title_text_color': colorToHex(titleTextColor),
      'bible_title_text_color': colorToHex(bibleTitleTextColor),
      'title_horizontal_position': titleHorizontalPosition.name,
      'title_vertical_position': titleVerticalPosition.name,
      'bible_title_horizontal_position': bibleTitleHorizontalPosition.name,
      'bible_title_vertical_position': bibleTitleVerticalPosition.name,
      'font_family': fontFamily,
      'background_image_path': backgroundImagePath,
    };
  }

  factory ExportStyle.fromJson(Map<String, dynamic> json) {
    VerticalTextPosition parseVertical(String? name) =>
        VerticalTextPosition.values.firstWhere(
          (e) => e.name == name,
          orElse: () => VerticalTextPosition.middle,
        );
    HorizontalPosition parseHorizontal(String? name) =>
        HorizontalPosition.values.firstWhere(
          (e) => e.name == name,
          orElse: () => HorizontalPosition.center,
        );
    return ExportStyle(
      fontSize: (json['font_size'] as num).toDouble(),
      bibleFontSize: (json['bible_font_size'] as num).toDouble(),
      textBoxTop: (json['text_box_top'] as num).toDouble(),
      bibleTextBoxTop: (json['bible_text_box_top'] as num).toDouble(),
      backgroundColor: parseHexColor(
        json['background_color'] as String?,
        const Color(0xFF1B1B1B),
      ),
      textColor: parseHexColor(json['text_color'] as String?, Colors.white),
      bibleTextColor: parseHexColor(
        json['bible_text_color'] as String?,
        Colors.white,
      ),
      textPosition: parseVertical(json['text_position'] as String?),
      bibleTextPosition: parseVertical(json['bible_text_position'] as String?),
      lyricsTextAlign: parseHorizontal(json['lyrics_text_align'] as String?),
      bibleTextAlign: parseHorizontal(json['bible_text_align'] as String?),
      includeEnglishLyrics:
          (json['include_english_lyrics'] as bool?) ?? true,
      englishTextColor: parseHexColor(
        json['english_text_color'] as String?,
        const Color(0xFFFFF176),
      ),
      showSongTitle: (json['show_song_title'] as bool?) ?? false,
      showBibleTitle: (json['show_bible_title'] as bool?) ?? false,
      titleFontSize: (json['title_font_size'] as num?)?.toDouble() ?? 14.0,
      bibleTitleFontSize:
          (json['bible_title_font_size'] as num?)?.toDouble() ?? 14.0,
      titleTextColor: parseHexColor(
        json['title_text_color'] as String?,
        const Color(0xB3FFFFFF),
      ),
      bibleTitleTextColor: parseHexColor(
        json['bible_title_text_color'] as String?,
        const Color(0xB3FFFFFF),
      ),
      titleHorizontalPosition: parseHorizontal(
        json['title_horizontal_position'] as String?,
      ),
      titleVerticalPosition: parseVertical(
        json['title_vertical_position'] as String?,
      ),
      bibleTitleHorizontalPosition: parseHorizontal(
        json['bible_title_horizontal_position'] as String?,
      ),
      bibleTitleVerticalPosition: parseVertical(
        json['bible_title_vertical_position'] as String?,
      ),
      fontFamily: (json['font_family'] as String?) ?? 'Pretendard',
      backgroundImagePath: json['background_image_path'] as String?,
    );
  }

  ExportStyle copyWith({
    double? fontSize,
    double? bibleFontSize,
    double? textBoxTop,
    double? bibleTextBoxTop,
    Color? backgroundColor,
    Color? textColor,
    Color? bibleTextColor,
    VerticalTextPosition? textPosition,
    VerticalTextPosition? bibleTextPosition,
    HorizontalPosition? lyricsTextAlign,
    HorizontalPosition? bibleTextAlign,
    bool? includeEnglishLyrics,
    Color? englishTextColor,
    bool? showSongTitle,
    bool? showBibleTitle,
    double? titleFontSize,
    double? bibleTitleFontSize,
    Color? titleTextColor,
    Color? bibleTitleTextColor,
    HorizontalPosition? titleHorizontalPosition,
    VerticalTextPosition? titleVerticalPosition,
    HorizontalPosition? bibleTitleHorizontalPosition,
    VerticalTextPosition? bibleTitleVerticalPosition,
    String? fontFamily,
    Object? backgroundImagePath = _sentinel,
  }) {
    return ExportStyle(
      fontSize: fontSize ?? this.fontSize,
      bibleFontSize: bibleFontSize ?? this.bibleFontSize,
      textBoxTop: textBoxTop ?? this.textBoxTop,
      bibleTextBoxTop: bibleTextBoxTop ?? this.bibleTextBoxTop,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      textColor: textColor ?? this.textColor,
      bibleTextColor: bibleTextColor ?? this.bibleTextColor,
      textPosition: textPosition ?? this.textPosition,
      bibleTextPosition: bibleTextPosition ?? this.bibleTextPosition,
      lyricsTextAlign: lyricsTextAlign ?? this.lyricsTextAlign,
      bibleTextAlign: bibleTextAlign ?? this.bibleTextAlign,
      includeEnglishLyrics: includeEnglishLyrics ?? this.includeEnglishLyrics,
      englishTextColor: englishTextColor ?? this.englishTextColor,
      showSongTitle: showSongTitle ?? this.showSongTitle,
      showBibleTitle: showBibleTitle ?? this.showBibleTitle,
      titleFontSize: titleFontSize ?? this.titleFontSize,
      bibleTitleFontSize: bibleTitleFontSize ?? this.bibleTitleFontSize,
      titleTextColor: titleTextColor ?? this.titleTextColor,
      bibleTitleTextColor: bibleTitleTextColor ?? this.bibleTitleTextColor,
      titleHorizontalPosition:
          titleHorizontalPosition ?? this.titleHorizontalPosition,
      titleVerticalPosition:
          titleVerticalPosition ?? this.titleVerticalPosition,
      bibleTitleHorizontalPosition:
          bibleTitleHorizontalPosition ?? this.bibleTitleHorizontalPosition,
      bibleTitleVerticalPosition:
          bibleTitleVerticalPosition ?? this.bibleTitleVerticalPosition,
      fontFamily: fontFamily ?? this.fontFamily,
      backgroundImagePath: identical(backgroundImagePath, _sentinel)
          ? this.backgroundImagePath
          : backgroundImagePath as String?,
    );
  }

  static const Object _sentinel = Object();
}
