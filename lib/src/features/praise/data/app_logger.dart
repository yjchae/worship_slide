import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  File? _logFile;

  Future<File> _getLogFile() async {
    if (_logFile != null) return _logFile!;
    final dir = await getApplicationSupportDirectory();
    final logDir = Directory(p.join(dir.path, 'logs'));
    await logDir.create(recursive: true);
    _logFile = File(p.join(logDir.path, 'app.log'));
    return _logFile!;
  }

  Future<void> error(String message, [Object? err, StackTrace? stack]) async {
    try {
      final file = await _getLogFile();
      final ts = DateTime.now().toIso8601String();
      final buf = StringBuffer()..writeln('[$ts] [ERROR] $message');
      if (err != null) buf.writeln('  원인: $err');
      if (stack != null) buf.writeln('  스택:\n$stack');
      await file.writeAsString(buf.toString(), mode: FileMode.append);
    } catch (_) {}
  }

  Future<void> info(String message) async {
    try {
      final file = await _getLogFile();
      final ts = DateTime.now().toIso8601String();
      await file.writeAsString(
        '[$ts] [INFO] $message\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  Future<String> readLogs() async {
    try {
      final file = await _getLogFile();
      if (!await file.exists()) return '(저장된 로그 없음)';
      final content = await file.readAsString();
      if (content.isEmpty) return '(저장된 로그 없음)';
      // 최근 500줄만 반환
      final lines = content.split('\n');
      if (lines.length > 500) {
        return '... (앞부분 생략, 전체 ${lines.length}줄) ...\n\n'
            '${lines.sublist(lines.length - 500).join('\n')}';
      }
      return content;
    } catch (e) {
      return '로그 읽기 실패: $e';
    }
  }

  Future<String?> logFilePath() async {
    try {
      final file = await _getLogFile();
      return file.path;
    } catch (_) {
      return null;
    }
  }
}
