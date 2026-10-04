import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:worship_slides/src/features/update/update_service.dart';

void main() {
  test('새 파일을 덮어쓰고 설치 폴더의 다른 파일(DB)은 남긴다', () {
    final root = Directory.systemTemp.createTempSync('ws_update_test');
    addTearDown(() => root.deleteSync(recursive: true));
    final src = p.join(root.path, 'worship_slides');
    final install = p.join(root.path, 'install');

    File(p.join(src, 'worship_slides.exe'))
      ..createSync(recursive: true)
      ..writeAsStringSync('new exe');
    File(p.join(src, 'python', 'ppt_tool', 'ppt_tool.exe'))
      ..createSync(recursive: true)
      ..writeAsStringSync('new tool');
    File(p.join(install, 'worship_slides.exe'))
      ..createSync(recursive: true)
      ..writeAsStringSync('old exe');
    File(p.join(install, 'worship_slides.db')).writeAsStringSync('db');

    final count = UpdateService.applyUpdateFiles(src, install);

    expect(count, 2);
    expect(
      File(p.join(install, 'worship_slides.exe')).readAsStringSync(),
      'new exe',
    );
    expect(
      File(
        p.join(install, 'python', 'ppt_tool', 'ppt_tool.exe'),
      ).readAsStringSync(),
      'new tool',
    );
    expect(File(p.join(install, 'worship_slides.db')).readAsStringSync(), 'db');
  });
}
