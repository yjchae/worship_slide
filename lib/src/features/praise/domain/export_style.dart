import 'package:flutter/material.dart';

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
    required this.textPosition,
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
  final VerticalTextPosition textPosition;
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
      'background_color':
          '#${backgroundColor.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
      'text_color':
          '#${textColor.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
      'text_position': textPosition.name,
      'include_english_lyrics': includeEnglishLyrics,
      'english_text_color':
          '#${englishTextColor.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
      'show_song_title': showSongTitle,
      'title_font_size': titleFontSize,
      'title_text_color':
          '#${titleTextColor.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
      'title_horizontal_position': titleHorizontalPosition.name,
      'title_vertical_position': titleVerticalPosition.name,
    };
  }

  ExportStyle copyWith({
    double? fontSize,
    Color? backgroundColor,
    Color? textColor,
    VerticalTextPosition? textPosition,
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
      textPosition: textPosition ?? this.textPosition,
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
