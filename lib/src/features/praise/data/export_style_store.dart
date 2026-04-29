import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/export_style.dart';

class ExportStyleStore {
  Future<ExportStyle?> load() async {
    final file = await _settingsFile();
    if (!await file.exists()) {
      return null;
    }

    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return ExportStyle(
      fontSize: (json['font_size'] as num?)?.toDouble() ?? 30,
      backgroundColor: parseHexColor(
        json['background_color'] as String?,
        const Color(0xFF1B1B1B),
      ),
      textColor: parseHexColor(json['text_color'] as String?, Colors.white),
      bibleTextColor: parseHexColor(
        json['bible_text_color'] as String?,
        parseHexColor(json['text_color'] as String?, Colors.white),
      ),
      textPosition: VerticalTextPosition.values.firstWhere(
        (position) => position.name == json['text_position'],
        orElse: () => VerticalTextPosition.middle,
      ),
      lyricsTextAlign: HorizontalPosition.values.firstWhere(
        (pos) => pos.name == json['lyrics_text_align'],
        orElse: () => HorizontalPosition.center,
      ),
      bibleTextAlign: HorizontalPosition.values.firstWhere(
        (pos) => pos.name == json['bible_text_align'],
        orElse: () => HorizontalPosition.center,
      ),
      includeEnglishLyrics: json['include_english_lyrics'] as bool? ?? true,
      englishTextColor: parseHexColor(
        json['english_text_color'] as String?,
        const Color(0xFFFFF176),
      ),
      showSongTitle: json['show_song_title'] as bool? ?? false,
      titleFontSize: (json['title_font_size'] as num?)?.toDouble() ?? 14,
      titleTextColor: parseHexColor(
        json['title_text_color'] as String?,
        const Color(0xB3FFFFFF),
      ),
      titleHorizontalPosition: HorizontalPosition.values.firstWhere(
        (pos) => pos.name == json['title_horizontal_position'],
        orElse: () => HorizontalPosition.right,
      ),
      titleVerticalPosition: VerticalTextPosition.values.firstWhere(
        (pos) => pos.name == json['title_vertical_position'],
        orElse: () => VerticalTextPosition.bottom,
      ),
    );
  }

  Future<void> save(ExportStyle style) async {
    final file = await _settingsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(style.toJson()));
  }

  Future<File> _settingsFile() async {
    final appDir = await getApplicationSupportDirectory();
    return File(p.join(appDir.path, 'export_style.json'));
  }
}
