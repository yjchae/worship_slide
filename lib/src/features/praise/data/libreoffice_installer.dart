import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';

/// 자동 설치에 쓸 패키지 관리자 명령 한 벌.
class LibreOfficePackageManager {
  const LibreOfficePackageManager({
    required this.label,
    required this.executable,
    required this.arguments,
    this.environment,
  });

  /// 화면에 보여 줄 이름 (winget / Homebrew).
  final String label;
  final String executable;
  final List<String> arguments;
  final Map<String, String>? environment;
}

/// LibreOffice(선택 의존성)가 깔려 있는지 보고, 없으면 OS 패키지 관리자로 설치한다.
///
/// 앱에 내장하지 않는 이유 — 수백 MB 라 업데이트 zip 이 매번 무거워진다.
/// Windows 는 winget, macOS 는 Homebrew 가 있을 때만 자동 설치하고,
/// 없으면 다운로드 페이지를 안내한다.
class LibreOfficeInstaller {
  static const downloadPage =
      'https://www.libreoffice.org/download/download-libreoffice/';

  static const _wingetId = 'TheDocumentFoundation.LibreOffice';

  /// 수백 MB 를 내려받으므로 넉넉히 둔다. 넘기면 프로세스를 죽이고 실패로 본다.
  static const _timeout = Duration(minutes: 30);

  /// `ppt_tool.py` `get_libreoffice_executable` 과 같은 곳을 본다.
  /// 두 곳이 다르면 "설치됨"이라고 해 놓고 Python 이 못 찾는다.
  static const _knownPaths = [
    '/Applications/LibreOffice.app/Contents/MacOS/soffice',
    r'C:\Program Files\LibreOffice\program\soffice.exe',
    r'C:\Program Files (x86)\LibreOffice\program\soffice.exe',
  ];

  static Future<bool> isInstalled() async {
    for (final path in _knownPaths) {
      if (await File(path).exists()) return true;
    }
    try {
      final r = await Process.run(Platform.isWindows ? 'where' : 'which', [
        'soffice',
      ]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 이 PC 에서 쓸 수 있는 패키지 관리자. 없으면 null (직접 설치 안내).
  static Future<LibreOfficePackageManager?> findPackageManager() async {
    if (Platform.isWindows) {
      // winget 은 WindowsApps 의 실행 별칭이라 파일 존재 확인보다 직접 불러 보는 게 확실하다.
      try {
        final r = await Process.run('winget', ['--version']);
        if (r.exitCode != 0) return null;
      } catch (_) {
        return null;
      }
      return const LibreOfficePackageManager(
        label: 'winget',
        executable: 'winget',
        arguments: [
          'install',
          '--id',
          _wingetId,
          '--exact',
          '--source',
          'winget',
          '--silent',
          '--accept-package-agreements',
          '--accept-source-agreements',
        ],
      );
    }
    if (Platform.isMacOS) {
      // Finder 로 띄운 앱은 PATH 에 Homebrew 가 없으므로 설치 위치를 직접 본다.
      for (final brew in const [
        '/opt/homebrew/bin/brew',
        '/usr/local/bin/brew',
      ]) {
        if (!await File(brew).exists()) continue;
        return LibreOfficePackageManager(
          label: 'Homebrew',
          executable: brew,
          arguments: const ['install', '--cask', 'libreoffice'],
          environment: {
            'PATH': '${p.dirname(brew)}:/usr/bin:/bin:/usr/sbin:/sbin',
            'NONINTERACTIVE': '1',
          },
        );
      }
    }
    return null;
  }

  /// 설치를 돌리고, 끝난 뒤 실제로 깔렸는지로 성공을 가린다.
  /// [onProgress] 에는 설치 도구가 내놓는 마지막 줄을 넘긴다(화면 표시용).
  static Future<bool> install(
    LibreOfficePackageManager manager, {
    void Function(String line)? onProgress,
  }) async {
    final log = AppLogger.instance;
    await log.info(
      '[libreoffice] 설치 시작: ${manager.executable} ${manager.arguments.join(' ')}',
    );
    final tail = <String>[]; // 로그에 남길 마지막 출력 몇 줄

    void collect(String chunk) {
      for (final raw in chunk.split(RegExp(r'[\r\n]+'))) {
        final line = raw.trim();
        // winget 은 한 글자짜리 스피너(-\|/)를 계속 찍는다.
        if (line.length <= 1) continue;
        tail.add(line);
        if (tail.length > 40) tail.removeAt(0);
        onProgress?.call(line);
      }
    }

    try {
      final process = await Process.start(
        manager.executable,
        manager.arguments,
        environment: manager.environment,
      );
      const decoder = Utf8Decoder(allowMalformed: true);
      final outputDone = Future.wait([
        process.stdout.transform(decoder).forEach(collect),
        process.stderr.transform(decoder).forEach(collect),
      ]);
      final exitCode = await process.exitCode.timeout(
        _timeout,
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      // 죽인 경우 자식 프로세스가 파이프를 붙잡고 있을 수 있어 오래 기다리지 않는다.
      await outputDone.timeout(const Duration(seconds: 5), onTimeout: () => []);
      await log.info('[libreoffice] 종료 코드 $exitCode\n${tail.join('\n')}');
    } catch (e, st) {
      await log.error('[libreoffice] 설치 실행 실패', e, st);
      return false;
    }
    // 종료 코드는 도구·버전마다 뜻이 달라서, 실제로 깔렸는지를 기준으로 본다.
    return isInstalled();
  }
}
