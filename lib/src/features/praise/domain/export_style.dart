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
  });

  final double fontSize;
  final double bibleFontSize;
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

  Map<String, dynamic> toJson() {
    return {
      'font_size': fontSize,
      'bible_font_size': bibleFontSize,
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
    };
  }

  ExportStyle copyWith({
    double? fontSize,
    double? bibleFontSize,
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
  }) {
    return ExportStyle(
      fontSize: fontSize ?? this.fontSize,
      bibleFontSize: bibleFontSize ?? this.bibleFontSize,
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
    );
  }
}
