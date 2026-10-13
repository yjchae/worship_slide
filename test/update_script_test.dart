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

  test('새 파일을 못 넣으면 기존 파일을 되돌려 놓는다(설치본이 깨지지 않게)', () {
    final root = Directory.systemTemp.createTempSync('ws_update_test');
    addTearDown(() => root.deleteSync(recursive: true));
    final src = p.join(root.path, 'worship_slides');
    final install = p.join(root.path, 'install');
    final srcTool = File(p.join(src, 'ppt_tool.exe'))
      ..createSync(recursive: true)
      ..writeAsStringSync('new tool');
    File(p.join(install, 'ppt_tool.exe'))
      ..createSync(recursive: true)
      ..writeAsStringSync('old tool');
    // 백신이 격리한 것처럼 원본을 못 읽게 만든다.
    Process.runSync('chmod', ['000', srcTool.path]);
    addTearDown(() => Process.runSync('chmod', ['644', srcTool.path]));

    expect(
      () => UpdateService.applyUpdateFiles(src, install),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(p.join(install, 'ppt_tool.exe')).readAsStringSync(), 'old tool');
    expect(File(p.join(install, 'ppt_tool.exe.old')).existsSync(), isFalse);
  }, skip: Platform.isWindows ? 'chmod 없음' : null);
}
