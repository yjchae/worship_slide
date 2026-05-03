import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/export_style.dart';
import '../domain/praise_song.dart';
import '../domain/staging_item.dart';

class ImportFailure {
  const ImportFailure({
    required this.fileName,
    required this.path,
    required this.error,
  });

  final String fileName;
  final String path;
  final String error;
}

class ImportResult {
  const ImportResult({
    required this.songs,
    required this.processedCount,
    required this.importedCount,
    required this.failedCount,
    required this.failures,
    required this.libreofficeMissing,
  });

  final List<PraiseSong> songs;
  final int processedCount;
  final int importedCount;
  final int failedCount;
  final List<ImportFailure> failures;
  final bool libreofficeMissing;
}

class PythonBridge {
  Future<ImportResult> importFolder(String folderPath) async {
    final result = await _runTool(['import', folderPath]);

    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final songsJson = json['songs'] as List<dynamic>;
    final songs = songsJson
        .map((song) => PraiseSong.fromJson(song as Map<String, dynamic>))
        .toList();
    final failuresJson = (json['errors'] as List<dynamic>? ?? const []);
    final failures = failuresJson
        .map(
          (entry) => ImportFailure(
            fileName: (entry as Map<String, dynamic>)['file_name'] as String,
            path: entry['path'] as String,
            error: entry['error'] as String,
          ),
        )
        .toList();

    return ImportResult(
      songs: songs,
      processedCount:
          (json['processed_count'] as num?)?.toInt() ?? songs.length,
      importedCount: (json['imported_count'] as num?)?.toInt() ?? songs.length,
      failedCount: (json['failed_count'] as num?)?.toInt() ?? failures.length,
      failures: failures,
      libreofficeMissing: (json['libreoffice_missing'] as bool?) ?? false,
    );
  }

  Future<String> exportPresentation({
    required String outputPath,
    required List<StagingItem> stagingItems,
    required ExportStyle style,
  }) async {
    final payload = jsonEncode({
      'output_path': outputPath,
      'songs': stagingItems.map((item) {
        return switch (item) {
          SongStagingItem(:final song) => {
            'type': 'song',
            'title': song.title,
            'lyrics': song.lyrics,
            'english_lyrics': song.englishLyrics,
          },
          BibleStagingItem(:final reference, :final text) => {
            'type': 'bible',
            'title': reference,
            'lyrics': text,
            'english_lyrics': '',
          },
        };
      }).toList(),
      'style': style.toJson(),
    });

    final result = await _runTool(['export', payload]);

    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    return json['output_path'] as String;
  }

  Future<ProcessResult> _runTool(List<String> arguments) async {
    final binary = _compiledBinaryPath;
    if (binary == null) {
      throw Exception(
        'ppt_tool 실행 파일을 찾을 수 없습니다. '
        '현재 위치: ${Directory.current.path}, 실행 파일: ${Platform.resolvedExecutable}',
      );
    }

    final result = await Process.run(binary, arguments, runInShell: false);
    if (result.exitCode != 0) {
      throw Exception(
        (result.stderr as String).trim().isEmpty
            ? 'ppt_tool 실행 실패.'
            : (result.stderr as String).trim(),
      );
    }
    return result;
  }

  // PyInstaller onefile/onedir 실행 파일 탐색
  String? get _compiledBinaryPath {
    final name = Platform.isWindows ? 'ppt_tool.exe' : 'ppt_tool';
    for (final root in _searchRoots) {
      final flatCandidate = File(p.join(root, 'python', name));
      if (flatCandidate.existsSync()) {
        return flatCandidate.path;
      }

      final oneDirCandidate = File(p.join(root, 'python', 'ppt_tool', name));
      if (oneDirCandidate.existsSync()) {
        return oneDirCandidate.path;
      }
    }
    return null;
  }

  List<String> get _searchRoots {
    final roots = <String>{};

    void addAncestorRoots(String startPath) {
      var current = Directory(startPath).absolute;
      while (true) {
        roots.add(p.normalize(current.path));
        final parent = current.parent;
        if (parent.path == current.path) {
          break;
        }
        current = parent;
      }
    }

    addAncestorRoots(Directory.current.path);
    addAncestorRoots(File(Platform.resolvedExecutable).parent.path);
    final pwd = Platform.environment['PWD'];
    if (pwd != null && pwd.isNotEmpty) {
      addAncestorRoots(pwd);
    }

    return roots.toList();
  }
}
