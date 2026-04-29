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
  static const _repo = 'make_ppt';
  static const _apiUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';

  Future<UpdateInfo?> checkForUpdates() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = info.version;

      final response = await http
          .get(
            Uri.parse(_apiUrl),
            headers: {'Accept': 'application/vnd.github.v3+json'},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      final data = json.decode(response.body) as Map<String, dynamic>;
      final tagName = data['tag_name'] as String;
      final latest =
          tagName.startsWith('v') ? tagName.substring(1) : tagName;

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
    } catch (_) {
      return null;
    }
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
    final extractDir = p.join(tmp, 'ws_extracted');
    final scriptPath = p.join(tmp, 'ws_update.ps1');

    await File(scriptPath).writeAsString('''
Start-Sleep -Seconds 2
Expand-Archive -Force "$zipPath" "$extractDir"
\$src = "$extractDir\\worship_slides"
Get-ChildItem "\$src" | Copy-Item -Destination "$installDir" -Recurse -Force
Start-Process "$installDir\\worship_slides.exe"
Remove-Item -Recurse -Force "$extractDir"
Remove-Item -Force "$zipPath"
Remove-Item -Force "$scriptPath"
''');
    await Process.start(
      'powershell',
      ['-WindowStyle', 'Hidden', '-NonInteractive', '-File', scriptPath],
      mode: ProcessStartMode.detached,
    );
    exit(0);
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
