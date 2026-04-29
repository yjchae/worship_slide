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
    required this.backgroundColor,
    required this.textColor,
    required this.bibleTextColor,
    required this.textPosition,
    required this.lyricsTextAlign,
    required this.bibleTextAlign,
    required this.includeEnglishLyrics,
    required this.englishTextColor,
    required this.showSongTitle,
    required this.titleFontSize,
    required this.titleTextColor,
    required this.titleHorizontalPosition,
    required this.titleVerticalPosition,
  });

  final double fontSize;
  final Color backgroundColor;
  final Color textColor;
  final Color bibleTextColor;
  final VerticalTextPosition textPosition;
  final HorizontalPosition lyricsTextAlign;
  final HorizontalPosition bibleTextAlign;
  final bool includeEnglishLyrics;
  final Color englishTextColor;
  final bool showSongTitle;
  final double titleFontSize;
  final Color titleTextColor;
  final HorizontalPosition titleHorizontalPosition;
  final VerticalTextPosition titleVerticalPosition;

  Map<String, dynamic> toJson() {
    return {
      'font_size': fontSize,
      'background_color': colorToHex(backgroundColor),
      'text_color': colorToHex(textColor),
      'bible_text_color': colorToHex(bibleTextColor),
      'text_position': textPosition.name,
      'lyrics_text_align': lyricsTextAlign.name,
      'bible_text_align': bibleTextAlign.name,
      'include_english_lyrics': includeEnglishLyrics,
      'english_text_color': colorToHex(englishTextColor),
      'show_song_title': showSongTitle,
      'title_font_size': titleFontSize,
      'title_text_color': colorToHex(titleTextColor),
      'title_horizontal_position': titleHorizontalPosition.name,
      'title_vertical_position': titleVerticalPosition.name,
    };
  }

  ExportStyle copyWith({
    double? fontSize,
    Color? backgroundColor,
    Color? textColor,
    Color? bibleTextColor,
    VerticalTextPosition? textPosition,
    HorizontalPosition? lyricsTextAlign,
    HorizontalPosition? bibleTextAlign,
    bool? includeEnglishLyrics,
    Color? englishTextColor,
    bool? showSongTitle,
    double? titleFontSize,
    Color? titleTextColor,
    HorizontalPosition? titleHorizontalPosition,
    VerticalTextPosition? titleVerticalPosition,
  }) {
    return ExportStyle(
      fontSize: fontSize ?? this.fontSize,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      textColor: textColor ?? this.textColor,
      bibleTextColor: bibleTextColor ?? this.bibleTextColor,
      textPosition: textPosition ?? this.textPosition,
      lyricsTextAlign: lyricsTextAlign ?? this.lyricsTextAlign,
      bibleTextAlign: bibleTextAlign ?? this.bibleTextAlign,
      includeEnglishLyrics: includeEnglishLyrics ?? this.includeEnglishLyrics,
      englishTextColor: englishTextColor ?? this.englishTextColor,
      showSongTitle: showSongTitle ?? this.showSongTitle,
      titleFontSize: titleFontSize ?? this.titleFontSize,
      titleTextColor: titleTextColor ?? this.titleTextColor,
      titleHorizontalPosition:
          titleHorizontalPosition ?? this.titleHorizontalPosition,
      titleVerticalPosition:
          titleVerticalPosition ?? this.titleVerticalPosition,
    );
  }
}
