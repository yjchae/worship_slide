import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/offering_design.dart';

/// 헌금송 기본 디자인(배경·은행·계좌·색·크기·기본 높낮이)을
/// Application Support/offering_design.json 에 보관한다. [ExportStyleStore] 와 같은 방식.
class OfferingDesignStore {
  Future<OfferingDesign?> load() async {
    final file = await _file();
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      return OfferingDesign.fromJson(json.cast<String, dynamic>());
    } catch (_) {
      // 설정 파일이 깨졌다고 앱이 안 뜨면 안 된다. 기본값으로 시작한다.
      return null;
    }
  }

  Future<void> save(OfferingDesign design) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(design.toJson()));
  }

  Future<File> _file() async {
    final appDir = await getApplicationSupportDirectory();
    return File(p.join(appDir.path, 'offering_design.json'));
  }
}
