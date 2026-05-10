import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../features/bible/data/bible_repository.dart';
import '../../../features/bible/domain/bible_verse.dart';
import '../../../features/update/update_service.dart';
import '../data/export_style_store.dart';
import '../data/praise_repository.dart';
import '../data/python_bridge.dart';
import '../domain/export_style.dart';
import '../domain/praise_song.dart';
import '../domain/staging_item.dart';
import 'slide_page_data.dart';

class PraiseHomePage extends StatefulWidget {
  const PraiseHomePage({super.key});

  @override
  State<PraiseHomePage> createState() => _PraiseHomePageState();
}

// 슬라이드 한 페이지 정보 (스테이징 아이템에서 펼쳐진 단위)
class _SlideInfo {
  const _SlideInfo({
    required this.stagingUid,
    required this.mainText,
    required this.englishText,
    required this.title,
    required this.isBible,
  });
  final int stagingUid;
  final String mainText;
  final String englishText;
  final String? title;
  final bool isBible;
}

class _PraiseHomePageState extends State<PraiseHomePage> {
  static const MethodChannel _savePanelChannel = MethodChannel(
    'worship_slides/save_panel',
  );
  static const MethodChannel _presentationChannel = MethodChannel(
    'worship_slides/presentation',
  );
  static const MethodChannel _mainPresentationChannel = MethodChannel(
    'worship_slides/presentation_main',
  );
  static const ExportStyle _defaultStyle = ExportStyle(
    fontSize: 30,
    bibleFontSize: 30,
    textBoxTop: 0.6,
    bibleTextBoxTop: 0.6,
    backgroundColor: Color(0xFF1B1B1B),
    textColor: Colors.white,
    bibleTextColor: Colors.white,
    textPosition: VerticalTextPosition.middle,
    bibleTextPosition: VerticalTextPosition.middle,
    lyricsTextAlign: HorizontalPosition.center,
    bibleTextAlign: HorizontalPosition.center,
    includeEnglishLyrics: true,
    englishTextColor: Color(0xFFFFF176),
    showSongTitle: false,
    showBibleTitle: false,
    titleFontSize: 14,
    bibleTitleFontSize: 14,
    titleTextColor: Color(0xB3FFFFFF),
    bibleTitleTextColor: Color(0xB3FFFFFF),
    titleHorizontalPosition: HorizontalPosition.right,
    titleVerticalPosition: VerticalTextPosition.bottom,
    bibleTitleHorizontalPosition: HorizontalPosition.right,
    bibleTitleVerticalPosition: VerticalTextPosition.bottom,
  );

  final PraiseRepository _repository = PraiseRepository();
  final PythonBridge _pythonBridge = PythonBridge();
  final ExportStyleStore _styleStore = ExportStyleStore();
  final BibleRepository _bibleRepository = BibleRepository();
  final TextEditingController _searchController = TextEditingController();
  final UpdateService _updateService = UpdateService();

  UpdateInfo? _pendingUpdate;
  bool _isDownloadingUpdate = false;
  double _updateProgress = 0.0;
  bool _isCheckingUpdate = false;

  List<PraiseSong> _songs = const [];
  final List<({int uid, StagingItem item})> _stagingItems = [];
  int _nextUid = 0;
  int? _previewStagingUid;
  double _stagingPanelRatio = 0.46;

  String? _selectedFolder;
  bool _isImporting = false;
  bool _isBibleImporting = false;
  bool _isExporting = false;
  int _storedCount = 0;
  int _bibleVerseCount = 0;
  int _bibleDataRevision = 0;
  int _importTotalCount = 0;
  int _importSavedCount = 0;
  String? _importStatusText;
  ExportStyle _style = _defaultStyle;

  // 발표 모드
  int _currentSlideIndex = 0;
  bool _isPresentationOpen = false;

  final List<Color> _swatches = const [
    Color(0xFF1B1B1B),
    Color(0xFF121212),
    Color(0xFF0F4C5C),
    Color(0xFF0B132B),
    Color(0xFF5F0F40),
    Color(0xFF2D1E2F),
    Color(0xFF445D48),
    Color(0xFFF4F1EA),
    Color(0xFFFFFFFF),
  ];

  final List<Color> _textSwatches = const [
    Colors.white,
    Colors.black,
    Color(0xFFE3F2FD),
    Color(0xFFFFF176),
    Color(0xFFFFCDD2),
    Color(0xFFFFF8E1),
    Color(0xFFC8E6C9),
    Color(0xFFD1C4E9),
  ];

  @override
  void initState() {
    super.initState();
    _loadSongs();
    _loadSavedStyle();
    _loadBibleCount();
    _searchController.addListener(_loadSongs);
    _checkForUpdates();
    _mainPresentationChannel.setMethodCallHandler((call) async {
      if (call.method == 'presentationClosed' && mounted) {
        setState(() => _isPresentationOpen = false);
      }
      return null;
    });
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_loadSongs)
      ..dispose();
    super.dispose();
  }

  // ── 계산된 프로퍼티 ───────────────────────────────────────────────────

  Set<int?> get _selectedSongIds => _stagingItems
      .map((e) => e.item)
      .whereType<SongStagingItem>()
      .map((item) => item.song.id)
      .toSet();

  // ── 데이터 로딩 ──────────────────────────────────────────────────────

  Future<void> _loadSongs() async {
    if (_searchController.value.composing != TextRange.empty) return;
    final songs = await _repository.searchSongs(_searchController.text);
    final storedCount = await _repository.countSongs();
    if (!mounted) return;
    if (_searchController.value.composing != TextRange.empty) return;
    setState(() {
      _songs = songs;
      _storedCount = storedCount;
    });
  }

  Future<void> _loadSavedStyle() async {
    final savedStyle = await _styleStore.load();
    if (!mounted || savedStyle == null) return;
    setState(() => _style = savedStyle);
  }

  Future<void> _updateStyle(ExportStyle style) async {
    setState(() => _style = style);
    await _styleStore.save(style);
    await _sendCurrentSlide();
  }

  // ── 발표 모드 ────────────────────────────────────────────────────────────

  List<_SlideInfo> get _allSlides {
    final slides = <_SlideInfo>[];
    for (final entry in _stagingItems) {
      final item = entry.item;
      if (item is SongStagingItem) {
        final song = item.song;
        final pages = song.pages;
        final englishPages = song.englishPages;
        for (var i = 0; i < pages.length; i++) {
          slides.add(
            _SlideInfo(
              stagingUid: entry.uid,
              mainText: pages[i],
              englishText: i < englishPages.length ? englishPages[i] : '',
              title: song.title,
              isBible: false,
            ),
          );
        }
      } else if (item is BibleStagingItem) {
        slides.add(
          _SlideInfo(
            stagingUid: entry.uid,
            mainText: item.text,
            englishText: '',
            title: item.reference,
            isBible: true,
          ),
        );
      }
    }
    return slides;
  }

  void _clampCurrentSlideIndex() {
    final total = _allSlides.length;
    if (total == 0) {
      _currentSlideIndex = 0;
    } else if (_currentSlideIndex >= total) {
      _currentSlideIndex = total - 1;
    }
  }

  int _findFirstSlideForStaging(int stagingUid) {
    final slides = _allSlides;
    for (var i = 0; i < slides.length; i++) {
      if (slides[i].stagingUid == stagingUid) return i;
    }
    return _currentSlideIndex;
  }

  SlidePageData _buildSlidePageData(int index) {
    final slides = _allSlides;
    final slide = index < slides.length ? slides[index] : null;
    return SlidePageData(
      mainText: slide?.mainText ?? '',
      englishText: slide?.englishText ?? '',
      title: slide?.title,
      isBible: slide?.isBible ?? false,
      pageIndex: index,
      totalPages: slides.length,
      style: _style,
    );
  }

  Future<void> _openPresentation() async {
    final slides = _allSlides;
    if (slides.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('표시할 슬라이드가 없습니다. 찬양이나 성경 본문을 먼저 선택해 주세요.'),
        ),
      );
      return;
    }
    try {
      final pageData = _buildSlidePageData(_currentSlideIndex);
      await _presentationChannel.invokeMethod(
        'openWindow',
        pageData.toJson(),
      );
      if (!mounted) return;
      setState(() => _isPresentationOpen = true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('발표 화면 열기 실패: $e')));
    }
  }

  Future<void> _closePresentation() async {
    try {
      await _presentationChannel.invokeMethod('closeWindow');
    } catch (_) {}
    if (mounted) setState(() => _isPresentationOpen = false);
  }

  Future<void> _sendCurrentSlide() async {
    if (!_isPresentationOpen) return;
    try {
      final pageData = _buildSlidePageData(_currentSlideIndex);
      await _presentationChannel.invokeMethod(
        'updatePage',
        pageData.toJson(),
      );
    } catch (_) {
      if (mounted) setState(() => _isPresentationOpen = false);
    }
  }

  Future<void> _prevSlide() async {
    final slides = _allSlides;
    if (slides.isEmpty || _currentSlideIndex <= 0) return;
    setState(() {
      _currentSlideIndex--;
      _previewStagingUid = slides[_currentSlideIndex].stagingUid;
    });
    await _sendCurrentSlide();
  }

  Future<void> _nextSlide() async {
    final slides = _allSlides;
    if (slides.isEmpty || _currentSlideIndex >= slides.length - 1) return;
    setState(() {
      _currentSlideIndex++;
      _previewStagingUid = slides[_currentSlideIndex].stagingUid;
    });
    await _sendCurrentSlide();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isPresentationOpen) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _nextSlide();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _prevSlide();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ── 업데이트 ─────────────────────────────────────────────────────────

  Future<void> _checkForUpdates() async {
    if (_isCheckingUpdate) return;
    setState(() => _isCheckingUpdate = true);
    final info = await _updateService.checkForUpdates();
    if (!mounted) return;
    setState(() {
      _isCheckingUpdate = false;
      if (info != null) _pendingUpdate = info;
    });
  }

  Future<void> _startUpdate() async {
    if (_pendingUpdate == null) return;
    setState(() {
      _isDownloadingUpdate = true;
      _updateProgress = 0.0;
    });
    try {
      await _updateService.downloadAndInstall(
        _pendingUpdate!,
        onProgress: (p) {
          if (mounted) setState(() => _updateProgress = p);
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isDownloadingUpdate = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('업데이트 실패: $e')));
    }
  }

  // ── 스테이징 조작 ────────────────────────────────────────────────────

  void _toggleSongSelection(PraiseSong song, bool isSelected) {
    setState(() {
      if (isSelected) {
        final alreadyAdded = _stagingItems.any(
          (e) =>
              e.item is SongStagingItem &&
              (e.item as SongStagingItem).song.id == song.id,
        );
        if (!alreadyAdded) {
          _stagingItems.add((uid: _nextUid++, item: SongStagingItem(song)));
        }
      } else {
        _stagingItems.removeWhere(
          (e) =>
              e.item is SongStagingItem &&
              (e.item as SongStagingItem).song.id == song.id,
        );
        _clampCurrentSlideIndex();
      }
    });
  }

  void _addBibleItem(BibleStagingItem item) {
    setState(() {
      final uid = _nextUid++;
      _stagingItems.add((uid: uid, item: item));
      _previewStagingUid = uid;
    });
  }

  void _removeFromStaging(int uid) {
    setState(() {
      _stagingItems.removeWhere((e) => e.uid == uid);
      if (_previewStagingUid == uid) {
        _previewStagingUid = _stagingItems.isEmpty
            ? null
            : _stagingItems.first.uid;
      }
      _clampCurrentSlideIndex();
    });
  }

  void _onStagingReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      final entry = _stagingItems.removeAt(oldIndex);
      _stagingItems.insert(newIndex, entry);
      _clampCurrentSlideIndex();
    });
  }

  // ── PPT 찬양 가져오기 ────────────────────────────────────────────────

  Future<void> _pickAndImportFolder() async {
    await FilePicker.skipEntitlementsChecks();
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: '찬양 PPT 폴더 선택',
    );
    if (folder == null) return;

    setState(() {
      _selectedFolder = folder;
      _isImporting = true;
      _importTotalCount = 0;
      _importSavedCount = 0;
      _importStatusText = '폴더를 분석하는 중입니다.';
    });

    try {
      final result = await _pythonBridge.importFolder(folder);
      if (!mounted) return;
      setState(() {
        _importTotalCount = result.importedCount;
        _importSavedCount = 0;
        _importStatusText = result.importedCount == 0
            ? '저장할 찬양이 없습니다.'
            : '가져온 찬양을 저장하는 중입니다.';
      });
      var insertedCount = 0;
      var duplicateCount = 0;
      if (result.songs.isNotEmpty) {
        final saveResult = await _repository.addNewSongs(
          result.songs,
          onProgress: (savedCount, skippedCount) async {
            if (!mounted) return;
            insertedCount = savedCount;
            duplicateCount = skippedCount;
            setState(() {
              _importSavedCount = savedCount;
              _importStatusText = skippedCount == 0
                  ? '찬양을 저장하는 중입니다.'
                  : '찬양 저장 중입니다. 중복 $skippedCount개 건너뜀';
            });
            await Future<void>.delayed(Duration.zero);
          },
        );
        insertedCount = saveResult.insertedCount;
        duplicateCount = saveResult.skippedCount;
      }
      await _loadSongs();
      if (!mounted) return;
      final message = switch ((
        insertedCount,
        duplicateCount,
        result.failedCount,
      )) {
        (0, 0, 0) => '가져올 PPT/PPTX 파일을 찾지 못했습니다.',
        (0, > 0, 0) => '이미 저장된 찬양 $duplicateCount개를 건너뛰었습니다.',
        (> 0, 0, 0) => '$insertedCount개의 찬양을 추가했습니다.',
        (> 0, > 0, 0) => '$insertedCount개 추가, 중복 $duplicateCount개 건너뜀',
        (0, 0, > 0) =>
          '처리한 ${result.processedCount}개 중 저장된 파일이 없습니다. '
              '첫 오류: ${result.failures.first.fileName}',
        _ =>
          '$insertedCount개 추가, 중복 $duplicateCount개, 실패 ${result.failedCount}개 '
              '(총 ${result.processedCount}개 검사)',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      if (result.libreofficeMissing && mounted) {
        await _showLibreofficeDialog();
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('가져오기 실패: $error')));
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
          _importStatusText = null;
        });
      }
    }
  }

  // ── 성경 JSON 가져오기 ───────────────────────────────────────────────

  Future<void> _loadBibleCount() async {
    final count = await _bibleRepository.countVerses();
    if (!mounted) return;
    setState(() => _bibleVerseCount = count);
  }

  Future<void> _pickAndImportBible() async {
    await FilePicker.skipEntitlementsChecks();
    final result = await FilePicker.pickFiles(
      dialogTitle: '성경 JSON 파일 선택',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null) return;
    final defaultVersion = _versionNameFromPath(path);
    final version = await _askBibleVersionName(defaultVersion);
    if (version == null) return;

    setState(() => _isBibleImporting = true);
    try {
      final content = await File(path).readAsString();
      final count = await _bibleRepository.importFromJson(
        content,
        version: version,
      );
      final totalCount = await _bibleRepository.countVerses();
      if (!mounted) return;
      setState(() {
        _bibleVerseCount = totalCount;
        _bibleDataRevision += 1;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$version 성경 $count절을 저장했습니다.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('성경 불러오기 실패: $e')));
    } finally {
      if (mounted) setState(() => _isBibleImporting = false);
    }
  }

  String _versionNameFromPath(String path) {
    final fileName = File(path).uri.pathSegments.last;
    final dotIndex = fileName.lastIndexOf('.');
    return dotIndex <= 0 ? fileName : fileName.substring(0, dotIndex);
  }

  Future<String?> _askBibleVersionName(String initialValue) async {
    final controller = TextEditingController(text: initialValue);
    final version = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('성경 버전 이름'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '버전',
            hintText: '예: 개역개정, 새번역, KRV',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => Navigator.of(context).pop(controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (version == null || version.trim().isEmpty) return null;
    return version.trim();
  }

  // ── PPTX 내보내기 ────────────────────────────────────────────────────

  Future<void> _exportPresentation() async {
    if (_stagingItems.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('먼저 찬양이나 성경 본문을 선택해 주세요.')));
      return;
    }

    final outputPath = await _pickPptxOutputPath();
    if (outputPath == null) return;
    final normalizedOutputPath = _withPptxExtension(outputPath);

    setState(() => _isExporting = true);

    try {
      final savedPath = await _pythonBridge.exportPresentation(
        outputPath: normalizedOutputPath,
        stagingItems: _stagingItems.map((e) => e.item).toList(),
        style: _style,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('PPTX 저장 완료: $savedPath')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('PPTX 저장 실패: $error')));
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  String _withPptxExtension(String outputPath) {
    if (p.extension(outputPath).toLowerCase() == '.pptx') {
      return outputPath;
    }
    return p.setExtension(outputPath, '.pptx');
  }

  Future<String?> _pickPptxOutputPath() async {
    if (Platform.isMacOS) {
      try {
        return await _savePanelChannel.invokeMethod<String>(
          'showPptxSavePanel',
          const {'title': '저장할 PPTX 파일 선택', 'fileName': 'worship_slides.pptx'},
        );
      } on MissingPluginException {
        // Fall through to file_picker for non-standard runners.
      }
    }

    await FilePicker.skipEntitlementsChecks();
    return FilePicker.saveFile(
      dialogTitle: '저장할 PPTX 파일 선택',
      fileName: 'worship_slides.pptx',
      type: FileType.custom,
      allowedExtensions: ['pptx'],
    );
  }

  // ── 곡 관리 ──────────────────────────────────────────────────────────

  Future<void> _clearAllSongs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('전체 초기화'),
        content: const Text('저장된 찬양 DB를 모두 삭제합니다. 계속할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('전체 삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _repository.clearAllSongs();
    if (!mounted) return;
    setState(() {
      _stagingItems.removeWhere((e) => e.item is SongStagingItem);
      _clampCurrentSlideIndex();
    });
    await _loadSongs();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('저장된 찬양을 모두 삭제했습니다.')));
  }

  Future<void> _deleteSelectedSongs() async {
    final deletableIds = _stagingItems
        .map((e) => e.item)
        .whereType<SongStagingItem>()
        .map((item) => item.song.id)
        .whereType<int>()
        .toList();
    if (deletableIds.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('삭제할 찬양을 먼저 선택해 주세요.')));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('선택 곡 삭제'),
        content: Text('${deletableIds.length}곡을 DB에서 삭제합니다. 계속할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _repository.deleteSongsByIds(deletableIds);
    if (!mounted) return;
    setState(() {
      _stagingItems.removeWhere(
        (e) =>
            e.item is SongStagingItem &&
            deletableIds.contains((e.item as SongStagingItem).song.id),
      );
      _clampCurrentSlideIndex();
    });
    await _loadSongs();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${deletableIds.length}곡을 삭제했습니다.')));
  }

  Future<void> _openSongEditor(PraiseSong? song) async {
    final result = await showDialog<PraiseSong>(
      context: context,
      builder: (context) => _SongEditDialog(song: song),
    );
    if (result == null || !mounted) return;
    if (song == null) {
      await _repository.insertSong(result);
    } else {
      await _repository.updateSong(result);
    }
    await _loadSongs();
  }

  void _openUrl(String url) {
    if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else if (Platform.isWindows) {
      Process.run('start', [url], runInShell: true);
    } else {
      Process.run('xdg-open', [url]);
    }
  }

  Future<void> _showLibreofficeDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('LibreOffice가 필요합니다'),
        content: const Text(
          '.ppt 파일을 읽으려면 LibreOffice가 설치되어 있어야 합니다.\n\n'
          '.pptx 파일은 LibreOffice 없이도 정상적으로 가져올 수 있습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('닫기'),
          ),
          FilledButton.icon(
            onPressed: () {
              _openUrl(
                'https://www.libreoffice.org/download/download-libreoffice/',
              );
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.download_rounded),
            label: const Text('LibreOffice 다운로드'),
          ),
        ],
      ),
    );
  }

  // ── 빌드 ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    StagingItem? previewItem;
    for (final entry in _stagingItems) {
      if (entry.uid == _previewStagingUid) {
        previewItem = entry.item;
        break;
      }
    }
    previewItem ??= _stagingItems.isEmpty ? null : _stagingItems.first.item;

    final slides = _allSlides;
    final currentSlideTitle = slides.isEmpty
        ? null
        : slides[_currentSlideIndex.clamp(0, slides.length - 1)].title;

    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 1120;
                return Flex(
                  direction: isWide ? Axis.horizontal : Axis.vertical,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 7,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_pendingUpdate != null) ...[
                            _UpdateBanner(
                              version: _pendingUpdate!.version,
                              isDownloading: _isDownloadingUpdate,
                              progress: _updateProgress,
                              onUpdate: _startUpdate,
                              onDismiss: () =>
                                  setState(() => _pendingUpdate = null),
                            ),
                            const SizedBox(height: 8),
                          ],
                          _TopBar(
                            storedCount: _storedCount,
                            bibleVerseCount: _bibleVerseCount,
                            selectedFolder: _selectedFolder,
                            isImporting: _isImporting,
                            isBibleImporting: _isBibleImporting,
                            importTotalCount: _importTotalCount,
                            importSavedCount: _importSavedCount,
                            importStatusText: _importStatusText,
                            onImportPressed: _pickAndImportFolder,
                            onBibleImportPressed: _pickAndImportBible,
                            isCheckingUpdate: _isCheckingUpdate,
                            hasUpdate: _pendingUpdate != null,
                            onCheckUpdate: _checkForUpdates,
                          ),
                          const SizedBox(height: 8),
                          _PresentationControlBar(
                            slidesReady: slides.isNotEmpty,
                            isPresentationOpen: _isPresentationOpen,
                            currentSlideIndex: _currentSlideIndex,
                            totalSlides: slides.length,
                            currentSlideTitle: currentSlideTitle,
                            onOpen: _openPresentation,
                            onClose: _closePresentation,
                            onPrev: _prevSlide,
                            onNext: _nextSlide,
                          ),
                          const SizedBox(height: 10),
                          Expanded(
                            child: _ResizableWorkArea(
                              stagingRatio: _stagingPanelRatio,
                              onRatioChanged: (value) =>
                                  setState(() => _stagingPanelRatio = value),
                              stagingPanel: _StagingPanel(
                                stagingItems: _stagingItems,
                                selectedUid: _previewStagingUid,
                                onReorder: _onStagingReorder,
                                onRemove: _removeFromStaging,
                                onSelect: (uid) {
                                  setState(() {
                                    _previewStagingUid = uid;
                                    _currentSlideIndex =
                                        _findFirstSlideForStaging(uid);
                                  });
                                  _sendCurrentSlide();
                                },
                              ),
                              searchPanel: _SearchAndBiblePanel(
                                searchController: _searchController,
                                songs: _songs,
                                selectedSongIds: _selectedSongIds,
                                onSongChanged: _toggleSongSelection,
                                onDeleteSelected: _deleteSelectedSongs,
                                onClearAll: _clearAllSongs,
                                onAddSong: () => _openSongEditor(null),
                                onEditSong: _openSongEditor,
                                bibleRepository: _bibleRepository,
                                bibleVerseCount: _bibleVerseCount,
                                bibleDataRevision: _bibleDataRevision,
                                onAddBibleItem: _addBibleItem,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  SizedBox(width: isWide ? 20 : 0, height: isWide ? 0 : 20),
                  Expanded(
                    flex: 4,
                    child: _DesignPanel(
                      style: _style,
                      isExporting: _isExporting,
                      swatches: _swatches,
                      textSwatches: _textSwatches,
                      previewItem: previewItem,
                      onStyleChanged: _updateStyle,
                      onExportPressed: _exportPresentation,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),   // Scaffold
  );     // Focus
  }
}

// ── PresentationControlBar ───────────────────────────────────────────────

class _PresentationControlBar extends StatelessWidget {
  const _PresentationControlBar({
    required this.slidesReady,
    required this.isPresentationOpen,
    required this.currentSlideIndex,
    required this.totalSlides,
    required this.currentSlideTitle,
    required this.onOpen,
    required this.onClose,
    required this.onPrev,
    required this.onNext,
  });

  final bool slidesReady;
  final bool isPresentationOpen;
  final int currentSlideIndex;
  final int totalSlides;
  final String? currentSlideTitle;
  final VoidCallback onOpen;
  final VoidCallback onClose;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: isPresentationOpen
            ? cs.primaryContainer
            : cs.surfaceContainerHighest,
      ),
      child: Row(
        children: [
          Icon(
            Icons.tv_rounded,
            size: 18,
            color: isPresentationOpen ? cs.onPrimaryContainer : cs.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          if (isPresentationOpen && currentSlideTitle != null) ...[
            Expanded(
              child: Text(
                currentSlideTitle!,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: cs.onPrimaryContainer,
                ),
              ),
            ),
          ] else ...[
            Text(
              isPresentationOpen ? '발표 중' : '발표 화면',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: isPresentationOpen
                    ? cs.onPrimaryContainer
                    : cs.onSurfaceVariant,
              ),
            ),
            const Spacer(),
          ],
          if (isPresentationOpen) ...[
            IconButton(
              icon: const Icon(Icons.arrow_back_ios_rounded, size: 16),
              tooltip: '이전  ←',
              color: cs.onPrimaryContainer,
              onPressed: currentSlideIndex > 0 ? onPrev : null,
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${currentSlideIndex + 1} / $totalSlides',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
              tooltip: '다음  →',
              color: cs.onPrimaryContainer,
              onPressed: currentSlideIndex < totalSlides - 1 ? onNext : null,
            ),
            const SizedBox(width: 4),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade400,
                foregroundColor: Colors.white,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: onClose,
              icon: const Icon(Icons.stop_rounded, size: 16),
              label: const Text('종료'),
            ),
          ] else ...[
            FilledButton.icon(
              onPressed: slidesReady ? onOpen : null,
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('발표 시작'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── ResizableWorkArea ─────────────────────────────────────────────────────

class _ResizableWorkArea extends StatelessWidget {
  const _ResizableWorkArea({
    required this.stagingRatio,
    required this.onRatioChanged,
    required this.stagingPanel,
    required this.searchPanel,
  });

  final double stagingRatio;
  final ValueChanged<double> onRatioChanged;
  final Widget stagingPanel;
  final Widget searchPanel;

  static const double _dividerHeight = 18;
  static const double _minPanelHeight = 140;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = (constraints.maxHeight - _dividerHeight)
            .clamp(0.0, double.infinity)
            .toDouble();
        final minRatio = availableHeight <= 0
            ? 0.2
            : (_minPanelHeight / availableHeight).clamp(0.12, 0.82);
        final maxRatio = 1 - minRatio;
        final ratio = stagingRatio.clamp(minRatio, maxRatio);
        final stagingHeight = availableHeight * ratio;
        final searchHeight = availableHeight - stagingHeight;

        return Column(
          children: [
            SizedBox(height: stagingHeight, child: stagingPanel),
            _PanelResizeHandle(
              height: _dividerHeight,
              color: colorScheme.outlineVariant,
              onDrag: (delta) {
                if (availableHeight <= 0) return;
                final nextRatio = (ratio + delta / availableHeight).clamp(
                  minRatio,
                  maxRatio,
                );
                onRatioChanged(nextRatio);
              },
            ),
            SizedBox(height: searchHeight, child: searchPanel),
          ],
        );
      },
    );
  }
}

class _PanelResizeHandle extends StatelessWidget {
  const _PanelResizeHandle({
    required this.height,
    required this.color,
    required this.onDrag,
  });

  final double height;
  final Color color;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) => onDrag(details.delta.dy),
        child: SizedBox(
          height: height,
          child: Center(
            child: Container(
              width: 72,
              height: 4,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── TopBar ────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.storedCount,
    required this.bibleVerseCount,
    required this.selectedFolder,
    required this.isImporting,
    required this.isBibleImporting,
    required this.importTotalCount,
    required this.importSavedCount,
    required this.importStatusText,
    required this.onImportPressed,
    required this.onBibleImportPressed,
    required this.isCheckingUpdate,
    required this.hasUpdate,
    required this.onCheckUpdate,
  });

  final int storedCount;
  final int bibleVerseCount;
  final String? selectedFolder;
  final bool isImporting;
  final bool isBibleImporting;
  final int importTotalCount;
  final int importSavedCount;
  final String? importStatusText;
  final VoidCallback onImportPressed;
  final VoidCallback onBibleImportPressed;
  final bool isCheckingUpdate;
  final bool hasUpdate;
  final VoidCallback onCheckUpdate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: const LinearGradient(
          colors: [Color(0xFF143642), Color(0xFF0F8B8D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Text(
            '예배 슬라이드 보관함',
            style: theme.textTheme.titleMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '저장 ',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Text(
                  '$storedCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(width: 1, height: 20, color: Colors.white30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  selectedFolder ?? '아직 선택된 폴더가 없습니다.',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                if (importStatusText != null)
                  Text(
                    importTotalCount > 0
                        ? '$importStatusText  $importSavedCount / $importTotalCount'
                        : importStatusText!,
                    style: const TextStyle(color: Colors.white60, fontSize: 11),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (!hasUpdate)
            Tooltip(
              message: '업데이트 확인',
              child: IconButton(
                onPressed: isCheckingUpdate ? null : onCheckUpdate,
                icon: isCheckingUpdate
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white54,
                        ),
                      )
                    : const Icon(Icons.refresh_rounded,
                        size: 18, color: Colors.white54),
              ),
            ),
          const SizedBox(width: 4),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.22),
              foregroundColor: Colors.white,
            ),
            onPressed: isImporting ? null : onImportPressed,
            icon: isImporting
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.upload_file_rounded, size: 16),
            label: Text(isImporting ? '읽는 중' : '찬양폴더 선택'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.22),
              foregroundColor: Colors.white,
            ),
            onPressed: isBibleImporting ? null : onBibleImportPressed,
            icon: isBibleImporting
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.menu_book_rounded, size: 16),
            label: Text(isBibleImporting ? '저장 중' : '성경 불러오기'),
          ),
        ],
      ),
    );
  }
}

// ── StagingPanel ──────────────────────────────────────────────────────────

class _StagingPanel extends StatelessWidget {
  const _StagingPanel({
    required this.stagingItems,
    required this.selectedUid,
    required this.onReorder,
    required this.onRemove,
    required this.onSelect,
  });

  final List<({int uid, StagingItem item})> stagingItems;
  final int? selectedUid;
  final void Function(int oldIndex, int newIndex) onReorder;
  final void Function(int uid) onRemove;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '선택한 순서',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                Text('${stagingItems.length}개'),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: stagingItems.isEmpty
                  ? const Center(
                      child: Text(
                        '찬양이나 성경 본문을 선택하면 순서가 여기에 표시됩니다.',
                        style: TextStyle(color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: stagingItems.length,
                      onReorder: onReorder,
                      itemBuilder: (context, index) {
                        final entry = stagingItems[index];
                        final item = entry.item;
                        final isBible = item is BibleStagingItem;
                        return ListTile(
                          key: ValueKey(entry.uid),
                          selected: entry.uid == selectedUid,
                          selectedTileColor: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.08),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          onTap: () => onSelect(entry.uid),
                          leading: SizedBox(
                            width: 28,
                            child: Center(
                              child: Text(
                                '${index + 1}',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          title: Row(
                            children: [
                              if (isBible)
                                Container(
                                  margin: const EdgeInsets.only(right: 6),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.shade100,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '성경',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.blue.shade700,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              Expanded(
                                child: Text(
                                  item.displayTitle,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            item.previewText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.close_rounded, size: 20),
                                tooltip: '제거',
                                onPressed: () => onRemove(entry.uid),
                              ),
                              ReorderableDragStartListener(
                                index: index,
                                child: const Icon(
                                  Icons.drag_handle_rounded,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── SearchAndBiblePanel (탭 패널) ─────────────────────────────────────────

class _SearchAndBiblePanel extends StatefulWidget {
  const _SearchAndBiblePanel({
    required this.searchController,
    required this.songs,
    required this.selectedSongIds,
    required this.onSongChanged,
    required this.onDeleteSelected,
    required this.onClearAll,
    required this.onAddSong,
    required this.onEditSong,
    required this.bibleRepository,
    required this.bibleVerseCount,
    required this.bibleDataRevision,
    required this.onAddBibleItem,
  });

  final TextEditingController searchController;
  final List<PraiseSong> songs;
  final Set<int?> selectedSongIds;
  final void Function(PraiseSong, bool) onSongChanged;
  final VoidCallback onDeleteSelected;
  final VoidCallback onClearAll;
  final VoidCallback onAddSong;
  final ValueChanged<PraiseSong> onEditSong;
  final BibleRepository bibleRepository;
  final int bibleVerseCount;
  final int bibleDataRevision;
  final void Function(BibleStagingItem) onAddBibleItem;

  @override
  State<_SearchAndBiblePanel> createState() => _SearchAndBiblePanelState();
}

class _SearchAndBiblePanelState extends State<_SearchAndBiblePanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: '찬양 검색'),
              Tab(text: '성경 검색'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _SongSearchContent(
                  controller: widget.searchController,
                  songs: widget.songs,
                  selectedSongIds: widget.selectedSongIds,
                  onChanged: widget.onSongChanged,
                  onDeleteSelected: widget.onDeleteSelected,
                  onClearAll: widget.onClearAll,
                  onAddSong: widget.onAddSong,
                  onEditSong: widget.onEditSong,
                ),
                _BibleSearchPanel(
                  bibleRepository: widget.bibleRepository,
                  bibleVerseCount: widget.bibleVerseCount,
                  bibleDataRevision: widget.bibleDataRevision,
                  onAddItem: widget.onAddBibleItem,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── SongSearchContent ─────────────────────────────────────────────────────

class _SongSearchContent extends StatelessWidget {
  const _SongSearchContent({
    required this.controller,
    required this.songs,
    required this.selectedSongIds,
    required this.onChanged,
    required this.onDeleteSelected,
    required this.onClearAll,
    required this.onAddSong,
    required this.onEditSong,
  });

  final TextEditingController controller;
  final List<PraiseSong> songs;
  final Set<int?> selectedSongIds;
  final void Function(PraiseSong song, bool isSelected) onChanged;
  final VoidCallback onDeleteSelected;
  final VoidCallback onClearAll;
  final VoidCallback onAddSong;
  final ValueChanged<PraiseSong> onEditSong;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${songs.length}건',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),
              OutlinedButton.icon(
                onPressed: onAddSong,
                icon: const Icon(Icons.add_rounded),
                label: const Text('새 곡'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: selectedSongIds.isEmpty ? null : onDeleteSelected,
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('선택 삭제'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: songs.isEmpty ? null : onClearAll,
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('DB 초기화'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: '제목 또는 가사로 검색',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: songs.isEmpty
                ? const Center(child: Text('저장된 찬양이 없습니다. 먼저 폴더를 불러와 주세요.'))
                : ListView.separated(
                    itemCount: songs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final song = songs[index];
                      final selected = selectedSongIds.contains(song.id);
                      return CheckboxListTile(
                        value: selected,
                        onChanged: (value) => onChanged(song, value ?? false),
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(song.title),
                        subtitle: Text(
                          song.pages.join(' / '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        contentPadding: EdgeInsets.zero,
                        secondary: IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          tooltip: '가사 수정',
                          onPressed: () => onEditSong(song),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ── BibleSearchPanel ──────────────────────────────────────────────────────

class _BibleSearchPanel extends StatefulWidget {
  const _BibleSearchPanel({
    required this.bibleRepository,
    required this.bibleVerseCount,
    required this.bibleDataRevision,
    required this.onAddItem,
  });

  final BibleRepository bibleRepository;
  final int bibleVerseCount;
  final int bibleDataRevision;
  final void Function(BibleStagingItem) onAddItem;

  @override
  State<_BibleSearchPanel> createState() => _BibleSearchPanelState();
}

class _BibleSearchPanelState extends State<_BibleSearchPanel>
    with AutomaticKeepAliveClientMixin {
  // 탭 전환 시 상태 유지
  @override
  bool get wantKeepAlive => true;

  bool _isLoading = false;
  bool _hasData = false;
  List<String> _versionNames = [];
  String? _selectedVersion;
  List<String> _bookNames = [];
  String? _selectedBook;
  final TextEditingController _bookController = TextEditingController();
  final TextEditingController _chapterController = TextEditingController();
  final TextEditingController _verseController = TextEditingController();
  List<BibleVerse> _verses = const [];
  final Set<int> _selectedVerseIds = {};
  int? _lastSelectedVerseIndex;
  int _versesPerPage = 2;
  bool _isSearching = false;
  bool _isSyncingBookController = false;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _chapterController.addListener(_onBibleInputChanged);
    _verseController.addListener(_onBibleInputChanged);
    _loadBookNames();
  }

  @override
  void didUpdateWidget(_BibleSearchPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bibleVerseCount != widget.bibleVerseCount ||
        oldWidget.bibleDataRevision != widget.bibleDataRevision) {
      _loadBibleOptions();
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _bookController.dispose();
    _chapterController.removeListener(_onBibleInputChanged);
    _verseController.removeListener(_onBibleInputChanged);
    _chapterController.dispose();
    _verseController.dispose();
    super.dispose();
  }

  Future<void> _loadBookNames() async {
    await _loadBibleOptions();
  }

  Future<void> _loadBibleOptions() async {
    if (mounted) setState(() => _isLoading = true);
    try {
      final has = await widget.bibleRepository.hasData();
      final versions = has
          ? await widget.bibleRepository.getVersions()
          : <String>[];
      var selectedVersion = _selectedVersion;
      if (selectedVersion == null || !versions.contains(selectedVersion)) {
        selectedVersion = versions.isEmpty ? null : versions.first;
      }
      final books = selectedVersion == null
          ? <String>[]
          : await widget.bibleRepository.getBookNamesForVersion(
              selectedVersion,
            );
      final selectedBook =
          _selectedBook != null && books.contains(_selectedBook)
          ? _selectedBook
          : null;
      if (!mounted) return;
      setState(() {
        _hasData = has;
        _versionNames = versions;
        _selectedVersion = selectedVersion;
        _bookNames = books;
        _selectedBook = selectedBook;
      });
      _setBookText(selectedBook ?? '');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onBibleInputChanged({bool isComposing = false}) {
    if (_isSyncingBookController) return;
    if (isComposing) return;
    final typedBook = _bookController.text.trim();
    final matchedBook = _matchingBook(typedBook);
    if (matchedBook != _selectedBook) {
      setState(() {
        _selectedBook = matchedBook;
        if (matchedBook == null) {
          _verses = const [];
          _selectedVerseIds.clear();
          _lastSelectedVerseIndex = null;
        }
      });
    }

    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _search(showMessages: false);
    });
  }

  void _setBookText(String value) {
    if (_bookController.text == value) return;
    _isSyncingBookController = true;
    _bookController.text = value;
    _isSyncingBookController = false;
  }

  void _setBookEditingValue(TextEditingValue value) {
    _isSyncingBookController = true;
    _bookController.value = value;
    _isSyncingBookController = false;
  }

  bool _isComposing(TextEditingValue value) {
    return value.composing.isValid && !value.composing.isCollapsed;
  }

  String? _matchingBook(String value) {
    final normalized = value.toLowerCase();
    for (final book in _bookNames) {
      if (book.toLowerCase() == normalized) return book;
    }
    return null;
  }

  Future<void> _search({bool showMessages = true}) async {
    final version = _selectedVersion;
    final book = _selectedBook;
    final chapter = int.tryParse(_chapterController.text.trim());
    final verseText = _verseController.text.trim();
    final verse = verseText.isEmpty ? null : int.tryParse(verseText);
    if (version == null) {
      if (showMessages) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('성경 버전을 선택해 주세요.')));
      }
      return;
    }
    if (book == null) {
      if (showMessages) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('성경을 선택해 주세요.')));
      }
      return;
    }
    if (chapter == null || chapter <= 0) {
      if (showMessages) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('장 번호를 입력해 주세요.')));
      }
      return;
    }
    if (verseText.isNotEmpty && (verse == null || verse <= 0)) {
      if (showMessages) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('절 번호를 올바르게 입력해 주세요.')));
      }
      return;
    }

    setState(() {
      _isSearching = true;
      _verses = const [];
      _selectedVerseIds.clear();
      _lastSelectedVerseIndex = null;
    });

    try {
      final verses = await widget.bibleRepository.getVerses(
        version: version,
        bookName: book,
        chapter: chapter,
        verse: verse,
      );
      if (!mounted) return;
      setState(() => _verses = verses);
      if (verses.isEmpty && mounted && showMessages) {
        final reference = verse == null
            ? '$book $chapter장'
            : '$book $chapter:$verse';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$reference에 절이 없습니다.')));
      }
    } catch (e) {
      if (!mounted) return;
      if (showMessages) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('검색 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  void _addSelected() {
    final version = _selectedVersion;
    if (_selectedVerseIds.isEmpty) return;
    if (version == null) return;
    final selected =
        _verses.where((v) => _selectedVerseIds.contains(v.id)).toList()
          ..sort((a, b) => a.verse.compareTo(b.verse));
    if (selected.isEmpty) return;

    final chunks = <List<BibleVerse>>[];
    for (var i = 0; i < selected.length; i += _versesPerPage) {
      final end = i + _versesPerPage > selected.length
          ? selected.length
          : i + _versesPerPage;
      chunks.add(selected.sublist(i, end));
    }

    for (final chunk in chunks) {
      final verseNums = chunk.map((v) => v.verse).toList();
      final ref = _buildReference(
        version,
        _selectedBook!,
        chunk.first.chapter,
        verseNums,
      );
      final text = chunk.map((v) => '${v.verse}. ${v.text}').join('\n');
      widget.onAddItem(BibleStagingItem(reference: ref, text: text));
    }
    setState(() => _selectedVerseIds.clear());

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${chunks.length}페이지 추가됨')));
  }

  int get _selectedBiblePageCount {
    if (_selectedVerseIds.isEmpty) return 0;
    return ((_selectedVerseIds.length - 1) ~/ _versesPerPage) + 1;
  }

  bool get _isShiftPressed {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
  }

  void _toggleVerseSelection(int index, bool isSelected) {
    final lastIndex = _lastSelectedVerseIndex;
    final shouldSelectRange =
        isSelected && _isShiftPressed && lastIndex != null;

    setState(() {
      if (shouldSelectRange) {
        final start = lastIndex < index ? lastIndex : index;
        final end = lastIndex < index ? index : lastIndex;
        for (var i = start; i <= end; i++) {
          _selectedVerseIds.add(_verses[i].id);
        }
      } else if (isSelected) {
        _selectedVerseIds.add(_verses[index].id);
      } else {
        _selectedVerseIds.remove(_verses[index].id);
      }
      _lastSelectedVerseIndex = index;
    });
  }

  Future<void> _selectVersion(String? version) async {
    if (version == null || version == _selectedVersion) return;
    setState(() {
      _selectedVersion = version;
      _selectedBook = null;
      _bookNames = const [];
      _verses = const [];
      _selectedVerseIds.clear();
      _lastSelectedVerseIndex = null;
    });
    _setBookText('');
    final books = await widget.bibleRepository.getBookNamesForVersion(version);
    if (!mounted) return;
    setState(() => _bookNames = books);
  }

  String _buildReference(
    String version,
    String book,
    int chapter,
    List<int> verses,
  ) {
    if (verses.isEmpty) return '';
    verses.sort();
    if (verses.length == 1) return '$version $book $chapter:${verses.first}';
    bool contiguous = true;
    for (int i = 1; i < verses.length; i++) {
      if (verses[i] != verses[i - 1] + 1) {
        contiguous = false;
        break;
      }
    }
    final verseStr = contiguous
        ? '${verses.first}-${verses.last}'
        : verses.join(',');
    return '$version $book $chapter:$verseStr';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 필수

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_hasData) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_rounded, size: 48, color: Colors.grey),
            SizedBox(height: 12),
            Text(
              '성경 데이터가 없습니다.\n상단의 \'성경 불러오기\' 버튼을 눌러 주세요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    const inputHeight = 56.0;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 검색 입력 행
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: inputHeight,
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedVersion,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '버전',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12),
                    ),
                    items: _versionNames
                        .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                        .toList(),
                    onChanged: _selectVersion,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: SizedBox(
                  height: inputHeight,
                  child: Autocomplete<String>(
                    key: ValueKey(_selectedVersion),
                    initialValue: TextEditingValue(text: _bookController.text),
                    optionsBuilder: (textEditingValue) {
                      final query = textEditingValue.text.trim().toLowerCase();
                      if (query.isEmpty) return _bookNames;
                      return _bookNames.where(
                        (book) => book.toLowerCase().contains(query),
                      );
                    },
                    onSelected: (book) {
                      _bookController.text = book;
                      setState(() => _selectedBook = book);
                      _search(showMessages: false);
                    },
                    fieldViewBuilder:
                        (context, controller, focusNode, onFieldSubmitted) {
                          return TextField(
                            controller: controller,
                            focusNode: focusNode,
                            textAlignVertical: TextAlignVertical.center,
                            decoration: const InputDecoration(
                              labelText: '성경 검색',
                              prefixIcon: Icon(Icons.search_rounded),
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                            ),
                            onChanged: (_) {
                              _setBookEditingValue(controller.value);
                              _onBibleInputChanged(
                                isComposing: _isComposing(controller.value),
                              );
                            },
                            onSubmitted: (_) {
                              _setBookEditingValue(controller.value);
                              onFieldSubmitted();
                              _search();
                            },
                          );
                        },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 96,
                height: inputHeight,
                child: TextField(
                  controller: _chapterController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  textAlignVertical: TextAlignVertical.center,
                  decoration: const InputDecoration(
                    labelText: '장',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 96,
                height: inputHeight,
                child: TextField(
                  controller: _verseController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  textAlignVertical: TextAlignVertical.center,
                  decoration: const InputDecoration(
                    labelText: '절',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 결과 목록
          Expanded(
            child: _isSearching
                ? const Center(child: CircularProgressIndicator())
                : _verses.isEmpty
                ? Center(
                    child: Text(
                      _selectedBook == null
                          ? '성경과 장 번호를 입력해 주세요.'
                          : '장 번호를 입력하면 절을 불러옵니다.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.separated(
                    itemCount: _verses.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final v = _verses[index];
                      return CheckboxListTile(
                        value: _selectedVerseIds.contains(v.id),
                        onChanged: (val) =>
                            _toggleVerseSelection(index, val ?? false),
                        controlAffinity: ListTileControlAffinity.leading,
                        title: RichText(
                          text: TextSpan(
                            style: DefaultTextStyle.of(context).style,
                            children: [
                              TextSpan(
                                text: '${v.verse}절  ',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              TextSpan(
                                text: v.text,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      );
                    },
                  ),
          ),
          // 추가 버튼
          if (_verses.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('페이지당'),
                const SizedBox(width: 8),
                SizedBox(
                  width: 92,
                  child: DropdownButtonFormField<int>(
                    initialValue: _versesPerPage,
                    isDense: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                    items: const [1, 2, 3, 4, 5, 10]
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text('$value절'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _versesPerPage = value);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _selectedVerseIds.isEmpty ? null : _addSelected,
                    icon: const Icon(Icons.add_rounded),
                    label: Text(
                      _selectedVerseIds.isEmpty
                          ? '절을 선택하면 추가할 수 있습니다'
                          : '${_selectedVerseIds.length}절 $_selectedBiblePageCount페이지로 추가',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ── DesignPanel ───────────────────────────────────────────────────────────

class _DesignPanel extends StatelessWidget {
  const _DesignPanel({
    required this.style,
    required this.isExporting,
    required this.swatches,
    required this.textSwatches,
    required this.previewItem,
    required this.onStyleChanged,
    required this.onExportPressed,
  });

  final ExportStyle style;
  final bool isExporting;
  final List<Color> swatches;
  final List<Color> textSwatches;
  final StagingItem? previewItem;
  final ValueChanged<ExportStyle> onStyleChanged;
  final VoidCallback onExportPressed;

  static final TextInputFormatter _hexInputFormatter =
      FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F#]'));

  List<ButtonSegment<T>> _segments<T>(
    List<T> values,
    String Function(T value) labelOf,
  ) => values
      .map(
        (value) => ButtonSegment<T>(value: value, label: Text(labelOf(value))),
      )
      .toList(growable: false);

  Future<void> _showColorDialog(
    BuildContext context, {
    required String title,
    required Color current,
    required List<Color> colors,
    required ValueChanged<Color> onSelected,
  }) async {
    final selected = await showDialog<Color>(
      context: context,
      builder: (context) => _HexColorDialog(
        title: title,
        initialColor: current,
        colors: colors,
        inputFormatter: _hexInputFormatter,
      ),
    );
    if (selected != null) onSelected(selected);
  }

  Widget _colorPicker({
    required BuildContext context,
    required String title,
    required Color selectedColor,
    required List<Color> colors,
    required ValueChanged<Color> onSelected,
  }) {
    final textColor =
        ThemeData.estimateBrightnessForColor(selectedColor) == Brightness.dark
        ? Colors.white
        : Colors.black;

    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: () => _showColorDialog(
        context,
        title: title,
        current: selectedColor,
        colors: colors,
        onSelected: onSelected,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            ),
          ),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: selectedColor,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Icon(
              Icons.palette_outlined,
              size: 16,
              color: textColor.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            colorToHex(selectedColor),
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _controlSection({required List<Widget> children}) {
    return Column(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          children[i],
        ],
      ],
    );
  }

  Widget _segmentedPicker<T>({
    required String title,
    required T selected,
    required List<T> values,
    required String Function(T value) labelOf,
    required ValueChanged<T> onSelected,
  }) {
    return Row(
      children: [
        Expanded(child: Text(title, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 12),
        Flexible(
          flex: 0,
          child: SegmentedButton<T>(
            segments: _segments(values, labelOf),
            selected: {selected},
            style: const ButtonStyle(
              visualDensity: VisualDensity(horizontal: -2, vertical: -2),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onSelectionChanged: (selection) => onSelected(selection.first),
          ),
        ),
      ],
    );
  }

  Widget _horizontalPicker({
    required String title,
    required HorizontalPosition selected,
    required ValueChanged<HorizontalPosition> onSelected,
  }) {
    return _segmentedPicker<HorizontalPosition>(
      title: title,
      selected: selected,
      values: HorizontalPosition.values,
      labelOf: (position) => position.label,
      onSelected: onSelected,
    );
  }

  Widget _verticalPicker({
    required String title,
    required VerticalTextPosition selected,
    required ValueChanged<VerticalTextPosition> onSelected,
  }) {
    return _segmentedPicker<VerticalTextPosition>(
      title: title,
      selected: selected,
      values: VerticalTextPosition.values,
      labelOf: (position) => position.label,
      onSelected: onSelected,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'PPTX 디자인',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: isExporting ? null : onExportPressed,
                icon: isExporting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.slideshow_rounded),
                label: Text(isExporting ? '생성 중' : '선택한 항목으로 PPTX 저장'),
              ),
            ),
            const SizedBox(height: 16),
            _PreviewBox(style: style, previewItem: previewItem),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _controlSection(
                      children: [
                        _colorPicker(
                          context: context,
                          title: '배경 색상',
                          selectedColor: style.backgroundColor,
                          colors: swatches,
                          onSelected: (color) => onStyleChanged(
                            style.copyWith(backgroundColor: color),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _StyleTabControls(
                      style: style,
                      previewItem: previewItem,
                      textSwatches: textSwatches,
                      colorPicker:
                          ({
                            required title,
                            required selectedColor,
                            required colors,
                            required onSelected,
                          }) => _colorPicker(
                            context: context,
                            title: title,
                            selectedColor: selectedColor,
                            colors: colors,
                            onSelected: onSelected,
                          ),
                      verticalPicker: _verticalPicker,
                      horizontalPicker: _horizontalPicker,
                      onStyleChanged: onStyleChanged,
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StyleTabControls extends StatefulWidget {
  const _StyleTabControls({
    required this.style,
    required this.previewItem,
    required this.textSwatches,
    required this.colorPicker,
    required this.verticalPicker,
    required this.horizontalPicker,
    required this.onStyleChanged,
  });

  final ExportStyle style;
  final StagingItem? previewItem;
  final List<Color> textSwatches;
  final Widget Function({
    required String title,
    required Color selectedColor,
    required List<Color> colors,
    required ValueChanged<Color> onSelected,
  })
  colorPicker;
  final Widget Function({
    required String title,
    required VerticalTextPosition selected,
    required ValueChanged<VerticalTextPosition> onSelected,
  })
  verticalPicker;
  final Widget Function({
    required String title,
    required HorizontalPosition selected,
    required ValueChanged<HorizontalPosition> onSelected,
  })
  horizontalPicker;
  final ValueChanged<ExportStyle> onStyleChanged;

  @override
  State<_StyleTabControls> createState() => _StyleTabControlsState();
}

class _StyleTabControlsState extends State<_StyleTabControls>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  int _selectedTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _selectedTabIndex = _tabIndexForItem(widget.previewItem) ?? 0;
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: _selectedTabIndex,
    );
  }

  @override
  void didUpdateWidget(_StyleTabControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(widget.previewItem, oldWidget.previewItem)) return;
    final nextIndex = _tabIndexForItem(widget.previewItem);
    if (nextIndex == null || nextIndex == _selectedTabIndex) return;
    setState(() => _selectedTabIndex = nextIndex);
    _tabController.animateTo(nextIndex);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  int? _tabIndexForItem(StagingItem? item) {
    return switch (item) {
      SongStagingItem() => 0,
      BibleStagingItem() => 1,
      null => null,
    };
  }

  Widget _controlSection({required List<Widget> children}) {
    return Column(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          children[i],
        ],
      ],
    );
  }

  Widget _fontSizeSlider({
    required String title,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$title ${value.toStringAsFixed(0)}'),
        Slider(
          min: 18,
          max: 54,
          divisions: 9,
          value: value,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _topMarginSlider({
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('본문 상단 여백 ${value.toStringAsFixed(1)}'),
        Slider(
          min: 0.3,
          max: 2.2,
          divisions: 19,
          value: value.clamp(0.3, 2.2),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _titleSizeSlider({
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('제목 크기 ${value.toStringAsFixed(0)}'),
        Slider(
          min: 8,
          max: 28,
          divisions: 10,
          value: value,
          onChanged: onChanged,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          onTap: (index) => setState(() => _selectedTabIndex = index),
          tabs: const [
            Tab(text: '찬양'),
            Tab(text: '성경본문'),
          ],
        ),
        const SizedBox(height: 14),
        IndexedStack(
          index: _selectedTabIndex,
          children: [
            _controlSection(
              children: [
                _fontSizeSlider(
                  title: '글자 크기',
                  value: widget.style.fontSize,
                  onChanged: (value) => widget.onStyleChanged(
                    widget.style.copyWith(fontSize: value),
                  ),
                ),
                widget.colorPicker(
                  title: '한글 가사 색상',
                  selectedColor: widget.style.textColor,
                  colors: widget.textSwatches,
                  onSelected: (color) => widget.onStyleChanged(
                    widget.style.copyWith(textColor: color),
                  ),
                ),
                widget.colorPicker(
                  title: '영어 가사 색상',
                  selectedColor: widget.style.englishTextColor,
                  colors: widget.textSwatches,
                  onSelected: (color) => widget.onStyleChanged(
                    widget.style.copyWith(englishTextColor: color),
                  ),
                ),
                widget.verticalPicker(
                  title: '가사 수직 위치',
                  selected: widget.style.textPosition,
                  onSelected: (position) => widget.onStyleChanged(
                    widget.style.copyWith(textPosition: position),
                  ),
                ),
                _topMarginSlider(
                  value: widget.style.textBoxTop,
                  onChanged: (value) => widget.onStyleChanged(
                    widget.style.copyWith(textBoxTop: value),
                  ),
                ),
                widget.horizontalPicker(
                  title: '가사 수평 정렬',
                  selected: widget.style.lyricsTextAlign,
                  onSelected: (position) => widget.onStyleChanged(
                    widget.style.copyWith(lyricsTextAlign: position),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('제목 표시'),
                  value: widget.style.showSongTitle,
                  onChanged: (value) => widget.onStyleChanged(
                    widget.style.copyWith(showSongTitle: value),
                  ),
                ),
                if (widget.style.showSongTitle)
                  _titleSizeSlider(
                    value: widget.style.titleFontSize,
                    onChanged: (value) => widget.onStyleChanged(
                      widget.style.copyWith(titleFontSize: value),
                    ),
                  ),
                if (widget.style.showSongTitle)
                  widget.colorPicker(
                    title: '제목 색상',
                    selectedColor: widget.style.titleTextColor,
                    colors: widget.textSwatches,
                    onSelected: (color) => widget.onStyleChanged(
                      widget.style.copyWith(titleTextColor: color),
                    ),
                  ),
                if (widget.style.showSongTitle)
                  widget.horizontalPicker(
                    title: '제목 수평 위치',
                    selected: widget.style.titleHorizontalPosition,
                    onSelected: (position) => widget.onStyleChanged(
                      widget.style.copyWith(titleHorizontalPosition: position),
                    ),
                  ),
                if (widget.style.showSongTitle)
                  widget.verticalPicker(
                    title: '제목 수직 위치',
                    selected: widget.style.titleVerticalPosition,
                    onSelected: (position) => widget.onStyleChanged(
                      widget.style.copyWith(titleVerticalPosition: position),
                    ),
                  ),
              ],
            ),
            _controlSection(
              children: [
                _fontSizeSlider(
                  title: '글자 크기',
                  value: widget.style.bibleFontSize,
                  onChanged: (value) => widget.onStyleChanged(
                    widget.style.copyWith(bibleFontSize: value),
                  ),
                ),
                widget.colorPicker(
                  title: '본문 색상',
                  selectedColor: widget.style.bibleTextColor,
                  colors: widget.textSwatches,
                  onSelected: (color) => widget.onStyleChanged(
                    widget.style.copyWith(bibleTextColor: color),
                  ),
                ),
                widget.verticalPicker(
                  title: '본문 수직 위치',
                  selected: widget.style.bibleTextPosition,
                  onSelected: (position) => widget.onStyleChanged(
                    widget.style.copyWith(bibleTextPosition: position),
                  ),
                ),
                _topMarginSlider(
                  value: widget.style.bibleTextBoxTop,
                  onChanged: (value) => widget.onStyleChanged(
                    widget.style.copyWith(bibleTextBoxTop: value),
                  ),
                ),
                widget.horizontalPicker(
                  title: '본문 수평 정렬',
                  selected: widget.style.bibleTextAlign,
                  onSelected: (position) => widget.onStyleChanged(
                    widget.style.copyWith(bibleTextAlign: position),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('제목 표시'),
                  value: widget.style.showBibleTitle,
                  onChanged: (value) => widget.onStyleChanged(
                    widget.style.copyWith(showBibleTitle: value),
                  ),
                ),
                if (widget.style.showBibleTitle)
                  _titleSizeSlider(
                    value: widget.style.bibleTitleFontSize,
                    onChanged: (value) => widget.onStyleChanged(
                      widget.style.copyWith(bibleTitleFontSize: value),
                    ),
                  ),
                if (widget.style.showBibleTitle)
                  widget.colorPicker(
                    title: '제목 색상',
                    selectedColor: widget.style.bibleTitleTextColor,
                    colors: widget.textSwatches,
                    onSelected: (color) => widget.onStyleChanged(
                      widget.style.copyWith(bibleTitleTextColor: color),
                    ),
                  ),
                if (widget.style.showBibleTitle)
                  widget.horizontalPicker(
                    title: '제목 수평 위치',
                    selected: widget.style.bibleTitleHorizontalPosition,
                    onSelected: (position) => widget.onStyleChanged(
                      widget.style.copyWith(
                        bibleTitleHorizontalPosition: position,
                      ),
                    ),
                  ),
                if (widget.style.showBibleTitle)
                  widget.verticalPicker(
                    title: '제목 수직 위치',
                    selected: widget.style.bibleTitleVerticalPosition,
                    onSelected: (position) => widget.onStyleChanged(
                      widget.style.copyWith(
                        bibleTitleVerticalPosition: position,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _HexColorDialog extends StatefulWidget {
  const _HexColorDialog({
    required this.title,
    required this.initialColor,
    required this.colors,
    required this.inputFormatter,
  });

  final String title;
  final Color initialColor;
  final List<Color> colors;
  final TextInputFormatter inputFormatter;

  @override
  State<_HexColorDialog> createState() => _HexColorDialogState();
}

class _HexColorDialogState extends State<_HexColorDialog> {
  late final TextEditingController _controller;
  bool _hasError = false;

  static final List<Color> _fullPalette = _buildFullPalette();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: colorToHex(widget.initialColor));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final color = tryParseHexColor(_controller.text);
    if (color == null) {
      setState(() => _hasError = true);
      return;
    }
    Navigator.of(context).pop(color);
  }

  void _selectColor(Color color) {
    _controller.text = colorToHex(color);
    Navigator.of(context).pop(color);
  }

  static List<Color> _buildFullPalette() {
    const hues = <double>[
      0,
      15,
      30,
      45,
      60,
      90,
      120,
      150,
      180,
      210,
      240,
      270,
      300,
      330,
    ];
    const values = <double>[0.95, 0.78, 0.62, 0.46];
    const saturations = <double>[0.28, 0.52, 0.76, 1.0];
    final colors = <Color>[
      const Color(0xFFFFFFFF),
      const Color(0xFFEDEDED),
      const Color(0xFFC8C8C8),
      const Color(0xFF8A8A8A),
      const Color(0xFF4A4A4A),
      const Color(0xFF000000),
    ];

    for (final hue in hues) {
      for (final value in values) {
        for (final saturation in saturations) {
          colors.add(HSVColor.fromAHSV(1, hue, saturation, value).toColor());
        }
      }
    }
    return colors;
  }

  Widget _paletteGrid(
    BuildContext context, {
    required List<Color> colors,
    required double size,
    required double spacing,
  }) {
    return Wrap(
      spacing: spacing,
      runSpacing: spacing,
      children: colors.map((color) {
        final selected = color.toARGB32() == widget.initialColor.toARGB32();
        return Tooltip(
          message: colorToHex(color),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => _selectColor(color),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).dividerColor,
                  width: selected ? 3 : 1,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _paletteGrid(
                context,
                colors: widget.colors,
                size: 34,
                spacing: 10,
              ),
              const SizedBox(height: 18),
              Text('전체 색상', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 10),
              _paletteGrid(context, colors: _fullPalette, size: 18, spacing: 5),
              const SizedBox(height: 18),
              TextField(
                controller: _controller,
                autofocus: false,
                decoration: InputDecoration(
                  labelText: 'HEX 색상',
                  hintText: '#FFFFFF',
                  errorText: _hasError ? '#RRGGBB 형식으로 입력해 주세요.' : null,
                  border: const OutlineInputBorder(),
                ),
                inputFormatters: [
                  widget.inputFormatter,
                  LengthLimitingTextInputFormatter(7),
                ],
                onChanged: (_) {
                  if (_hasError) setState(() => _hasError = false);
                },
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _submit, child: const Text('적용')),
      ],
    );
  }
}

// ── PreviewBox ────────────────────────────────────────────────────────────

class _PreviewBox extends StatelessWidget {
  const _PreviewBox({required this.style, required this.previewItem});

  final ExportStyle style;
  final StagingItem? previewItem;

  static const double _slideW = 13.333;
  static const double _slideH = 7.5;
  static const double _lyricsBoxT = 0.6;
  static const double _lyricsBoxH = 5.4;
  static const double _lyricsBoxBottom = _slideH - _lyricsBoxT - _lyricsBoxH;
  static const double _lyricsBoxW = _slideW * 0.9;
  static const double _lyricsBoxL = (_slideW - _lyricsBoxW) / 2;
  static const double _titleBoxH = 0.55;
  static const double _titlePad = 0.2;
  static const double _titleBoxWSide = _slideW - (_titlePad * 2);
  static const double _titleBoxWCenter = 10.0;

  @override
  Widget build(BuildContext context) {
    final String sampleText;
    final String sampleEnglishText;
    final String? titleText;
    final bool isBiblePreview;

    switch (previewItem) {
      case SongStagingItem(:final song):
        sampleText = song.pages.isEmpty ? song.title : song.pages.first;
        sampleEnglishText = song.englishPages.isEmpty
            ? ''
            : song.englishPages.first;
        titleText = song.title;
        isBiblePreview = false;
      case BibleStagingItem(:final text, :final reference):
        sampleText = text;
        sampleEnglishText = '';
        titleText = reference;
        isBiblePreview = true;
      case null:
        sampleText = '선택한 항목이 여기에 미리보기로 보입니다.';
        sampleEnglishText = '';
        titleText = null;
        isBiblePreview = false;
    }

    final bodyTextPosition = isBiblePreview
        ? style.bibleTextPosition
        : style.textPosition;
    final titleHorizontalPosition = isBiblePreview
        ? style.bibleTitleHorizontalPosition
        : style.titleHorizontalPosition;
    final titleVerticalPosition = isBiblePreview
        ? style.bibleTitleVerticalPosition
        : style.titleVerticalPosition;
    final bodyFontSize = isBiblePreview ? style.bibleFontSize : style.fontSize;
    final bodyBoxTop = isBiblePreview
        ? style.bibleTextBoxTop
        : style.textBoxTop;
    final bodyBoxHeight = _slideH - bodyBoxTop - _lyricsBoxBottom;
    final showTitle = isBiblePreview
        ? style.showBibleTitle
        : style.showSongTitle;
    final titleFontSize = isBiblePreview
        ? style.bibleTitleFontSize
        : style.titleFontSize;
    final titleTextColor = isBiblePreview
        ? style.bibleTitleTextColor
        : style.titleTextColor;

    final alignment = switch (bodyTextPosition) {
      VerticalTextPosition.top => Alignment.topCenter,
      VerticalTextPosition.middle => Alignment.center,
      VerticalTextPosition.bottom => Alignment.bottomCenter,
    };

    final bodyTextAlign = isBiblePreview
        ? style.bibleTextAlign
        : style.lyricsTextAlign;
    final bodyTextColor = isBiblePreview
        ? style.bibleTextColor
        : style.textColor;

    final lyricsTextAlign = switch (bodyTextAlign) {
      HorizontalPosition.left => TextAlign.left,
      HorizontalPosition.center => TextAlign.center,
      HorizontalPosition.right => TextAlign.right,
    };

    return AspectRatio(
      aspectRatio: _slideW / _slideH,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          final fontScale = h / (_slideH * 72);

          final double titleBoxW;
          final double titleLeft;
          final TextAlign titleAlign;
          switch (titleHorizontalPosition) {
            case HorizontalPosition.left:
              titleBoxW = _titleBoxWSide;
              titleLeft = _titlePad;
              titleAlign = TextAlign.left;
            case HorizontalPosition.center:
              titleBoxW = _titleBoxWCenter;
              titleLeft = (_slideW - _titleBoxWCenter) / 2;
              titleAlign = TextAlign.center;
            case HorizontalPosition.right:
              titleBoxW = _titleBoxWSide;
              titleLeft = _slideW - _titlePad - _titleBoxWSide;
              titleAlign = TextAlign.right;
          }
          final double titleTop = switch (titleVerticalPosition) {
            VerticalTextPosition.top => _titlePad,
            VerticalTextPosition.middle => (_slideH - _titleBoxH) / 2,
            VerticalTextPosition.bottom => _slideH - _titlePad - _titleBoxH,
          };

          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              children: [
                Container(
                  color: style.backgroundColor,
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: w * _lyricsBoxL / _slideW,
                      top: h * bodyBoxTop / _slideH,
                      right: w * (1 - (_lyricsBoxL + _lyricsBoxW) / _slideW),
                      bottom: h * (1 - (bodyBoxTop + bodyBoxHeight) / _slideH),
                    ),
                    child: Align(
                      alignment: alignment,
                      child: DefaultTextStyle(
                        style: const TextStyle(),
                        child: RichText(
                          textAlign: lyricsTextAlign,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: sampleText,
                                style: TextStyle(
                                  color: bodyTextColor,
                                  fontSize: bodyFontSize * fontScale,
                                  fontWeight: FontWeight.w700,
                                  height: 1.25,
                                ),
                              ),
                              if (style.includeEnglishLyrics &&
                                  sampleEnglishText.isNotEmpty)
                                TextSpan(
                                  text: '\n$sampleEnglishText',
                                  style: TextStyle(
                                    color: style.englishTextColor,
                                    fontSize: style.fontSize * 0.8 * fontScale,
                                    fontWeight: FontWeight.w700,
                                    height: 1.3,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (showTitle && titleText != null)
                  Positioned(
                    left: w * titleLeft / _slideW,
                    top: h * titleTop / _slideH,
                    width: w * titleBoxW / _slideW,
                    height: h * _titleBoxH / _slideH,
                    child: Text(
                      titleText,
                      textAlign: titleAlign,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: titleTextColor,
                        fontSize: titleFontSize * fontScale,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ── SongEditDialog ────────────────────────────────────────────────────────

// ── 업데이트 배너 ─────────────────────────────────────────────────────

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({
    required this.version,
    required this.isDownloading,
    required this.progress,
    required this.onUpdate,
    required this.onDismiss,
  });

  final String version;
  final bool isDownloading;
  final double progress;
  final VoidCallback onUpdate;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.system_update_rounded, color: scheme.onPrimaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: isDownloading
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '업데이트 다운로드 중... ${(progress * 100).toStringAsFixed(0)}%',
                        style: TextStyle(color: scheme.onPrimaryContainer),
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: progress > 0 ? progress : null,
                      ),
                    ],
                  )
                : Text(
                    '새 버전 v$version이 출시되었습니다.',
                    style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
          ),
          if (!isDownloading) ...[
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: onUpdate,
              child: const Text('지금 업데이트'),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.close),
              color: scheme.onPrimaryContainer,
              tooltip: '닫기',
              onPressed: onDismiss,
            ),
          ],
        ],
      ),
    );
  }
}

// ── 곡 편집 다이얼로그 ─────────────────────────────────────────────────

class _SongEditDialog extends StatefulWidget {
  const _SongEditDialog({this.song});

  final PraiseSong? song;

  @override
  State<_SongEditDialog> createState() => _SongEditDialogState();
}

class _SongEditDialogState extends State<_SongEditDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _lyricsController;
  late final TextEditingController _englishController;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.song?.title ?? '');
    _lyricsController = TextEditingController(
      text: _toEditText(widget.song?.lyrics ?? ''),
    );
    _englishController = TextEditingController(
      text: _toEditText(widget.song?.englishLyrics ?? ''),
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _lyricsController.dispose();
    _englishController.dispose();
    super.dispose();
  }

  String _normalizeLyrics(String raw) {
    final unified = raw.replaceAll(RegExp(r'[ \t]*###[ \t]*'), '\n\n');
    return unified
        .split(RegExp(r'\n[ \t]*\n+'))
        .map((page) => page.trim())
        .where((page) => page.isNotEmpty)
        .join('\n###\n');
  }

  static String _toEditText(String stored) =>
      stored.replaceAll('\n###\n', '\n\n');

  void _save() {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    Navigator.of(context).pop(
      PraiseSong(
        id: widget.song?.id,
        fileName: widget.song?.fileName ?? title,
        title: title,
        lyrics: _normalizeLyrics(_lyricsController.text),
        englishLyrics: _normalizeLyrics(_englishController.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.song == null;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isNew ? '새 곡 추가' : '가사 수정',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: '제목',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _lyricsController,
                maxLines: 10,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  labelText: '한글 가사',
                  hintText: '페이지 구분: 빈 줄 (또는 ###)',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _englishController,
                maxLines: 10,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  labelText: '영어 가사',
                  hintText: '페이지 구분: 빈 줄 (또는 ###)',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('취소'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _save,
                    child: Text(isNew ? '추가' : '저장'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
