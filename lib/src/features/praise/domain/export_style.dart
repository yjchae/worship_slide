import 'package:flutter/material.dart';

enum VerticalTextPosition {
  top('상단'),
  middle('중단'),
  bottom('하단');

  const VerticalTextPosition(this.label);
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
  });

  final double fontSize;
  final Color backgroundColor;
  final Color textColor;
  final VerticalTextPosition textPosition;
  final bool includeEnglishLyrics;
  final Color englishTextColor;

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
    };
  }

  ExportStyle copyWith({
    double? fontSize,
    Color? backgroundColor,
    Color? textColor,
    VerticalTextPosition? textPosition,
    bool? includeEnglishLyrics,
    Color? englishTextColor,
  }) {
    return ExportStyle(
      fontSize: fontSize ?? this.fontSize,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      textColor: textColor ?? this.textColor,
      textPosition: textPosition ?? this.textPosition,
      includeEnglishLyrics: includeEnglishLyrics ?? this.includeEnglishLyrics,
      englishTextColor: englishTextColor ?? this.englishTextColor,
    );
  }
}
