import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../domain/export_style.dart';
import '../domain/praise_song.dart';
import '../domain/slide_background.dart';
import '../domain/staging_item.dart';
import 'app_logger.dart';
import 'font_library.dart';

class LibreOfficeMissingException implements Exception {
  const LibreOfficeMissingException();

  @override
  String toString() => 'PPT를 이미지로 변환하려면 LibreOffice가 필요합니다. 설치 후 다시 시도해 주세요.';
}

class ClipboardEmptyException implements Exception {
  const ClipboardEmptyException();

  @override
  String toString() => Platform.isMacOS
      // ⌘⇧4 는 파일로만 저장하고 클립보드에는 넣지 않는다.
      ? '클립보드에 악보 그림이 없습니다. ⌘⇧4 는 캡처를 파일로만 저장합니다 — '
            '⌘⌃⇧4(Control 추가)로 캡처하거나, 캡처한 파일을 Finder 에서 ⌘C 로 복사한 뒤 다시 시도해 주세요.'
      : '클립보드에 악보 그림이 없습니다. 악보를 캡처하거나 복사한 뒤 다시 시도해 주세요.';
}

class TesseractMissingException implements Exception {
  const TesseractMissingException();

  @override
  String toString() => '악보에서 가사를 읽으려면 Tesseract OCR이 필요합니다. 설치 후 다시 시도해 주세요.';
}

/// 악보 한 장(또는 PDF 한 권)에서 뽑아낸 가사.
class SheetLyricsResult {
  const SheetLyricsResult({
    required this.sourceName,
    required this.lyrics,
    required this.staffCount,
  });

  final String sourceName;
  final String lyrics;

  /// 찾아낸 오선 단 수. 0이면 오선을 못 찾아 이미지 전체를 읽었다는 뜻이다.
  final int staffCount;
}

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
  /// OS 내장 OCR(macOS Vision, Windows.Media.Ocr). 악보 가사 줄 이미지를 읽는다.
  static const MethodChannel _ocrChannel = MethodChannel('worship_slides/ocr');

  /// 한 번 물어본 뒤로는 기억한다 (언어 팩을 새로 깔면 앱을 다시 켜야 반영된다).
  static Future<bool>? _nativeOcrAvailable;

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

  /// 외부 PPT/PPTX의 모든 페이지를 PNG로 굽고 이미지 항목으로 돌려준다.
  Future<ImageStagingItem> renderPptToImages(String filePath) async {
    final result = await _runTool(['render', filePath]);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    if (json['error'] == 'libreoffice_missing') {
      throw const LibreOfficeMissingException();
    }
    return ImageStagingItem(
      sourceName: json['source_name'] as String,
      imagePaths: (json['image_paths'] as List<dynamic>).cast<String>(),
      sourcePath: filePath,
    );
  }

  /// 악보(이미지·PDF)에서 오선 아래 가사만 읽어 온다.
  /// 글자가 박힌 PDF 는 OCR 없이 읽는다.
  /// [filePath] 가 null 이면 클립보드의 그림(캡처·복사한 이미지)을 읽는다.
  ///
  /// 그림은 OS 내장 OCR 이 있으면 그것으로, 없으면(macOS 12 이하, Windows 한국어 OCR 미설치)
  /// Tesseract 로 읽는다. 오선·가사 줄 찾기와 절 정리는 어느 쪽이든 Python 이 한다.
  Future<SheetLyricsResult> extractSheetLyrics(String? filePath) async {
    // macOS 는 클립보드를 앱이 읽어 파일로 넘긴다 — ppt_tool(osascript)이 읽으면
    // 붙여넣기 허용 창이 안 보인 채 멈춘다.
    if (filePath == null && Platform.isMacOS) {
      filePath = await _ocrChannel.invokeMethod<String>('clipboardImage');
      if (filePath == null) throw const ClipboardEmptyException();
    }
    SheetLyricsResult? nativeEmpty;
    if (await _hasNativeOcr()) {
      try {
        final result = await _extractWithNativeOcr(filePath);
        if (!result.unreadImages) return result.lyrics;
        // 줄 이미지에서 글자를 하나도 못 읽었다. 이미지마다 조용히 실패했을 수도(경로를 못 여는 등),
        // 가사 없는 악보일 수도 있어서 Tesseract 로 한 번 더 해 본다.
        nativeEmpty = result.lyrics;
        await AppLogger.instance.info(
          '[sheet-ocr] OS OCR 이 글자를 못 읽어 Tesseract 로 다시 읽습니다',
        );
      } on PlatformException catch (error, stack) {
        // OS OCR 이 갑자기 실패하면(언어 팩 제거 등) Tesseract 로 한 번 더 해 본다.
        await AppLogger.instance.error(
          'OS OCR 실패, Tesseract 로 읽습니다',
          error,
          stack,
        );
      }
    }
    try {
      final result = await _runTool(['sheet', filePath ?? '--clipboard']);
      return _sheetResult(result.stdout as String);
    } catch (error) {
      // OS OCR 로 이미 읽은(빈) 결과가 있으면, 다시 읽기가 어떤 이유로 실패하든(Tesseract 없음,
      // 그 사이 클립보드가 바뀜 등) 오류 대신 그 결과를 보여 준다. OS OCR 이 주 엔진이라
      // 가사 없는 악보에 'Tesseract 를 설치하라'고 하면 더 헷갈린다.
      if (nativeEmpty != null) return nativeEmpty;
      rethrow;
    }
  }

  Future<bool> _hasNativeOcr() {
    return _nativeOcrAvailable ??= () async {
      if (!Platform.isMacOS && !Platform.isWindows) return false;
      try {
        final available =
            await _ocrChannel.invokeMethod<bool>('isAvailable') ?? false;
        await AppLogger.instance.info(
          '[sheet-ocr] OS 내장 OCR 사용 가능: $available',
        );
        return available;
      } on PlatformException {
        return false;
      } on MissingPluginException {
        return false;
      }
    }();
  }

  /// Python 이 가사 줄 이미지를 잘라 두면(1단계) OS OCR 로 읽고,
  /// 그 결과를 다시 Python 에 넘겨 정리한다(2단계).
  /// `unreadImages` = 읽을 이미지가 있었는데 한 장에서도 글자를 못 찾았다.
  Future<({SheetLyricsResult lyrics, bool unreadImages})> _extractWithNativeOcr(
    String? filePath,
  ) async {
    final workDir = await Directory.systemTemp.createTemp('worship_sheet_ocr_');
    try {
      final stage1 = await _runTool([
        'sheet',
        filePath ?? '--clipboard',
        '--ocr-lines',
        workDir.path,
      ]);
      final json = jsonDecode(stage1.stdout as String) as Map<String, dynamic>;
      // 글자가 박힌 PDF 처럼 OCR 이 필요 없으면 1단계에서 바로 끝난다.
      if (json['needs_ocr'] != true) {
        return (
          lyrics: _sheetResult(stage1.stdout as String),
          unreadImages: false,
        );
      }

      final images = (json['images'] as List<dynamic>).cast<String>();
      final found = await _ocrChannel.invokeMethod<Map<Object?, Object?>>(
        'recognize',
        {'paths': images},
      );
      final anyText =
          found?.values.any((lines) => lines is List && lines.isNotEmpty) ??
          false;
      final ocrFile = File(p.join(workDir.path, 'ocr.json'));
      await ocrFile.writeAsString(jsonEncode(found ?? const {}));
      final stage2 = await _runTool([
        'sheet-finish',
        json['job'] as String,
        ocrFile.path,
      ]);
      return (
        lyrics: _sheetResult(stage2.stdout as String),
        unreadImages: !anyText,
      );
    } finally {
      try {
        await workDir.delete(recursive: true);
      } on FileSystemException {
        // 임시 폴더라 못 지워도 OS 가 언젠가 치운다.
      }
    }
  }

  SheetLyricsResult _sheetResult(String stdout) {
    final json = jsonDecode(stdout) as Map<String, dynamic>;
    if (json['error'] == 'tesseract_missing') {
      throw const TesseractMissingException();
    }
    if (json['error'] == 'clipboard_empty') {
      throw const ClipboardEmptyException();
    }
    return SheetLyricsResult(
      sourceName: json['source_name'] as String,
      lyrics: json['lyrics'] as String,
      staffCount: (json['staff_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// [stagingItems] 의 `background` 는 그 항목에만 적용되는 배경 오버라이드.
  /// null 이면 [style] 의 전역 배경을 그대로 쓴다.
  Future<String> exportPresentation({
    required String outputPath,
    required List<
      ({StagingItem item, SlideBackground? background, bool noSpacer})
    >
    stagingItems,
    required ExportStyle style,
  }) async {
    final payload = jsonEncode({
      'output_path': outputPath,
      'songs': stagingItems.map((entry) {
        final Map<String, dynamic> json = switch (entry.item) {
          SongStagingItem(:final song) => {
            'type': 'song',
            'title': song.displayTitle,
            'lyrics': song.lyrics,
            'english_lyrics': song.englishLyrics,
          },
          BibleStagingItem(:final reference, :final text, :final subText) => {
            'type': 'bible',
            'title': reference,
            'lyrics': text,
            'english_lyrics': subText,
          },
          BlankStagingItem(:final mainText, :final englishText) => {
            'type': 'blank',
            'title': '',
            'lyrics': mainText,
            'english_lyrics': englishText,
          },
          ImageStagingItem(:final sourceName, :final imagePaths) => {
            'type': 'image',
            'title': sourceName,
            'lyrics': '',
            'english_lyrics': '',
            'image_paths': imagePaths,
          },
        };
        final background = entry.background;
        json['background'] = background == null
            ? null
            : {
                ...background.toJson(),
                if (background.fontFamily != null)
                  'font_files': FontLibrary.filesFor(background.fontFamily!),
              };
        if (entry.noSpacer) json['no_spacer'] = true;
        return json;
      }).toList(),
      'style': {
        ...style.toJson(),
        'font_files': FontLibrary.filesFor(style.fontFamily),
      },
    });

    final result = await _runTool(['export', payload]);

    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    return json['output_path'] as String;
  }

  Future<ProcessResult> _runTool(List<String> arguments) async {
    final binary = _compiledBinaryPath;
    if (binary == null) {
      final msg =
          'ppt_tool 실행 파일을 찾을 수 없습니다. '
          '현재 위치: ${Directory.current.path}, 실행 파일: ${Platform.resolvedExecutable}';
      await AppLogger.instance.error(msg);
      throw Exception(msg);
    }

    final result = await Process.run(binary, arguments, runInShell: false);
    if (result.exitCode != 0) {
      final stderr = (result.stderr as String).trim();
      final msg = stderr.isEmpty ? 'ppt_tool 실행 실패.' : stderr;
      await AppLogger.instance.error(
        'ppt_tool 오류 (cmd: ${arguments.first})',
        msg,
      );
      throw Exception(msg);
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
