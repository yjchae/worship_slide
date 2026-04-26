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
      backgroundColor: _parseColor(
        json['background_color'] as String?,
        const Color(0xFF1B1B1B),
      ),
      textColor: _parseColor(json['text_color'] as String?, Colors.white),
      textPosition: VerticalTextPosition.values.firstWhere(
        (position) => position.name == json['text_position'],
        orElse: () => VerticalTextPosition.middle,
      ),
      includeEnglishLyrics: json['include_english_lyrics'] as bool? ?? true,
      englishTextColor: _parseColor(
        json['english_text_color'] as String?,
        const Color(0xFFE3F2FD),
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

  Color _parseColor(String? value, Color fallback) {
    if (value == null || value.length != 7 || !value.startsWith('#')) {
      return fallback;
    }
    return Color(int.parse('FF${value.substring(1)}', radix: 16));
  }
}
