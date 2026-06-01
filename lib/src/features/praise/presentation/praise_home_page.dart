import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../features/bible/data/bible_repository.dart';
import '../../../features/bible/domain/bible_verse.dart';
import '../../../features/update/update_service.dart';
import '../data/app_logger.dart';
import '../data/export_style_store.dart';
import '../data/praise_repository.dart';
import '../data/python_bridge.dart';
import '../data/worship_conti_repository.dart';
import '../domain/worship_conti.dart';
import '../domain/export_style.dart';
import '../domain/praise_song.dart';
import '../domain/staging_item.dart';
import 'slide_page_data.dart';
import 'slide_render_view.dart';

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
    required this.pageIndexInItem,
    this.isBlank = false,
  });
  final int stagingUid;
  final String mainText;
  final String englishText;
  final String? title;
  final bool isBible;
  final int pageIndexInItem; // 해당 아이템(곡/성경) 내의 페이지 인덱스
  final bool isBlank;
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
  final WorshipContiRepository _contiRepository = WorshipContiRepository();
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
  bool _isSearchCollapsed = false;
  bool _isDesignCollapsed = false;
  bool _isSlideOrderCollapsed = false;
  bool _isSlideOrderMaximized = false;
  bool _isStagingCollapsed = false;
  double _presentationPanelRatio = 0.28;
  String _slideJumpBuffer = '';

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
  bool _isBlackout = false;

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
    _checkForUpdates(isStartup: true);
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
    for (var i = 0; i < _stagingItems.length; i++) {
      final entry = _stagingItems[i];
      final item = entry.item;
      final isLast = i == _stagingItems.length - 1;
      final nextIsBlank = !isLast && _stagingItems[i + 1].item is BlankStagingItem;

      if (item is BlankStagingItem) {
        slides.add(
          _SlideInfo(
            stagingUid: entry.uid,
            mainText: '',
            englishText: '',
            title: null,
            isBible: false,
            pageIndexInItem: 0,
            isBlank: true,
          ),
        );
      } else if (item is SongStagingItem) {
        final song = item.song;
        final pairs = song.pairedPages;
        for (var j = 0; j < pairs.length; j++) {
          slides.add(
            _SlideInfo(
              stagingUid: entry.uid,
              mainText: pairs[j].korean,
              englishText: pairs[j].english,
              title: song.title,
              isBible: false,
              pageIndexInItem: j,
            ),
          );
        }
        if (!isLast && !nextIsBlank) {
          slides.add(
            _SlideInfo(
              stagingUid: entry.uid,
              mainText: '',
              englishText: '',
              title: null,
              isBible: false,
              pageIndexInItem: pairs.length,
              isBlank: true,
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
            pageIndexInItem: 0,
          ),
        );
        if (!isLast && !nextIsBlank) {
          slides.add(
            _SlideInfo(
              stagingUid: entry.uid,
              mainText: '',
              englishText: '',
              title: null,
              isBible: false,
              pageIndexInItem: 1,
              isBlank: true,
            ),
          );
        }
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
      await _presentationChannel.invokeMethod('openWindow', pageData.toJson());
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
    if (mounted) {
      setState(() {
        _isPresentationOpen = false;
        _isBlackout = false;
        _isSlideOrderCollapsed = false;
        _isSlideOrderMaximized = false;
      });
    }
  }

  Future<void> _toggleBlackout() async {
    if (!_isPresentationOpen) return;
    try {
      await _presentationChannel.invokeMethod('blackout');
      if (mounted) setState(() => _isBlackout = !_isBlackout);
    } catch (_) {}
  }

  Future<void> _sendCurrentSlide() async {
    if (!_isPresentationOpen) return;
    try {
      final pageData = _buildSlidePageData(_currentSlideIndex);
      await _presentationChannel.invokeMethod('updatePage', pageData.toJson());
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

  Future<void> _editSlide(int slideIndex) async {
    final slides = _allSlides;
    if (slideIndex >= slides.length) return;
    final info = slides[slideIndex];

    final result = await showDialog<(String, String)?>(
      context: context,
      builder: (_) => _SlideQuickEditDialog(
        mainText: info.mainText,
        englishText: info.englishText,
        isBible: info.isBible,
        title: info.title,
      ),
    );
    if (result == null || !mounted) return;
    final (newMain, newEnglish) = result;
    await _applySlideEdit(info, newMain, newEnglish, slideIndex);
  }

  Future<void> _applySlideEdit(
    _SlideInfo info,
    String newMain,
    String newEnglish,
    int slideIndex,
  ) async {
    final stagingIndex = _stagingItems.indexWhere(
      (e) => e.uid == info.stagingUid,
    );
    if (stagingIndex == -1) return;

    final entry = _stagingItems[stagingIndex];
    final item = entry.item;

    StagingItem newItem;
    PraiseSong? updatedSong;
    if (item is SongStagingItem) {
      final song = item.song;
      final pairs = List.of(song.pairedPages);

      if (info.pageIndexInItem < pairs.length) {
        pairs[info.pageIndexInItem] = (korean: newMain, english: newEnglish);
      }

      final newSong = PraiseSong(
        id: song.id,
        fileName: song.fileName,
        title: song.title,
        lyrics: encodePages(pairs.map((p) => p.korean)),
        englishLyrics: encodePages(pairs.map((p) => p.english)),
      );
      newItem = SongStagingItem(newSong);
      updatedSong = newSong;
    } else if (item is BibleStagingItem) {
      newItem = BibleStagingItem(reference: item.reference, text: newMain);
    } else {
      return;
    }

    setState(() {
      _stagingItems[stagingIndex] = (uid: entry.uid, item: newItem);
    });

    if (updatedSong != null) {
      await _repository.updateSong(updatedSong);
      if (mounted) {
        setState(() {
          final idx = _songs.indexWhere((s) => s.id == updatedSong!.id);
          if (idx != -1) {
            final newList = List.of(_songs);
            newList[idx] = updatedSong!;
            _songs = newList;
          }
        });
      }
    }

    if (_currentSlideIndex == slideIndex) {
      _sendCurrentSlide();
    }
  }

  Future<void> _goToSlide(int index) async {
    final slides = _allSlides;
    if (index < 0 || index >= slides.length) return;
    setState(() {
      _currentSlideIndex = index;
      _previewStagingUid = slides[index].stagingUid;
    });
    await _sendCurrentSlide();
  }

  static final _digitKeys = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.digit0: '0',
    LogicalKeyboardKey.digit1: '1',
    LogicalKeyboardKey.digit2: '2',
    LogicalKeyboardKey.digit3: '3',
    LogicalKeyboardKey.digit4: '4',
    LogicalKeyboardKey.digit5: '5',
    LogicalKeyboardKey.digit6: '6',
    LogicalKeyboardKey.digit7: '7',
    LogicalKeyboardKey.digit8: '8',
    LogicalKeyboardKey.digit9: '9',
    LogicalKeyboardKey.numpad0: '0',
    LogicalKeyboardKey.numpad1: '1',
    LogicalKeyboardKey.numpad2: '2',
    LogicalKeyboardKey.numpad3: '3',
    LogicalKeyboardKey.numpad4: '4',
    LogicalKeyboardKey.numpad5: '5',
    LogicalKeyboardKey.numpad6: '6',
    LogicalKeyboardKey.numpad7: '7',
    LogicalKeyboardKey.numpad8: '8',
    LogicalKeyboardKey.numpad9: '9',
  };

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isPresentationOpen) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    final digit = _digitKeys[key];
    if (digit != null) {
      setState(() => _slideJumpBuffer += digit);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_slideJumpBuffer.isNotEmpty) {
        final target = int.tryParse(_slideJumpBuffer) ?? 0;
        setState(() => _slideJumpBuffer = '');
        if (target >= 1) {
          _goToSlide((target - 1).clamp(0, _allSlides.length - 1));
        }
        return KeyEventResult.handled;
      }
    }

    if (key == LogicalKeyboardKey.escape) {
      if (_slideJumpBuffer.isNotEmpty) {
        setState(() => _slideJumpBuffer = '');
        return KeyEventResult.handled;
      }
    }

    if (_slideJumpBuffer.isNotEmpty) {
      setState(() => _slideJumpBuffer = '');
    }

    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown) {
      _nextSlide();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp) {
      _prevSlide();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyB) {
      _toggleBlackout();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ── 업데이트 ─────────────────────────────────────────────────────────

  Future<void> _checkForUpdates({bool isStartup = false}) async {
    if (_isCheckingUpdate) return;
    setState(() => _isCheckingUpdate = true);
    final info = await _updateService.checkForUpdates(
      maxAttempts: isStartup ? 3 : 1,
    );
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

  void _addBlankItem() {
    setState(() {
      final uid = _nextUid++;
      final selectedIndex =
          _stagingItems.indexWhere((e) => e.uid == _previewStagingUid);
      final insertIndex =
          selectedIndex >= 0 ? selectedIndex + 1 : _stagingItems.length;
      _stagingItems.insert(insertIndex, (uid: uid, item: const BlankStagingItem()));
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
    } catch (error, stack) {
      await AppLogger.instance.error('찬양 폴더 가져오기 실패', error, stack);
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
    } catch (e, stack) {
      await AppLogger.instance.error('성경 불러오기 실패', e, stack);
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
    } catch (error, stack) {
      await AppLogger.instance.error('PPTX 내보내기 실패', error, stack);
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

  // ── 예배 콘티 저장/불러오기 ──────────────────────────────────────────

  Future<void> _saveConti() async {
    if (_stagingItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('저장할 항목이 없습니다. 찬양이나 성경 본문을 먼저 선택해 주세요.')),
      );
      return;
    }

    final now = DateTime.now();
    final defaultName =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} 예배';
    final controller = TextEditingController(text: defaultName);

    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('예배 콘티 저장'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '콘티 이름',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => Navigator.of(ctx).pop(controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (name == null || name.isEmpty || !mounted) return;

    await _contiRepository.saveConti(name, _stagingItems);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('"$name" 콘티를 저장했습니다.')));
  }

  Future<void> _loadContiDialog() async {
    final contis = await _contiRepository.listContis();
    if (!mounted) return;

    if (contis.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('저장된 예배 콘티가 없습니다.')));
      return;
    }

    final selected = await showDialog<WorshipConti>(
      context: context,
      builder: (ctx) => _ContiListDialog(
        contis: contis,
        onDelete: (conti) async {
          await _contiRepository.deleteConti(conti.id);
        },
      ),
    );
    if (selected == null || !mounted) return;

    if (_stagingItems.isNotEmpty) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('현재 콘티 교체'),
          content: Text(
            '현재 선택된 ${_stagingItems.length}개 항목을 지우고 "${selected.name}" 콘티를 불러올까요?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('교체'),
            ),
          ],
        ),
      );
      if (replace != true || !mounted) return;
    }

    final result = await _contiRepository.loadConti(selected.id, _nextUid);
    if (!mounted) return;

    setState(() {
      _stagingItems
        ..clear()
        ..addAll(result.items);
      _nextUid += result.items.length;
      _previewStagingUid = result.items.isEmpty ? null : result.items.first.uid;
      _currentSlideIndex = 0;
    });

    if (result.missingCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '"${selected.name}" 불러오기 완료'
            ' (${result.missingCount}개 항목은 DB에서 삭제되어 제외됨)',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('"${selected.name}" 콘티를 불러왔습니다.')));
    }
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
      _replaceStagedSong(result);
    }
    await _loadSongs();
  }

  void _replaceStagedSong(PraiseSong updatedSong) {
    final updatedId = updatedSong.id;
    if (updatedId == null) return;
    var replaced = false;
    setState(() {
      for (var i = 0; i < _stagingItems.length; i++) {
        final entry = _stagingItems[i];
        final item = entry.item;
        if (item is SongStagingItem && item.song.id == updatedId) {
          _stagingItems[i] = (
            uid: entry.uid,
            item: SongStagingItem(updatedSong),
          );
          replaced = true;
        }
      }
      if (replaced) {
        _clampCurrentSlideIndex();
      }
    });
    if (replaced) {
      _sendCurrentSlide();
    }
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

  // ── 로그 추출 ────────────────────────────────────────────────────────

  Future<void> _showExtractLogsDialog() async {
    final logs = await AppLogger.instance.readLogs();
    final logPath = await AppLogger.instance.logFilePath();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _LogViewerDialog(
        logs: logs,
        logFilePath: logPath,
        onOpenFolder: logPath != null
            ? () {
                final dir = File(logPath).parent.path;
                if (Platform.isMacOS) {
                  Process.run('open', [dir]);
                } else if (Platform.isWindows) {
                  Process.run('explorer', [dir]);
                } else {
                  Process.run('xdg-open', [dir]);
                }
              }
            : null,
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
                            onExtractLogsPressed: _showExtractLogsDialog,
                            isCheckingUpdate: _isCheckingUpdate,
                            hasUpdate: _pendingUpdate != null,
                            onCheckUpdate: _checkForUpdates,
                          ),
                          const SizedBox(height: 8),
                          _PresentationControlBar(
                            slidesReady: slides.isNotEmpty,
                            isPresentationOpen: _isPresentationOpen,
                            isBlackout: _isBlackout,
                            currentSlideIndex: _currentSlideIndex,
                            totalSlides: slides.length,
                            currentSlideTitle: currentSlideTitle,
                            slideJumpBuffer: _slideJumpBuffer,
                            onOpen: _openPresentation,
                            onClose: _closePresentation,
                            onPrev: _prevSlide,
                            onNext: _nextSlide,
                            onBlackout: _toggleBlackout,
                          ),
                          const SizedBox(height: 10),
                          Expanded(
                            child: _isPresentationOpen
                                ? _PresentingLayout(
                                    presentationRatio: _presentationPanelRatio,
                                    onPresentationRatioChanged: (v) => setState(
                                      () => _presentationPanelRatio = v,
                                    ),
                                    isSlideOrderCollapsed:
                                        _isSlideOrderCollapsed,
                                    isSlideOrderMaximized:
                                        _isSlideOrderMaximized,
                                    presentationPanel:
                                        _PresentationControllerPanel(
                                          slides: slides,
                                          currentIndex: _currentSlideIndex,
                                          style: _style,
                                          onSlideSelected: _goToSlide,
                                          onSlideEdit: _editSlide,
                                          onCollapse: () => setState(
                                            () => _isSlideOrderCollapsed = true,
                                          ),
                                          isMaximized: _isSlideOrderMaximized,
                                          onToggleMaximized: () => setState(
                                            () => _isSlideOrderMaximized =
                                                !_isSlideOrderMaximized,
                                          ),
                                        ),
                                    collapsedSlideStrip:
                                        _CollapsedSlideOrderStrip(
                                          currentIndex: _currentSlideIndex,
                                          totalSlides: slides.length,
                                          onExpand: () => setState(
                                            () =>
                                                _isSlideOrderCollapsed = false,
                                          ),
                                        ),
                                    workArea: _ResizableWorkArea(
                                      stagingRatio: _stagingPanelRatio,
                                      onRatioChanged: (value) => setState(
                                        () => _stagingPanelRatio = value,
                                      ),
                                      isSearchCollapsed: _isSearchCollapsed,
                                      isStagingCollapsed: _isStagingCollapsed,
                                      stagingPanel: _StagingPanel(
                                        stagingItems: _stagingItems,
                                        selectedUid: _previewStagingUid,
                                        onReorder: _onStagingReorder,
                                        onRemove: _removeFromStaging,
                                        isCollapsed: _isStagingCollapsed,
                                        onToggleCollapsed: () => setState(
                                          () => _isStagingCollapsed =
                                              !_isStagingCollapsed,
                                        ),
                                        onSaveConti: _saveConti,
                                        onLoadConti: _loadContiDialog,
                                        onAddBlank: _addBlankItem,
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
                                        isCollapsed: _isSearchCollapsed,
                                        onToggleCollapsed: () => setState(
                                          () => _isSearchCollapsed =
                                              !_isSearchCollapsed,
                                        ),
                                      ),
                                    ),
                                  )
                                : _ResizableWorkArea(
                                    stagingRatio: _stagingPanelRatio,
                                    onRatioChanged: (value) => setState(
                                      () => _stagingPanelRatio = value,
                                    ),
                                    isSearchCollapsed: _isSearchCollapsed,
                                    isStagingCollapsed: _isStagingCollapsed,
                                    stagingPanel: _StagingPanel(
                                      stagingItems: _stagingItems,
                                      selectedUid: _previewStagingUid,
                                      onReorder: _onStagingReorder,
                                      onRemove: _removeFromStaging,
                                      isCollapsed: _isStagingCollapsed,
                                      onToggleCollapsed: () => setState(
                                        () => _isStagingCollapsed =
                                            !_isStagingCollapsed,
                                      ),
                                      onSaveConti: _saveConti,
                                      onLoadConti: _loadContiDialog,
                                      onAddBlank: _addBlankItem,
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
                                      isCollapsed: _isSearchCollapsed,
                                      onToggleCollapsed: () => setState(
                                        () => _isSearchCollapsed =
                                            !_isSearchCollapsed,
                                      ),
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: isWide ? 20 : 0, height: isWide ? 0 : 20),
                    if (_isDesignCollapsed)
                      _CollapsedPanelStrip(
                        label: 'PPTX 디자인',
                        isVertical: isWide,
                        onExpand: () =>
                            setState(() => _isDesignCollapsed = false),
                      )
                    else
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
                          onCollapse: () =>
                              setState(() => _isDesignCollapsed = true),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ), // Scaffold
    ); // Focus
  }
}

// ── PresentationControlBar ───────────────────────────────────────────────

class _PresentationControlBar extends StatelessWidget {
  const _PresentationControlBar({
    required this.slidesReady,
    required this.isPresentationOpen,
    required this.isBlackout,
    required this.currentSlideIndex,
    required this.totalSlides,
    required this.currentSlideTitle,
    required this.slideJumpBuffer,
    required this.onOpen,
    required this.onClose,
    required this.onPrev,
    required this.onNext,
    required this.onBlackout,
  });

  final bool slidesReady;
  final bool isPresentationOpen;
  final bool isBlackout;
  final int currentSlideIndex;
  final int totalSlides;
  final String? currentSlideTitle;
  final String slideJumpBuffer;
  final VoidCallback onOpen;
  final VoidCallback onClose;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onBlackout;

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
            color: isPresentationOpen
                ? cs.onPrimaryContainer
                : cs.onSurfaceVariant,
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
              child: slideJumpBuffer.isNotEmpty
                  ? Text(
                      '→ $slideJumpBuffer',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: cs.primary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    )
                  : Text(
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
            IconButton(
              tooltip: isBlackout ? '블랙아웃 해제  B' : '블랙아웃  B',
              style: IconButton.styleFrom(
                backgroundColor: isBlackout
                    ? Colors.white.withValues(alpha: 0.2)
                    : Colors.transparent,
                foregroundColor: cs.onPrimaryContainer,
              ),
              onPressed: onBlackout,
              icon: Icon(
                isBlackout
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_off_outlined,
                size: 18,
              ),
            ),
            const SizedBox(width: 2),
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
    required this.isSearchCollapsed,
    required this.isStagingCollapsed,
  });

  final double stagingRatio;
  final ValueChanged<double> onRatioChanged;
  final Widget stagingPanel;
  final Widget searchPanel;
  final bool isSearchCollapsed;
  final bool isStagingCollapsed;

  static const double _dividerHeight = 18;
  static const double _minPanelHeight = 140;
  static const double _collapsedSearchHeight = 48;
  static const double _collapsedStagingHeight = 48;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (isStagingCollapsed && isSearchCollapsed) {
      return Column(
        children: [
          SizedBox(height: _collapsedStagingHeight, child: stagingPanel),
          Expanded(child: searchPanel),
        ],
      );
    }

    if (isStagingCollapsed) {
      return Column(
        children: [
          SizedBox(height: _collapsedStagingHeight, child: stagingPanel),
          Expanded(child: searchPanel),
        ],
      );
    }

    if (isSearchCollapsed) {
      return Column(
        children: [
          Expanded(child: stagingPanel),
          SizedBox(height: _collapsedSearchHeight, child: searchPanel),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = (constraints.maxHeight - _dividerHeight)
            .clamp(0.0, double.infinity)
            .toDouble();
        final ratio = clampSplitRatioForLayout(
          ratio: stagingRatio,
          available: availableHeight,
          firstMin: _minPanelHeight,
          secondMin: _minPanelHeight,
          minRatioMin: 0.12,
          minRatioMax: 0.5,
          maxRatioMin: 0.5,
          maxRatioMax: 0.88,
        );
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
                final nextRatio = clampSplitRatioForLayout(
                  ratio: ratio + delta / availableHeight,
                  available: availableHeight,
                  firstMin: _minPanelHeight,
                  secondMin: _minPanelHeight,
                  minRatioMin: 0.12,
                  minRatioMax: 0.5,
                  maxRatioMin: 0.5,
                  maxRatioMax: 0.88,
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

@visibleForTesting
double clampSplitRatioForLayout({
  required double ratio,
  required double available,
  required double firstMin,
  required double secondMin,
  required double minRatioMin,
  required double minRatioMax,
  required double maxRatioMin,
  required double maxRatioMax,
}) {
  if (available <= 0) return ratio.clamp(0.0, 1.0).toDouble();
  final hasRoomForMinimums = available >= firstMin + secondMin;
  final minRatio = !hasRoomForMinimums
      ? 0.0
      : (firstMin / available).clamp(minRatioMin, minRatioMax);
  final maxRatio = !hasRoomForMinimums
      ? 1.0
      : (1 - secondMin / available).clamp(maxRatioMin, maxRatioMax);
  return ratio.clamp(minRatio, maxRatio).toDouble();
}

// ── PresentingLayout ──────────────────────────────────────────────────────

class _PresentingLayout extends StatelessWidget {
  const _PresentingLayout({
    required this.presentationRatio,
    required this.onPresentationRatioChanged,
    required this.isSlideOrderCollapsed,
    required this.isSlideOrderMaximized,
    required this.presentationPanel,
    required this.collapsedSlideStrip,
    required this.workArea,
  });

  final double presentationRatio;
  final ValueChanged<double> onPresentationRatioChanged;
  final bool isSlideOrderCollapsed;
  final bool isSlideOrderMaximized;
  final Widget presentationPanel;
  final Widget collapsedSlideStrip;
  final Widget workArea;

  static const double _dividerHeight = 18;
  static const double _collapsedHeight = 40;
  static const double _minPresentationHeight = 100;
  static const double _minWorkAreaHeight = 120;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (isSlideOrderMaximized) {
      return Expanded(child: presentationPanel);
    }

    if (isSlideOrderCollapsed) {
      return Column(
        children: [
          SizedBox(height: _collapsedHeight, child: collapsedSlideStrip),
          const SizedBox(height: 10),
          Expanded(child: workArea),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = (constraints.maxHeight - _dividerHeight)
            .clamp(0.0, double.infinity)
            .toDouble();
        final ratio = clampSplitRatioForLayout(
          ratio: presentationRatio,
          available: available,
          firstMin: _minPresentationHeight,
          secondMin: _minWorkAreaHeight,
          minRatioMin: 0.1,
          minRatioMax: 0.8,
          maxRatioMin: 0.2,
          maxRatioMax: 0.9,
        );
        final presentH = available * ratio;
        final workH = available - presentH;

        return Column(
          children: [
            SizedBox(height: presentH, child: presentationPanel),
            _PanelResizeHandle(
              height: _dividerHeight,
              color: cs.outlineVariant,
              onDrag: (delta) {
                if (available <= 0) return;
                final next = clampSplitRatioForLayout(
                  ratio: ratio + delta / available,
                  available: available,
                  firstMin: _minPresentationHeight,
                  secondMin: _minWorkAreaHeight,
                  minRatioMin: 0.1,
                  minRatioMax: 0.8,
                  maxRatioMin: 0.2,
                  maxRatioMax: 0.9,
                );
                onPresentationRatioChanged(next);
              },
            ),
            SizedBox(height: workH, child: workArea),
          ],
        );
      },
    );
  }
}

// ── CollapsedSlideOrderStrip ──────────────────────────────────────────────

class _CollapsedSlideOrderStrip extends StatelessWidget {
  const _CollapsedSlideOrderStrip({
    required this.currentIndex,
    required this.totalSlides,
    required this.onExpand,
  });

  final int currentIndex;
  final int totalSlides;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(
            Icons.view_carousel_outlined,
            size: 16,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Text(
            '슬라이드 순서',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${currentIndex + 1} / $totalSlides',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.expand_more_rounded),
            iconSize: 18,
            tooltip: '슬라이드 순서 펼치기',
            color: cs.onSurfaceVariant,
            visualDensity: VisualDensity.compact,
            onPressed: onExpand,
          ),
        ],
      ),
    );
  }
}

// ── CollapsedPanelStrip ───────────────────────────────────────────────────

class _CollapsedPanelStrip extends StatelessWidget {
  const _CollapsedPanelStrip({
    required this.label,
    required this.isVertical,
    required this.onExpand,
  });

  final String label;
  final bool isVertical;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final content = isVertical
        ? Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left_rounded),
                tooltip: '$label 펼치기',
                color: cs.onSurfaceVariant,
                onPressed: onExpand,
              ),
              const SizedBox(height: 8),
              RotatedBox(
                quarterTurns: 1,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          )
        : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.expand_more_rounded),
                tooltip: '$label 펼치기',
                color: cs.onSurfaceVariant,
                onPressed: onExpand,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          );

    return Card(
      child: SizedBox(width: isVertical ? 48 : double.infinity, child: content),
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
    required this.onExtractLogsPressed,
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
  final VoidCallback onExtractLogsPressed;
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
                    : const Icon(
                        Icons.refresh_rounded,
                        size: 18,
                        color: Colors.white54,
                      ),
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
          const SizedBox(width: 4),
          Tooltip(
            message: '저장된 로그 추출',
            child: IconButton(
              onPressed: onExtractLogsPressed,
              icon: const Icon(
                Icons.description_outlined,
                size: 18,
                color: Colors.white70,
              ),
            ),
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
    required this.isCollapsed,
    required this.onToggleCollapsed,
    required this.onSaveConti,
    required this.onLoadConti,
    required this.onAddBlank,
  });

  final List<({int uid, StagingItem item})> stagingItems;
  final int? selectedUid;
  final void Function(int oldIndex, int newIndex) onReorder;
  final void Function(int uid) onRemove;
  final ValueChanged<int> onSelect;
  final bool isCollapsed;
  final VoidCallback onToggleCollapsed;
  final VoidCallback onSaveConti;
  final VoidCallback onLoadConti;
  final VoidCallback onAddBlank;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (isCollapsed) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '예배 콘티',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '${stagingItems.length}개',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
              IconButton(
                icon: const Icon(Icons.expand_more_rounded),
                iconSize: 18,
                tooltip: '예배 콘티 펼치기',
                color: cs.onSurfaceVariant,
                visualDensity: VisualDensity.compact,
                onPressed: onToggleCollapsed,
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '예배 콘티',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  '${stagingItems.length}개',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.add_box_outlined, size: 18),
                  tooltip: '빈 페이지 추가',
                  color: cs.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                  onPressed: onAddBlank,
                ),
                IconButton(
                  icon: const Icon(Icons.save_outlined, size: 18),
                  tooltip: '콘티 저장',
                  color: cs.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                  onPressed: onSaveConti,
                ),
                IconButton(
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  tooltip: '콘티 불러오기',
                  color: cs.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                  onPressed: onLoadConti,
                ),
                IconButton(
                  icon: const Icon(Icons.expand_less_rounded),
                  iconSize: 18,
                  tooltip: '예배 콘티 접기',
                  color: cs.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                  onPressed: onToggleCollapsed,
                ),
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
                        final isBlank = item is BlankStagingItem;
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
                              if (isBlank)
                                Container(
                                  margin: const EdgeInsets.only(right: 6),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade200,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '빈 페이지',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade600,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              Expanded(
                                child: Text(
                                  isBlank ? '' : item.displayTitle,
                                  overflow: TextOverflow.ellipsis,
                                  style: isBlank
                                      ? TextStyle(color: Colors.grey.shade500)
                                      : null,
                                ),
                              ),
                            ],
                          ),
                          subtitle: isBlank
                              ? null
                              : Text(
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
    required this.isCollapsed,
    required this.onToggleCollapsed,
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
  final bool isCollapsed;
  final VoidCallback onToggleCollapsed;

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
    final cs = Theme.of(context).colorScheme;
    final tabBar = TabBar(
      controller: _tabController,
      tabs: const [
        Tab(text: '찬양 검색'),
        Tab(text: '성경 검색'),
      ],
    );

    if (widget.isCollapsed) {
      return Card(
        child: Row(
          children: [
            Expanded(child: tabBar),
            IconButton(
              icon: const Icon(Icons.expand_less_rounded),
              tooltip: '검색 패널 펼치기',
              color: cs.onSurfaceVariant,
              onPressed: widget.onToggleCollapsed,
            ),
          ],
        ),
      );
    }

    return Card(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: tabBar),
              IconButton(
                icon: const Icon(Icons.expand_more_rounded),
                tooltip: '검색 패널 접기',
                color: cs.onSurfaceVariant,
                onPressed: widget.onToggleCollapsed,
              ),
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
    required this.onCollapse,
  });

  final ExportStyle style;
  final bool isExporting;
  final List<Color> swatches;
  final List<Color> textSwatches;
  final StagingItem? previewItem;
  final ValueChanged<ExportStyle> onStyleChanged;
  final VoidCallback onExportPressed;
  final VoidCallback onCollapse;

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
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showPreview = constraints.maxHeight >= 320;
          final previewMaxHeight = constraints.maxHeight < 520 ? 118.0 : 180.0;

          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'PPTX 디자인',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right_rounded),
                      tooltip: '디자인 패널 접기',
                      color: cs.onSurfaceVariant,
                      onPressed: onCollapse,
                    ),
                  ],
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
                if (showPreview) ...[
                  const SizedBox(height: 16),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: previewMaxHeight),
                    child: _PreviewBox(style: style, previewItem: previewItem),
                  ),
                  const SizedBox(height: 12),
                ] else
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
                            _BackgroundImagePicker(
                              imagePath: style.backgroundImagePath,
                              onChanged: (path) => onStyleChanged(
                                style.copyWith(backgroundImagePath: path),
                              ),
                            ),
                            _FontFamilyPicker(
                              selected: style.fontFamily,
                              onChanged: (family) => onStyleChanged(
                                style.copyWith(fontFamily: family),
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
          );
        },
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
      BlankStagingItem() => null,
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

  @override
  Widget build(BuildContext context) {
    final String sampleText;
    final String sampleEnglishText;
    final String? titleText;
    final bool isBible;

    switch (previewItem) {
      case SongStagingItem(:final song):
        sampleText = song.pages.isEmpty ? song.title : song.pages.first;
        sampleEnglishText = song.englishPages.isEmpty
            ? ''
            : song.englishPages.first;
        titleText = song.title;
        isBible = false;
      case BibleStagingItem(:final text, :final reference):
        sampleText = text;
        sampleEnglishText = '';
        titleText = reference;
        isBible = true;
      case BlankStagingItem():
        sampleText = '';
        sampleEnglishText = '';
        titleText = null;
        isBible = false;
      case null:
        sampleText = '선택한 항목이 여기에 미리보기로 보입니다.';
        sampleEnglishText = '';
        titleText = null;
        isBible = false;
    }

    return AspectRatio(
      aspectRatio: 13.333 / 7.5,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SlideRenderView(
          data: SlidePageData(
            mainText: sampleText,
            englishText: sampleEnglishText,
            title: titleText,
            isBible: isBible,
            pageIndex: 0,
            totalPages: 1,
            style: style,
          ),
        ),
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

// 저장 형식이 편집 형식과 동일하므로 변환 불필요.
@visibleForTesting
String lyricsToEditText(String stored) => stored;

// 편집 텍스트 → 저장 형식 정규화.
// 규칙: 빈 줄 1개(\n\n) = 페이지 구분, 빈 줄 N개 = 빈 페이지 N-1장.
// ### 은 하위 호환 페이지 구분자로 허용.
@visibleForTesting
String normalizeEditableLyrics(String raw) {
  var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // ### → \n\n (주변 줄바꿈 포함 소비)
  text = text.replaceAll(RegExp(r'\n?[ \t]*###[ \t]*\n?'), '\n\n');
  // 분리 → 각 페이지 trim → 후행 빈 페이지 제거 → 재결합
  final pages = text
      .split(RegExp(r'\n[ \t]*\n'))
      .map((p) => p.trim())
      .toList();
  while (pages.isNotEmpty && pages.last.isEmpty) {
    pages.removeLast();
  }
  return pages.join('\n\n');
}

// 페이지 목록 → 저장 형식 인코딩.
@visibleForTesting
String encodePages(Iterable<String> pages) {
  final list = pages.toList();
  while (list.isNotEmpty && list.last.isEmpty) list.removeLast();
  return list.join('\n\n');
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
    return normalizeEditableLyrics(raw);
  }

  static String _toEditText(String stored) => lyricsToEditText(stored);

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
                  hintText: '페이지 구분: 빈 줄',
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
                  hintText: '페이지 구분: 빈 줄',
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

// ── PresentationControllerPanel ───────────────────────────────────────────

class _PresentationControllerPanel extends StatefulWidget {
  const _PresentationControllerPanel({
    required this.slides,
    required this.currentIndex,
    required this.style,
    required this.onSlideSelected,
    required this.onSlideEdit,
    required this.onCollapse,
    required this.isMaximized,
    required this.onToggleMaximized,
  });

  final List<_SlideInfo> slides;
  final int currentIndex;
  final ExportStyle style;
  final ValueChanged<int> onSlideSelected;
  final ValueChanged<int> onSlideEdit;
  final VoidCallback onCollapse;
  final bool isMaximized;
  final VoidCallback onToggleMaximized;

  @override
  State<_PresentationControllerPanel> createState() =>
      _PresentationControllerPanelState();
}

class _PresentationControllerPanelState
    extends State<_PresentationControllerPanel> {
  final _scrollController = ScrollController();
  final _gridScrollController = ScrollController();

  double _zoomLevel = 1.0;
  static const double _baseThumbW = 210.0;
  static const double _itemSpacing = 8;
  static const double _padding = 10;
  static const double _minZoom = 0.35;
  static const double _maxZoom = 3.0;

  double get _thumbW => (_baseThumbW * _zoomLevel).clamp(70.0, 700.0);

  void _changeZoom(double delta) {
    setState(() {
      _zoomLevel = (_zoomLevel + delta).clamp(_minZoom, _maxZoom);
    });
  }

  @override
  void didUpdateWidget(_PresentationControllerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex && !widget.isMaximized) {
      _scrollToCurrentItem();
    }
  }

  void _scrollToCurrentItem() {
    if (!_scrollController.hasClients) return;
    final tw = _thumbW;
    final targetOffset = widget.currentIndex * (tw + _itemSpacing) + _padding;
    final viewportWidth = _scrollController.position.viewportDimension;
    final centeredOffset = targetOffset - (viewportWidth - tw) / 2;
    _scrollController.animateTo(
      centeredOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _gridScrollController.dispose();
    super.dispose();
  }

  SlidePageData _pageDataFor(int i) {
    final info = widget.slides[i];
    return SlidePageData(
      mainText: info.mainText,
      englishText: info.englishText,
      title: info.title,
      isBible: info.isBible,
      pageIndex: i,
      totalPages: widget.slides.length,
      style: widget.style,
    );
  }

  Widget _buildHorizontalList() {
    final tw = _thumbW;
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent &&
            (HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed)) {
          setState(() {
            _zoomLevel = (_zoomLevel - event.scrollDelta.dy * 0.004).clamp(
              _minZoom,
              _maxZoom,
            );
          });
        }
      },
      child: ListView.builder(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.all(_padding),
        itemCount: widget.slides.length,
        itemBuilder: (context, i) => SizedBox(
          width: tw,
          child: Padding(
            padding: EdgeInsets.only(
              right: i < widget.slides.length - 1 ? _itemSpacing : 0,
            ),
            child: _SlideThumbnail(
              data: _pageDataFor(i),
              isSelected: i == widget.currentIndex,
              index: i,
              onTap: () => widget.onSlideSelected(i),
              onEdit: () => widget.onSlideEdit(i),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGrid() {
    const aspectRatio = 13.333 / 7.5;
    const labelH = 22.0;

    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent &&
            (HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed)) {
          setState(() {
            _zoomLevel = (_zoomLevel - event.scrollDelta.dy * 0.004).clamp(
              _minZoom,
              _maxZoom,
            );
          });
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final W = (constraints.maxWidth - _padding * 2).clamp(
            1.0,
            double.infinity,
          );
          final n = widget.slides.length.clamp(1, 9999);

          final targetThumbW = _thumbW;
          final cols = ((W + _itemSpacing) / (targetThumbW + _itemSpacing))
              .floor()
              .clamp(1, n);
          final actualThumbW = (W - (cols - 1) * _itemSpacing) / cols;
          final cellH = actualThumbW / aspectRatio + labelH;
          final childAspectRatio = (actualThumbW / cellH).clamp(0.1, 100.0);

          return GridView.builder(
            controller: _gridScrollController,
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.all(_padding),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: _itemSpacing,
              crossAxisSpacing: _itemSpacing,
              childAspectRatio: childAspectRatio,
            ),
            itemCount: n,
            itemBuilder: (context, i) => _SlideThumbnail(
              data: _pageDataFor(i),
              isSelected: i == widget.currentIndex,
              index: i,
              onTap: () => widget.onSlideSelected(i),
              onEdit: () => widget.onSlideEdit(i),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
            child: Row(
              children: [
                Text(
                  '슬라이드 순서',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${widget.currentIndex + 1} / ${widget.slides.length}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.remove_rounded),
                  iconSize: 16,
                  tooltip: '축소 (⌘ + 스크롤)',
                  color: cs.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                  onPressed: _zoomLevel > _minZoom
                      ? () => _changeZoom(-0.2)
                      : null,
                ),
                SizedBox(
                  width: 40,
                  child: Text(
                    '${(_zoomLevel * 100).round()}%',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_rounded),
                  iconSize: 16,
                  tooltip: '확대 (⌘ + 스크롤)',
                  color: cs.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                  onPressed: _zoomLevel < _maxZoom
                      ? () => _changeZoom(0.2)
                      : null,
                ),
                IconButton(
                  icon: Icon(
                    widget.isMaximized
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                  ),
                  iconSize: 18,
                  tooltip: widget.isMaximized ? '원래 크기로' : '최대화',
                  color: cs.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onToggleMaximized,
                ),
                if (!widget.isMaximized)
                  IconButton(
                    icon: const Icon(Icons.expand_less_rounded),
                    iconSize: 18,
                    tooltip: '슬라이드 순서 접기',
                    color: cs.onSurfaceVariant,
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onCollapse,
                  ),
              ],
            ),
          ),
          Expanded(
            child: widget.isMaximized ? _buildGrid() : _buildHorizontalList(),
          ),
        ],
      ),
    );
  }
}

// ── SlideThumbnail ────────────────────────────────────────────────────────

class _SlideThumbnail extends StatefulWidget {
  const _SlideThumbnail({
    required this.data,
    required this.isSelected,
    required this.index,
    required this.onTap,
    required this.onEdit,
  });

  final SlidePageData data;
  final bool isSelected;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  State<_SlideThumbnail> createState() => _SlideThumbnailState();
}

class _SlideThumbnailState extends State<_SlideThumbnail> {
  bool _hovered = false;

  static const double _aspectRatio = 13.333 / 7.5;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: widget.onTap,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                        color: widget.isSelected
                            ? cs.primary
                            : cs.outlineVariant,
                        width: widget.isSelected ? 2.5 : 1,
                      ),
                      boxShadow: widget.isSelected
                          ? [
                              BoxShadow(
                                color: cs.primary.withValues(alpha: 0.35),
                                blurRadius: 6,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: AspectRatio(
                        aspectRatio: _aspectRatio,
                        child: SlideRenderView(data: widget.data),
                      ),
                    ),
                  ),
                  if (_hovered)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        onTap: widget.onEdit,
                        child: Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color: cs.surface.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(5),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.edit_rounded,
                            size: 13,
                            color: cs.primary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.index + 1}',
              style: TextStyle(
                fontSize: 11,
                color: widget.isSelected ? cs.primary : cs.onSurfaceVariant,
                fontWeight: widget.isSelected
                    ? FontWeight.w700
                    : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── SlideQuickEditDialog ──────────────────────────────────────────────────

class _SlideQuickEditDialog extends StatefulWidget {
  const _SlideQuickEditDialog({
    required this.mainText,
    required this.englishText,
    required this.isBible,
    this.title,
  });

  final String mainText;
  final String englishText;
  final bool isBible;
  final String? title;

  @override
  State<_SlideQuickEditDialog> createState() => _SlideQuickEditDialogState();
}

class _SlideQuickEditDialogState extends State<_SlideQuickEditDialog> {
  late final TextEditingController _mainCtrl;
  late final TextEditingController _englishCtrl;

  @override
  void initState() {
    super.initState();
    _mainCtrl = TextEditingController(text: widget.mainText);
    _englishCtrl = TextEditingController(text: widget.englishText);
  }

  @override
  void dispose() {
    _mainCtrl.dispose();
    _englishCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final titleLabel = widget.title != null
        ? '슬라이드 수정 — ${widget.title}'
        : '슬라이드 수정';
    return AlertDialog(
      title: Text(titleLabel),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _mainCtrl,
              maxLines: 7,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '본문',
                border: OutlineInputBorder(),
              ),
            ),
            if (!widget.isBible) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _englishCtrl,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '영어 가사 (선택)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, (_mainCtrl.text, _englishCtrl.text)),
          child: const Text('적용'),
        ),
      ],
    );
  }
}

// ── ContiListDialog ───────────────────────────────────────────────────────

class _ContiListDialog extends StatefulWidget {
  const _ContiListDialog({required this.contis, required this.onDelete});

  final List<WorshipConti> contis;
  final Future<void> Function(WorshipConti) onDelete;

  @override
  State<_ContiListDialog> createState() => _ContiListDialogState();
}

class _ContiListDialogState extends State<_ContiListDialog> {
  late final List<WorshipConti> _contis;

  @override
  void initState() {
    super.initState();
    _contis = List.of(widget.contis);
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _delete(WorshipConti conti) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('콘티 삭제'),
        content: Text('"${conti.name}"을(를) 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.onDelete(conti);
    if (!mounted) return;
    setState(() => _contis.removeWhere((c) => c.id == conti.id));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('예배 콘티 불러오기'),
      contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
      content: SizedBox(
        width: 420,
        child: _contis.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '저장된 콘티가 없습니다.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: _contis.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final conti = _contis[i];
                  return ListTile(
                    title: Text(
                      conti.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${_formatDate(conti.createdAt)}  ·  ${conti.itemCount}개',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      tooltip: '삭제',
                      color: Colors.red.shade300,
                      onPressed: () => _delete(conti),
                    ),
                    onTap: () => Navigator.of(context).pop(conti),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
      ],
    );
  }
}

// ── LogViewerDialog ───────────────────────────────────────────────────────

class _LogViewerDialog extends StatelessWidget {
  const _LogViewerDialog({
    required this.logs,
    required this.logFilePath,
    required this.onOpenFolder,
  });

  final String logs;
  final String? logFilePath;
  final VoidCallback? onOpenFolder;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('저장된 로그'),
      content: SizedBox(
        width: 640,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (logFilePath != null)
              Text(
                logFilePath!,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(6),
                ),
                padding: const EdgeInsets.all(12),
                child: SingleChildScrollView(
                  child: SelectableText(
                    logs,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (onOpenFolder != null)
          TextButton.icon(
            onPressed: () {
              onOpenFolder!();
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.folder_open_rounded, size: 16),
            label: const Text('로그 폴더 열기'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}

// ── _FontFamilyPicker ─────────────────────────────────────────────────────

class _FontFamilyPicker extends StatelessWidget {
  const _FontFamilyPicker({
    required this.selected,
    required this.onChanged,
  });

  final String selected;
  final ValueChanged<String> onChanged;

  static const _fonts = [
    ('Pretendard', 'Pretendard'),
    ('NanumGothic', '나눔고딕'),
    ('NanumMyeongjo', '나눔명조'),
  ];

  String get _displayName =>
      _fonts.firstWhere((f) => f.$1 == selected, orElse: () => _fonts.first).$2;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      offset: const Offset(0, 4),
      onSelected: onChanged,
      itemBuilder: (_) => _fonts
          .map(
            (f) => PopupMenuItem(
              value: f.$1,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      f.$2,
                      style: TextStyle(fontFamily: f.$1),
                    ),
                  ),
                  if (f.$1 == selected)
                    Icon(Icons.check_rounded, size: 16, color: cs.primary),
                ],
              ),
            ),
          )
          .toList(),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: null,
        child: Row(
          children: [
            Expanded(
              child: Text(
                '폰트',
                style: TextStyle(color: cs.onSurface),
              ),
            ),
            Text(
              _displayName,
              style: TextStyle(
                fontFamily: selected,
                color: cs.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more_rounded, size: 16, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

// ── _BackgroundImagePicker ────────────────────────────────────────────────

class _BackgroundImagePicker extends StatelessWidget {
  const _BackgroundImagePicker({
    required this.imagePath,
    required this.onChanged,
  });

  final String? imagePath;
  final ValueChanged<String?> onChanged;

  Future<void> _pick() async {
    await FilePicker.skipEntitlementsChecks();
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result != null && result.files.single.path != null) {
      onChanged(result.files.single.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasImage = imagePath != null;
    final fileName = hasImage ? p.basename(imagePath!) : null;

    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: _pick,
      child: Row(
        children: [
          Expanded(
            child: Text(
              '배경 이미지',
              style: TextStyle(color: cs.onSurface),
            ),
          ),
          if (hasImage) ...[
            Flexible(
              child: Text(
                fileName!,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => onChanged(null),
              child: Icon(Icons.close_rounded, size: 16, color: cs.onSurfaceVariant),
            ),
          ] else
            Text(
              '없음',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}
