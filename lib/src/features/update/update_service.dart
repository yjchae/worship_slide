import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  Future<void> _applyWindows(String zipPath) async {
    final exe = Platform.resolvedExecutable;
    final installDir = p.dirname(exe);
    final tmp = p.dirname(zipPath);
    final scriptPath = p.join(tmp, 'ws_update.ps1');

    final script = buildWindowsUpdateScript(
      appPid: pid,
      exePath: exe,
      installDir: installDir,
      zipPath: zipPath,
      extractDir: p.join(tmp, 'ws_extracted'),
      logPath: p.join(tmp, 'ws_update.log'),
    );
    // Windows PowerShell 5.1 은 BOM 없는 .ps1 을 시스템 ANSI(CP949)로 읽는다.
    // 경로에 한글이 있으면 깨져서 스크립트 전체가 파싱 에러로 실행조차 안 된다.
    await File(scriptPath).writeAsBytes([
      0xEF, 0xBB, 0xBF, // UTF-8 BOM
      ...utf8.encode(script),
    ]);

    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final powershell = p.join(
      systemRoot,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    await Process.start(
      powershell,
      [
        '-NoProfile',
        // Windows 기본 실행 정책(Restricted)은 .ps1 실행 자체를 막는다
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-NonInteractive',
        '-File', scriptPath,
      ],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }

  /// Windows 업데이트 스크립트.
  ///
  /// 1. 앱 프로세스가 완전히 끝날 때까지 기다린다 (실행 중인 exe·dll 은 덮어쓸 수 없다)
  /// 2. zip 을 풀어 `worship_slides/` 내용을 설치 폴더에 덮어쓴다 (robocopy, 잠김은 재시도)
  /// 3. 성공하든 실패하든 앱을 다시 띄우고, 과정은 [logPath] 에 남긴다
  @visibleForTesting
  static String buildWindowsUpdateScript({
    required int appPid,
    required String exePath,
    required String installDir,
    required String zipPath,
    required String extractDir,
    required String logPath,
  }) {
    // 작은따옴표 문자열은 $ 를 해석하지 않는다. 안의 ' 만 '' 로 바꾸면 된다
    String q(String v) => "'${v.replaceAll("'", "''")}'";
    return '''
\$ErrorActionPreference = 'Stop'
\$log = ${q(logPath)}
\$installDir = ${q(installDir)}
\$exePath = ${q(exePath)}
\$zipPath = ${q(zipPath)}
\$extractDir = ${q(extractDir)}
function Log([string]\$msg) {
  Add-Content -LiteralPath \$log -Value "\$(Get-Date -Format s) \$msg" -Encoding UTF8
}
Set-Content -LiteralPath \$log -Value "update start (pid $appPid)" -Encoding UTF8
try {
  try { Wait-Process -Id $appPid -Timeout 60 -ErrorAction Stop } catch { }
  Start-Sleep -Seconds 1
  if (Test-Path -LiteralPath \$extractDir) {
    Remove-Item -LiteralPath \$extractDir -Recurse -Force
  }
  Expand-Archive -LiteralPath \$zipPath -DestinationPath \$extractDir -Force
  \$src = Join-Path \$extractDir 'worship_slides'
  if (-not (Test-Path -LiteralPath \$src)) {
    throw "worship_slides folder not found in zip"
  }
  Log "copy \$src -> \$installDir"
  \$out = robocopy \$src \$installDir /E /IS /R:10 /W:1 /NP /NJH /NDL
  \$code = \$LASTEXITCODE
  Log (\$out -join "`n")
  if (\$code -ge 8) { throw "robocopy failed (exit \$code)" }
  Log "update ok"
} catch {
  Log "update failed: \$_"
} finally {
  try {
    Start-Process -FilePath \$exePath -WorkingDirectory \$installDir
  } catch {
    Log "restart failed: \$_"
  }
  Remove-Item -LiteralPath \$extractDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath \$zipPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath \$PSCommandPath -Force -ErrorAction SilentlyContinue
}
''';
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
