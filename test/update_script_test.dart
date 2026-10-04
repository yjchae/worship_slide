import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/update/update_service.dart';

void main() {
  String build({String installDir = r'C:\예배\worship_slides'}) =>
      UpdateService.buildWindowsUpdateScript(
        appPid: 1234,
        exePath: '$installDir\\worship_slides.exe',
        installDir: installDir,
        zipPath: r'C:\Temp\ws_update_1.2.0.zip',
        extractDir: r'C:\Temp\ws_extracted',
        logPath: r'C:\Temp\ws_update.log',
      );

  test('앱 종료를 기다린 뒤 덮어쓰고 다시 띄운다', () {
    final script = build();
    expect(script, contains('Wait-Process -Id 1234'));
    expect(script, contains('robocopy'));
    expect(script, contains('Start-Process -FilePath \$exePath'));
    expect(script, contains(r"$installDir = 'C:\예배\worship_slides'"));
  });

  test('경로의 작은따옴표는 두 번 써서 이스케이프한다', () {
    final script = build(installDir: r"C:\Users\O'Neil\worship_slides");
    expect(script, contains(r"$installDir = 'C:\Users\O''Neil\worship_slides'"));
  });
}
