import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import '../../../features/bible/data/bible_repository.dart';
import '../../../features/bible/domain/bible_verse.dart';
import '../../../features/update/update_service.dart';
import '../data/app_logger.dart';
import '../data/export_style_store.dart';
import '../data/offering_background_composer.dart';
import '../data/offering_design_store.dart';
import '../data/background_image_library.dart';
import '../data/font_library.dart';
import '../data/praise_repository.dart';
import '../data/python_bridge.dart';
import '../data/worship_conti_repository.dart';
import '../domain/worship_conti.dart';
import '../domain/export_style.dart';
import '../domain/offering_design.dart';
import '../domain/praise_song.dart';
import '../domain/slide_background.dart';
import '../domain/staging_item.dart';
import 'background_image_gallery.dart';
import 'offering_dialog.dart';
import 'offering_overlay_painter.dart';
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
    this.isAutoSpacer = false,
    this.imagePath,
    this.background,
  });
  final int stagingUid;
  final String mainText;
  final String englishText;
  final String? title;
  final bool isBible;
  final int pageIndexInItem; // 해당 아이템(곡/성경) 내의 페이지 인덱스
  final bool isBlank;
  // 곡/말씀 사이에 자동으로 삽입되는 여백 페이지. 별도 항목이 아니라
  // 앞 항목의 stagingUid를 그대로 빌려 쓰므로 수정 시 원본을 덮어쓰게 되어 편집 불가.
  final bool isAutoSpacer;
  // 외부 PPT에서 구운 페이지 이미지 경로. 있으면 텍스트 대신 이미지가 표시된다.
  final String? imagePath;
  // 이 슬라이드에만 적용되는 배경. null 이면 전역 디자인의 배경을 쓴다.
  final SlideBackground? background;
}

class _PraiseHomePageState extends State<PraiseHomePage>
    with SingleTickerProviderStateMixin {
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
  final OfferingDesignStore _offeringStore = OfferingDesignStore();
  final OfferingBackgroundComposer _offeringComposer =
      OfferingBackgroundComposer();
  final BackgroundImageLibrary _backgroundImages = BackgroundImageLibrary();
  final BibleRepository _bibleRepository = BibleRepository();
  final WorshipContiRepository _contiRepository = WorshipContiRepository();
  final TextEditingController _searchController = TextEditingController();
  final UpdateService _updateService = UpdateService();
  final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  UpdateInfo? _pendingUpdate;
  bool _isDownloadingUpdate = false;
  double _updateProgress = 0.0;
  bool _isCheckingUpdate = false;

  List<PraiseSong> _songs = const [];
  bool _searchInTitle = true;
  bool _searchInLyrics = true;
  final List<({int uid, StagingItem item})> _stagingItems = [];
  int _nextUid = 0;
  int? _previewStagingUid;
  bool _isSearchCollapsed = false;
  bool _isRibbonCollapsed = false;
  bool _isStagingCollapsed = false;
  // 최상위 탭: 0 편집(콘티·검색·디자인), 1 발표 보기
  late final TabController _mainTabController;
  final Map<String, String> _slideNotes = {};
  // 콘티 항목별 배경 오버라이드. 키는 항목 uid. 없는 항목은 전역 배경을 쓴다.
  // (헌금송만 다른 배경으로 띄우는 등 "일부만 다르게" 하기 위한 것)
  final Map<int, SlideBackground> _itemBackgrounds = {};
  // 헌금송 기본 디자인(배경·은행·계좌). 항목에 적용할 때 여기서 시작해 높낮이만 곡마다 맞춘다.
  OfferingDesign _offeringDesign = const OfferingDesign();
  // offering_design.json 이 있으면(한 번이라도 등록했으면) true. 배경·계좌 없이 등록해도 된다.
  bool _offeringRegistered = false;
  PresenterPointerMode _pointerMode = PresenterPointerMode.off;
  double _pointerSize = 100;
  // 관객 화면 확대. 확대 영역은 슬라이드와 같은 비율이라 크기 하나(가로 비율)면 된다.
  bool _isZoomOn = false;
  double _zoomScale = 0.45; // 영역 폭 / 슬라이드 폭 → 실제 배율은 1/이 값
  Offset _zoomCenter = const Offset(0.5, 0.5);
  // 콘솔이 트리에서 빠져도 남아야 하는 값들 (경과 시간, 분할 비율 등)
  final PresenterViewState _presenterView = PresenterViewState();
  double _workColumnRatio = 3 / 7;
  String _slideJumpBuffer = '';

  String? _selectedFolder;
  bool _isImporting = false;
  bool _isBibleImporting = false;
  bool _isExporting = false;
  int _storedCount = 0;
  int _bibleVerseCount = 0;
  int _bibleDataRevision = 0;
  // 다국어 선택지. 곡 임포트·성경 임포트 때 다시 읽는다.
  List<String> _subLanguages = const [PraiseRepository.defaultSubLanguage];
  List<String> _bibleVersions = const [];
  int _importTotalCount = 0;
  int _importSavedCount = 0;
  String? _importStatusText;
  ExportStyle _style = _defaultStyle;

  // 발표 모드
  int _currentSlideIndex = 0;
  bool _isPresentationOpen = false;
  bool _isBlackout = false;
  final Set<String> _deletedSlideKeys = {};

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

  // 발표 단축키를 받는 노드. autofocus 로 뺏지 않고 발표를 시작할 때만 가져온다.
  // Focus 가 아니라 FocusScope 인 이유: 검색창에서 포커스가 빠지면(다른 곳 클릭 등)
  // 포커스가 "가장 가까운 상위 스코프"로 돌아오는데, 그게 이 노드여야 단축키가 계속 먹는다.
  final FocusScopeNode _presentationFocusNode = FocusScopeNode(
    debugLabel: 'presentation-shortcuts',
    skipTraversal: true,
  );

  @override
  void initState() {
    super.initState();
    // 탭 전환에 애니메이션을 쓰지 않는다. TabBarView(PageView) 의 전환 애니메이션이
    // 중간에 멈추면(발표 창이 뜨면서 메인 창이 가려지는 등으로 프레임이 끊길 때)
    // 내부 카운터가 0으로 안 돌아와 탭이 영영 안 넘어간다.
    _mainTabController = TabController(
      length: 2,
      vsync: this,
      animationDuration: Duration.zero,
    )..addListener(_onMainTabChanged);
    _loadSongs();
    _loadSavedStyle();
    _loadOfferingDesign();
    _loadBibleCount();
    _loadSubLanguages();
    _searchController.addListener(_loadSongs);
    _checkForUpdates(isStartup: true);
    _mainPresentationChannel.setMethodCallHandler((call) async {
      if (call.method == 'presentationClosed' && mounted) {
        setState(_resetPresentationState);
      }
      return null;
    });
  }

  void _onMainTabChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _mainTabController
      ..removeListener(_onMainTabChanged)
      ..dispose();
    _presentationFocusNode.dispose();
    _searchController
      ..removeListener(_loadSongs)
      ..dispose();
    super.dispose();
  }

  // ── 계산된 프로퍼티 ───────────────────────────────────────────────────

  static String _slideKey(int stagingUid, int pageIndexInItem) =>
      '$stagingUid:$pageIndexInItem';

  // 콘티가 하나라도 있으면 발표 맨 앞에 무조건 삽입되는 빈 페이지.
  // 실제 스테이징 항목이 아니므로 uid는 절대 겹치지 않는 -1로 고정.
  static const int _leadingBlankUid = -1;

  Set<int?> get _selectedSongIds => _stagingItems
      .map((e) => e.item)
      .whereType<SongStagingItem>()
      .map((item) => item.song.id)
      .toSet();

  /// 삭제된 슬라이드와 수정된 가사를 반영한 실제 내보내기용 스테이징 아이템 목록.
  List<({int uid, StagingItem item})> get _effectiveStagingItems {
    final result = <({int uid, StagingItem item})>[];
    for (final entry in _stagingItems) {
      final uid = entry.uid;
      final item = entry.item;
      if (item is SongStagingItem) {
        final song = item.song;
        final pairs = song.pairedPages;
        final kept = [
          for (var j = 0; j < pairs.length; j++)
            if (!_deletedSlideKeys.contains(_slideKey(uid, j))) pairs[j],
        ];
        if (kept.isEmpty) continue;
        if (kept.length == pairs.length) {
          result.add(entry);
        } else {
          result.add((
            uid: uid,
            item: SongStagingItem(
              PraiseSong(
                id: song.id,
                fileName: song.fileName,
                title: song.title,
                lyrics: encodePages(kept.map((p) => p.korean)),
                englishLyrics: encodePages(kept.map((p) => p.english)),
              ),
            ),
          ));
        }
      } else if (item is ImageStagingItem) {
        final kept = [
          for (var j = 0; j < item.imagePaths.length; j++)
            if (!_deletedSlideKeys.contains(_slideKey(uid, j)))
              item.imagePaths[j],
        ];
        if (kept.isEmpty) continue;
        result.add(
          kept.length == item.imagePaths.length
              ? entry
              : (
                  uid: uid,
                  item: ImageStagingItem(
                    sourceName: item.sourceName,
                    imagePaths: kept,
                  ),
                ),
        );
      } else if (item is BibleStagingItem) {
        if (!_deletedSlideKeys.contains(_slideKey(uid, 0))) result.add(entry);
      } else if (item is BlankStagingItem) {
        result.add(entry); // 빈 페이지는 삭제 여부와 무관하게 항상 포함
      }
    }
    return result;
  }

  // 저장되는 항목은 삭제한 슬라이드가 빠진 상태(_effectiveStagingItems)라
  // 메모가 달린 페이지 번호도 그만큼 당겨서 맞춰 준다.
  Map<String, String> get _effectiveSlideNotes {
    if (_slideNotes.isEmpty) return const {};
    final out = <String, String>{};
    for (final entry in _stagingItems) {
      final uid = entry.uid;
      final item = entry.item;
      final total = switch (item) {
        SongStagingItem(:final song) => song.pairedPages.length,
        ImageStagingItem(:final imagePaths) => imagePaths.length,
        _ => 1,
      };
      var newIndex = 0;
      for (var j = 0; j < total; j++) {
        // 빈 페이지는 삭제 여부와 무관하게 항상 저장된다(_effectiveStagingItems 참고).
        if (item is! BlankStagingItem &&
            _deletedSlideKeys.contains(_slideKey(uid, j))) {
          continue;
        }
        final note = _slideNotes[_slideKey(uid, j)];
        if (note != null && note.isNotEmpty) {
          out[_slideKey(uid, newIndex)] = note;
        }
        newIndex++;
      }
    }
    return out;
  }

  // ── 데이터 로딩 ──────────────────────────────────────────────────────

  Future<void> _loadSongs() async {
    if (_searchController.value.composing != TextRange.empty) return;
    final songs = await _repository.searchSongs(
      _searchController.text,
      searchInTitle: _searchInTitle,
      searchInLyrics: _searchInLyrics,
    );
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

  Future<void> _loadOfferingDesign() async {
    final saved = await _offeringStore.load();
    if (!mounted || saved == null) return;
    setState(() {
      _offeringDesign = saved;
      _offeringRegistered = true;
    });
  }

  Future<void> _updateStyle(ExportStyle style) async {
    final languageChanged = style.subLanguage != _style.subLanguage;
    setState(() => _style = style);
    await _styleStore.save(style);
    if (languageChanged) await _reapplySubLanguage();
    await _sendCurrentSlide();
  }

  // ── 보조 언어 ────────────────────────────────────────────────────────
  //
  // 곡을 콘티에 담는 순간 선택한 언어의 가사를 englishLyrics 슬롯에 확정해 넣는다
  // (가사 스냅샷과 같은 방식). 그래서 슬라이드·미리보기·내보내기·발표 창은
  // 다국어를 전혀 몰라도 된다 — 원래 영어가 오던 자리에 그 언어가 올 뿐이다.

  Future<PraiseSong> _withSubLyrics(PraiseSong song) async {
    final sub = await _repository.subLyricsFor(song, _style.subLanguage);
    if (sub == song.englishLyrics) return song;
    return PraiseSong(
      id: song.id,
      fileName: song.fileName,
      title: song.title,
      lyrics: song.lyrics,
      englishLyrics: sub,
    );
  }

  /// 언어를 바꿨을 때 이미 담아 둔 곡들의 보조 가사를 다시 입힌다.
  /// 본문(한글) 가사는 슬라이드에서 고쳤을 수 있으므로 그대로 둔다.
  Future<void> _reapplySubLanguage() async {
    final updated = <(int, StagingItem)>[];
    for (var i = 0; i < _stagingItems.length; i++) {
      final item = _stagingItems[i].item;
      if (item is! SongStagingItem) continue;
      final matches = _songs.where((s) => s.id == item.song.id);
      if (matches.isEmpty) continue;
      final base = matches.first;
      final sub = await _repository.subLyricsFor(base, _style.subLanguage);
      if (sub == item.song.englishLyrics) continue;
      updated.add((
        i,
        SongStagingItem(
          PraiseSong(
            id: item.song.id,
            fileName: item.song.fileName,
            title: item.song.title,
            lyrics: item.song.lyrics,
            englishLyrics: sub,
          ),
        ),
      ));
    }
    if (updated.isEmpty || !mounted) return;
    setState(() {
      for (final (index, item) in updated) {
        _stagingItems[index] = (uid: _stagingItems[index].uid, item: item);
      }
      _clampCurrentSlideIndex();
    });
  }

  // ── 발표 모드 ────────────────────────────────────────────────────────────

  List<_SlideInfo> get _allSlides {
    final slides = <_SlideInfo>[];

    void tryAdd(_SlideInfo info) {
      if (!_deletedSlideKeys.contains(
        _slideKey(info.stagingUid, info.pageIndexInItem),
      )) {
        slides.add(info);
      }
    }

    if (_stagingItems.isNotEmpty) {
      slides.add(
        const _SlideInfo(
          stagingUid: _leadingBlankUid,
          mainText: '',
          englishText: '',
          title: null,
          isBible: false,
          pageIndexInItem: 0,
          isBlank: true,
          isAutoSpacer: true,
        ),
      );
    }

    for (var i = 0; i < _stagingItems.length; i++) {
      final entry = _stagingItems[i];
      final item = entry.item;
      final isLast = i == _stagingItems.length - 1;
      final nextIsBlank =
          !isLast && _stagingItems[i + 1].item is BlankStagingItem;
      // 항목에 배경 오버라이드가 걸려 있으면 그 항목이 만드는 모든 페이지가
      // (뒤에 자동으로 붙는 여백까지) 같은 배경을 쓴다.
      final background = _itemBackgrounds[entry.uid];

      if (item is BlankStagingItem) {
        tryAdd(
          _SlideInfo(
            stagingUid: entry.uid,
            mainText: item.mainText,
            englishText: item.englishText,
            title: null,
            isBible: false,
            pageIndexInItem: 0,
            isBlank: true,
            background: background,
          ),
        );
      } else if (item is SongStagingItem) {
        final song = item.song;
        final pairs = song.pairedPages;
        for (var j = 0; j < pairs.length; j++) {
          tryAdd(
            _SlideInfo(
              stagingUid: entry.uid,
              mainText: pairs[j].korean,
              englishText: pairs[j].english,
              title: song.title,
              isBible: false,
              pageIndexInItem: j,
              background: background,
            ),
          );
        }
        if (!isLast && !nextIsBlank) {
          tryAdd(
            _SlideInfo(
              stagingUid: entry.uid,
              mainText: '',
              englishText: '',
              title: null,
              isBible: false,
              pageIndexInItem: pairs.length,
              isBlank: true,
              isAutoSpacer: true,
              background: background,
            ),
          );
        }
      } else if (item is ImageStagingItem) {
        for (var j = 0; j < item.imagePaths.length; j++) {
          tryAdd(
            _SlideInfo(
              stagingUid: entry.uid,
              mainText: '',
              englishText: '',
              title: null,
              isBible: false,
              pageIndexInItem: j,
              imagePath: item.imagePaths[j],
              background: background,
            ),
          );
        }
        if (!isLast && !nextIsBlank) {
          tryAdd(
            _SlideInfo(
              stagingUid: entry.uid,
              mainText: '',
              englishText: '',
              title: null,
              isBible: false,
              pageIndexInItem: item.imagePaths.length,
              isBlank: true,
              isAutoSpacer: true,
              background: background,
            ),
          );
        }
      } else if (item is BibleStagingItem) {
        tryAdd(
          _SlideInfo(
            stagingUid: entry.uid,
            mainText: item.text,
            englishText: item.subText,
            title: item.reference,
            isBible: true,
            pageIndexInItem: 0,
            background: background,
          ),
        );
        // 말씀 다음이 말씀이면 빈 페이지 삽입 안 함
        if (!isLast &&
            !nextIsBlank &&
            _stagingItems[i + 1].item is! BibleStagingItem) {
          tryAdd(
            _SlideInfo(
              stagingUid: entry.uid,
              mainText: '',
              englishText: '',
              title: null,
              isBible: false,
              pageIndexInItem: 1,
              isBlank: true,
              isAutoSpacer: true,
              background: background,
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
      style: _style.withBackground(slide?.background),
      imagePath: slide?.imagePath,
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
      // 검색창에 커서가 있어도 발표 시작 시엔 단축키가 먹어야 한다.
      FocusManager.instance.primaryFocus?.unfocus();
      _presentationFocusNode.requestFocus();
      setState(() {
        _isPresentationOpen = true;
      });
      // 발표를 시작하면 발표 보기 탭으로. 편집 탭은 그대로 살아 있다.
      _mainTabController.index = 1;
      // 발표 전에 잡아둔 확대 영역을 새 창에 그대로 반영한다.
      await _sendZoom();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('발표 화면 열기 실패: $e')));
    }
  }

  void _resetPresentationState() {
    _isPresentationOpen = false;
    _isBlackout = false;
    // 발표 창을 닫으면 네이티브 쪽 확대 상태도 함께 사라진다(macOS 는 컨트롤러를
    // 통째로 버린다). Dart 쪽만 켜져 있으면 다음 발표에서 어긋나므로 같이 끈다.
    _isZoomOn = false;
  }

  Future<void> _closePresentation() async {
    try {
      await _presentationChannel.invokeMethod('closeWindow');
    } catch (_) {}
    if (mounted) setState(_resetPresentationState);
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

  // 발표자 보기에서 현재 슬라이드 위 좌표(0~1)를 관객 화면에 그대로 넘긴다.
  Offset? _lastPointerPos;

  Future<void> _sendPointer(Offset? position) async {
    _lastPointerPos = position;
    if (!_isPresentationOpen) return;
    try {
      await _presentationChannel.invokeMethod('pointer', {
        'mode': position == null ? 'off' : _pointerMode.name,
        'x': position?.dx ?? 0.0,
        'y': position?.dy ?? 0.0,
        'size': _pointerSize,
      });
    } catch (_) {}
  }

  Future<void> _sendZoom() async {
    if (!_isPresentationOpen) return;
    try {
      await _presentationChannel.invokeMethod('zoom', {
        'on': _isZoomOn,
        'x': _zoomCenter.dx - _zoomScale / 2,
        'y': _zoomCenter.dy - _zoomScale / 2,
        'size': _zoomScale,
      });
    } catch (_) {}
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
    if (info.imagePath != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('가져온 PPT 슬라이드는 내용을 수정할 수 없습니다.')),
      );
      return;
    }
    if (info.isAutoSpacer) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('여백 페이지는 수정할 수 없습니다. "빈 페이지 추가"로 만든 페이지만 수정할 수 있어요.'),
        ),
      );
      return;
    }

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
    if (info.isAutoSpacer) return;

    final stagingIndex = _stagingItems.indexWhere(
      (e) => e.uid == info.stagingUid,
    );
    if (stagingIndex == -1) return;

    final entry = _stagingItems[stagingIndex];
    final item = entry.item;

    StagingItem newItem;
    if (item is SongStagingItem) {
      final song = item.song;
      final pairs = List.of(song.pairedPages);

      if (info.pageIndexInItem < pairs.length) {
        pairs[info.pageIndexInItem] = (korean: newMain, english: newEnglish);
      }

      newItem = SongStagingItem(
        PraiseSong(
          id: song.id,
          fileName: song.fileName,
          title: song.title,
          lyrics: encodePages(pairs.map((p) => p.korean)),
          englishLyrics: encodePages(pairs.map((p) => p.english)),
        ),
      );
    } else if (item is BibleStagingItem) {
      newItem = BibleStagingItem(
        reference: item.reference,
        text: newMain,
        subText: newEnglish,
      );
    } else if (item is BlankStagingItem) {
      newItem = BlankStagingItem(mainText: newMain, englishText: newEnglish);
    } else {
      return;
    }

    setState(() {
      _stagingItems[stagingIndex] = (uid: entry.uid, item: newItem);
    });

    if (_currentSlideIndex == slideIndex) {
      _sendCurrentSlide();
    }
  }

  /// 콘티에 담긴 항목의 본문을 통째로 고친다. 이 콘티에서만 유효하고
  /// 저장된 곡(DB)은 건드리지 않는다 — 담을 때 만든 스냅샷만 바뀐다.
  Future<void> _editStagingItemText(int uid) async {
    final index = _stagingItems.indexWhere((e) => e.uid == uid);
    if (index == -1) return;
    final item = _stagingItems[index].item;
    if (item is ImageStagingItem) return;

    final (mainText, subText, isBible) = switch (item) {
      SongStagingItem(:final song) => (song.lyrics, song.englishLyrics, false),
      BibleStagingItem(:final text, :final subText) => (text, subText, true),
      BlankStagingItem(:final mainText, :final englishText) => (
        mainText,
        englishText,
        false,
      ),
      _ => ('', '', false),
    };

    final result = await showDialog<(String, String)?>(
      context: context,
      builder: (_) => _SlideQuickEditDialog(
        mainText: mainText,
        englishText: subText,
        isBible: isBible,
        title: item.displayTitle,
        heading: '이 콘티에서만 수정',
        helper: '빈 줄 1개 = 페이지 구분. 저장된 곡은 그대로 두고 이번 콘티에만 적용됩니다.',
        // 콘티에 담을 때 언어가 이미 확정되므로 여기서 언어를 고르지는 않는다.
        // 대신 지금 어느 언어 칸인지 이름으로 보여 준다 (바꾸려면 디자인 탭 '보조 언어').
        subLabel: isBible
            ? '보조 역본 본문 (비워도 됩니다)'
            : '${_style.subLanguage} 가사 (비워도 됩니다)',
        mainMaxLines: 12,
      ),
    );
    if (result == null || !mounted) return;
    final (newMain, newSub) = result;

    final StagingItem newItem = switch (item) {
      SongStagingItem(:final song) => SongStagingItem(
        PraiseSong(
          id: song.id,
          fileName: song.fileName,
          title: song.title,
          lyrics: normalizeEditableLyrics(newMain),
          englishLyrics: normalizeEditableLyrics(newSub),
        ),
      ),
      BibleStagingItem(:final reference) => BibleStagingItem(
        reference: reference,
        text: newMain,
        subText: newSub,
      ),
      BlankStagingItem() => BlankStagingItem(
        mainText: newMain,
        englishText: newSub,
      ),
      _ => item,
    };

    setState(() {
      _stagingItems[index] = (uid: uid, item: newItem);
      // 페이지 수가 달라지면 "발표 중 삭제" 표시가 엉뚱한 페이지를 가리킨다.
      _deletedSlideKeys.removeWhere((k) => k.startsWith('$uid:'));
      _clampCurrentSlideIndex();
    });
    if (_isPresentationOpen) await _sendCurrentSlide();
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

  void _deleteSlide(int slideIndex) {
    final slides = _allSlides;
    if (slideIndex >= slides.length) return;
    final info = slides[slideIndex];
    if (info.stagingUid == _leadingBlankUid) return;
    setState(() {
      _deletedSlideKeys.add(_slideKey(info.stagingUid, info.pageIndexInItem));
      _clampCurrentSlideIndex();
    });
    _sendCurrentSlide();
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

  /// 검색창 등 텍스트 입력 중이면 발표 단축키가 글자를 가로채면 안 된다.
  bool get _isTextFieldFocused {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null &&
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isPresentationOpen) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_isTextFieldFocused) return KeyEventResult.ignored;

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
      _closePresentation();
      return KeyEventResult.handled;
    }

    if (_slideJumpBuffer.isNotEmpty) {
      setState(() => _slideJumpBuffer = '');
    }

    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.space) {
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

  Future<void> _toggleSongSelection(PraiseSong song, bool isSelected) async {
    if (isSelected) {
      final alreadyAdded = _stagingItems.any(
        (e) =>
            e.item is SongStagingItem &&
            (e.item as SongStagingItem).song.id == song.id,
      );
      if (alreadyAdded) return;
      final staged = await _withSubLyrics(song);
      if (!mounted) return;
      setState(() {
        _stagingItems.add((uid: _nextUid++, item: SongStagingItem(staged)));
      });
      return;
    }
    setState(() {
      _stagingItems.removeWhere((e) {
        final item = e.item;
        final matches = item is SongStagingItem && item.song.id == song.id;
        if (matches) _itemBackgrounds.remove(e.uid);
        return matches;
      });
      _clampCurrentSlideIndex();
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
      final selectedIndex = _stagingItems.indexWhere(
        (e) => e.uid == _previewStagingUid,
      );
      final insertIndex = selectedIndex >= 0
          ? selectedIndex + 1
          : _stagingItems.length;
      _stagingItems.insert(insertIndex, (
        uid: uid,
        item: const BlankStagingItem(),
      ));
      _previewStagingUid = uid;
    });
  }

  /// 콘티 항목 하나의 배경만 따로 지정한다(헌금송만 다른 배경 등).
  /// 다이얼로그에서 "전역 배경 사용"으로 되돌리면 오버라이드가 지워진다.
  Future<void> _editItemBackground(int uid) async {
    final index = _stagingItems.indexWhere((e) => e.uid == uid);
    if (index < 0) return;
    final entry = _stagingItems[index];

    final result = await showDialog<({SlideBackground? background})>(
      context: context,
      builder: (ctx) => _ItemBackgroundDialog(
        item: entry.item,
        initial: _itemBackgrounds[uid],
        globalStyle: _style,
        swatches: _swatches,
        imageLibrary: _backgroundImages,
      ),
    );
    if (result == null || !mounted) return;

    setState(() {
      if (result.background == null) {
        _itemBackgrounds.remove(uid);
      } else {
        _itemBackgrounds[uid] = result.background!;
      }
      _previewStagingUid = uid;
    });
    await _sendCurrentSlide();
  }

  // ── 헌금송 ──────────────────────────────────────────────────────────

  /// 콘티 항목 [uid] 가 만드는 가사 페이지들. 헌금송 다이얼로그에서 띠와 겹쳐 본다.
  List<OfferingPreviewPage> _offeringPreviewPages(int? uid) {
    if (uid == null) return const [];
    return [
      for (final slide in _allSlides)
        if (slide.stagingUid == uid && !slide.isAutoSpacer)
          (
            mainText: slide.mainText,
            englishText: slide.englishText,
            title: slide.title,
          ),
    ];
  }

  /// 헌금송 기본 디자인 등록(배경 이미지·은행·계좌·색·크기·기본 높낮이).
  Future<void> _editOfferingDesign() async {
    final result = await showDialog<({OfferingDesign? design})>(
      context: context,
      builder: (ctx) => OfferingDialog(
        mode: OfferingDialogMode.defaults,
        initial: _offeringDesign,
        globalStyle: _style,
        imageLibrary: _backgroundImages,
        previewPages: _offeringPreviewPages(_previewStagingUid),
      ),
    );
    final design = result?.design;
    if (design == null || !mounted) return;
    setState(() {
      _offeringDesign = design;
      _offeringRegistered = true;
    });
    await _offeringStore.save(design);
    // 배경 이미지는 한 장만 둔다. 새로 등록했으면 이전 이미지를 지운다.
  }

  /// 콘티 항목 하나를 헌금송으로 표시한다.
  ///
  /// 헌금송 디자인을 PNG 한 장으로 구워 그 항목의 배경 오버라이드로 건다. 가사는
  /// 평소처럼 그 위에 그려지므로 미리보기·발표 창·PPTX 가 모두 그대로 따라온다.
  Future<void> _applyOffering(int uid) async {
    final index = _stagingItems.indexWhere((e) => e.uid == uid);
    if (index < 0) return;
    final entry = _stagingItems[index];
    final current = _itemBackgrounds[uid]?.offering;

    // 배경·계좌는 공통 설정이다. 아직 등록 전이면 등록부터 받는다.
    if (!_offeringRegistered) {
      await _editOfferingDesign();
      if (!mounted || !_offeringRegistered) return;
    }

    // 이미 헌금송이면 그 곡의 높낮이 그대로, 아니면 기본 디자인에서 시작한다.
    // 배경·계좌 등은 늘 최신 기본값을 따르게 한다(지난주에 계좌를 바꿨을 수 있다).
    final initial = current == null
        ? _offeringDesign
        : _offeringDesign.copyWith(bandCenterY: current.bandCenterY);

    final result = await showDialog<({OfferingDesign? design})>(
      context: context,
      builder: (ctx) => OfferingDialog(
        mode: OfferingDialogMode.item,
        initial: initial,
        globalStyle: _style,
        imageLibrary: _backgroundImages,
        itemTitle: entry.item is BlankStagingItem
            ? '빈 페이지'
            : entry.item.displayTitle,
        previewPages: _offeringPreviewPages(uid),
        canRemove: current != null,
      ),
    );
    if (result == null || !mounted) return;

    final design = result.design;
    if (design == null) {
      setState(() {
        _itemBackgrounds.remove(uid);
        _previewStagingUid = uid;
      });
      await _sendCurrentSlide();
      return;
    }

    // 높낮이는 곡마다 다르므로 기본값에는 높낮이를 빼고 나머지만 남긴다.
    final newDefaults = design.copyWith(
      bandCenterY: _offeringDesign.bandCenterY,
    );

    final String imagePath;
    try {
      imagePath = await _offeringComposer.compose(design);
    } catch (e, st) {
      await AppLogger.instance.error('헌금송 배경 생성 실패', e, st);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('헌금송 배경을 만들지 못했습니다: $e')));
      return;
    }
    if (!mounted) return;

    if (newDefaults != _offeringDesign) {
      _offeringDesign = newDefaults;
      await _offeringStore.save(newDefaults);
      if (!mounted) return;
    }

    // "가사는 띠 위쪽"이면 이 항목만 가사를 하단 기준 + 띠 윗선까지 올린 위치로 낸다.
    final placement = OfferingOverlayPainter.lyricsPlacement(design);
    setState(() {
      _itemBackgrounds[uid] = SlideBackground(
        color: design.backgroundColor,
        imagePath: imagePath,
        offering: design,
        lyricsPosition: placement.position,
        lyricsOffsetY: placement.offsetY,
      );
      _previewStagingUid = uid;
    });
    await _sendCurrentSlide();
  }

  /// 불러온 콘티의 헌금송 배경 PNG 가 사라졌으면(다른 PC·설정 폴더 정리 등) 저장된
  /// 디자인으로 다시 굽는다. 배경 이미지 원본까지 없으면 단색 위에 띠만 그려진다.
  Future<void> _restoreOfferingBackgrounds() async {
    final missing = _itemBackgrounds.entries
        .where(
          (e) =>
              e.value.isOffering &&
              !(e.value.hasImage && File(e.value.imagePath!).existsSync()),
        )
        .toList();
    if (missing.isEmpty) return;

    final restored = <int, SlideBackground>{};
    for (final entry in missing) {
      try {
        final path = await _offeringComposer.compose(entry.value.offering!);
        restored[entry.key] = entry.value.copyWith(imagePath: path);
      } catch (e, st) {
        await AppLogger.instance.error('헌금송 배경 복원 실패', e, st);
      }
    }
    if (!mounted || restored.isEmpty) return;
    setState(() => _itemBackgrounds.addAll(restored));
    await _sendCurrentSlide();
  }

  /// 로컬 PPT/PPTX를 골라 페이지별 이미지로 변환한 뒤 콘티에 넣는다.
  Future<void> _addPptImages() async {
    await FilePicker.skipEntitlementsChecks();
    final picked = await FilePicker.pickFiles(
      dialogTitle: '콘티에 추가할 PPT / PDF 파일 선택',
      type: FileType.custom,
      // PDF 는 LibreOffice 변환 없이 바로 페이지를 굽는다(ppt_tool.render 참고).
      allowedExtensions: ['ppt', 'pptx', 'pdf'],
      allowMultiple: true,
    );
    final paths = picked?.paths.whereType<String>().toList() ?? const [];
    if (paths.isEmpty || !mounted) return;

    final progress = ValueNotifier<String>('변환 중…');
    _showProgressDialog(progress);

    final items = <ImageStagingItem>[];
    String? errorMessage;
    try {
      for (var i = 0; i < paths.length; i++) {
        progress.value = paths.length == 1
            ? '${p.basename(paths[i])} 변환 중…'
            : '${paths.length}개 중 ${i + 1}번째 변환 중…';
        items.add(await _pythonBridge.renderPptToImages(paths[i]));
      }
    } on LibreOfficeMissingException catch (error) {
      errorMessage = error.toString();
    } catch (error, stack) {
      await AppLogger.instance.error('PPT/PDF 이미지 변환 실패', error, stack);
      errorMessage = '가져오기 실패: $error';
    }

    progress.dispose();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (items.isNotEmpty) {
      setState(() {
        final selectedIndex = _stagingItems.indexWhere(
          (e) => e.uid == _previewStagingUid,
        );
        var insertIndex = selectedIndex >= 0
            ? selectedIndex + 1
            : _stagingItems.length;
        for (final item in items) {
          final uid = _nextUid++;
          _stagingItems.insert(insertIndex++, (uid: uid, item: item));
          _previewStagingUid = uid;
        }
      });
    }

    if (errorMessage != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(errorMessage)));
    }
  }

  /// 닫기는 호출한 쪽에서 `Navigator.of(context, rootNavigator: true).pop()`.
  void _showProgressDialog(ValueNotifier<String> progress) {
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ValueListenableBuilder<String>(
                    valueListenable: progress,
                    builder: (_, text, _) => Text(text),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 악보 가사 추출 ──────────────────────────────────────────────────

  /// 악보 파일(이미지·PDF)을 골라 오선 아래 가사만 읽어 오고, 그대로 새 곡으로 만든다.
  Future<void> _importSheetMusic() async {
    await FilePicker.skipEntitlementsChecks();
    final picked = await FilePicker.pickFiles(
      dialogTitle: '가사를 추출할 악보 파일 선택 (이미지 · PDF)',
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'bmp', 'tif', 'tiff', 'pdf'],
      allowMultiple: true,
    );
    final paths = picked?.paths.whereType<String>().toList() ?? const [];
    if (paths.isEmpty || !mounted) return;

    final progress = ValueNotifier<String>('가사 읽는 중…');
    _showProgressDialog(progress);

    final texts = <String>[];
    String? errorMessage;
    var tesseractMissing = false;
    try {
      for (var i = 0; i < paths.length; i++) {
        progress.value = paths.length == 1
            ? '${p.basename(paths[i])} 읽는 중…'
            : '${paths.length}개 중 ${i + 1}번째 읽는 중…';
        final result = await _pythonBridge.extractSheetLyrics(paths[i]);
        if (result.lyrics.trim().isNotEmpty) {
          texts.add(result.lyrics.trim());
        }
      }
    } on TesseractMissingException {
      tesseractMissing = true;
    } catch (error, stack) {
      await AppLogger.instance.error('악보 가사 추출 실패', error, stack);
      errorMessage = '가사 추출 실패: $error';
    }

    progress.dispose();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (tesseractMissing) {
      await _showTesseractDialog();
      return;
    }
    if (errorMessage != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(errorMessage)));
      return;
    }
    if (texts.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('악보에서 가사를 찾지 못했습니다.')));
      return;
    }

    final title = p.basenameWithoutExtension(paths.first);
    // 악보 여러 장이면 장마다 빈 줄로 나눠 붙인다 (빈 줄 = 페이지 구분).
    final edited = await showDialog<String>(
      context: context,
      builder: (context) =>
          _SheetLyricsDialog(title: title, lyrics: texts.join('\n\n')),
    );
    if (edited == null || !mounted) return;

    await _openSongEditor(
      PraiseSong(
        id: null,
        fileName: title,
        title: title,
        lyrics: edited,
        englishLyrics: '',
      ),
    );
  }

  Future<void> _showTesseractDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tesseract OCR이 필요합니다'),
        content: const Text(
          '악보에서 가사를 읽으려면 글자 인식기(Tesseract)가 설치되어 있어야 합니다.\n\n'
          'macOS: 터미널에서 brew install tesseract tesseract-lang\n'
          'Windows: 설치 프로그램에서 한국어(Korean) 언어 데이터를 함께 선택하세요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('닫기'),
          ),
          FilledButton.icon(
            onPressed: () {
              _openUrl('https://github.com/tesseract-ocr/tesseract');
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.download_rounded),
            label: const Text('설치 안내 열기'),
          ),
        ],
      ),
    );
  }

  void _removeFromStaging(int uid) {
    setState(() {
      _stagingItems.removeWhere((e) => e.uid == uid);
      _deletedSlideKeys.removeWhere((k) => k.startsWith('$uid:'));
      _itemBackgrounds.remove(uid);
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
    if (!mounted) return;

    // 이 폴더 PPT 의 한글이 아닌 줄을 어느 언어로 저장할지.
    final language = await showDialog<String>(
      context: context,
      builder: (context) => _TextPromptDialog(
        title: '이 폴더의 보조 언어',
        label: '언어',
        hintText: '예: 영어, 일본어, 중국어',
        initialValue: PraiseRepository.defaultSubLanguage,
      ),
    );
    if (language == null) return;
    final subLanguage = language.trim().isEmpty
        ? PraiseRepository.defaultSubLanguage
        : language.trim();

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
      // 영어가 아닌 언어는 곡을 새로 만들지 않고 제목에 가사만 붙인다.
      // 같은 곡의 한글 가사가 파일마다 조금씩 달라 중복 곡이 생기는 걸 막는다.
      if (subLanguage != PraiseRepository.defaultSubLanguage) {
        await _repository.saveTranslations(subLanguage, {
          for (final song in result.songs)
            if (song.englishLyrics.trim().isNotEmpty)
              song.title: song.englishLyrics,
        });
        await _loadSubLanguages();
        final saved = await _repository.countTranslations(subLanguage);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.songs.isEmpty
                  ? '가져올 PPT/PPTX 파일을 찾지 못했습니다.'
                  : '$subLanguage 가사 $saved곡을 제목 기준으로 저장했습니다.',
            ),
          ),
        );
        if (result.libreofficeMissing && mounted) {
          await _showLibreofficeDialog();
        }
        return;
      }
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
    final versions = await _bibleRepository.getVersions();
    if (!mounted) return;
    setState(() {
      _bibleVerseCount = count;
      _bibleVersions = versions;
    });
  }

  Future<void> _loadSubLanguages() async {
    final languages = await _repository.getSubLanguages();
    if (!mounted) return;
    setState(() => _subLanguages = languages);
  }

  // ── 곡 모음 내보내기/가져오기 (다른 PC 와 합치기) ─────────────────────

  Future<void> _exportSongBundle() async {
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    await FilePicker.skipEntitlementsChecks();
    var path = await FilePicker.saveFile(
      dialogTitle: '곡 모음 내보내기',
      fileName: '곡모음_$stamp.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (path == null) return;
    if (p.extension(path).toLowerCase() != '.json') {
      path = p.setExtension(path, '.json');
    }
    try {
      final bundle = await _repository.exportSongBundle();
      await File(path).writeAsString(jsonEncode(bundle));
      if (!mounted) return;
      final count = (bundle['songs'] as List).length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('곡 $count개를 내보냈습니다: ${p.basename(path)}')),
      );
    } catch (error, stack) {
      await AppLogger.instance.error('곡 모음 내보내기 실패', error, stack);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('내보내기 실패: $error')));
    }
  }

  /// 다른 PC 에서 내보낸 곡 모음을 합친다. 같은 제목의 곡은 새로 넣지 않는다.
  Future<void> _importSongBundle() async {
    await FilePicker.skipEntitlementsChecks();
    final picked = await FilePicker.pickFiles(
      dialogTitle: '곡 모음 가져오기 (.json)',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    try {
      final bundle = jsonDecode(await File(path).readAsString());
      if (bundle is! Map<String, Object?>) {
        throw const FormatException('곡 모음 파일이 아닙니다.');
      }
      final result = await _repository.importSongBundle(bundle);
      await _loadSongs();
      await _loadSubLanguages();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '곡 ${result.addedCount}개 추가 · 같은 제목 ${result.skippedCount}개 건너뜀'
            '${result.subLyricsAddedCount > 0 ? ' · 번역 가사 ${result.subLyricsAddedCount}개 채움' : ''}',
          ),
        ),
      );
    } catch (error, stack) {
      await AppLogger.instance.error('곡 모음 가져오기 실패', error, stack);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is FormatException
                ? '곡 모음 파일이 아닙니다. "곡 모음 내보내기"로 만든 .json 을 골라 주세요.'
                : '가져오기 실패: $error',
          ),
        ),
      );
    }
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
      final versions = await _bibleRepository.getVersions();
      if (!mounted) return;
      setState(() {
        _bibleVerseCount = totalCount;
        _bibleVersions = versions;
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
    final version = await showDialog<String>(
      context: context,
      builder: (context) => _TextPromptDialog(
        title: '성경 버전 이름',
        label: '버전',
        hintText: '예: 개역개정, 새번역, KRV',
        initialValue: initialValue,
      ),
    );
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
        stagingItems: _effectiveStagingItems
            .map((e) => (item: e.item, background: _itemBackgrounds[e.uid]))
            .toList(),
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
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => _TextPromptDialog(
        title: '예배 콘티 저장',
        label: '콘티 이름',
        initialValue: defaultName,
      ),
    );

    if (name == null || name.isEmpty || !mounted) return;

    try {
      await _contiRepository.saveConti(
        name,
        _effectiveStagingItems,
        notes: _effectiveSlideNotes,
        backgrounds: _itemBackgrounds,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('"$name" 콘티를 저장했습니다.')));
    } catch (error, stack) {
      await AppLogger.instance.error('콘티 저장 실패', error, stack);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('콘티 저장 실패: $error')));
    }
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
      _deletedSlideKeys.clear();
      _slideNotes
        ..clear()
        ..addAll(result.notes);
      _itemBackgrounds
        ..clear()
        ..addAll(result.backgrounds);
      _nextUid += result.items.length;
      _previewStagingUid = result.items.isEmpty ? null : result.items.first.uid;
      _currentSlideIndex = 0;
    });
    unawaited(_restoreOfferingBackgrounds());

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
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('전체 삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _repository.clearAllSongs();
    if (!mounted) return;
    setState(() {
      _stagingItems.removeWhere((e) {
        final isSong = e.item is SongStagingItem;
        if (isSong) _itemBackgrounds.remove(e.uid);
        return isSong;
      });
      _deletedSlideKeys.clear();
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
    final translations = song == null
        ? const <String, String>{}
        : await _repository.translationsForTitle(song.title);
    if (!mounted) return;
    final result = await showDialog<SongEditResult>(
      context: context,
      builder: (context) => _SongEditDialog(
        song: song,
        translations: translations,
        languages: _subLanguages,
      ),
    );
    if (result == null || !mounted) return;
    final (edited, subLyrics) = result;
    // 악보에서 만든 초안은 song 이 있어도 id 가 없다 → 새 곡으로 넣는다.
    if (edited.id == null) {
      await _repository.insertSong(edited);
    } else {
      await _repository.updateSong(edited);
    }
    for (final entry in subLyrics.entries) {
      if (entry.key == PraiseRepository.defaultSubLanguage) continue;
      await _repository.saveTranslations(entry.key, {
        edited.title: entry.value,
      });
    }
    await _loadSubLanguages();
    if (edited.id != null && mounted) {
      _replaceStagedSong(await _withSubLyrics(edited));
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
    ({int uid, StagingItem item})? previewEntry;
    for (final entry in _stagingItems) {
      if (entry.uid == _previewStagingUid) {
        previewEntry = entry;
        break;
      }
    }
    previewEntry ??= _stagingItems.isEmpty ? null : _stagingItems.first;
    final previewItem = previewEntry?.item;
    // 미리보기는 그 항목의 배경 오버라이드까지 반영해야 실제 발표 화면과 같다.
    final previewBackground = previewEntry == null
        ? null
        : _itemBackgrounds[previewEntry.uid];

    final slides = _allSlides;
    return FocusScope(
      node: _presentationFocusNode,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // 디자인은 위쪽 리본으로 올라갔으므로 콘티·검색 두 열만 들어가면 된다.
                    final isWide = constraints.maxWidth >= 900;
                    return Column(
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
                          onImportPptPressed: _addPptImages,
                          onImportSheetPressed: _importSheetMusic,
                          onExportSongsPressed: _exportSongBundle,
                          onImportSongsPressed: _importSongBundle,
                          onExtractLogsPressed: _showExtractLogsDialog,
                          isCheckingUpdate: _isCheckingUpdate,
                          hasUpdate: _pendingUpdate != null,
                          onCheckUpdate: _checkForUpdates,
                        ),
                        const SizedBox(height: 10),
                        Builder(
                          builder: (context) {
                            // 편집 탭에는 콘티만. 발표 제어·슬라이드 순서는 발표 보기 탭으로 갔다.
                            final stagingPanel = _StagingPanel(
                              stagingItems: _stagingItems,
                              selectedUid: _previewStagingUid,
                              backgrounds: _itemBackgrounds,
                              onEditBackground: _editItemBackground,
                              onOffering: _applyOffering,
                              onEditText: _editStagingItemText,
                              onReorder: _onStagingReorder,
                              onRemove: _removeFromStaging,
                              isCollapsed: _isStagingCollapsed,
                              onToggleCollapsed: () => setState(
                                () =>
                                    _isStagingCollapsed = !_isStagingCollapsed,
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
                            );
                            final presentationAndStagingColumn = Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_isStagingCollapsed)
                                  stagingPanel
                                else
                                  Expanded(child: stagingPanel),
                              ],
                            );

                            final presenterConsole = _PresenterConsole(
                              slides: slides,
                              currentIndex: _currentSlideIndex.clamp(
                                0,
                                slides.isEmpty ? 0 : slides.length - 1,
                              ),
                              style: _style,
                              isPresentationOpen: _isPresentationOpen,
                              isBlackout: _isBlackout,
                              notes: _slideNotes,
                              onNoteChanged: (key, note) {
                                if (key.isEmpty) return;
                                setState(() {
                                  if (note.isEmpty) {
                                    _slideNotes.remove(key);
                                  } else {
                                    _slideNotes[key] = note;
                                  }
                                });
                              },
                              onSlideSelected: _goToSlide,
                              onSlideEdit: _editSlide,
                              onSlideDelete: _deleteSlide,
                              onPrev: _prevSlide,
                              onNext: _nextSlide,
                              onToggleBlackout: _toggleBlackout,
                              pointerMode: _pointerMode,
                              pointerSize: _pointerSize,
                              onPointerModeChanged: (m) {
                                setState(() => _pointerMode = m);
                                // 마지막 좌표로 바로 다시 그린다. 안 그러면 마우스를
                                // 다시 움직일 때까지 예전 모양이 남는다.
                                _sendPointer(
                                  m == PresenterPointerMode.off
                                      ? null
                                      : _lastPointerPos,
                                );
                              },
                              onPointerSizeChanged: (v) {
                                setState(() => _pointerSize = v);
                                _sendPointer(_lastPointerPos);
                              },
                              onPointerMove: _sendPointer,
                              isZoomOn: _isZoomOn,
                              zoomScale: _zoomScale,
                              zoomCenter: _zoomCenter,
                              onZoomToggled: () {
                                setState(() => _isZoomOn = !_isZoomOn);
                                _sendZoom();
                              },
                              viewState: _presenterView,
                              onZoomChanged: (center, scale) {
                                setState(() {
                                  _zoomCenter = center;
                                  _zoomScale = scale;
                                });
                                _sendZoom();
                              },
                            );

                            final searchColumn = _SearchAndBiblePanel(
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
                              bibleSubVersion: _style.bibleSubVersion,
                              onCollapse: () =>
                                  setState(() => _isSearchCollapsed = true),
                              searchInTitle: _searchInTitle,
                              searchInLyrics: _searchInLyrics,
                              onSearchInTitleChanged: (v) => setState(() {
                                _searchInTitle = v;
                                _loadSongs();
                              }),
                              onSearchInLyricsChanged: (v) => setState(() {
                                _searchInLyrics = v;
                                _loadSongs();
                              }),
                            );

                            final collapsedSearchStrip = _CollapsedPanelStrip(
                              label: '찬양 검색',
                              isVertical: isWide,
                              onExpand: () =>
                                  setState(() => _isSearchCollapsed = false),
                            );

                            // 리본이 따라갈 항목 종류. 편집 탭은 콘티에서 고른 항목,
                            // 발표 보기는 지금 나가는 슬라이드를 기준으로 한다.
                            final isPresenterTab =
                                _mainTabController.index == 1;
                            final _RibbonTab? ribbonContext;
                            if (isPresenterTab && slides.isNotEmpty) {
                              final slide =
                                  slides[_currentSlideIndex.clamp(
                                    0,
                                    slides.length - 1,
                                  )];
                              ribbonContext =
                                  slide.imagePath != null || slide.isBlank
                                  ? null
                                  : slide.isBible
                                  ? _RibbonTab.bible
                                  : _RibbonTab.song;
                            } else {
                              ribbonContext = switch (previewItem) {
                                SongStagingItem() => _RibbonTab.song,
                                BibleStagingItem() => _RibbonTab.bible,
                                _ => null,
                              };
                            }

                            final designRibbon = _DesignRibbon(
                              style: _style,
                              swatches: _swatches,
                              textSwatches: _textSwatches,
                              subLanguages: _subLanguages,
                              bibleVersions: _bibleVersions,
                              onStyleChanged: _updateStyle,
                              isCollapsed: _isRibbonCollapsed,
                              onCollapsedChanged: (v) =>
                                  setState(() => _isRibbonCollapsed = v),
                              contextTab: ribbonContext,
                              // 발표 보기는 현재 슬라이드가 이미 크게 보인다.
                              preview: isPresenterTab
                                  ? null
                                  : _PreviewBox(
                                      style: _style.withBackground(
                                        previewBackground,
                                      ),
                                      previewItem: previewItem,
                                    ),
                              isExporting: _isExporting,
                              onExportPressed: _exportPresentation,
                              offeringDesign: _offeringDesign,
                              onEditOffering: _editOfferingDesign,
                              imageLibrary: _backgroundImages,
                            );

                            // ── 콘티 + 검색 (가로 크기 조절 가능) ──
                            final workspace = isWide
                                ? _ResizableColumnSplit(
                                    ratio: _workColumnRatio,
                                    onRatioChanged: (v) =>
                                        setState(() => _workColumnRatio = v),
                                    first: presentationAndStagingColumn,
                                    second: searchColumn,
                                    isSecondCollapsed: _isSearchCollapsed,
                                    collapsedSecond: collapsedSearchStrip,
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        flex: 3,
                                        child: presentationAndStagingColumn,
                                      ),
                                      const SizedBox(height: 20),
                                      if (_isSearchCollapsed)
                                        collapsedSearchStrip
                                      else
                                        Expanded(flex: 4, child: searchColumn),
                                    ],
                                  );

                            return Expanded(
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TabBar(
                                          controller: _mainTabController,
                                          isScrollable: true,
                                          tabAlignment: TabAlignment.start,
                                          tabs: const [
                                            Tab(text: '편집'),
                                            Tab(text: '발표 보기'),
                                          ],
                                        ),
                                      ),
                                      if (_isPresentationOpen) ...[
                                        Text(
                                          _slideJumpBuffer.isEmpty
                                              ? '발표 중 ${_currentSlideIndex + 1} / ${slides.length}'
                                              : '이동 → $_slideJumpBuffer',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                            color: _slideJumpBuffer.isEmpty
                                                ? null
                                                : Theme.of(
                                                    context,
                                                  ).colorScheme.primary,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        FilledButton.tonalIcon(
                                          onPressed: _closePresentation,
                                          icon: const Icon(
                                            Icons.stop_rounded,
                                            size: 17,
                                          ),
                                          label: const Text('발표 종료'),
                                          style: FilledButton.styleFrom(
                                            backgroundColor: Theme.of(
                                              context,
                                            ).colorScheme.errorContainer,
                                            foregroundColor: Theme.of(
                                              context,
                                            ).colorScheme.onErrorContainer,
                                          ),
                                        ),
                                      ] else
                                        FilledButton.icon(
                                          onPressed: slides.isEmpty
                                              ? null
                                              : _openPresentation,
                                          icon: const Icon(
                                            Icons.play_arrow_rounded,
                                            size: 18,
                                          ),
                                          label: const Text('발표 시작'),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  designRibbon,
                                  const SizedBox(height: 12),
                                  // TabBarView 가 아니라 IndexedStack 인 이유:
                                  // 드래그 전환은 어차피 막아 뒀고, PageView 스크롤을
                                  // 거치지 않아야 탭 전환이 항상 즉시 먹는다.
                                  // (디자인 패널 탭도 같은 방식)
                                  Expanded(
                                    child: IndexedStack(
                                      index: _mainTabController.index,
                                      sizing: StackFit.expand,
                                      children: [
                                        // 숨은 탭은 그려지지 않을 뿐 살아 있다.
                                        // 검색창/메모창에 포커스가 남으면 발표 단축키가
                                        // 안 보이는 입력칸으로 빨려 들어가므로 잘라낸다.
                                        for (final (i, child) in [
                                          workspace,
                                          presenterConsole,
                                        ].indexed)
                                          ExcludeFocus(
                                            excluding:
                                                i != _mainTabController.index,
                                            child: child,
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),
              Positioned(
                right: 10,
                bottom: 2,
                child: FutureBuilder<PackageInfo>(
                  future: _packageInfo,
                  builder: (context, snapshot) => Text(
                    snapshot.hasData
                        ? '${snapshot.data!.appName} v${snapshot.data!.version}'
                        : '',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PanelResizeHandle extends StatelessWidget {
  const _PanelResizeHandle({
    required this.crossExtent,
    required this.color,
    required this.onDrag,
    this.axis = Axis.vertical,
  });

  final double crossExtent;
  final Color color;
  final ValueChanged<double> onDrag;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final isRowSplit = axis == Axis.vertical;
    return MouseRegion(
      cursor: isRowSplit
          ? SystemMouseCursors.resizeRow
          : SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: isRowSplit
            ? (details) => onDrag(details.delta.dy)
            : null,
        onHorizontalDragUpdate: isRowSplit
            ? null
            : (details) => onDrag(details.delta.dx),
        child: SizedBox(
          height: isRowSplit ? crossExtent : null,
          width: isRowSplit ? null : crossExtent,
          child: Center(
            child: Container(
              width: isRowSplit ? 72 : 4,
              height: isRowSplit ? 4 : 72,
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

// ── ResizableColumnSplit ──────────────────────────────────────────────────
// 발표·콘티 열과 검색 열 사이를 가로로 드래그해 너비를 나눈다.

class _ResizableColumnSplit extends StatelessWidget {
  const _ResizableColumnSplit({
    required this.ratio,
    required this.onRatioChanged,
    required this.first,
    required this.second,
    required this.isSecondCollapsed,
    required this.collapsedSecond,
  });

  final double ratio;
  final ValueChanged<double> onRatioChanged;
  final Widget first;
  final Widget second;
  final bool isSecondCollapsed;
  final Widget collapsedSecond;

  static const double _dividerWidth = 18;
  static const double _minColumnWidth = 280;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (isSecondCollapsed) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: first),
          const SizedBox(width: 20),
          collapsedSecond,
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = (constraints.maxWidth - _dividerWidth)
            .clamp(0.0, double.infinity)
            .toDouble();
        final r = clampSplitRatioForLayout(
          ratio: ratio,
          available: available,
          firstMin: _minColumnWidth,
          secondMin: _minColumnWidth,
          minRatioMin: 0.2,
          minRatioMax: 0.5,
          maxRatioMin: 0.5,
          maxRatioMax: 0.8,
        );
        final firstWidth = available * r;
        final secondWidth = available - firstWidth;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: firstWidth, child: first),
            _PanelResizeHandle(
              crossExtent: _dividerWidth,
              axis: Axis.horizontal,
              color: cs.outlineVariant,
              onDrag: (delta) {
                if (available <= 0) return;
                final next = clampSplitRatioForLayout(
                  ratio: r + delta / available,
                  available: available,
                  firstMin: _minColumnWidth,
                  secondMin: _minColumnWidth,
                  minRatioMin: 0.2,
                  minRatioMax: 0.5,
                  maxRatioMin: 0.5,
                  maxRatioMax: 0.8,
                );
                onRatioChanged(next);
              },
            ),
            SizedBox(width: secondWidth, child: second),
          ],
        );
      },
    );
  }
}

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
    required this.onImportPptPressed,
    required this.onImportSheetPressed,
    required this.onExportSongsPressed,
    required this.onImportSongsPressed,
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
  final VoidCallback onImportPptPressed;
  final VoidCallback onImportSheetPressed;
  final VoidCallback onExportSongsPressed;
  final VoidCallback onImportSongsPressed;
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
          // 다른 헤더 버튼(반투명 흰색)과 구분되도록 단색 앰버 + 짙은 글자.
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFFC24B),
              foregroundColor: const Color(0xFF10333D),
              textStyle: const TextStyle(fontWeight: FontWeight.w700),
            ),
            onPressed: onImportPptPressed,
            icon: const Icon(Icons.slideshow_rounded, size: 18),
            label: const Text('PPT · PDF 가져오기'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.22),
              foregroundColor: Colors.white,
            ),
            onPressed: onImportSheetPressed,
            icon: const Icon(Icons.music_note_rounded, size: 16),
            label: const Text('악보 가져오기'),
          ),
          const SizedBox(width: 8),
          // 다른 PC 의 곡과 합치기. 같은 제목은 중복으로 넣지 않는다.
          PopupMenuButton<VoidCallback>(
            tooltip: '다른 PC 와 곡 합치기',
            onSelected: (action) => action(),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: onExportSongsPressed,
                child: const ListTile(
                  dense: true,
                  leading: Icon(Icons.file_upload_outlined),
                  title: Text('곡 모음 내보내기'),
                ),
              ),
              PopupMenuItem(
                value: onImportSongsPressed,
                child: const ListTile(
                  dense: true,
                  leading: Icon(Icons.file_download_outlined),
                  title: Text('곡 모음 가져오기'),
                  subtitle: Text('같은 제목은 건너뜁니다'),
                ),
              ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sync_alt_rounded, size: 16, color: Colors.white),
                  SizedBox(width: 6),
                  Text('곡 모음', style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
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
    required this.backgrounds,
    required this.onEditBackground,
    required this.onOffering,
    required this.onEditText,
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
  // 항목별 배경 오버라이드. 키가 있는 항목만 전역 배경 대신 이 배경으로 나간다.
  final Map<int, SlideBackground> backgrounds;
  final ValueChanged<int> onEditBackground;
  // 찬양(또는 빈 페이지)을 헌금송 배경으로 표시
  final ValueChanged<int> onOffering;
  final ValueChanged<int> onEditText;
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

    // 좁은 패널에서도 넘치지 않게 아이콘 버튼 기본 48px 탭 타깃을 32px로 줄인다.
    // (그러지 않으면 저장/불러오기 버튼이 오른쪽으로 잘려 사라진다)
    final compactIcon = IconButton.styleFrom(
      minimumSize: const Size(32, 32),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

    final accentShape = RoundedRectangleBorder(
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      side: BorderSide(color: cs.primary.withValues(alpha: 0.35), width: 1.4),
    );

    if (isCollapsed) {
      return Card(
        shape: accentShape,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '예배 콘티',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: cs.primary,
                  ),
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
      shape: accentShape,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    '예배 콘티',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: cs.primary,
                    ),
                  ),
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
                  style: compactIcon,
                  color: cs.onSurfaceVariant,
                  onPressed: onAddBlank,
                ),
                IconButton(
                  icon: const Icon(Icons.save_outlined, size: 18),
                  tooltip: '콘티 저장',
                  style: compactIcon,
                  color: cs.onSurfaceVariant,
                  onPressed: onSaveConti,
                ),
                IconButton(
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  tooltip: '콘티 불러오기',
                  style: compactIcon,
                  color: cs.onSurfaceVariant,
                  onPressed: onLoadConti,
                ),
                IconButton(
                  icon: const Icon(Icons.expand_less_rounded),
                  iconSize: 18,
                  tooltip: '예배 콘티 접기',
                  style: compactIcon,
                  color: cs.onSurfaceVariant,
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
                      onReorderItem: onReorder,
                      proxyDecorator: (child, index, animation) {
                        return AnimatedBuilder(
                          animation: animation,
                          builder: (context, child) => Material(
                            elevation: 4,
                            shadowColor: Colors.black26,
                            borderRadius: BorderRadius.circular(4),
                            color: Theme.of(context).colorScheme.surface,
                            child: child,
                          ),
                          child: child,
                        );
                      },
                      itemBuilder: (context, index) {
                        final entry = stagingItems[index];
                        final item = entry.item;
                        final isBible = item is BibleStagingItem;
                        final isBlank = item is BlankStagingItem;
                        final cs = Theme.of(context).colorScheme;
                        final isSelected = entry.uid == selectedUid;
                        final background = backgrounds[entry.uid];
                        return Material(
                          key: ValueKey(entry.uid),
                          color: isSelected
                              ? cs.primary.withValues(alpha: 0.08)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => onSelect(entry.uid),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 6,
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
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
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Row(
                                          children: [
                                            if (isBible)
                                              Container(
                                                margin: const EdgeInsets.only(
                                                  right: 6,
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 5,
                                                      vertical: 1,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.blue.shade100,
                                                  borderRadius:
                                                      BorderRadius.circular(4),
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
                                                margin: const EdgeInsets.only(
                                                  right: 6,
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 5,
                                                      vertical: 1,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.grey.shade200,
                                                  borderRadius:
                                                      BorderRadius.circular(4),
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
                                            if (background != null)
                                              _BackgroundBadge(
                                                background: background,
                                              ),
                                            Flexible(
                                              child: Text(
                                                isBlank
                                                    ? ''
                                                    : item.displayTitle,
                                                overflow: TextOverflow.ellipsis,
                                                style: isBlank
                                                    ? TextStyle(
                                                        color: Colors
                                                            .grey
                                                            .shade500,
                                                      )
                                                    : null,
                                              ),
                                            ),
                                          ],
                                        ),
                                        if (item.previewText.isNotEmpty)
                                          Text(
                                            item.previewText,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Colors.grey,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  // 버튼이 여럿이라 기본 48px 탭 타깃이면 제목이 밀린다.
                                  if (item is! ImageStagingItem)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.edit_note_rounded,
                                        size: 20,
                                      ),
                                      tooltip: '이 콘티에서만 내용 수정',
                                      style: compactIcon,
                                      onPressed: () => onEditText(entry.uid),
                                    ),
                                  if (item is SongStagingItem ||
                                      item is BlankStagingItem)
                                    IconButton(
                                      icon: Icon(
                                        background?.isOffering == true
                                            ? Icons.volunteer_activism
                                            : Icons.volunteer_activism_outlined,
                                        size: 18,
                                        color: background?.isOffering == true
                                            ? cs.primary
                                            : cs.onSurfaceVariant,
                                      ),
                                      tooltip: background?.isOffering == true
                                          ? '헌금송 높낮이·디자인 수정'
                                          : '헌금송으로 표시',
                                      style: compactIcon,
                                      onPressed: () => onOffering(entry.uid),
                                    ),
                                  IconButton(
                                    icon: Icon(
                                      background == null
                                          ? Icons.wallpaper_rounded
                                          : Icons.wallpaper,
                                      size: 19,
                                      color: background == null
                                          ? cs.onSurfaceVariant
                                          : cs.primary,
                                    ),
                                    tooltip: background == null
                                        ? '이 항목만 배경 바꾸기'
                                        : '이 항목의 배경 수정',
                                    style: compactIcon,
                                    onPressed: () =>
                                        onEditBackground(entry.uid),
                                  ),
                                  const SizedBox(width: 4),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 20,
                                    ),
                                    tooltip: '제거',
                                    style: compactIcon,
                                    onPressed: () => onRemove(entry.uid),
                                  ),
                                  ReorderableDragStartListener(
                                    index: index,
                                    child: const Padding(
                                      padding: EdgeInsets.all(8),
                                      child: Icon(
                                        Icons.drag_handle_rounded,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
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
    required this.bibleSubVersion,
    required this.onCollapse,
    required this.searchInTitle,
    required this.searchInLyrics,
    required this.onSearchInTitleChanged,
    required this.onSearchInLyricsChanged,
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
  final String bibleSubVersion;
  final VoidCallback onCollapse;
  final bool searchInTitle;
  final bool searchInLyrics;
  final ValueChanged<bool> onSearchInTitleChanged;
  final ValueChanged<bool> onSearchInLyricsChanged;

  @override
  State<_SearchAndBiblePanel> createState() => _SearchAndBiblePanelState();
}

class _SearchAndBiblePanelState extends State<_SearchAndBiblePanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    // 애니메이션 0: 프레임이 끊기면(발표 창이 메인 창을 가릴 때 등) TabBarView 의
    // 전환 애니메이션이 안 끝나 탭이 영영 안 넘어간다. 메인 탭과 같은 이유.
    _tabController = TabController(
      length: 2,
      vsync: this,
      animationDuration: Duration.zero,
    );
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

    return Card(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: tabBar),
              IconButton(
                icon: const Icon(Icons.chevron_right_rounded),
                tooltip: '검색 패널 접기',
                color: cs.onSurfaceVariant,
                onPressed: widget.onCollapse,
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
                  searchInTitle: widget.searchInTitle,
                  searchInLyrics: widget.searchInLyrics,
                  onSearchInTitleChanged: widget.onSearchInTitleChanged,
                  onSearchInLyricsChanged: widget.onSearchInLyricsChanged,
                ),
                _BibleSearchPanel(
                  bibleRepository: widget.bibleRepository,
                  bibleVerseCount: widget.bibleVerseCount,
                  bibleDataRevision: widget.bibleDataRevision,
                  onAddItem: widget.onAddBibleItem,
                  subVersion: widget.bibleSubVersion,
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
    required this.searchInTitle,
    required this.searchInLyrics,
    required this.onSearchInTitleChanged,
    required this.onSearchInLyricsChanged,
  });

  final TextEditingController controller;
  final List<PraiseSong> songs;
  final Set<int?> selectedSongIds;
  final void Function(PraiseSong song, bool isSelected) onChanged;
  final VoidCallback onDeleteSelected;
  final VoidCallback onClearAll;
  final VoidCallback onAddSong;
  final ValueChanged<PraiseSong> onEditSong;
  final bool searchInTitle;
  final bool searchInLyrics;
  final ValueChanged<bool> onSearchInTitleChanged;
  final ValueChanged<bool> onSearchInLyricsChanged;

  @override
  Widget build(BuildContext context) {
    final hintText = switch ((searchInTitle, searchInLyrics)) {
      (true, true) => '제목 또는 가사로 검색',
      (true, false) => '제목으로 검색',
      (false, true) => '가사로 검색',
      _ => '검색',
    };

    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search_rounded),
                    hintText: hintText,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: onAddSong,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('새 곡'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _SearchFilterChip(
                label: '제목',
                value: searchInTitle,
                onChanged: onSearchInTitleChanged,
              ),
              const SizedBox(width: 6),
              _SearchFilterChip(
                label: '가사',
                value: searchInLyrics,
                onChanged: onSearchInLyricsChanged,
              ),
              const SizedBox(width: 10),
              Text(
                '${songs.length}건',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 19),
                tooltip: '선택 삭제',
                visualDensity: VisualDensity.compact,
                onPressed: selectedSongIds.isEmpty ? null : onDeleteSelected,
              ),
              IconButton(
                icon: const Icon(Icons.restart_alt_rounded, size: 19),
                tooltip: 'DB 초기화',
                visualDensity: VisualDensity.compact,
                color: cs.error,
                onPressed: songs.isEmpty ? null : onClearAll,
              ),
            ],
          ),
          const SizedBox(height: 6),
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
                        selected: selected,
                        selectedTileColor: cs.primaryContainer.withValues(
                          alpha: 0.25,
                        ),
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        onChanged: (value) => onChanged(song, value ?? false),
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(song.title),
                        subtitle: Text(
                          song.pages.join(' / '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                        ),
                        secondary: IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          tooltip: '가사 수정',
                          visualDensity: VisualDensity.compact,
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

// ── SearchFilterChip ──────────────────────────────────────────────────────

class _SearchFilterChip extends StatelessWidget {
  const _SearchFilterChip({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: value ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: value ? cs.primary : cs.outline.withValues(alpha: 0.4),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: value ? cs.onPrimaryContainer : cs.onSurfaceVariant,
          ),
        ),
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
    required this.subVersion,
  });

  final BibleRepository bibleRepository;
  final int bibleVerseCount;
  final int bibleDataRevision;
  final void Function(BibleStagingItem) onAddItem;

  /// 본문 아래 함께 담을 보조 역본. 빈 문자열이면 담지 않는다.
  final String subVersion;

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

  Future<void> _addSelected() async {
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

    // 보조 역본 본문을 절 번호로 찾아 쓸 수 있게 미리 한 장(章)을 통째로 읽는다.
    final subTexts = await _loadSubVerses(version, selected.first.chapter);

    for (final chunk in chunks) {
      final verseNums = chunk.map((v) => v.verse).toList();
      final ref = _buildReference(
        version,
        _selectedBook!,
        chunk.first.chapter,
        verseNums,
      );
      final text = chunk.map((v) => '${v.verse}. ${v.text}').join('\n');
      final subText = subTexts == null
          ? ''
          : chunk
                .where((v) => subTexts.containsKey(v.verse))
                .map((v) => '${v.verse}. ${subTexts[v.verse]}')
                .join('\n');
      widget.onAddItem(
        BibleStagingItem(reference: ref, text: text, subText: subText),
      );
    }
    if (!mounted) return;
    setState(() => _selectedVerseIds.clear());

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${chunks.length}페이지 추가됨')));
  }

  /// 보조 역본의 같은 장을 {절 번호: 본문} 으로. 못 찾으면 null.
  Future<Map<int, String>?> _loadSubVerses(String version, int chapter) async {
    final sub = widget.subVersion;
    if (sub.isEmpty || sub == version) return null;
    final book = await widget.bibleRepository.mapBookName(
      bookName: _selectedBook!,
      fromVersion: version,
      inVersion: sub,
    );
    if (book == null) return null;
    final verses = await widget.bibleRepository.getVerses(
      version: sub,
      bookName: book,
      chapter: chapter,
    );
    return {for (final v in verses) v.verse: v.text};
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

// 색 입력 다이얼로그(리본·항목 배경)가 같이 쓰는 hex 입력 규칙.
final TextInputFormatter _hexInputFormatter = FilteringTextInputFormatter.allow(
  RegExp(r'[0-9a-fA-F#]'),
);

/// 리본 탭. 찬양/성경은 콘티에서 고른 항목(발표 보기에서는 현재 슬라이드)에 따라
/// 자동으로 전환된다.
enum _RibbonTab {
  common('공통', Icons.wallpaper_outlined),
  song('찬양', Icons.music_note_rounded),
  bible('성경 본문', Icons.menu_book_rounded);

  const _RibbonTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// 상단 "디자인" 리본 (PowerPoint 리본처럼 접을 수 있다).
///
/// 편집·발표 보기 두 탭이 같이 쓴다. 스타일을 바꾸면 `_updateStyle` 이 발표 창에
/// 현재 페이지를 다시 보내므로 발표 중에도 바로 반영된다.
///
/// 한 묶음(`_RibbonGroup`) = 최대 3줄짜리 열 여러 개 + 아래쪽 묶음 이름.
/// 한 줄 = `_PropertyRow`(왼쪽 라벨 + 오른쪽 컨트롤).
class _DesignRibbon extends StatefulWidget {
  const _DesignRibbon({
    required this.style,
    required this.swatches,
    required this.textSwatches,
    required this.subLanguages,
    required this.bibleVersions,
    required this.onStyleChanged,
    required this.isCollapsed,
    required this.onCollapsedChanged,
    required this.contextTab,
    required this.preview,
    required this.isExporting,
    required this.onExportPressed,
    required this.offeringDesign,
    required this.onEditOffering,
    required this.imageLibrary,
  });

  final ExportStyle style;
  final List<Color> swatches;
  final List<Color> textSwatches;

  /// 찬양 보조 가사로 고를 수 있는 언어 / 성경 보조로 고를 수 있는 역본.
  final List<String> subLanguages;
  final List<String> bibleVersions;
  final ValueChanged<ExportStyle> onStyleChanged;

  final bool isCollapsed;
  final ValueChanged<bool> onCollapsedChanged;

  /// 지금 다루는 항목의 종류. 바뀌면 그 탭으로 넘어간다. null 이면 그대로 둔다.
  final _RibbonTab? contextTab;

  /// 리본 왼쪽에 둘 미리보기. 발표 보기에서는 현재 슬라이드가 이미 크게 보이므로 null.
  final Widget? preview;

  final bool isExporting;
  final VoidCallback onExportPressed;

  /// 등록된 헌금송 디자인(계좌 등). '공통' 탭의 헌금송 묶음에서 연다.
  final OfferingDesign offeringDesign;
  final VoidCallback onEditOffering;

  /// 공통 배경 이미지 모음. '공통' 탭의 전체 배경 이미지를 여기서 고른다.
  final BackgroundImageLibrary imageLibrary;

  @override
  State<_DesignRibbon> createState() => _DesignRibbonState();
}

class _DesignRibbonState extends State<_DesignRibbon> {
  // 3줄 + 줄 사이 + 묶음 이름. 리본 내용 높이가 이 값으로 고정된다.
  static const double _contentHeight = 118;
  static const double _columnWidth = 236;
  static const double _rowGap = 4;

  late _RibbonTab _tab;

  ExportStyle get _style => widget.style;
  void _update(ExportStyle next) => widget.onStyleChanged(next);

  @override
  void initState() {
    super.initState();
    _tab = widget.contextTab ?? _RibbonTab.song;
  }

  @override
  void didUpdateWidget(_DesignRibbon oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.contextTab;
    // '공통' 탭을 보고 있을 때는 곡/성경을 오가도 끌고 가지 않는다.
    if (next == null || next == oldWidget.contextTab) return;
    if (_tab == _RibbonTab.common) return;
    setState(() => _tab = next);
  }

  void _selectTab(_RibbonTab tab) {
    // 접힌 상태에서 탭을 누르면 펼치고, 펼친 상태에서 같은 탭을 누르면 접는다.
    if (widget.isCollapsed) {
      setState(() => _tab = tab);
      widget.onCollapsedChanged(false);
    } else if (tab == _tab) {
      widget.onCollapsedChanged(true);
    } else {
      setState(() => _tab = tab);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 발표 중 단축키(←/→/Space)를 슬라이더·세그먼트가 가로채지 않도록
    // 리본 안의 컨트롤은 키보드 포커스를 받지 않는다. 마우스 조작은 그대로 된다.
    return ExcludeFocus(
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(cs),
            if (!widget.isCollapsed) ...[
              Divider(height: 1, color: cs.outlineVariant),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                child: SizedBox(height: _contentHeight, child: _content(cs)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header(ColorScheme cs) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(Icons.palette_outlined, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          const Text(
            '디자인',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 14),
          for (final tab in _RibbonTab.values)
            _RibbonTabButton(
              tab: tab,
              isSelected: !widget.isCollapsed && tab == _tab,
              onTap: () => _selectTab(tab),
            ),
          const Spacer(),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontSize: 12.5),
            ),
            onPressed: widget.isExporting ? null : widget.onExportPressed,
            icon: widget.isExporting
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.slideshow_rounded, size: 16),
            label: Text(widget.isExporting ? '생성 중' : 'PPTX 저장'),
          ),
          IconButton(
            tooltip: widget.isCollapsed ? '리본 펼치기' : '리본 접기',
            visualDensity: VisualDensity.compact,
            color: cs.onSurfaceVariant,
            onPressed: () => widget.onCollapsedChanged(!widget.isCollapsed),
            icon: Icon(
              widget.isCollapsed
                  ? Icons.expand_more_rounded
                  : Icons.expand_less_rounded,
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _content(ColorScheme cs) {
    final groups = switch (_tab) {
      _RibbonTab.common => _commonGroups(),
      _RibbonTab.song => _songGroups(),
      _RibbonTab.bible => _bibleGroups(),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.preview != null) ...[
          SizedBox(width: _contentHeight * 13.333 / 7.5, child: widget.preview),
          VerticalDivider(width: 21, color: cs.outlineVariant),
        ],
        // 창이 좁으면 묶음들만 가로로 스크롤한다.
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < groups.length; i++) ...[
                  if (i > 0)
                    VerticalDivider(width: 21, color: cs.outlineVariant),
                  groups[i],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 최대 3줄짜리 설정 열. 긴 글(계좌 번호 등)을 보여 줄 열만 [width] 를 넓힌다.
  Widget _column(List<Widget> rows, {double width = _columnWidth}) {
    return SizedBox(
      width: width,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: _rowGap),
            rows[i],
          ],
        ],
      ),
    );
  }

  // ── 공통 ──

  List<Widget> _commonGroups() {
    return [
      _RibbonGroup(
        label: '글꼴',
        columns: [
          _column([
            _PropertyRow(
              label: '폰트',
              child: _FontFamilyPicker(
                selected: _style.fontFamily,
                onChanged: (family) =>
                    _update(_style.copyWith(fontFamily: family)),
              ),
            ),
          ]),
        ],
      ),
      _RibbonGroup(
        label: '배경',
        columns: [
          _column([
            _PropertyRow(
              label: '배경 색',
              child: _ColorField(
                dialogTitle: '배경 색상',
                color: _style.backgroundColor,
                colors: widget.swatches,
                onSelected: (c) => _update(_style.copyWith(backgroundColor: c)),
              ),
            ),
            _PropertyRow(
              label: '배경 이미지',
              child: _BackgroundImagePicker(
                library: widget.imageLibrary,
                imagePath: _style.backgroundImagePath,
                onChanged: (path) =>
                    _update(_style.copyWith(backgroundImagePath: path)),
              ),
            ),
          ]),
        ],
      ),
      _RibbonGroup(
        label: '헌금송',
        columns: [
          _column([
            _PropertyRow(
              label: '디자인 등록',
              child: _OfferingDesignButton(
                design: widget.offeringDesign,
                onPressed: widget.onEditOffering,
              ),
            ),
          ], width: 320),
        ],
      ),
    ];
  }

  // ── 찬양 ──

  List<Widget> _songGroups() {
    return [
      _RibbonGroup(
        label: '가사',
        columns: [
          _column([
            _PropertyRow(
              label: '크기',
              child: _ValueSlider(
                value: _style.fontSize,
                min: 18,
                max: 54,
                divisions: 9,
                onChanged: (v) => _update(_style.copyWith(fontSize: v)),
              ),
            ),
            _PropertyRow(
              label: '색상',
              child: Row(
                children: [
                  Expanded(
                    child: _ColorField(
                      caption: '한글',
                      dialogTitle: '한글 가사 색상',
                      color: _style.textColor,
                      colors: widget.textSwatches,
                      onSelected: (c) => _update(_style.copyWith(textColor: c)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _ColorField(
                      caption: '보조',
                      dialogTitle: '보조 언어 가사 색상',
                      color: _style.englishTextColor,
                      colors: widget.textSwatches,
                      onSelected: (c) =>
                          _update(_style.copyWith(englishTextColor: c)),
                    ),
                  ),
                ],
              ),
            ),
            _PropertyRow(
              label: '보조 언어',
              child: _DenseDropdown(
                value: widget.subLanguages.contains(_style.subLanguage)
                    ? _style.subLanguage
                    : PraiseRepository.defaultSubLanguage,
                items: widget.subLanguages,
                onChanged: (language) => _update(
                  _style.copyWith(
                    subLanguage:
                        language ?? PraiseRepository.defaultSubLanguage,
                  ),
                ),
              ),
            ),
          ]),
        ],
      ),
      _positionGroup(
        label: '가사 위치',
        vertical: _style.textPosition,
        offsetY: _style.textOffsetY,
        align: _style.lyricsTextAlign,
        onVertical: (v) => _update(_style.copyWith(textPosition: v)),
        onOffsetY: (v) => _update(_style.copyWith(textOffsetY: v)),
        onAlign: (v) => _update(_style.copyWith(lyricsTextAlign: v)),
      ),
      _titleGroup(
        visible: _style.showSongTitle,
        fontSize: _style.titleFontSize,
        color: _style.titleTextColor,
        horizontal: _style.titleHorizontalPosition,
        vertical: _style.titleVerticalPosition,
        offsetY: _style.titleOffsetY,
        onVisible: (v) => _update(_style.copyWith(showSongTitle: v)),
        onFontSize: (v) => _update(_style.copyWith(titleFontSize: v)),
        onColor: (c) => _update(_style.copyWith(titleTextColor: c)),
        onHorizontal: (v) =>
            _update(_style.copyWith(titleHorizontalPosition: v)),
        onVertical: (v) => _update(_style.copyWith(titleVerticalPosition: v)),
        onOffsetY: (v) => _update(_style.copyWith(titleOffsetY: v)),
      ),
    ];
  }

  // ── 성경 본문 ──

  List<Widget> _bibleGroups() {
    return [
      _RibbonGroup(
        label: '본문',
        columns: [
          _column([
            _PropertyRow(
              label: '크기',
              child: _ValueSlider(
                value: _style.bibleFontSize,
                min: 18,
                max: 54,
                divisions: 9,
                onChanged: (v) => _update(_style.copyWith(bibleFontSize: v)),
              ),
            ),
            _PropertyRow(
              label: '본문 색',
              child: _ColorField(
                dialogTitle: '본문 색상',
                color: _style.bibleTextColor,
                colors: widget.textSwatches,
                onSelected: (c) => _update(_style.copyWith(bibleTextColor: c)),
              ),
            ),
            _PropertyRow(
              label: '보조 역본',
              child: widget.bibleVersions.isEmpty
                  ? const _HintText('성경을 먼저 가져와 주세요.')
                  : _DenseDropdown(
                      value:
                          widget.bibleVersions.contains(_style.bibleSubVersion)
                          ? _style.bibleSubVersion
                          : '',
                      items: widget.bibleVersions,
                      noneLabel: '표시 안 함',
                      onChanged: (version) => _update(
                        _style.copyWith(bibleSubVersion: version ?? ''),
                      ),
                    ),
            ),
          ]),
        ],
      ),
      _positionGroup(
        label: '본문 위치',
        vertical: _style.bibleTextPosition,
        offsetY: _style.bibleTextOffsetY,
        align: _style.bibleTextAlign,
        onVertical: (v) => _update(_style.copyWith(bibleTextPosition: v)),
        onOffsetY: (v) => _update(_style.copyWith(bibleTextOffsetY: v)),
        onAlign: (v) => _update(_style.copyWith(bibleTextAlign: v)),
      ),
      _titleGroup(
        visible: _style.showBibleTitle,
        fontSize: _style.bibleTitleFontSize,
        color: _style.bibleTitleTextColor,
        horizontal: _style.bibleTitleHorizontalPosition,
        vertical: _style.bibleTitleVerticalPosition,
        offsetY: _style.bibleTitleOffsetY,
        onVisible: (v) => _update(_style.copyWith(showBibleTitle: v)),
        onFontSize: (v) => _update(_style.copyWith(bibleTitleFontSize: v)),
        onColor: (c) => _update(_style.copyWith(bibleTitleTextColor: c)),
        onHorizontal: (v) =>
            _update(_style.copyWith(bibleTitleHorizontalPosition: v)),
        onVertical: (v) =>
            _update(_style.copyWith(bibleTitleVerticalPosition: v)),
        onOffsetY: (v) => _update(_style.copyWith(bibleTitleOffsetY: v)),
      ),
    ];
  }

  // ── 찬양/성경 공용 묶음 ──

  /// 본문 상자의 세로 기준 + 미세 조정 + 가로 정렬.
  Widget _positionGroup({
    required String label,
    required VerticalTextPosition vertical,
    required double offsetY,
    required HorizontalPosition align,
    required ValueChanged<VerticalTextPosition> onVertical,
    required ValueChanged<double> onOffsetY,
    required ValueChanged<HorizontalPosition> onAlign,
  }) {
    return _RibbonGroup(
      label: label,
      columns: [
        _column([
          _PropertyRow(
            label: '세로 기준',
            child: _OptionSegments<VerticalTextPosition>(
              values: VerticalTextPosition.values,
              selected: vertical,
              labelOf: (v) => v.label,
              onSelected: onVertical,
            ),
          ),
          _PropertyRow(
            label: '미세 조정',
            child: _OffsetSlider(value: offsetY, onChanged: onOffsetY),
          ),
          _PropertyRow(
            label: '가로 정렬',
            child: _OptionSegments<HorizontalPosition>(
              values: HorizontalPosition.values,
              selected: align,
              labelOf: (v) => v.label,
              onSelected: onAlign,
            ),
          ),
        ]),
      ],
    );
  }

  /// 제목: 왼쪽 열(표시·크기·색) + 오른쪽 열(위치 셋).
  /// 제목을 끄면 나머지는 흐리게 잠근다(자리를 유지해서 리본이 출렁이지 않게).
  Widget _titleGroup({
    required bool visible,
    required double fontSize,
    required Color color,
    required HorizontalPosition horizontal,
    required VerticalTextPosition vertical,
    required double offsetY,
    required ValueChanged<bool> onVisible,
    required ValueChanged<double> onFontSize,
    required ValueChanged<Color> onColor,
    required ValueChanged<HorizontalPosition> onHorizontal,
    required ValueChanged<VerticalTextPosition> onVertical,
    required ValueChanged<double> onOffsetY,
  }) {
    Widget lockable(Widget child) => IgnorePointer(
      ignoring: !visible,
      child: Opacity(opacity: visible ? 1 : 0.38, child: child),
    );

    return _RibbonGroup(
      label: '제목',
      columns: [
        _column([
          _PropertyRow(
            label: '제목 표시',
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                height: 26,
                child: FittedBox(
                  child: Switch(
                    value: visible,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: onVisible,
                  ),
                ),
              ),
            ),
          ),
          lockable(
            _PropertyRow(
              label: '크기',
              child: _ValueSlider(
                value: fontSize,
                min: 8,
                max: 28,
                divisions: 10,
                onChanged: onFontSize,
              ),
            ),
          ),
          lockable(
            _PropertyRow(
              label: '색상',
              child: _ColorField(
                dialogTitle: '제목 색상',
                color: color,
                colors: widget.textSwatches,
                onSelected: onColor,
              ),
            ),
          ),
        ]),
        lockable(
          _column([
            _PropertyRow(
              label: '가로 위치',
              child: _OptionSegments<HorizontalPosition>(
                values: HorizontalPosition.values,
                selected: horizontal,
                labelOf: (v) => v.label,
                onSelected: onHorizontal,
              ),
            ),
            _PropertyRow(
              label: '세로 기준',
              child: _OptionSegments<VerticalTextPosition>(
                values: VerticalTextPosition.values,
                selected: vertical,
                labelOf: (v) => v.label,
                onSelected: onVertical,
              ),
            ),
            _PropertyRow(
              label: '미세 조정',
              child: _OffsetSlider(value: offsetY, onChanged: onOffsetY),
            ),
          ]),
        ),
      ],
    );
  }
}

// ── 리본 공용 조각 ────────────────────────────────────────────────────────

/// 리본 머리의 탭 버튼. 선택되면 밑줄이 생긴다.
class _RibbonTabButton extends StatelessWidget {
  const _RibbonTabButton({
    required this.tab,
    required this.isSelected,
    required this.onTap,
  });

  final _RibbonTab tab;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = isSelected ? cs.primary : cs.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isSelected ? cs.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(tab.icon, size: 15, color: color),
            const SizedBox(width: 5),
            Text(
              tab.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 리본의 한 묶음: 설정 열들 + 아래쪽 가운데 묶음 이름 (PowerPoint 리본과 같은 배치).
class _RibbonGroup extends StatelessWidget {
  const _RibbonGroup({required this.label, required this.columns});

  final String label;
  final List<Widget> columns;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < columns.length; i++) ...[
                if (i > 0) const SizedBox(width: 16),
                columns[i],
              ],
            ],
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 왼쪽 고정 폭 라벨 + 오른쪽 컨트롤 한 줄.
class _PropertyRow extends StatelessWidget {
  const _PropertyRow({required this.label, required this.child});

  static const double labelWidth = 64;

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 30),
      child: Row(
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 테두리 있는 한 줄짜리 입력 칸 모양. 색·폰트·이미지 선택기가 같이 쓴다.
class _FieldBox extends StatelessWidget {
  const _FieldBox({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(8);
    return Material(
      color: cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: SizedBox(
          height: 30,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 색 견본 + hex. 누르면 hex 입력 다이얼로그를 연다.
class _ColorField extends StatelessWidget {
  const _ColorField({
    required this.dialogTitle,
    required this.color,
    required this.colors,
    required this.onSelected,
    this.caption,
  });

  final String dialogTitle;

  /// 있으면 hex 대신 이 짧은 이름을 보여 준다(한 줄에 색 두 개를 놓을 때). hex 는 툴팁으로.
  final String? caption;
  final Color color;
  final List<Color> colors;
  final ValueChanged<Color> onSelected;

  Future<void> _open(BuildContext context) async {
    final selected = await showDialog<Color>(
      context: context,
      builder: (context) => _HexColorDialog(
        title: dialogTitle,
        initialColor: color,
        colors: colors,
        inputFormatter: _hexInputFormatter,
      ),
    );
    if (selected != null) onSelected(selected);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final field = _FieldBox(
      onTap: () => _open(context),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              caption ?? colorToHex(color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: cs.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (caption == null)
            Icon(Icons.palette_outlined, size: 15, color: cs.onSurfaceVariant),
        ],
      ),
    );
    if (caption == null) return field;
    return Tooltip(message: '$dialogTitle ${colorToHex(color)}', child: field);
  }
}

/// 작은 슬라이더 + 현재 값.
class _ValueSlider extends StatelessWidget {
  const _ValueSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _CompactSlider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        _ValueBadge(text: value.toStringAsFixed(0)),
      ],
    );
  }
}

/// 상단/중단/하단 기준선에서 위아래로 더 밀어 주는 미세 조정.
/// 슬라이더로 크게, 위/아래 버튼으로 한 칸(0.05인치)씩 움직인다.
/// 값 배지를 누르면 0(기본)으로 되돌린다. 본문과 제목이 같은 위젯을 쓴다.
class _OffsetSlider extends StatelessWidget {
  const _OffsetSlider({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  // 0.05를 더해 나가면 0.30000000000000004 같은 값이 남는다. 눈금에 맞춰 끊는다.
  static double _snap(double raw) {
    final steps = (clampTextOffsetY(raw) / kTextOffsetYStep).round();
    return clampTextOffsetY(
      double.parse((steps * kTextOffsetYStep).toStringAsFixed(2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = clampTextOffsetY(value);
    final label = current == 0
        ? '기본'
        : '${current > 0 ? '+' : '-'}${current.abs().toStringAsFixed(2)}';

    void nudge(double delta) {
      final next = _snap(current + delta);
      if (next != current) onChanged(next);
    }

    return Row(
      children: [
        _NudgeButton(
          tooltip: '위로 조금',
          icon: Icons.keyboard_arrow_up_rounded,
          onPressed: current <= kMinTextOffsetY
              ? null
              : () => nudge(-kTextOffsetYStep),
        ),
        Expanded(
          child: _CompactSlider(
            min: kMinTextOffsetY,
            max: kMaxTextOffsetY,
            divisions: ((kMaxTextOffsetY - kMinTextOffsetY) / kTextOffsetYStep)
                .round(),
            value: current,
            onChanged: (next) => onChanged(_snap(next)),
          ),
        ),
        _NudgeButton(
          tooltip: '아래로 조금',
          icon: Icons.keyboard_arrow_down_rounded,
          onPressed: current >= kMaxTextOffsetY
              ? null
              : () => nudge(kTextOffsetYStep),
        ),
        const SizedBox(width: 2),
        _ValueBadge(
          text: label,
          tooltip: current == 0 ? null : '눌러서 기본값으로',
          onTap: current == 0 ? null : () => onChanged(0),
        ),
      ],
    );
  }
}

class _NudgeButton extends StatelessWidget {
  const _NudgeButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      iconSize: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 24, height: 28),
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}

/// 여백을 줄인 슬라이더. 기본 Slider 는 위아래 48px 을 차지한다.
class _CompactSlider extends StatelessWidget {
  const _CompactSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        tickMarkShape: SliderTickMarkShape.noTickMark,
      ),
      child: SizedBox(
        height: 28,
        child: Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// 슬라이더 오른쪽 현재 값 표시. [onTap] 이 있으면 눌러서 초기화한다.
class _ValueBadge extends StatelessWidget {
  const _ValueBadge({required this.text, this.tooltip, this.onTap});

  final String text;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = onTap != null;
    final badge = Material(
      color: active ? cs.primaryContainer : cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: SizedBox(
          width: 42,
          height: 22,
          child: Center(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: active ? cs.onPrimaryContainer : cs.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? badge : Tooltip(message: tooltip!, child: badge);
  }
}

/// 상단/중단/하단, 왼쪽/가운데/오른쪽 같은 짧은 선택지.
class _OptionSegments<T> extends StatelessWidget {
  const _OptionSegments({
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
  });

  final List<T> values;
  final T selected;
  final String Function(T value) labelOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    // SegmentedButton 은 고유 너비 아래로 안 줄어든다. 패널이 좁으면
    // 오른쪽으로 넘치고 글자도 '상/단' 으로 쪼개지므로 통째로 축소한다.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: SegmentedButton<T>(
        segments: [
          for (final value in values)
            ButtonSegment<T>(value: value, label: Text(labelOf(value))),
        ],
        selected: {selected},
        showSelectedIcon: false,
        style: ButtonStyle(
          visualDensity: const VisualDensity(horizontal: -3, vertical: -3),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 10),
          ),
          // 새 TextStyle 로 덮으면 테마 글꼴이 빠지므로 테마 스타일에서 크기만 바꾼다.
          textStyle: WidgetStatePropertyAll(
            Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12.5),
          ),
        ),
        onSelectionChanged: (selection) => onSelected(selection.first),
      ),
    );
  }
}

/// 보조 언어·역본 드롭다운. [noneLabel] 이 있으면 맨 위에 '' 값으로 넣는다.
class _DenseDropdown extends StatelessWidget {
  const _DenseDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    this.noneLabel,
  });

  final String? value;
  final List<String> items;
  final ValueChanged<String?> onChanged;
  final String? noneLabel;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && noneLabel == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return DropdownButtonFormField<String>(
      isExpanded: true,
      isDense: true,
      initialValue: value,
      style: Theme.of(
        context,
      ).textTheme.bodyMedium?.copyWith(fontSize: 12.5, color: cs.onSurface),
      icon: Icon(
        Icons.expand_more_rounded,
        size: 16,
        color: cs.onSurfaceVariant,
      ),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: cs.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
      ),
      items: [
        if (noneLabel != null)
          DropdownMenuItem(value: '', child: Text(noneLabel!)),
        for (final item in items)
          DropdownMenuItem(value: item, child: Text(item)),
      ],
      onChanged: onChanged,
    );
  }
}

class _HintText extends StatelessWidget {
  const _HintText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
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
    String? imagePath;

    switch (previewItem) {
      case ImageStagingItem(:final imagePaths):
        sampleText = '';
        sampleEnglishText = '';
        titleText = null;
        isBible = false;
        imagePath = imagePaths.isEmpty ? null : imagePaths.first;
      case SongStagingItem(:final song):
        sampleText = song.pages.isEmpty ? song.title : song.pages.first;
        sampleEnglishText = song.englishPages.isEmpty
            ? ''
            : song.englishPages.first;
        titleText = song.title;
        isBible = false;
      case BibleStagingItem(:final text, :final reference, :final subText):
        sampleText = text;
        sampleEnglishText = subText;
        titleText = reference;
        isBible = true;
      case BlankStagingItem(:final mainText, :final englishText):
        sampleText = mainText;
        sampleEnglishText = englishText;
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
            imagePath: imagePath,
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

// ── 악보 가사 추출 결과 ────────────────────────────────────────────────────

/// 악보에서 읽어 온 가사를 보여 주고 고칠 수 있게 한다.
/// '곡으로 저장'을 누르면 고친 가사를 돌려주고, 닫으면 null.
class _SheetLyricsDialog extends StatefulWidget {
  const _SheetLyricsDialog({required this.title, required this.lyrics});

  final String title;
  final String lyrics;

  @override
  State<_SheetLyricsDialog> createState() => _SheetLyricsDialogState();
}

class _SheetLyricsDialogState extends State<_SheetLyricsDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.lyrics,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: _controller.text));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('가사를 복사했습니다.')));
  }

  void _saveAsSong() {
    final lyrics = _controller.text.trim();
    if (lyrics.isEmpty) return;
    Navigator.of(context).pop(lyrics);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.music_note_rounded,
                    size: 22,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '악보 가사 추출',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                maxLines: 14,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  labelText: '읽어 온 가사',
                  hintText: '오선 아래 글자만 읽습니다. 잘못 읽은 곳은 고쳐서 쓰세요.',
                  helperText: '빈 줄 = 페이지 구분',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _copy,
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('복사'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('닫기'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _saveAsSong,
                    icon: const Icon(Icons.library_add_rounded, size: 18),
                    label: const Text('곡으로 저장'),
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

// ── 곡 편집 다이얼로그 ─────────────────────────────────────────────────

/// 곡 편집 결과: 곡 본체 + 언어별 보조 가사 ('영어' 는 song.englishLyrics).
typedef SongEditResult = (PraiseSong song, Map<String, String> subLyrics);

class _SongEditDialog extends StatefulWidget {
  const _SongEditDialog({
    this.song,
    this.translations = const {},
    this.languages = const [PraiseRepository.defaultSubLanguage],
  });

  final PraiseSong? song;

  /// 영어를 뺀 언어별 가사 (DB 에서 읽어 온 것).
  final Map<String, String> translations;

  /// 드롭다운에 띄울 언어 목록.
  final List<String> languages;

  @override
  State<_SongEditDialog> createState() => _SongEditDialogState();
}

// 저장 형식이 편집 형식과 동일하므로 변환 불필요.
@visibleForTesting
String lyricsToEditText(String stored) => stored;

// 편집 텍스트 → 저장 형식 정규화.
// 규칙: 빈 줄 1개(\n\n) = 페이지 구분, 빈 줄 N개 = 빈 페이지 N-1장.
// ###, ==== 은 명시적 페이지 구분자로 허용.
@visibleForTesting
String normalizeEditableLyrics(String raw) {
  var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // ###, ==== → \n\n (주변 줄바꿈 포함 소비)
  text = text.replaceAll(RegExp(r'\n?[ \t]*(###|====)[ \t]*\n?'), '\n\n');
  // 분리 → 각 페이지 trim → 후행 빈 페이지 제거 → 재결합
  final pages = text.split(RegExp(r'\n[ \t]*\n')).map((p) => p.trim()).toList();
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
  late Map<String, String> _subLyrics;
  late String _language;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.song?.title ?? '');
    _lyricsController = TextEditingController(
      text: _toEditText(widget.song?.lyrics ?? ''),
    );
    _subLyrics = {
      PraiseRepository.defaultSubLanguage: widget.song?.englishLyrics ?? '',
      for (final language in widget.languages)
        if (language != PraiseRepository.defaultSubLanguage)
          language: widget.translations[language] ?? '',
      ...widget.translations,
    };
    _language = PraiseRepository.defaultSubLanguage;
    _englishController = TextEditingController(
      text: _toEditText(_subLyrics[_language] ?? ''),
    );
  }

  /// 편집 중인 언어의 내용을 맵에 되돌려 넣는다.
  void _stashCurrent() {
    _subLyrics[_language] = _normalizeLyrics(_englishController.text);
  }

  void _switchLanguage(String language) {
    setState(() {
      _stashCurrent();
      _language = language;
      _englishController.text = _toEditText(_subLyrics[language] ?? '');
    });
  }

  Future<void> _addLanguage() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _TextPromptDialog(
        title: '언어 추가',
        label: '언어',
        hintText: '예: 일본어, 중국어, 스페인어',
        initialValue: '',
      ),
    );
    final language = name?.trim() ?? '';
    if (language.isEmpty || !mounted) return;
    _subLyrics.putIfAbsent(language, () => '');
    _switchLanguage(language);
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
    _stashCurrent();
    Navigator.of(context).pop((
      PraiseSong(
        id: widget.song?.id,
        fileName: widget.song?.fileName ?? title,
        title: title,
        lyrics: _normalizeLyrics(_lyricsController.text),
        englishLyrics: _subLyrics[PraiseRepository.defaultSubLanguage] ?? '',
      ),
      Map<String, String>.from(_subLyrics),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.song?.id == null;
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
                  hintText: '페이지 구분: 빈 줄 (또는 ### / ====)',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('보조 언어'),
                  const SizedBox(width: 12),
                  DropdownButton<String>(
                    value: _language,
                    items: [
                      for (final language in _subLyrics.keys)
                        DropdownMenuItem(
                          value: language,
                          child: Text(language),
                        ),
                    ],
                    onChanged: (language) {
                      if (language != null) _switchLanguage(language);
                    },
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: _addLanguage,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('언어 추가'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _englishController,
                maxLines: 10,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  labelText: '$_language 가사',
                  hintText: '페이지 구분: 빈 줄 (또는 ### / ====)',
                  border: const OutlineInputBorder(),
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

class _SlideThumbnail extends StatefulWidget {
  const _SlideThumbnail({
    required this.data,
    required this.isSelected,
    required this.index,
    this.isEditable = true,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final SlidePageData data;
  final bool isSelected;
  final int index;
  final bool isEditable;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

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
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: widget.onDelete,
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
                                Icons.delete_outline_rounded,
                                size: 13,
                                color: cs.error,
                              ),
                            ),
                          ),
                          if (widget.isEditable) ...[
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: widget.onEdit,
                              child: Container(
                                padding: const EdgeInsets.all(5),
                                decoration: BoxDecoration(
                                  color: cs.surface.withValues(alpha: 0.92),
                                  borderRadius: BorderRadius.circular(5),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.2,
                                      ),
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
                          ],
                        ],
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
    this.heading = '슬라이드 수정',
    this.helper,
    this.subLabel,
    this.mainMaxLines = 7,
  });

  final String mainText;
  final String englishText;
  final bool isBible;
  final String? title;
  final String heading;
  final String? helper;
  // 보조 칸 라벨. 콘티 임시 수정은 어느 언어 칸인지 이름으로 알려 준다.
  final String? subLabel;
  final int mainMaxLines;

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
        ? '${widget.heading} — ${widget.title}'
        : widget.heading;
    return AlertDialog(
      title: Text(titleLabel),
      // 창이 낮으면 긴 본문 칸이 다이얼로그 높이를 넘긴다. 스크롤로 받아 준다.
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _mainCtrl,
                maxLines: widget.mainMaxLines,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '본문',
                  helperText: widget.helper,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _englishCtrl,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText:
                      widget.subLabel ??
                      (widget.isBible ? '보조 역본 본문 (선택)' : '보조 언어 가사 (선택)'),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
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
  const _FontFamilyPicker({required this.selected, required this.onChanged});

  final String selected;
  final ValueChanged<String> onChanged;

  static const _bundled = [
    ('Pretendard', 'Pretendard'),
    ('NanumGothic', '나눔고딕'),
    ('NanumMyeongjo', '나눔명조'),
  ];

  List<(String, String)> get _fonts => [
    ..._bundled,
    for (final f in FontLibrary.fonts) (f.family, f.displayName),
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
                    child: Text(f.$2, style: TextStyle(fontFamily: f.$1)),
                  ),
                  if (f.$1 == selected)
                    Icon(Icons.check_rounded, size: 16, color: cs.primary),
                ],
              ),
            ),
          )
          .toList(),
      child: _FieldBox(
        child: Row(
          children: [
            Expanded(
              child: Text(
                _displayName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: selected,
                  fontSize: 13,
                  color: cs.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              Icons.expand_more_rounded,
              size: 16,
              color: cs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

// ── _BackgroundImagePicker ────────────────────────────────────────────────

class _BackgroundImagePicker extends StatelessWidget {
  const _BackgroundImagePicker({
    required this.library,
    required this.imagePath,
    required this.onChanged,
  });

  final BackgroundImageLibrary library;
  final String? imagePath;
  final ValueChanged<String?> onChanged;

  /// 공통 배경 이미지 모음에서 고른다(헌금송·항목 배경과 같은 모음).
  Future<void> _pick(BuildContext context) async {
    final result = await showDialog<({String? path})>(
      context: context,
      builder: (ctx) {
        var selected = imagePath;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('전체 배경 이미지'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: BackgroundImageGallery(
                  library: library,
                  selected: selected,
                  onChanged: (path) => setDialogState(() => selected = path),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop((path: selected)),
                child: const Text('적용'),
              ),
            ],
          ),
        );
      },
    );
    if (result != null) onChanged(result.path);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasImage = imagePath != null;

    return _FieldBox(
      onTap: () => _pick(context),
      child: Row(
        children: [
          Icon(Icons.image_outlined, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              hasImage ? p.basename(imagePath!) : '없음 (눌러서 선택)',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: hasImage ? cs.onSurface : cs.onSurfaceVariant,
                fontWeight: hasImage ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          if (hasImage)
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => onChanged(null),
              child: Tooltip(
                message: '배경 이미지 지우기',
                child: Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── 헌금송 ───────────────────────────────────────────────────────────────

/// 리본 '공통' 탭의 "헌금송 디자인 등록" 칸. 등록된 계좌를 한 줄로 보여준다.
class _OfferingDesignButton extends StatelessWidget {
  const _OfferingDesignButton({required this.design, required this.onPressed});

  final OfferingDesign design;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final account = design.accountLine;
    return Tooltip(
      message: '헌금송 디자인 등록',
      child: _FieldBox(
        onTap: onPressed,
        child: Row(
          children: [
            Icon(
              Icons.volunteer_activism_outlined,
              size: 16,
              color: cs.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                account.isEmpty ? '미등록 (눌러서 등록)' : account,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: account.isEmpty ? cs.onSurfaceVariant : cs.onSurface,
                  fontWeight: account.isEmpty ? null : FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.edit_outlined, size: 15, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

// ── 항목별 배경 ───────────────────────────────────────────────────────────

/// 콘티 목록에서 "이 항목은 배경이 다르다"를 한눈에 보여주는 작은 칩.
class _BackgroundBadge extends StatelessWidget {
  const _BackgroundBadge({required this.background});

  final SlideBackground background;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: background.color,
              shape: BoxShape.circle,
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            background.isOffering
                ? '헌금송'
                : background.hasImage
                ? '배경 이미지'
                : '배경',
            style: TextStyle(
              fontSize: 11,
              color: cs.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 콘티 항목 하나의 배경만 따로 정하는 다이얼로그.
///
/// "전역 배경 사용"이면 오버라이드를 지우고 전역 디자인을 따른다. 끄고 색·이미지를
/// 고르면 그 항목(과 뒤에 자동으로 붙는 여백)만 다른 배경으로 나간다.
/// 결과로 `(background: null)` 을 돌려주면 "오버라이드 없음", 다이얼로그를 그냥
/// 닫으면 null 이라 아무것도 바꾸지 않는다.
class _ItemBackgroundDialog extends StatefulWidget {
  const _ItemBackgroundDialog({
    required this.item,
    required this.initial,
    required this.globalStyle,
    required this.swatches,
    required this.imageLibrary,
  });

  final StagingItem item;
  final SlideBackground? initial;
  final ExportStyle globalStyle;
  final List<Color> swatches;
  final BackgroundImageLibrary imageLibrary;

  @override
  State<_ItemBackgroundDialog> createState() => _ItemBackgroundDialogState();
}

class _ItemBackgroundDialogState extends State<_ItemBackgroundDialog> {
  late bool _useCustom = widget.initial != null;
  late SlideBackground _background =
      widget.initial ?? SlideBackground.fromStyle(widget.globalStyle);

  ExportStyle get _previewStyle =>
      widget.globalStyle.withBackground(_useCustom ? _background : null);

  Future<void> _pickColor() async {
    final selected = await showDialog<Color>(
      context: context,
      builder: (ctx) => _HexColorDialog(
        title: '이 항목의 배경 색상',
        initialColor: _background.color,
        colors: widget.swatches,
        inputFormatter: _hexInputFormatter,
      ),
    );
    if (selected != null && mounted) {
      setState(() => _background = _background.copyWith(color: selected));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = widget.item is BlankStagingItem
        ? '빈 페이지'
        : widget.item.displayTitle;

    return AlertDialog(
      title: Text('항목 배경 — $title', overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PreviewBox(style: _previewStyle, previewItem: widget.item),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _useCustom,
                title: const Text('이 항목만 다른 배경 사용'),
                subtitle: Text(
                  _useCustom
                      ? '이 항목의 모든 페이지에 아래 배경이 적용됩니다.'
                      : 'PPTX 디자인의 전역 배경을 그대로 씁니다.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                onChanged: (value) => setState(() => _useCustom = value),
              ),
              const SizedBox(height: 8),
              AnimatedOpacity(
                opacity: _useCustom ? 1 : 0.4,
                duration: const Duration(milliseconds: 150),
                child: IgnorePointer(
                  ignoring: !_useCustom,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: _pickColor,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '배경 색상',
                                style: TextStyle(color: cs.onSurface),
                              ),
                            ),
                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: _background.color,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: Theme.of(context).dividerColor,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              colorToHex(_background.color),
                              style: TextStyle(
                                color: cs.primary,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '배경 이미지 (공통 모음)',
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      BackgroundImageGallery(
                        library: widget.imageLibrary,
                        selected: _background.imagePath,
                        emptyColor: _background.color,
                        onChanged: (path) => setState(
                          () => _background = _background.copyWith(
                            imagePath: path,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
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
        FilledButton(
          onPressed: () => Navigator.of(context).pop((
            background: !_useCustom
                ? null
                // 손대지 않았으면 헌금송 정보를 그대로 두고, 색·이미지를 바꿨으면
                // 더는 헌금송 배경이 아니므로 떼어 낸다.
                : _background == widget.initial
                ? _background
                : _background.copyWith(
                    offering: null,
                    lyricsPosition: null,
                    lyricsOffsetY: null,
                  ),
          )),
          child: const Text('적용'),
        ),
      ],
    );
  }
}

// 발표자 보기의 "화면을 떠나도 남아야 하는" 값들. 콘솔은 탭을 옮기거나
// 모든 페이지 보기로 바꾸면 통째로 트리에서 빠지기 때문에, State 안에 두면
// 예배 도중에 경과 시간이 00:00 으로 리셋된다.
class PresenterViewState {
  Duration elapsed = Duration.zero;
  bool isPaused = false;
  int targetMinutes = 20;
  double splitRatio = 0.68;
  // 아래 썸네일 줄 높이. 현재 슬라이드와 썸네일 사이 막대를 끌어 바꾼다.
  double stripHeight = _PresenterConsoleState._defaultStripHeight;
  bool showAllPages = false;
  double gridThumbW = 140;
}

// ── PresenterConsole ─────────────────────────────────────────────────────
// PPT 발표자 보기. 검색 패널의 세 번째 탭으로 들어간다(창을 새로 띄우지 않는 이유는
// 발표 중에도 같은 창에서 검색·콘티 편집을 해야 하기 때문).
// 관객 화면은 기존 네이티브 발표 창이 그대로 담당한다.

enum PresenterPointerMode { hand, dot, off }

class _PresenterConsole extends StatefulWidget {
  const _PresenterConsole({
    required this.slides,
    required this.currentIndex,
    required this.style,
    required this.isPresentationOpen,
    required this.isBlackout,
    required this.notes,
    required this.onNoteChanged,
    required this.onSlideSelected,
    required this.onSlideEdit,
    required this.onSlideDelete,
    required this.onPrev,
    required this.onNext,
    required this.onToggleBlackout,
    required this.pointerMode,
    required this.pointerSize,
    required this.onPointerModeChanged,
    required this.onPointerSizeChanged,
    required this.onPointerMove,
    required this.isZoomOn,
    required this.zoomScale,
    required this.zoomCenter,
    required this.onZoomToggled,
    required this.onZoomChanged,
    required this.viewState,
  });

  final List<_SlideInfo> slides;
  final int currentIndex;
  final ExportStyle style;
  final bool isPresentationOpen;
  final bool isBlackout;
  // 메모 키는 부모의 _slideKey(uid, page) 와 같은 형식이라 여기서 바로 만든다.
  // 부모 콜백을 부르면 썸네일마다 _allSlides 를 다시 계산하게 된다.
  final Map<String, String> notes;
  final void Function(String key, String note) onNoteChanged;
  final ValueChanged<int> onSlideSelected;
  final ValueChanged<int> onSlideEdit;
  final ValueChanged<int> onSlideDelete;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToggleBlackout;
  final PresenterPointerMode pointerMode;
  final double pointerSize;
  final ValueChanged<PresenterPointerMode> onPointerModeChanged;
  final ValueChanged<double> onPointerSizeChanged;
  // 현재 슬라이드 미리보기 위의 좌표(0~1). null 이면 화면 밖으로 나간 것.
  final ValueChanged<Offset?> onPointerMove;
  final bool isZoomOn;
  final double zoomScale;
  final Offset zoomCenter;
  final VoidCallback onZoomToggled;
  final void Function(Offset center, double scale) onZoomChanged;
  final PresenterViewState viewState;

  @override
  State<_PresenterConsole> createState() => _PresenterConsoleState();
}

class _PresenterConsoleState extends State<_PresenterConsole> {
  final _noteController = TextEditingController();
  final _stripScrollController = ScrollController();
  String _noteKey = '';
  PresenterViewState get _view => widget.viewState;

  static const double _thumbAspect = 13.333 / 7.5;
  static const double _defaultStripHeight = 104;
  static const double _minStripHeight = 80;
  // 썸네일을 키워도 현재 슬라이드 쪽에 이만큼은 남긴다.
  static const double _minStageHeight = 180;
  static const double _stripHandleHeight = 14;
  static const double _stripSpacing = 8;

  // 마지막으로 그린 썸네일 줄 높이(창 크기에 맞춰 줄어든 값). 자동 스크롤이 쓴다.
  double _renderedStripHeight = _defaultStripHeight;

  // 썸네일 아래 번호 줄(26) 을 뺀 높이가 슬라이드 높이다.
  static double _thumbWidthFor(double stripHeight) =>
      (stripHeight - 26) * _thumbAspect;

  @override
  void initState() {
    super.initState();
    _syncNote();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollStripToCurrent(),
    );
  }

  @override
  void didUpdateWidget(_PresenterConsole oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 콘티를 재정렬하면 인덱스·개수는 그대로여도 슬라이드가 바뀐다. 키 비교는 안에서 한다.
    _syncNote();
    if (oldWidget.currentIndex != widget.currentIndex ||
        oldWidget.slides.length != widget.slides.length) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollStripToCurrent(),
      );
    }
  }

  @override
  void dispose() {
    _noteController.dispose();
    _stripScrollController.dispose();
    super.dispose();
  }

  // 슬라이드가 바뀌면 그 슬라이드의 메모를 컨트롤러에 옮긴다.
  void _syncNote() {
    final key = _keyAt(widget.currentIndex);
    final text = widget.notes[key] ?? '';
    // 키가 같아도 콘티를 다시 불러오면 내용이 통째로 바뀐다.
    if (key == _noteKey && _noteController.text == text) return;
    _noteKey = key;
    if (_noteController.text != text) _noteController.text = text;
  }

  void _scrollStripToCurrent() {
    if (!_stripScrollController.hasClients || widget.slides.isEmpty) return;
    final tw = _thumbWidthFor(_renderedStripHeight);
    final target = widget.currentIndex * (tw + _stripSpacing);
    final viewport = _stripScrollController.position.viewportDimension;
    _stripScrollController.animateTo(
      (target - (viewport - tw) / 2).clamp(
        0.0,
        _stripScrollController.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
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
      style: widget.style.withBackground(info.background),
      imagePath: info.imagePath,
    );
  }

  String _keyAt(int index) {
    if (index < 0 || index >= widget.slides.length) return '';
    final info = widget.slides[index];
    // 자동으로 끼워 넣는 빈 페이지·여백은 콘티 항목이 아니라 메모를 저장할 곳이 없다.
    // 키를 주지 않아서 메모칸도 잠그고 썸네일 배지도 안 뜨게 한다.
    if (info.isAutoSpacer ||
        info.stagingUid == _PraiseHomePageState._leadingBlankUid) {
      return '';
    }
    return '${info.stagingUid}:${info.pageIndexInItem}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (widget.slides.isEmpty) {
      return _centerHint(
        cs,
        Icons.co_present_rounded,
        '콘티에 찬양이나 성경 본문을 담으면\n여기에서 발표자 보기를 쓸 수 있습니다.',
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: LayoutBuilder(
        builder: (context, constraints) => _consoleBody(cs, constraints),
      ),
    );
  }

  /// 썸네일 줄이 가질 수 있는 가장 큰 높이. 헤더와 현재 슬라이드 최소 높이를 뺀 나머지.
  double _maxStripHeight(BoxConstraints constraints) {
    const headerHeight = 58.0; // 헤더 + 아래 여백
    final room =
        constraints.maxHeight -
        headerHeight -
        _minStageHeight -
        _stripHandleHeight;
    return room < _minStripHeight ? _minStripHeight : room;
  }

  Widget _consoleBody(ColorScheme cs, BoxConstraints constraints) {
    final maxStrip = _maxStripHeight(constraints);
    // 창을 줄이면 저장해 둔 높이가 넘칠 수 있다. 값은 두고 그릴 때만 줄인다.
    final stripHeight = _view.stripHeight.clamp(_minStripHeight, maxStrip);
    _renderedStripHeight = stripHeight;
    return Column(
      children: [
        _header(cs),
        const SizedBox(height: 10),
        Expanded(
          child: _view.showAllPages
              ? _allPagesGrid(cs)
              : LayoutBuilder(
                  builder: (context, constraints) {
                    // 좁으면 옆 패널을 아래로 내린다.
                    final isWide = constraints.maxWidth >= 620;
                    final current = _currentStage(cs);
                    final side = _sidePanel(cs);
                    return isWide
                        ? _ResizableColumnSplit(
                            ratio: _view.splitRatio,
                            onRatioChanged: (v) =>
                                setState(() => _view.splitRatio = v),
                            first: current,
                            second: side,
                            isSecondCollapsed: false,
                            collapsedSecond: const SizedBox.shrink(),
                          )
                        : Column(
                            children: [
                              Expanded(flex: 3, child: current),
                              const SizedBox(height: 12),
                              Expanded(flex: 2, child: side),
                            ],
                          );
                  },
                ),
        ),
        if (!_view.showAllPages) ...[
          // 끌어서 썸네일 줄 높이를 바꾼다(위로 끌면 커진다).
          _PanelResizeHandle(
            crossExtent: _stripHandleHeight,
            color: cs.outlineVariant,
            onDrag: (dy) {
              final next = (stripHeight - dy)
                  .clamp(_minStripHeight, maxStrip)
                  .toDouble();
              if (next == _view.stripHeight) return;
              setState(() => _view.stripHeight = next);
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _scrollStripToCurrent(),
              );
            },
          ),
          SizedBox(height: stripHeight, child: _thumbStrip(cs, stripHeight)),
        ],
      ],
    );
  }

  Widget _centerHint(ColorScheme cs, IconData icon, String text) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42, color: cs.outline),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _header(ColorScheme cs) {
    final open = widget.isPresentationOpen;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: open ? cs.primaryContainer : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                open ? Icons.cast_connected_rounded : Icons.cast_rounded,
                size: 15,
                color: open ? cs.onPrimaryContainer : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                open ? '발표 중' : '발표 대기',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: open ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '${widget.currentIndex + 1} / ${widget.slides.length}',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        IconButton(
          onPressed: widget.currentIndex > 0 ? widget.onPrev : null,
          icon: const Icon(Icons.chevron_left_rounded),
          tooltip: '이전 (←)',
        ),
        IconButton(
          onPressed: widget.currentIndex < widget.slides.length - 1
              ? widget.onNext
              : null,
          icon: const Icon(Icons.chevron_right_rounded),
          tooltip: '다음 (→ Space)',
        ),
        const SizedBox(width: 4),
        IconButton(
          onPressed: () =>
              setState(() => _view.showAllPages = !_view.showAllPages),
          icon: Icon(
            _view.showAllPages
                ? Icons.view_carousel_rounded
                : Icons.grid_view_rounded,
          ),
          tooltip: _view.showAllPages ? '발표자 보기로' : '모든 페이지 보기',
          color: _view.showAllPages ? cs.primary : null,
        ),
        IconButton(
          onPressed: widget.onZoomToggled,
          icon: Icon(
            widget.isZoomOn ? Icons.zoom_in_rounded : Icons.search_rounded,
          ),
          tooltip: widget.isZoomOn ? '확대 끄기' : '영역 확대',
          color: widget.isZoomOn ? cs.primary : null,
        ),
        // 발표 시작/종료는 탭 옆 상단 버튼이 담당한다. 여기선 화면 끄기만.
        if (open)
          IconButton(
            onPressed: widget.onToggleBlackout,
            icon: Icon(
              widget.isBlackout
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_rounded,
            ),
            tooltip: '화면 끄기 (B)',
            color: widget.isBlackout ? cs.error : null,
          ),
      ],
    );
  }

  Widget _currentStage(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(cs, '현재 슬라이드'),
        const SizedBox(height: 6),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => MouseRegion(
              onHover: (event) =>
                  _emitPointer(constraints.biggest, event.localPosition),
              onExit: (_) => widget.onPointerMove(null),
              child: Center(
                child: AspectRatio(
                  aspectRatio: _thumbAspect,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: cs.outlineVariant),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          SlideRenderView(
                            data: _pageDataFor(widget.currentIndex),
                          ),
                          if (widget.isZoomOn)
                            _ZoomRegionOverlay(
                              center: widget.zoomCenter,
                              scale: widget.zoomScale,
                              onChanged: widget.onZoomChanged,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _emitPointer(Size size, Offset local) {
    if (widget.pointerMode == PresenterPointerMode.off) return;
    if (size.isEmpty) return;
    // MouseRegion 은 stage 전체를 덮지만 슬라이드는 그 안에서 비율을 유지한 채
    // 가운데 놓인다. 슬라이드 영역 기준으로 다시 계산해야 관객 화면과 맞는다.
    var w = size.width;
    var h = w / _thumbAspect;
    if (h > size.height) {
      h = size.height;
      w = h * _thumbAspect;
    }
    final left = (size.width - w) / 2;
    final top = (size.height - h) / 2;
    final x = (local.dx - left) / w;
    final y = (local.dy - top) / h;
    if (x < 0 || x > 1 || y < 0 || y > 1) {
      widget.onPointerMove(null);
      return;
    }
    widget.onPointerMove(Offset(x, y));
  }

  Widget _sidePanel(ColorScheme cs) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(cs, '다음 슬라이드'),
          const SizedBox(height: 6),
          _nextPreview(cs),
          const SizedBox(height: 14),
          _ElapsedClock(isRunning: widget.isPresentationOpen, state: _view),
          const SizedBox(height: 14),
          _pointerBox(cs),
          const SizedBox(height: 14),
          _sectionLabel(cs, '발표 메모'),
          const SizedBox(height: 6),
          _noteBox(cs),
        ],
      ),
    );
  }

  Widget _nextPreview(ColorScheme cs) {
    final hasNext = widget.currentIndex < widget.slides.length - 1;
    return AspectRatio(
      aspectRatio: _thumbAspect,
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        clipBehavior: Clip.antiAlias,
        child: hasNext
            ? SlideRenderView(data: _pageDataFor(widget.currentIndex + 1))
            : Center(
                child: Text(
                  '— 마지막 —',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
      ),
    );
  }

  Widget _pointerBox(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(cs, '관객 화면 포인터'),
        const SizedBox(height: 6),
        SegmentedButton<PresenterPointerMode>(
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(fontSize: 11),
          ),
          segments: const [
            ButtonSegment(value: PresenterPointerMode.hand, label: Text('손가락')),
            ButtonSegment(value: PresenterPointerMode.dot, label: Text('레이저')),
            ButtonSegment(value: PresenterPointerMode.off, label: Text('숨김')),
          ],
          selected: {widget.pointerMode},
          onSelectionChanged: (s) => widget.onPointerModeChanged(s.first),
        ),
        if (widget.pointerMode != PresenterPointerMode.off) ...[
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: widget.pointerSize,
                  min: 40,
                  max: 260,
                  onChanged: widget.onPointerSizeChanged,
                ),
              ),
              Text(
                widget.pointerSize.round().toString(),
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          Text(
            '현재 슬라이드 위에서 마우스를 움직이면\n관객 화면에 그대로 표시됩니다.',
            style: TextStyle(
              fontSize: 11,
              height: 1.4,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _noteBox(ColorScheme cs) {
    final canWrite = _noteKey.isNotEmpty;
    return TextField(
      controller: _noteController,
      maxLines: 5,
      minLines: 3,
      enabled: canWrite,
      style: const TextStyle(fontSize: 12, height: 1.5),
      decoration: InputDecoration(
        isDense: true,
        hintText: canWrite
            ? '이 슬라이드에서 할 말을 적어두세요.\n콘티를 저장하면 함께 저장됩니다.'
            : '자동으로 들어간 빈 페이지에는\n메모를 저장할 수 없습니다.',
        hintMaxLines: 2,
        border: const OutlineInputBorder(),
      ),
      onChanged: (v) => widget.onNoteChanged(_noteKey, v),
    );
  }

  Widget _sectionLabel(ColorScheme cs, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
        color: cs.onSurfaceVariant,
      ),
    );
  }

  // 모든 페이지 보기. 기본 크기는 하단 스트립 썸네일과 비슷하게 두고,
  // 많아지면 세로로 스크롤한다. +/- 나 Ctrl(⌘)+휠로 크기를 바꾼다.
  Widget _allPagesGrid(ColorScheme cs) {
    void changeZoom(double delta) {
      setState(
        () => _view.gridThumbW = (_view.gridThumbW + delta).clamp(70.0, 460.0),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _sectionLabel(cs, '모든 페이지 · ${widget.slides.length}장'),
            const Spacer(),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () => changeZoom(-30),
              icon: const Icon(Icons.remove_rounded, size: 18),
              tooltip: '작게',
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () => changeZoom(30),
              icon: const Icon(Icons.add_rounded, size: 18),
              tooltip: '크게',
            ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent &&
                  (HardwareKeyboard.instance.isControlPressed ||
                      HardwareKeyboard.instance.isMetaPressed)) {
                changeZoom(-event.scrollDelta.dy * 0.6);
              }
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                const spacing = 8.0;
                const labelH = 20.0;
                const pad = 10.0;
                final avail = (constraints.maxWidth - pad * 2).clamp(
                  1.0,
                  double.infinity,
                );
                final cols = ((avail + spacing) / (_view.gridThumbW + spacing))
                    .floor()
                    .clamp(1, widget.slides.length.clamp(1, 9999));
                final tw = (avail - (cols - 1) * spacing) / cols;
                final cellH = tw / _thumbAspect + labelH;

                return GridView.builder(
                  padding: const EdgeInsets.all(pad),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    crossAxisSpacing: spacing,
                    mainAxisSpacing: spacing,
                    childAspectRatio: (tw / cellH).clamp(0.1, 100.0),
                  ),
                  itemCount: widget.slides.length,
                  itemBuilder: (context, i) => _SlideThumbnail(
                    data: _pageDataFor(i),
                    isSelected: i == widget.currentIndex,
                    index: i,
                    isEditable: !widget.slides[i].isAutoSpacer,
                    // 누른 페이지로 넘기고 발표자 보기로 돌아간다.
                    onTap: () {
                      widget.onSlideSelected(i);
                      setState(() => _view.showAllPages = false);
                    },
                    onEdit: () => widget.onSlideEdit(i),
                    onDelete: () => widget.onSlideDelete(i),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _thumbStrip(ColorScheme cs, double stripHeight) {
    final thumbW = _thumbWidthFor(stripHeight);
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        controller: _stripScrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        itemCount: widget.slides.length,
        itemBuilder: (context, i) {
          final hasNote = (widget.notes[_keyAt(i)] ?? '').isNotEmpty;
          return Padding(
            padding: EdgeInsets.only(
              right: i < widget.slides.length - 1 ? _stripSpacing : 0,
            ),
            child: SizedBox(
              width: thumbW,
              child: Stack(
                children: [
                  // 편집 탭의 슬라이드 순서와 같은 썸네일. 마우스를 올리면
                  // 수정·삭제 버튼이 그대로 나온다.
                  _SlideThumbnail(
                    data: _pageDataFor(i),
                    isSelected: i == widget.currentIndex,
                    index: i,
                    isEditable: !widget.slides[i].isAutoSpacer,
                    onTap: () => widget.onSlideSelected(i),
                    onEdit: () => widget.onSlideEdit(i),
                    onDelete: () => widget.onSlideDelete(i),
                  ),
                  // 수정/삭제 버튼이 오른쪽 위에 뜨므로 메모 표시는 왼쪽에.
                  if (hasNote)
                    Positioned(
                      top: 3,
                      left: 3,
                      child: Icon(
                        Icons.sticky_note_2_rounded,
                        size: 12,
                        color: cs.primary,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// 경과 시간만 따로 뗀 이유: 1초마다 setState 를 하면 콘솔 전체(슬라이드 미리보기
// 두 장 + 썸네일 전부)가 매초 다시 그려진다. 시계만 다시 그리게 가둔다.
class _ElapsedClock extends StatefulWidget {
  const _ElapsedClock({required this.isRunning, required this.state});

  final bool isRunning;
  final PresenterViewState state;

  @override
  State<_ElapsedClock> createState() => _ElapsedClockState();
}

class _ElapsedClockState extends State<_ElapsedClock> {
  Timer? _ticker;
  late final _targetController = TextEditingController(
    text: widget.state.targetMinutes.toString(),
  );

  // 시계 값은 위젯이 아니라 부모가 들고 있다(탭을 옮겨도 계속 흘러야 한다).
  Duration get _elapsed => widget.state.elapsed;
  bool get _isPaused => widget.state.isPaused;
  int get _targetMinutes => widget.state.targetMinutes;

  @override
  void initState() {
    super.initState();
    if (widget.isRunning) _start();
  }

  @override
  void didUpdateWidget(_ElapsedClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 발표를 새로 시작하면 0부터 다시.
    if (!oldWidget.isRunning && widget.isRunning) {
      widget.state.elapsed = Duration.zero;
      widget.state.isPaused = false;
      _start();
    } else if (oldWidget.isRunning && !widget.isRunning) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _targetController.dispose();
    super.dispose();
  }

  void _start() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _isPaused) return;
      setState(() => widget.state.elapsed += const Duration(seconds: 1));
    });
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final target = Duration(minutes: _targetMinutes);
    final ratio = target.inSeconds == 0
        ? 0.0
        : (_elapsed.inSeconds / target.inSeconds).clamp(0.0, 1.0);
    final over = _elapsed > target;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '경과 시간',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              _fmt(_elapsed),
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                height: 1.0,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: over ? cs.error : cs.onSurface,
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                TimeOfDay.now().format(context),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 5,
            backgroundColor: cs.surfaceContainerHighest,
            color: over ? cs.error : cs.primary,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 52,
              height: 32,
              child: TextField(
                controller: _targetController,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 6),
                  border: OutlineInputBorder(),
                ),
                // 입력하는 즉시 반영한다. 엔터를 안 치고 넘어가면 목표가 옛날 값으로
                // 남아 진행 막대가 엉뚱하게 보인다.
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n > 0) {
                    setState(() => widget.state.targetMinutes = n);
                  }
                },
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '분',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const Spacer(),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () =>
                  setState(() => widget.state.isPaused = !_isPaused),
              icon: Icon(
                _isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                size: 19,
              ),
              tooltip: _isPaused ? '계속' : '일시정지',
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () =>
                  setState(() => widget.state.elapsed = Duration.zero),
              icon: const Icon(Icons.restart_alt_rounded, size: 19),
              tooltip: '리셋',
            ),
          ],
        ),
      ],
    );
  }
}

// 이름을 한 줄 입력받는 다이얼로그.
// 컨트롤러를 다이얼로그 자신이 들고 있는 이유: 호출한 쪽에서 `await showDialog` 직후에
// dispose 하면 퇴장 애니메이션이 도는 동안 TextField 가 다시 그려지면서
// "A TextEditingController was used after being disposed" 로 터진다.
class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.label,
    required this.initialValue,
    this.hintText,
  });

  final String title;
  final String label;
  final String initialValue;
  final String? hintText;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hintText,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _submit, child: const Text('저장')),
      ],
    );
  }
}

// 현재 슬라이드 미리보기 위에 얹는 "관객 화면에 확대해서 보여줄 영역" 상자.
// 안쪽을 끌면 위치가, 오른쪽 아래 손잡이를 끌면 크기가 바뀐다. 빈 곳을 누르면
// 그 지점이 상자 가운데로 온다. 영역 비율은 슬라이드와 같으므로 크기 값 하나로 충분하다.
class _ZoomRegionOverlay extends StatelessWidget {
  const _ZoomRegionOverlay({
    required this.center,
    required this.scale,
    required this.onChanged,
  });

  final Offset center; // 0~1
  final double scale; // 영역 폭 / 슬라이드 폭
  final void Function(Offset center, double scale) onChanged;

  static const double _minScale = 0.12;
  static const double _maxScale = 0.9;
  static const double _handle = 22;

  // 상자가 슬라이드 밖으로 나가지 않게 가운데 좌표를 가둔다.
  Offset _clampCenter(Offset c, double s) {
    final half = s / 2;
    return Offset(c.dx.clamp(half, 1 - half), c.dy.clamp(half, 1 - half));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final boxW = w * scale;
        final boxH = h * scale;
        final left = center.dx * w - boxW / 2;
        final top = center.dy * h - boxH / 2;

        void moveTo(Offset local) {
          onChanged(
            _clampCenter(Offset(local.dx / w, local.dy / h), scale),
            scale,
          );
        }

        return Stack(
          children: [
            // 상자 밖은 어둡게 — 어디가 확대되는지 한눈에 보이게.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => moveTo(d.localPosition),
                child: CustomPaint(
                  painter: _ZoomDimPainter(
                    rect: Rect.fromLTWH(left, top, boxW, boxH),
                    color: Colors.black.withValues(alpha: 0.45),
                  ),
                ),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              width: boxW,
              height: boxH,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => onChanged(
                  _clampCenter(
                    Offset(
                      center.dx + d.delta.dx / w,
                      center.dy + d.delta.dy / h,
                    ),
                    scale,
                  ),
                  scale,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: cs.primary, width: 2),
                  ),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      color: cs.primary,
                      child: Text(
                        '${(1 / scale).toStringAsFixed(1)}x',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: cs.onPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 크기 조절 손잡이
            Positioned(
              left: left + boxW - _handle / 2,
              top: top + boxH - _handle / 2,
              width: _handle,
              height: _handle,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeUpLeftDownRight,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (d) {
                    final next = (scale + d.delta.dx / w * 2).clamp(
                      _minScale,
                      _maxScale,
                    );
                    onChanged(_clampCenter(center, next), next);
                  },
                  child: Center(
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: cs.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ZoomDimPainter extends CustomPainter {
  const _ZoomDimPainter({required this.rect, required this.color});

  final Rect rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRect(rect),
    );
    canvas.drawPath(outside, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ZoomDimPainter old) =>
      old.rect != rect || old.color != color;
}
