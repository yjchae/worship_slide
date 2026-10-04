import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../praise/data/app_logger.dart';

class UpdateInfo {
  final String version;
  final String tagName;
  final String releaseUrl;
  final String? downloadUrl;

  const UpdateInfo({
    required this.version,
    required this.tagName,
    required this.releaseUrl,
    this.downloadUrl,
  });
}

class UpdateService {
  static const _owner = 'yjchae';
  static const _repo = 'worship_slide';
  static const _apiUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';

  Future<UpdateInfo?> checkForUpdates({int maxAttempts = 1}) async {
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        await Future.delayed(Duration(seconds: attempt * 5));
      }
      try {
        return await _fetchUpdateInfo();
      } on SocketException catch (e) {
        debugPrint('[UpdateService] attempt $attempt network error: $e');
      } on TimeoutException catch (e) {
        debugPrint('[UpdateService] attempt $attempt timeout: $e');
      } catch (e, st) {
        debugPrint('[UpdateService] unexpected error: $e\n$st');
        return null;
      }
    }
    return null;
  }

  Future<UpdateInfo?> _fetchUpdateInfo() async {
    final info = await PackageInfo.fromPlatform();
    final current = info.version;

    final response = await http
        .get(
          Uri.parse(_apiUrl),
          headers: {'Accept': 'application/vnd.github.v3+json'},
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      debugPrint('[UpdateService] HTTP ${response.statusCode}');
      return null;
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    final tagName = data['tag_name'] as String;
    final latest = tagName.startsWith('v') ? tagName.substring(1) : tagName;

    if (!_isNewer(latest, current)) return null;

    final assets = data['assets'] as List<dynamic>;
    String? downloadUrl;
    final platformId = Platform.isMacOS
        ? 'macos'
        : Platform.isWindows
            ? 'windows'
            : null;

    if (platformId != null) {
      for (final asset in assets) {
        final name = asset['name'] as String;
        if (name.contains(platformId) && name.endsWith('.zip')) {
          downloadUrl = asset['browser_download_url'] as String;
          break;
        }
      }
    }

    return UpdateInfo(
      version: latest,
      tagName: tagName,
      releaseUrl: data['html_url'] as String,
      downloadUrl: downloadUrl,
    );
  }

  bool _isNewer(String latest, String current) {
    int seg(String v, int i) {
      final parts = v.split('.');
      return i < parts.length ? (int.tryParse(parts[i]) ?? 0) : 0;
    }

    for (var i = 0; i < 3; i++) {
      final l = seg(latest, i);
      final c = seg(current, i);
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }

  Future<void> downloadAndInstall(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    if (info.downloadUrl == null) {
      _launch(info.releaseUrl);
      return;
    }

    final tmp = await getTemporaryDirectory();
    final zipPath = p.join(tmp.path, 'ws_update_${info.version}.zip');
    await _downloadFile(info.downloadUrl!, zipPath, onProgress);

    if (Platform.isMacOS && kReleaseMode) {
      await _applyMacos(zipPath);
    } else if (Platform.isWindows && kReleaseMode) {
      await _applyWindows(zipPath);
    } else {
      // dev 환경이거나 지원하지 않는 플랫폼 → 브라우저 열기
      _launch(info.releaseUrl);
    }
  }

  Future<void> _downloadFile(
    String url,
    String dest,
    void Function(double)? onProgress,
  ) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      final res = await client.send(req);
      if (res.statusCode != 200) {
        throw HttpException('다운로드 실패 (HTTP ${res.statusCode})');
      }
      final total = res.contentLength ?? 0;
      var received = 0;
      final sink = File(dest).openWrite();
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.close();
    } finally {
      client.close();
    }
  }

  Future<void> _applyMacos(String zipPath) async {
    final exe = Platform.resolvedExecutable;
    // exe = <installDir>/Worship Slides.app/Contents/MacOS/worship_slides
    final appBundle = p.dirname(p.dirname(p.dirname(exe)));
    final installDir = p.dirname(appBundle);

    final scriptPath = p.join(p.dirname(zipPath), 'ws_update.sh');
    await File(scriptPath).writeAsString('''
#!/bin/bash
sleep 2
tmpDir="\$(mktemp -d)"
unzip -o "$zipPath" -d "\$tmpDir"
newApp="\$tmpDir/worship_slides/Worship Slides.app"
newPython="\$tmpDir/worship_slides/python"
if [ -d "\$newApp" ]; then
  ditto "\$newApp" "$appBundle"
fi
if [ -d "\$newPython" ]; then
  cp -R "\$newPython/" "$installDir/python/"
fi
open -n "$appBundle"
rm -rf "\$tmpDir"
rm -f "$zipPath"
rm -f "$scriptPath"
''');
    await Process.run('chmod', ['+x', scriptPath]);
    await Process.start(
      'bash',
      [scriptPath],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }

  /// Windows 는 PowerShell 도우미 없이 앱이 직접 덮어쓴다.
  /// 예전엔 숨은 PowerShell(.ps1, ExecutionPolicy Bypass)에 맡겼는데, 백신이 이 조합을
  /// 조용히 막아 스크립트가 한 줄도 안 돌았다(로그 파일조차 안 생김).
  /// 실행 중인 exe·dll 은 덮어쓸 수는 없어도 **이름은 바꿀 수 있으므로**, 잠긴 파일은
  /// `.old` 로 비켜 두고 새 파일을 넣은 뒤 새 exe 를 띄우고 종료한다.
  /// `.old` 는 다음 실행 때 [cleanupWindowsLeftovers] 가 지운다.
  Future<void> _applyWindows(String zipPath) async {
    final exe = Platform.resolvedExecutable;
    final installDir = p.dirname(exe);
    final extractDir = p.join(p.dirname(zipPath), 'ws_extracted');
    final log = AppLogger.instance;

    await log.info('[update] extract $zipPath');
    final dir = Directory(extractDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    // Windows 10(1803)+ 에 기본으로 들어 있는 bsdtar 가 zip 도 푼다.
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final tar = await Process.run(p.join(systemRoot, 'System32', 'tar.exe'), [
      '-xf',
      zipPath,
      '-C',
      extractDir,
    ]);
    if (tar.exitCode != 0) {
      throw Exception('압축 풀기 실패: ${tar.stderr}');
    }
    final src = p.join(extractDir, 'worship_slides');
    if (!Directory(src).existsSync()) {
      throw Exception('업데이트 파일에 worship_slides 폴더가 없습니다.');
    }

    final count = applyUpdateFiles(src, installDir);
    await log.info('[update] copied $count files -> $installDir');
    try {
      dir.deleteSync(recursive: true);
      File(zipPath).deleteSync();
    } catch (_) {}

    await Process.start(
      exe,
      const [],
      workingDirectory: installDir,
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }

  /// [srcDir] 의 파일을 [installDir] 에 덮어쓴다(지우지 않는다 — 옆의 DB 가 살아야 한다).
  /// 잠겨서 못 덮어쓰는 파일은 기존 것을 `.old` 로 이름만 바꾸고 넣는다. 복사한 파일 수를 돌려준다.
  @visibleForTesting
  static int applyUpdateFiles(String srcDir, String installDir) {
    var count = 0;
    for (final entity in Directory(srcDir).listSync(recursive: true)) {
      if (entity is! File) continue;
      final dest = p.join(installDir, p.relative(entity.path, from: srcDir));
      Directory(p.dirname(dest)).createSync(recursive: true);
      try {
        entity.copySync(dest);
      } on FileSystemException {
        final old = '$dest.old';
        try {
          File(old).deleteSync();
        } catch (_) {}
        File(dest).renameSync(old);
        entity.copySync(dest);
      }
      count++;
    }
    return count;
  }

  /// 지난 업데이트가 비켜 둔 `.old` 파일을 지운다. 앱 시작 때 부른다.
  static void cleanupWindowsLeftovers() {
    if (!Platform.isWindows || !kReleaseMode) return;
    final installDir = Directory(p.dirname(Platform.resolvedExecutable));
    try {
      for (final f in installDir.listSync(recursive: true)) {
        if (f is File && f.path.endsWith('.old')) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _launch(String url) {
    if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else if (Platform.isWindows) {
      Process.run('start', [url], runInShell: true);
    } else {
      Process.run('xdg-open', [url]);
    }
  }
}
