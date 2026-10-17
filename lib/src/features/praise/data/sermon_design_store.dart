import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/slide_background.dart';

/// 설교 제목 페이지 기본 디자인(배경·글꼴·크기·색)을
/// Application Support/sermon_design.json 에 보관한다. [OfferingDesignStore] 와 같은 방식.
class SermonDesignStore {
  Future<SlideBackground?> load() async {
    final file = await _file();
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      return SlideBackground.fromJson(
        json.cast<String, dynamic>(),
      )?.copyWith(isSermon: true);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(SlideBackground design) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(design.toJson()));
  }

  Future<File> _file() async {
    final appDir = await getApplicationSupportDirectory();
    return File(p.join(appDir.path, 'sermon_design.json'));
  }
}
