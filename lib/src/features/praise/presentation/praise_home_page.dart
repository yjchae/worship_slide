import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable, mapEquals, setEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';

// 가사 페이지 형식 함수는 lyrics_page_grid.dart 로 옮겼다. 예전처럼 이 파일에서도 보이게 둔다.
export 'lyrics_page_grid.dart'
    show encodePages, lyricsToEditText, normalizeEditableLyrics;

import '../../../app_colors.dart';
import '../../../app_theme.dart';
import '../../../features/bible/data/bible_repository.dart';
import '../../../features/bible/domain/bible_text_search.dart';
import '../../../features/bible/domain/bible_voice_parse.dart';
import '../../../features/bible/domain/bible_verse.dart';
import '../../../features/update/update_service.dart';
import '../data/app_logger.dart';
import '../data/export_style_store.dart';
import '../data/offering_background_composer.dart';
import '../data/offering_design_store.dart';
import '../data/sermon_design_store.dart';
import '../data/background_image_library.dart';
import '../data/font_library.dart';
import '../data/libreoffice_installer.dart';
import '../data/praise_repository.dart';
import '../data/python_bridge.dart';
import '../data/screen_choice_store.dart';
import '../data/singer_web_server.dart';
import '../data/sync_service.dart';
import '../data/sync_store.dart';
import '../data/source_file_watcher.dart';
import '../data/speech_listener.dart';
import '../data/worship_conti_repository.dart';
import '../domain/worship_conti.dart';
import '../domain/export_style.dart';
import '../domain/offering_design.dart';
import '../domain/praise_song.dart';
import '../domain/slide_background.dart';
import '../domain/slide_media.dart';
import '../domain/staging_item.dart';
import 'background_image_gallery.dart';
import 'libreoffice_install_dialog.dart';
import 'lyrics_editor_dialog.dart';
import 'lyrics_overlay_renderer.dart';
import 'lyrics_page_grid.dart';
import 'offering_dialog.dart';
import 'offering_overlay_painter.dart';
import 'presentation_timer.dart';
import 'singer_view_data.dart';
import 'slide_backdrop.dart';
import 'slide_page_data.dart';
import 'slide_render_view.dart';
import 'slide_text_layout.dart';
import 'cloud_conti_dialog.dart';
import 'conti_text_import_dialog.dart';
import 'sync_dialog.dart';

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
    this.extraText = '',
    required this.title,
    required this.isBible,
    required this.pageIndexInItem,
    this.isBlank = false,
    this.isAutoSpacer = false,
    this.imagePath,
    this.background,
    this.media,
  });
  final int stagingUid;
  final String mainText;
  final String englishText;
  // 추가 보조 줄(관객 화면 세 번째 줄).
  final String extraText;
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
  // 동영상·음악·유튜브 페이지, 또는 동영상이 든 PPT 페이지.
  final SlideMedia? media;
}

/// 발표 보기에서 복사·옮기는 콘티 항목 하나: 새 항목 + 배경 + 다음 조각과 여백 없이 이을지
/// (곡 + 떼어 낸 끝 빈 페이지) + 이 항목에 담긴 원래 페이지들.
typedef _SlidePiece = ({
  StagingItem item,
  SlideBackground? background,
  bool joinNext,
  List<_SlideInfo> pages,
});

/// 발표 보기 성경 음성 검색 상태 줄에 보일 것.
class _VoiceState {
  const _VoiceState({
    required this.version,
    this.heard = '',
    this.message = '',
    this.isError = false,
    this.insertedUids = const [],
    this.label = '',
  });

  /// 지금 찾는 역본.
  final String version;

  /// 지금 들리는 말(중간 결과).
  final String heard;

  /// 마지막으로 한 일(넣음·못 찾음).
  final String message;
  final bool isError;

  /// 마지막으로 넣은 항목들(띄우기·되돌리기 대상)과 그 구절.
  final List<int> insertedUids;
  final String label;

  _VoiceState copyWith({String? heard}) => _VoiceState(
    version: version,
    heard: heard ?? this.heard,
    message: message,
    isError: isError,
    insertedUids: insertedUids,
    label: label,
  );
}

/// 음성 넣기 직전(또는 직후) 콘티 상태. `_insertItemsAfterSlide` 가 곡·PPT 를 나누며 바꾸는 것만 담는다.
class _VoiceUndo {
  _VoiceUndo.capture(_PraiseHomePageState s)
    : items = List.of(s._stagingItems),
      noSpacer = Set.of(s._noSpacerUids),
      backgrounds = Map.of(s._itemBackgrounds),
      notes = Map.of(s._slideNotes),
      deleted = Set.of(s._deletedSlideKeys),
      mediaGroups = Map.of(s._mediaGroups);

  final List<({int uid, StagingItem item})> items;
  final Set<int> noSpacer;
  final Map<int, SlideBackground> backgrounds;
  final Map<String, String> notes;
  final Set<String> deleted;
  final Map<int, int> mediaGroups;

  /// 넣을 때 기준이 된 페이지(그 바로 뒤에 넣었다). 되돌린 뒤 관객 화면이 돌아갈 곳.
  int slideIndex = 0;

  /// 넣은 직후 상태. 지금이 이것과 하나라도 다르면(그 사이 메모·지우기·배경 등을 고침) 통째로 되돌리지 않는다.
  _VoiceUndo? after;

  bool _sameAs(_VoiceUndo o) {
    if (items.length != o.items.length) return false;
    for (var i = 0; i < items.length; i++) {
      if (items[i].uid != o.items[i].uid ||
          !identical(items[i].item, o.items[i].item)) {
        return false;
      }
    }
    return setEquals(noSpacer, o.noSpacer) &&
        mapEquals(backgrounds, o.backgrounds) &&
        mapEquals(notes, o.notes) &&
        setEquals(deleted, o.deleted) &&
        mapEquals(mediaGroups, o.mediaGroups);
  }

  /// 되돌렸으면 true. setState 안에서 부른다.
  bool restore(_PraiseHomePageState s) {
    final expected = after;
    if (expected == null || !_VoiceUndo.capture(s)._sameAs(expected)) {
      return false;
    }
    s._stagingItems
      ..clear()
      ..addAll(items);
    s._noSpacerUids
      ..clear()
      ..addAll(noSpacer);
    s._itemBackgrounds
      ..clear()
      ..addAll(backgrounds);
    s._slideNotes
      ..clear()
      ..addAll(notes);
    s._deletedSlideKeys
      ..clear()
      ..addAll(deleted);
    s._mediaGroups
      ..clear()
      ..addAll(mediaGroups);
    return true;
  }
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
  // 구글 드라이브(관리자가 건넨 접속 키)로 여러 PC 의 찬양을 맞추고 콘티를 주고받는다(모두 손으로).
  final SyncService _sync = SyncService();
  final PythonBridge _pythonBridge = PythonBridge();
  final ExportStyleStore _styleStore = ExportStyleStore();
  final OfferingDesignStore _offeringStore = OfferingDesignStore();
  final ScreenChoiceStore _screenStore = ScreenChoiceStore();
  // 관객·싱어 창을 띄울 모니터. null = 자동.
  ScreenChoice? _audienceScreen;
  ScreenChoice? _singerScreen;
  final OfferingBackgroundComposer _offeringComposer =
      OfferingBackgroundComposer();
  final BackgroundImageLibrary _backgroundImages = BackgroundImageLibrary();
  final BackgroundImageLibrary _backgroundVideos =
      const BackgroundImageLibrary.videos();
  // 배경 영상 위에 얹을 가사 PNG.
  final LyricsOverlayRenderer _lyricsOverlays = LyricsOverlayRenderer();
  final BibleRepository _bibleRepository = BibleRepository();

  // 발표 보기 성경 음성 검색. null = 꺼짐. 켜 두는 동안 계속 듣는다.
  final SpeechListener _speech = SpeechListener();
  final ValueNotifier<_VoiceState?> _voice = ValueNotifier(null);
  List<String> _voiceVersions = const [];
  // 이어 말하기("17절")·역본은 켤 때마다 새로 시작한다.
  String _voiceVersion = '';
  int? _voiceBook;
  int? _voiceChapter;
  // 같은 구절을 여러 번 말해도 한 번만 넣는다(구절 → 넣은 시각).
  final Map<String, DateTime> _voiceRecent = {};
  // 역본마다 책 이름(말할 때마다 3만여 절을 다시 훑지 않게).
  final Map<String, List<String>> _voiceBooks = {};
  // 들은 마디를 하나씩 차례로 처리한다(빨리 연달아 와도 순서·중복 검사가 꼬이지 않게).
  Future<void> _voiceQueue = Future.value();
  // 마지막으로 음성으로 넣은 항목과 그때 보던 페이지. 페이지를 안 넘기고 또 말하면 그 뒤에 잇는다
  // (안 그러면 둘째 구절이 첫째 앞에 들어가 순서가 뒤집힌다).
  ({String currentKey, int lastUid})? _voiceChain;
  // 마지막 넣기 직전 콘티 상태. 되돌리기 때 곡을 나눈 것까지 되돌린다.
  _VoiceUndo? _voiceUndo;
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
  // 뒤 자동 여백을 뺀 항목 uid(곡 중간 붙여 넣기, 여백 페이지 삭제). 저장·PPTX 에도 실린다.
  final Set<int> _noSpacerUids = {};
  // 헌금송 기본 디자인(배경·은행·계좌). 항목에 적용할 때 여기서 시작해 높낮이만 곡마다 맞춘다.
  OfferingDesign _offeringDesign = const OfferingDesign();
  // offering_design.json 이 있으면(한 번이라도 등록했으면) true. 배경·계좌 없이 등록해도 된다.
  bool _offeringRegistered = false;
  // 설교 제목 페이지 기본 디자인. 마지막으로 쓴 디자인을 다음 설교 페이지가 이어받는다.
  final SermonDesignStore _sermonStore = SermonDesignStore();
  SlideBackground? _sermonDesign;
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
  // 싱어용 화면(현재 + 다음 페이지). 발표 창과 따로 뜨는 두 번째 네이티브 창이다.
  bool _isSingerOpen = false;
  // 같은 망 휴대폰용 싱어 화면(웹). 발표를 끝내면 같이 끈다.
  final SingerWebServer _singerWeb = SingerWebServer();
  // 창을 닫아 앱이 끝날 때는 dispose 가 불리지 않는다. 그대로 두면 cloudflared 터널 프로세스가
  // 앱 밖에 남으므로 종료 요청 때 끈다. 이 신호가 안 오는 경우(강제 종료, Windows 에서 발표 창이
  // 열린 채 닫기 등)는 다음 시작 때 [SingerWebServer.killLeftoverTunnel] 이 치운다.
  late final AppLifecycleListener _exitListener;

  // '원본 열어 수정' 으로 연 PPT 가 저장되면 다시 굽는다.
  late final SourceFileWatcher _sourceWatcher = SourceFileWatcher(
    onChanged: (path) => unawaited(_reloadImageSource(path, automatic: true)),
  );
  // 같은 파일을 겹쳐 굽지 않게 지금 굽고 있는 원본 경로.
  final Set<String> _reloadingSources = {};
  // 굽는 동안 또 저장된 원본. 끝나면 한 번 더 굽는다.
  final Set<String> _reloadAgainSources = {};
  final Set<String> _deletedSlideKeys = {};
  // 발표 보기에서 복사한 페이지. 복사하는 순간의 내용을 콘티 항목으로 떠 둔다.
  List<_SlidePiece> _slideClipboard = const [];
  // 옮기거나 나누느라 새 uid 를 받은 항목 → 원래 미디어 묶음. 발표 창의 미디어 키가 같게 남아
  // 재생 중인 동영상을 처음부터 다시 틀지 않는다. 없으면 uid 자신이 묶음이다.
  final Map<int, int> _mediaGroups = {};

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
    // 일시정지·리셋·목표를 바꾸면 싱어 화면(네이티브·휴대폰)도 바로 맞춘다.
    _presenterView.timer.addListener(_sendSingerView);
    _exitListener = AppLifecycleListener(
      onExitRequested: () async {
        // 무슨 일이 있어도 앱은 닫혀야 한다.
        await _singerWeb
            .stop()
            .timeout(const Duration(seconds: 3))
            .catchError((_) {});
        return AppExitResponse.exit;
      },
    );
    unawaited(SingerWebServer.killLeftoverTunnel());
    _singerWeb.onControl = _handleRemoteControl;
    // 탭 전환에 애니메이션을 쓰지 않는다. TabBarView(PageView) 의 전환 애니메이션이
    // 중간에 멈추면(발표 창이 뜨면서 메인 창이 가려지는 등으로 프레임이 끊길 때)
    // 내부 카운터가 0으로 안 돌아와 탭이 영영 안 넘어간다.
    _mainTabController = TabController(
      length: 2,
      vsync: this,
      animationDuration: Duration.zero,
    )..addListener(_onMainTabChanged);
    _loadSongs();
    _repository.onSongsChanged = _sync.markLocalChanged;
    // 자동으로 하는 건 켤 때 한 번 서버를 보는 것뿐이다.
    _sync.load().then((_) => _checkServerOnStartup());
    _loadSavedStyle();
    _loadOfferingDesign();
    _sermonStore.load().then((v) {
      if (mounted && v != null) setState(() => _sermonDesign = v);
    });
    _screenStore.load().then((v) {
      if (!mounted) return;
      setState(() {
        _audienceScreen = v.$1;
        _singerScreen = v.$2;
      });
    });
    _loadBibleCount();
    _loadSubLanguages();
    _searchController.addListener(_loadSongs);
    _checkForUpdates(isStartup: true);
    HardwareKeyboard.instance.addHandler(_handleStartKey);
    _mainPresentationChannel.setMethodCallHandler((call) async {
      if (!mounted) return null;
      switch (call.method) {
        case 'presentationClosed':
          // 발표가 끝나면 싱어 화면도 같이 닫는다.
          await _closeSingerWindow();
          if (mounted) setState(_resetPresentationState);
        case 'singerClosed':
          setState(() => _isSingerOpen = false);
        case 'mediaState':
          _mediaPlayback.value = MediaPlayback.tryParse(call.arguments);
        case 'singerKey':
          // 싱어 화면을 클릭해 포커스가 그쪽에 가 있어도 넘기기는 되게 한다.
          if (call.arguments == 'next') {
            await _nextSlide();
          } else if (call.arguments == 'prev') {
            await _prevSlide();
          }
      }
      return null;
    });
  }

  void _onMainTabChanged() {
    // 성경 음성 검색은 발표 보기에서만 쓴다.
    if (_mainTabController.index != 1 && _voice.value != null) _stopVoice();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _speech.stop();
    _voice.dispose();
    _presenterView.timer.removeListener(_sendSingerView);
    _presenterView.timer.dispose();
    _exitListener.dispose();
    _mediaPlayback.dispose();
    _remoteSyncTimer?.cancel();
    _singerWeb.stop();
    _sourceWatcher.dispose();
    _repository.onSongsChanged = null;
    _sync.dispose();
    HardwareKeyboard.instance.removeHandler(_handleStartKey);
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

  /// 항목이 만드는 페이지 수(자동 여백 제외).
  static int _pageCount(StagingItem item) => switch (item) {
    SongStagingItem(:final song) => song.pairedPages.length,
    ImageStagingItem(:final imagePaths) => imagePaths.length,
    _ => 1,
  };

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
        result.add(
          kept.length == pairs.length
              ? entry
              : (uid: uid, item: SongStagingItem(_songWithPages(song, kept))),
        );
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
                  // 지운 페이지만 빠졌을 뿐 원본 파일 그대로라 다시 굽기는 남긴다.
                  item: ImageStagingItem(
                    sourceName: item.sourceName,
                    imagePaths: kept,
                    sourcePath: item.sourcePath,
                  ),
                ),
        );
      } else if (item is BibleStagingItem) {
        if (!_deletedSlideKeys.contains(_slideKey(uid, 0))) result.add(entry);
      } else if (item is BlankStagingItem) {
        // 발표 화면(_allSlides)에서 지운 빈 페이지는 저장·내보내기에서도 뺀다.
        if (!_deletedSlideKeys.contains(_slideKey(uid, 0))) result.add(entry);
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
      final total = _pageCount(item);
      var newIndex = 0;
      for (var j = 0; j < total; j++) {
        if (_deletedSlideKeys.contains(_slideKey(uid, j))) continue;
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
    // 추가 보조가 보조와 같은 언어면 추가 보조는 없는 것(_extraLyricsFor)이라 그 값으로 비교한다 —
    // 보조만 바꿔도 추가 보조가 비거나 다시 채워질 수 있다.
    String effectiveExtra(ExportStyle s) =>
        s.extraLanguage == s.subLanguage ? '' : s.extraLanguage;
    final subChanged = style.subLanguage != _style.subLanguage;
    final extraChanged = effectiveExtra(style) != effectiveExtra(_style);
    // 성경도 같다 — 추가 역본이 보조 역본과 같으면 없는 것(_bibleItemsFor).
    String effectiveBibleExtra(ExportStyle s) =>
        s.bibleExtraVersion == s.bibleSubVersion ? '' : s.bibleExtraVersion;
    final bibleSubChanged = style.bibleSubVersion != _style.bibleSubVersion;
    final bibleExtraChanged =
        effectiveBibleExtra(style) != effectiveBibleExtra(_style);
    setState(() => _style = style);
    await _styleStore.save(style);
    if (subChanged || extraChanged) {
      await _reapplySubLanguage(
        subChanged: subChanged,
        extraChanged: extraChanged,
      );
    }
    if (bibleSubChanged || bibleExtraChanged) {
      await _reapplyBibleVersions(
        subChanged: bibleSubChanged,
        extraChanged: bibleExtraChanged,
      );
    }
    await _sendCurrentSlide();
  }

  // ── 보조 언어 ────────────────────────────────────────────────────────
  //
  // 곡을 콘티에 담는 순간 선택한 언어의 가사를 englishLyrics 슬롯에 확정해 넣는다
  // (가사 스냅샷과 같은 방식). 그래서 슬라이드·미리보기·내보내기·발표 창은
  // 다국어를 전혀 몰라도 된다 — 원래 영어가 오던 자리에 그 언어가 올 뿐이다.

  Future<PraiseSong> _withSubLyrics(PraiseSong song) async {
    final sub = await _repository.subLyricsFor(song, _style.subLanguage);
    final extra = await _extraLyricsFor(song);
    if (sub == song.englishLyrics && extra == song.extraLyrics) return song;
    return song.copyWith(englishLyrics: sub, extraLyrics: extra);
  }

  /// 추가 보조 언어 가사. 언어를 안 골랐거나 보조와 같은 언어면 빈 문자열.
  Future<String> _extraLyricsFor(PraiseSong song) async {
    final language = _style.extraLanguage;
    if (language.isEmpty || language == _style.subLanguage) return '';
    return _repository.subLyricsFor(song, language);
  }

  /// 언어를 바꿨을 때 이미 담아 둔 곡들의 보조 가사를 다시 입힌다.
  /// 본문(한글) 가사는 슬라이드에서 고쳤을 수 있으므로 그대로 둔다.
  /// 바뀐 언어 칸에서 원본 페이지를 못 찾은 페이지(이 콘티에서 고친 페이지)는 비운다 —
  /// 옛 언어 글이 남지 않게. 바뀌지 않은 칸은 그대로 둔다(콘티에서 고친 번역 보존).
  Future<void> _reapplySubLanguage({
    required bool subChanged,
    required bool extraChanged,
  }) async {
    final updated = <(int, StagingItem)>[];
    for (var i = 0; i < _stagingItems.length; i++) {
      final item = _stagingItems[i].item;
      if (item is! SongStagingItem) continue;
      final matches = _songs.where((s) => s.id == item.song.id);
      if (matches.isEmpty) continue;
      final base = matches.first;
      // 바뀐 언어만 읽는다(안 바뀐 칸은 아래에서 지금 값을 그대로 쓴다).
      final sub = subChanged
          ? await _repository.subLyricsFor(base, _style.subLanguage)
          : item.song.englishLyrics;
      final extra = extraChanged
          ? await _extraLyricsFor(base)
          : item.song.extraLyrics;
      final full = base
          .copyWith(englishLyrics: sub, extraLyrics: extra)
          .pairedPages;
      final mine = item.song.pairedPages;
      // 곡을 나누거나 일부만 복사한 항목은 같은 가사 페이지를 찾아 그 번역만 입힌다.
      final byMain = {for (final f in full) f.korean: f};
      // 추가 보조가 원본보다 길면 장 수만으로는 통째인지 모르므로 원본 가사도 본다.
      final whole =
          item.song.lyrics == base.lyrics || mine.length == full.length;
      final newSub = !subChanged
          ? item.song.englishLyrics
          : whole
          ? sub
          : encodePages(mine.map((m) => byMain[m.korean]?.english ?? ''));
      final newExtra = !extraChanged
          ? item.song.extraLyrics
          : whole
          ? extra
          : encodePages(mine.map((m) => byMain[m.korean]?.extra ?? ''));
      if (newSub == item.song.englishLyrics &&
          newExtra == item.song.extraLyrics) {
        continue;
      }
      updated.add((
        i,
        SongStagingItem(
          item.song.copyWith(englishLyrics: newSub, extraLyrics: newExtra),
        ),
      ));
    }
    if (updated.isEmpty || !mounted) return;
    // 보던 슬라이드는 번호가 아니라 (항목, 페이지)로 다시 찾는다 — 앞 곡 장 수가 바뀌어도 관객 화면이 안 넘어가게.
    final slides = _allSlides;
    final current = _currentSlideIndex < slides.length
        ? slides[_currentSlideIndex]
        : null;
    setState(() {
      for (final (index, item) in updated) {
        final entry = _stagingItems[index];
        // 번역이 원본보다 길면 장 수가 바뀐다. 앞 페이지 번호는 그대로라 지운 표시·메모는 두고
        // 자동 여백 것만 새 끝으로 옮긴다.
        remapTrailingPages(
          uid: entry.uid,
          oldCount: _pageCount(entry.item),
          newCount: _pageCount(item),
          deletedKeys: _deletedSlideKeys,
          notes: _slideNotes,
        );
        _stagingItems[index] = (uid: entry.uid, item: item);
      }
      if (current != null) {
        final found = _allSlides.indexWhere(
          (s) =>
              s.stagingUid == current.stagingUid &&
              s.isAutoSpacer == current.isAutoSpacer &&
              (current.isAutoSpacer ||
                  s.pageIndexInItem == current.pageIndexInItem),
        );
        if (found >= 0) _currentSlideIndex = found;
      }
      _clampCurrentSlideIndex();
    });
  }

  /// 보조·추가 역본을 바꿨을 때 이미 담아 둔 성경 항목에도 다시 입힌다 (찬양의 [_reapplySubLanguage] 와 같은 일).
  /// 역본·책·장·절은 항목 참조(`역본 책 장:절`)에서 다시 푼다. 바뀐 칸만 고치므로 안 바뀐 칸에서 손으로
  /// 고친 글은 남는다. 참조를 못 풀거나 그 역본에 짝 책이 없으면 그 칸을 비운다(옛 역본 글이 남지 않게).
  /// 성경 항목은 늘 한 장이라 장 수·보던 슬라이드는 그대로다.
  Future<void> _reapplyBibleVersions({
    required bool subChanged,
    required bool extraChanged,
  }) async {
    final subVersion = _style.bibleSubVersion;
    final extraVersion = _style.bibleExtraVersion == subVersion
        ? ''
        : _style.bibleExtraVersion;
    final chapters = <(String, String, String, int), Map<int, String>?>{};
    Future<String> textIn(String other, BibleReference? ref) async {
      if (ref == null) return '';
      final key = (other, ref.version, ref.book, ref.chapter);
      if (!chapters.containsKey(key)) {
        chapters[key] = await _loadOtherVersionVerses(
          _bibleRepository,
          other,
          ref.version,
          ref.book,
          ref.chapter,
        );
      }
      return verseNumbersText(ref.verses, chapters[key]);
    }

    final updated = <int, (BibleStagingItem, BibleStagingItem)>{};
    for (final entry in List.of(_stagingItems)) {
      final item = entry.item;
      if (item is! BibleStagingItem) continue;
      final ref = parseBibleReference(item.reference, _bibleVersions);
      final sub = subChanged ? await textIn(subVersion, ref) : item.subText;
      final extra = extraChanged
          ? await textIn(extraVersion, ref)
          : item.extraText;
      if (sub == item.subText && extra == item.extraText) continue;
      updated[entry.uid] = (
        item,
        BibleStagingItem(
          reference: item.reference,
          text: item.text,
          subText: sub,
          extraText: extra,
        ),
      );
    }
    if (updated.isEmpty || !mounted) return;
    setState(() {
      for (var i = 0; i < _stagingItems.length; i++) {
        final entry = _stagingItems[i];
        final change = updated[entry.uid];
        // 읽는 사이 그 항목을 고쳤으면(가사 수정 등) 고친 쪽을 둔다.
        if (change == null || !identical(entry.item, change.$1)) continue;
        _stagingItems[i] = (uid: entry.uid, item: change.$2);
      }
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
      // 다음이 직접 넣은 빈 페이지여도 자동 여백은 그대로 둔다 — 빈 페이지를
      // 추가하면 실제로 한 장이 늘어나야 한다(ppt_tool.py export 와 같은 규칙).
      // 항목에 배경 오버라이드가 걸려 있으면 그 항목이 만드는 모든 페이지가
      // (뒤에 자동으로 붙는 여백까지) 같은 배경을 쓴다.
      final background = _itemBackgrounds[entry.uid];

      if (item is BlankStagingItem) {
        tryAdd(
          _SlideInfo(
            stagingUid: entry.uid,
            mainText: item.mainText,
            englishText: item.englishText,
            extraText: item.extraText,
            title: null,
            isBible: false,
            pageIndexInItem: 0,
            isBlank: true,
            background: background,
            media: item.media,
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
              extraText: pairs[j].extra,
              title: song.displayTitle,
              isBible: false,
              pageIndexInItem: j,
              background: background,
            ),
          );
        }
        if (!isLast && !_noSpacerUids.contains(entry.uid)) {
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
              media: _pptMedia(item.imagePaths[j]),
            ),
          );
        }
        if (!isLast && !_noSpacerUids.contains(entry.uid)) {
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
            extraText: item.extraText,
            title: item.reference,
            isBible: true,
            pageIndexInItem: 0,
            background: background,
          ),
        );
        // 말씀 다음이 말씀이면 빈 페이지 삽입 안 함
        if (!isLast &&
            !_noSpacerUids.contains(entry.uid) &&
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

  /// 항목 uid → 가사 상자를 넘는 페이지 수(콘티 목록의 '넘침 N'). 재는 값은 기억해 두므로
  /// 다시 그릴 때마다 TextPainter 를 돌리지 않는다.
  Map<int, int> _overflowCounts() {
    // 다시 그릴 때마다 모든 페이지를 재지 않게, 넘침에 영향을 주는 것이 그대로면 지난 값을 쓴다.
    // 항목·배경은 바뀔 때 새 객체로 갈아 끼우므로 identity 로 충분하다.
    final signature = Object.hash(
      identityHashCode(_style),
      Object.hashAll([
        for (final e in _stagingItems) ...[e.uid, identityHashCode(e.item)],
      ]),
      Object.hashAllUnordered([
        for (final e in _itemBackgrounds.entries)
          Object.hash(e.key, identityHashCode(e.value)),
      ]),
      Object.hashAllUnordered(_deletedSlideKeys),
      Object.hashAllUnordered(_noSpacerUids),
    );
    if (signature == _overflowSignature) return _overflowCountsMemo;
    _overflowSignature = signature;
    return _overflowCountsMemo = _measureOverflowCounts();
  }

  int? _overflowSignature;
  Map<int, int> _overflowCountsMemo = const {};

  Map<int, int> _measureOverflowCounts() {
    final slides = _allSlides;
    final counts = <int, int>{};
    for (var i = 0; i < slides.length; i++) {
      final slide = slides[i];
      final page = SlidePageData(
        mainText: slide.mainText,
        englishText: slide.englishText,
        extraText: slide.extraText,
        isBible: slide.isBible,
        pageIndex: i,
        totalPages: slides.length,
        style: _style.withBackground(slide.background),
        imagePath: slide.imagePath,
      );
      if (SlideTextLayout.overflows(page)) {
        counts.update(slides[i].stagingUid, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return counts;
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

  int _mediaGroupOf(int stagingUid) => _mediaGroups[stagingUid] ?? stagingUid;

  SlidePageData _buildSlidePageData(int index, [List<_SlideInfo>? allSlides]) {
    final slides = allSlides ?? _allSlides;
    final slide = index < slides.length ? slides[index] : null;
    return SlidePageData(
      mainText: slide?.mainText ?? '',
      englishText: slide?.englishText ?? '',
      extraText: slide?.extraText ?? '',
      title: slide?.title,
      isBible: slide?.isBible ?? false,
      pageIndex: index,
      totalPages: slides.length,
      style: _style.withBackground(slide?.background),
      imagePath: slide?.imagePath,
      media: slide?.media,
      mediaGroup: slide == null ? null : _mediaGroupOf(slide.stagingUid),
      backdrop: _backdropFor(slide, checkFile: true),
    );
  }

  /// 발표 창에 보낼 페이지. 배경 영상이 걸린 페이지면 가사 PNG 를 구워 싣는다
  /// (못 구우면 평소 슬라이드). 다음 페이지 것도 미리 굽기 시작한다 — 넘길 때 기다리지 않게.
  ///
  /// [isStale] 이 있으면 아직 안 구운 페이지는 잠깐 기다렸다가, 그 사이 더 새 요청이 왔으면
  /// 굽지 않고 null — 디자인 슬라이더를 끄는 동안 값마다 1920x1080 PNG 를 굽지 않게.
  Future<SlidePageData?> _presentablePage(
    int index,
    List<_SlideInfo> slides, {
    bool Function()? isStale,
  }) async {
    final page = _buildSlidePageData(index, slides);
    final backdrop = page.backdrop;
    if (backdrop == null) return page;
    if (isStale != null && !_lyricsOverlays.isCached(page)) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      if (isStale()) return null;
    }
    final overlay = await _lyricsOverlays.render(page);
    if (index + 1 < slides.length) {
      final next = _buildSlidePageData(index + 1, slides);
      if (next.backdrop != null) unawaited(_lyricsOverlays.render(next));
    }
    return page.withBackdrop(
      overlay == null ? null : backdrop.withOverlay(overlay),
    );
  }

  // PPT 페이지 이미지 옆 `.media.json`(ppt_tool render 가 동영상을 꺼내 둔 것). 페이지를
  // 나누거나 복사해도 경로가 따라가므로 콘티 모델은 이걸 모른다. _allSlides 가 자주 불리니
  // 한 번 읽은 결과를 기억한다 — 렌더 캐시는 굽고 나면 바뀌지 않는다.
  final Map<String, SlideMedia?> _pptMediaCache = {};

  SlideMedia? _pptMedia(String imagePath) {
    final base = _pptMediaCache.putIfAbsent(imagePath, () {
      final file = File(p.setExtension(imagePath, '.media.json'));
      try {
        if (!file.existsSync()) return null;
        final json = jsonDecode(file.readAsStringSync()) as Map;
        final video = p.join(p.dirname(imagePath), json['file'] as String);
        return SlideMedia.fromJson({
          'kind': 'video',
          'source': video,
          'rect': json['rect'],
        });
      } catch (_) {
        return null;
      }
    });
    return base?.copyWith(
      fadeIn: _style.mediaFadeIn,
      fadeOut: _style.mediaFadeOut,
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
      final pageData = (await _presentablePage(
        _currentSlideIndex,
        _allSlides,
      ))!;
      _noteSentMedia(pageData);
      await _presentationChannel.invokeMethod('openWindow', {
        ...pageData.toJson(),
        'screen': await _screenIndex(_audienceScreen),
      });
      if (!mounted) return;
      // 검색창에 커서가 있어도 발표 시작 시엔 단축키가 먹어야 한다.
      FocusManager.instance.primaryFocus?.unfocus();
      _presentationFocusNode.requestFocus();
      setState(() {
        _isPresentationOpen = true;
      });
      _presenterView.timer.start();
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
    if (_isPresentationOpen) _presenterView.timer.stop();
    _isPresentationOpen = false;
    _isBlackout = false;
    // 발표 창을 닫으면 네이티브 쪽 확대 상태도 함께 사라진다(macOS 는 컨트롤러를
    // 통째로 버린다). Dart 쪽만 켜져 있으면 다음 발표에서 어긋나므로 같이 끈다.
    _isZoomOn = false;
    _sentMediaKey = null;
    _mediaPlayback.value = null;
    _singerWeb.stop();
  }

  Future<void> _closePresentation() async {
    await _closeSingerWindow();
    try {
      await _presentationChannel.invokeMethod('closeWindow');
    } catch (_) {}
    if (mounted) setState(_resetPresentationState);
  }

  Future<void> _toggleBlackout() async {
    if (!_isPresentationOpen) return;
    // 네이티브 'blackout' 은 토글이다. 값을 먼저 바꿔 둬야 응답을 기다리는 사이 온 리모컨 요청
    // (on=1 두 번 등)이 옛 값을 보고 한 번 더 토글하지 않는다.
    setState(() => _isBlackout = !_isBlackout);
    try {
      await _presentationChannel.invokeMethod('blackout');
    } catch (_) {
      // 그 사이 발표가 끝났으면 _resetPresentationState 가 이미 false 로 돌려 두었다.
      if (mounted && _isPresentationOpen) {
        setState(() => _isBlackout = !_isBlackout);
      }
      return;
    }
    // 싱어 화면은 가사를 계속 보여 주고 "관객 화면 꺼짐" 표시만 바꾼다.
    await _sendSingerView();
  }

  // ── 싱어 화면 ───────────────────────────────────────────────────────────

  /// [originalOnly] = 휴대폰(싱어·리모컨)용: 보조 가사를 빼고 원본만. 설교 부제는 내용이라 둔다.
  SingerViewData _buildSingerViewData([
    List<_SlideInfo>? allSlides,
    bool originalOnly = false,
  ]) {
    final slides = allSlides ?? _allSlides;
    final index = slides.isEmpty
        ? 0
        : _currentSlideIndex.clamp(0, slides.length - 1);
    SingerPage? pageAt(int i) {
      if (i < 0 || i >= slides.length) return null;
      final slide = slides[i];
      return SingerPage(
        mainText: slide.mainText,
        // 디자인에서 보조 언어를 꺼 두면 싱어 화면에서도 뺀다(관객 화면과 같게).
        // 설교 부제는 이 스위치와 상관없이 보이므로 그 페이지 style 로 본다.
        englishText:
            (originalOnly && !(slide.background?.isSermon ?? false)) ||
                !_style.withBackground(slide.background).includeEnglishLyrics
            ? ''
            : slide.englishText,
        title: slide.title,
        imagePath: slide.imagePath,
      );
    }

    return SingerViewData(
      current: pageAt(index) ?? const SingerPage(mainText: ''),
      next: pageAt(index + 1),
      pageNumber: slides.isEmpty ? 0 : index + 1,
      totalPages: slides.length,
      isBlackout: _isBlackout,
      clock: _presenterView.timer.toSingerJson(),
    );
  }

  Future<void> _toggleSingerWindow() async {
    if (_isSingerOpen) {
      await _closeSingerWindow();
      return;
    }
    if (!_isPresentationOpen) return;
    try {
      final json = _buildSingerViewData().toJson();
      await _presentationChannel.invokeMethod('openSingerWindow', {
        ...json,
        'screen': await _screenIndex(_singerScreen, singer: true),
      });
      _lastSingerJson = _singerDedupeKey(json);
      if (mounted) setState(() => _isSingerOpen = true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('싱어 화면 열기 실패: $e')));
    }
  }

  // ── 휴대폰 싱어 화면 ────────────────────────────────────────────────────

  /// 켜져 있지 않으면 켜고, 휴대폰에서 열 주소를 보여 준다. 다이얼로그에서 끌 수 있다.
  bool _isMobileSingerBusy = false; // 두 번 눌러 다이얼로그가 둘 뜨지 않게

  Future<void> _showMobileSinger() async {
    if (_isMobileSingerBusy) return;
    _isMobileSingerBusy = true;
    try {
      await _showMobileSingerDialog();
    } finally {
      _isMobileSingerBusy = false;
    }
  }

  Future<void> _showMobileSingerDialog() async {
    try {
      // 앞서 걸어 둔 stop(발표 종료) 이 있으면 그 뒤에 켜진다.
      await _singerWeb.start();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('휴대폰 싱어 화면 켜기 실패: $e')));
      return;
    }
    if (!mounted) return;
    setState(() {});
    await _sendSingerView();
    final addresses = await SingerWebServer.lanAddresses();
    if (!mounted) return;
    // 싱어 화면(보기만) / 발표자 리모컨(넘기기·확대·블랙아웃). 키가 달라 QR 도 다르다.
    var remote = false;
    // 주소 줄과 QR 을 왼쪽에 맞춘다(주소 길이가 달라도 QR 이 같은 자리에).
    Widget qr(String url) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SelectableText(
                url,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 4),
            // 단톡방 등에 붙여 넣기 쉽게.
            _CopyTextButton(text: url),
          ],
        ),
        const SizedBox(height: 8),
        // 휴대폰 카메라가 어두운 테마에서도 읽게 늘 흰 바탕.
        // QrImageView 는 안에 LayoutBuilder 가 있어 AlertDialog 의 크기 재기
        // (intrinsic/dry layout)에서 터진다. 그래서 QrPainter 를 직접 그린다.
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(10),
          child: CustomPaint(
            size: const Size.square(180),
            painter: QrPainter(data: url, version: QrVersions.auto),
          ),
        ),
      ],
    );
    final stop = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final urls = [
            for (final a in addresses) _singerWeb.urlFor(a, remote: remote),
          ];
          return AlertDialog(
            // QR 이 두 줄(바깥 망 + 같은 망)이라 작은 화면에서 넘치지 않게.
            scrollable: true,
            title: Row(
              children: [
                const Expanded(child: Text('휴대폰 화면')),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('싱어 화면')),
                    ButtonSegment(value: true, label: Text('발표자 리모컨')),
                  ],
                  selected: {remote},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) =>
                      setDialogState(() => remote = v.first),
                ),
              ],
            ),
            // 발표가 끝나 서버가 꺼지면 QR 대신 꺼졌다고 보여 준다(찍어도 접속이 안 되므로).
            content: ValueListenableBuilder<bool>(
              valueListenable: _singerWeb.running,
              builder: (context, running, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!running)
                    const Text('휴대폰 싱어 화면이 꺼졌습니다. 발표를 다시 시작한 뒤 켜 주세요.')
                  else ...[
                    // 다른 망(LTE·다른 와이파이)용 공개 주소. 터널은 몇 초 걸려서 따로 듣는다.
                    ValueListenableBuilder<TunnelState>(
                      valueListenable: _singerWeb.tunnel,
                      builder: (context, state, _) => switch (state) {
                        TunnelState.ready => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('어느 망에서든(LTE 포함) 이 QR 이나 주소로 열 수 있습니다.'),
                            const SizedBox(height: 8),
                            qr(_singerWeb.publicUrl(remote: remote)!),
                            const SizedBox(height: 16),
                          ],
                        ),
                        TunnelState.connecting => const Padding(
                          padding: EdgeInsets.only(bottom: 16),
                          child: Text('바깥 망 주소를 만드는 중...'),
                        ),
                        TunnelState.failed => const Padding(
                          padding: EdgeInsets.only(bottom: 16),
                          child: Text(
                            '바깥 망 연결이 안 됩니다. 자동으로 다시 시도하는 중입니다.\n'
                            '인터넷 연결을 확인해 주세요. 같은 와이파이 주소는 그대로 쓸 수 있습니다.',
                          ),
                        ),
                        TunnelState.missing => Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '다른 망(LTE 등)에서도 보려면 cloudflared 가 필요합니다.',
                              ),
                              const SizedBox(height: 8),
                              _CloudflaredInstallButton(
                                onInstalled: _singerWeb.retryTunnel,
                                onOpenDownloadPage: () => _openUrl(
                                  'https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/',
                                ),
                              ),
                            ],
                          ),
                        ),
                        TunnelState.off => const SizedBox.shrink(),
                      },
                    ),
                    if (remote) ...[
                      Text(
                        '좌우로 밀기·화면 양쪽 끝 누르기 = 페이지 넘기기, 두 손가락 벌리기 = 확대(관객 화면도 같이),\n'
                        '두 번 누르기 = 확대 풀기, \'화면 끄기\' 길게 누르기 = 블랙아웃. 발표자 메모도 보입니다.\n'
                        '이 QR 은 발표를 조작할 수 있으니 발표자만 찍으세요.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    const Text(
                      '같은 와이파이에 연결된 휴대폰 카메라로 QR 을 찍거나 브라우저에서 주소를 여세요.',
                    ),
                    const SizedBox(height: 12),
                    if (urls.isEmpty)
                      const Text('네트워크 주소를 찾지 못했습니다. 와이파이 연결을 확인해 주세요.')
                    else
                      // 다이얼로그를 열 때마다 지금 주소로 새로 만든다(IP 가 바뀌어도 맞게).
                      // 와이파이·유선처럼 주소가 여럿이면 주소마다 QR 을 붙인다(와이파이·유선이 앞).
                      Wrap(
                        spacing: 20,
                        runSpacing: 16,
                        children: [for (final url in urls) qr(url)],
                      ),
                    const SizedBox(height: 12),
                    Text(
                      '처음 켤 때 방화벽이 "들어오는 연결 허용"을 물으면 허용해 주세요.\n'
                      '주소는 켤 때마다 바뀌므로(보안 키 포함) 매번 이 QR 로 여세요.\n'
                      '같은 와이파이 주소로 열면 휴대폰 화면 꺼짐 방지가 안 되니 휴대폰 자동 잠금을 꺼 두세요.\n'
                      '발표를 끝내면 자동으로 꺼집니다.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('끄기'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('닫기'),
              ),
            ],
          );
        },
      ),
    );
    if (stop == true) {
      await _singerWeb.stop();
      if (mounted) setState(() {});
    }
  }

  // ── 모니터 선택 ─────────────────────────────────────────────────────────

  Future<List<ScreenInfo>> _getScreens() async {
    try {
      final list = await _presentationChannel.invokeMethod<List<dynamic>>(
        'getScreens',
      );
      return [
        for (final (i, s) in (list ?? const []).indexed)
          ScreenInfo.fromJson(i, s as Map),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 네이티브에 넘길 모니터 번호. -1 = 자동. 고른 모니터가 지금 없거나, 메인 창이 그쪽으로
  /// 옮겨 갔거나, 싱어가 관객과 같은 모니터면 자동으로 연다(조작 화면·관객 화면을 덮지 않게).
  Future<int> _screenIndex(ScreenChoice? choice, {bool singer = false}) async {
    if (choice == null) return -1;
    final screens = await _getScreens();
    final index = ScreenChoice.resolve(choice, screens);
    if (index < 0 || screens[index].isMain) return -1;
    if (singer && index == ScreenChoice.resolve(_audienceScreen, screens)) {
      return -1;
    }
    return index;
  }

  Future<void> _showScreenMenu(BuildContext anchor) async {
    final screens = await _getScreens();
    if (!mounted || !anchor.mounted) return;
    final box = anchor.findRenderObject() as RenderBox;
    final overlay = Overlay.of(anchor).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(box.size.bottomLeft(Offset.zero), ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final audienceIndex = ScreenChoice.resolve(_audienceScreen, screens);
    final singerIndex = ScreenChoice.resolve(_singerScreen, screens);

    // 메인 창 모니터와 다른 쪽 창이 고른 모니터는 고를 수 없다(전체화면이 서로를 덮는다).
    List<PopupMenuEntry<(bool, ScreenInfo?)>> group(
      String title,
      bool singer,
      int selected,
      int taken,
    ) => [
      PopupMenuItem(
        enabled: false,
        height: 32,
        child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      CheckedPopupMenuItem(
        value: (singer, null),
        checked: selected < 0,
        child: const Text('자동'),
      ),
      for (final s in screens)
        CheckedPopupMenuItem(
          value: (singer, s),
          checked: selected == s.index,
          enabled: !s.isMain && s.index != taken,
          child: Text(
            s.index == taken
                ? '${s.label} · ${singer ? '관객' : '싱어'} 화면'
                : s.label,
          ),
        ),
    ];

    final picked = await showMenu<(bool, ScreenInfo?)>(
      context: context,
      position: position,
      items: [
        ...group('관객 화면', false, audienceIndex, singerIndex),
        const PopupMenuDivider(),
        ...group('싱어 화면', true, singerIndex, audienceIndex),
      ],
    );
    if (picked == null || !mounted) return;
    final (singer, screen) = picked;
    final choice = screen == null
        ? null
        : ScreenChoice(screen.index, screen.name);
    setState(() {
      if (singer) {
        _singerScreen = choice;
      } else {
        _audienceScreen = choice;
      }
    });
    await _screenStore.save(_audienceScreen, _singerScreen);
    // 이미 떠 있으면 고른 모니터로 바로 옮긴다('자동'은 다음에 열 때부터).
    if (screen == null) return;
    try {
      if (singer && _isSingerOpen) {
        final json = _buildSingerViewData().toJson();
        await _presentationChannel.invokeMethod('openSingerWindow', {
          ...json,
          'screen': screen.index,
        });
        _lastSingerJson = _singerDedupeKey(json);
      } else if (!singer && _isPresentationOpen) {
        final pageData = (await _presentablePage(
          _currentSlideIndex,
          _allSlides,
        ))!;
        await _presentationChannel.invokeMethod('openWindow', {
          ...pageData.toJson(),
          'screen': screen.index,
        });
      }
    } catch (_) {}
  }

  Future<void> _closeSingerWindow() async {
    if (!_isSingerOpen) return;
    try {
      await _presentationChannel.invokeMethod('closeSingerWindow');
    } catch (_) {}
    if (mounted) setState(() => _isSingerOpen = false);
  }

  // 경과 시간은 흐르는 동안 매번 달라서 빼고 비교한다. 시계 쪽이 바뀌면 rev 가 바뀐다.
  static String _singerDedupeKey(Map<String, dynamic> json) => jsonEncode({
    ...json,
    'clock': {...?(json['clock'] as Map?)}..remove('elapsed_ms'),
  });

  // 마지막으로 싱어 창에 보낸 JSON. 싱어 화면은 스타일을 안 쓰므로 디자인 슬라이더를
  // 끌 때처럼 내용이 그대로면 다시 보내지 않는다(macOS 는 보낼 때마다 HTML 을 통째로 다시 읽는다).
  String? _lastSingerJson;

  /// 관객 화면 미디어 레이어가 0.25초마다 보내는 재생 위치. 발표 보기 재생바만 다시 그린다
  /// (이 큰 화면 전체를 setState 하지 않게). 미디어가 바뀌면 새 레이어가 보낼 때까지 null.
  final ValueNotifier<MediaPlayback?> _mediaPlayback = ValueNotifier(null);
  String? _sentMediaKey;

  void _noteSentMedia(SlidePageData page) {
    if (page.mediaKey == _sentMediaKey) return;
    _sentMediaKey = page.mediaKey;
    _mediaPlayback.value = null;
  }

  Future<void> _seekMedia(double seconds) async {
    if (!_isPresentationOpen) return;
    try {
      await _presentationChannel.invokeMethod('mediaSeek', {'t': seconds});
    } catch (_) {}
  }

  Future<void> _sendSingerView([List<_SlideInfo>? slides]) async {
    if (!_isSingerOpen && !_singerWeb.isRunning) return;
    slides ??= _allSlides; // getter 가 매번 목록을 새로 만들므로 한 번만
    final json = _buildSingerViewData(slides).toJson();
    _singerWeb.update({
      ..._buildSingerViewData(slides, true).toJson(),
      // 리모컨에만 간다(SingerWebServer.remoteOnlyKeys).
      'note': _slideNotes[_currentNoteKey(slides)] ?? '',
      'zoom': _zoomJson,
    });
    if (!_isSingerOpen) return;
    final encoded = _singerDedupeKey(json);
    if (encoded == _lastSingerJson) return;
    try {
      await _presentationChannel.invokeMethod('updateSinger', json);
      // 보낸 게 확인된 뒤에만 기록한다. 실패하면 다음 갱신 때 다시 보낸다.
      _lastSingerJson = encoded;
    } catch (_) {}
  }

  // 확대 영역 판을 PC 를 끄는 동안(마우스 움직임마다)·메모를 칠 때(글자마다) 리모컨 갱신을 묶어서 보낸다.
  // 그때마다 _allSlides 를 새로 만들고 이미지 파일을 stat 하면 끌기·입력이 버벅인다.
  Timer? _remoteSyncTimer;

  void _scheduleRemoteSync() {
    if (!_singerWeb.isRunning || _remoteSyncTimer != null) return;
    _remoteSyncTimer = Timer(const Duration(milliseconds: 100), () {
      _remoteSyncTimer = null;
      if (mounted) _sendSingerView();
    });
  }

  // 관객 화면 확대 명령과 휴대폰 리모컨이 같은 값을 쓴다(x·y = 왼쪽 위).
  Map<String, Object> get _zoomJson => {
    'on': _isZoomOn,
    'x': _zoomCenter.dx - _zoomScale / 2,
    'y': _zoomCenter.dy - _zoomScale / 2,
    'size': _zoomScale,
  };

  // 발표 보기 메모칸과 같은 키(_PresenterConsoleState._keyAt). 자동 여백·맨 앞 빈 페이지는 메모가 없다.
  String _currentNoteKey(List<_SlideInfo> slides) {
    if (slides.isEmpty) return '';
    // _buildSingerViewData 와 같게 자른다(페이지를 지워 번호가 끝을 넘었을 때).
    final info = slides[_currentSlideIndex.clamp(0, slides.length - 1)];
    if (info.isAutoSpacer || info.stagingUid == _leadingBlankUid) return '';
    return _slideKey(info.stagingUid, info.pageIndexInItem);
  }

  /// 휴대폰 발표자 리모컨 요청([SingerWebServer.onControl]).
  Future<void> _handleRemoteControl(
    String action,
    Map<String, String> params,
  ) async {
    // 발표를 끝낸 뒤 늦게 온 요청은 버린다(다음 발표가 확대된 채 시작하는 등).
    if (!mounted || !_isPresentationOpen) return;
    double num(String key, double fallback) {
      final v = double.tryParse(params[key] ?? '');
      return v == null || !v.isFinite ? fallback : v; // NaN 은 clamp 를 그냥 지나간다
    }

    switch (action) {
      case 'next' || 'prev':
        // 휴대폰이 보던 쪽에서만 넘긴다. 늦게 온 요청·리모컨 두 대·PC 에서 먼저 넘긴 경우
        // 두 장씩 넘어가지 않게.
        if (int.tryParse(params['from'] ?? '') != _currentSlideIndex + 1) {
          return;
        }
        await (action == 'next' ? _nextSlide() : _prevSlide());
      case 'blackout':
        if ((params['on'] == '1') != _isBlackout) await _toggleBlackout();
      case 'zoom':
        final on = params['on'] == '1';
        final size = num(
          'size',
          _zoomScale,
        ).clamp(_ZoomRegionOverlay._minScale, _ZoomRegionOverlay._maxScale);
        final x = num('x', 0).clamp(0.0, 1 - size);
        final y = num('y', 0).clamp(0.0, 1 - size);
        setState(() {
          _isZoomOn = on;
          if (on) {
            _zoomScale = size;
            _zoomCenter = Offset(x + size / 2, y + size / 2);
          }
        });
        await _sendZoom();
        // _sendZoom 의 리모컨 갱신은 묶어서 늦게 가므로, 응답에 새 확대가 실리게 바로 보낸다.
        await _sendSingerView();
    }
  }

  int _pageSendSeq = 0;

  Future<void> _sendCurrentSlide() async {
    // 페이지가 바뀌는 모든 곳(넘기기·점프·편집·디자인 변경)이 이 함수를 거치므로
    // 싱어 화면도 여기서 함께 갱신한다. 관객 화면을 먼저 보내 싱어 갱신을 기다리지 않게 한다.
    final slides = _allSlides;
    final seq = ++_pageSendSeq;
    if (_isPresentationOpen) {
      try {
        final pageData = await _presentablePage(
          _currentSlideIndex,
          slides,
          isStale: () => seq != _pageSendSeq,
        );
        // 가사 PNG 를 굽는 사이 다음 페이지로 넘어갔으면 그쪽이 보낸다(옛 페이지가 늦게 덮지 않게).
        if (pageData == null || seq != _pageSendSeq || !_isPresentationOpen) {
          return;
        }
        _noteSentMedia(pageData);
        await _presentationChannel.invokeMethod(
          'updatePage',
          pageData.toJson(),
        );
      } catch (_) {
        await _closeSingerWindow();
        await _singerWeb.stop();
        if (mounted) setState(() => _isPresentationOpen = false);
        return;
      }
    }
    await _sendSingerView(slides);
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
      await _presentationChannel.invokeMethod('zoom', _zoomJson);
    } catch (_) {}
    // 휴대폰 리모컨도 지금 확대 영역을 따라 그린다.
    _scheduleRemoteSync();
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

    final result = await showDialog<(String, String, String)?>(
      context: context,
      builder: (_) => _SlideQuickEditDialog(
        mainText: info.mainText,
        englishText: info.englishText,
        extraText: info.extraText,
        isBible: info.isBible,
        title: info.title,
        subLabel: _subFieldLabel(info.isBible),
        extraLabel: _extraFieldLabel(info.isBible),
      ),
    );
    if (result == null || !mounted) return;
    final (newMain, newEnglish, newExtra) = result;
    await _applySlideEdit(info, newMain, newEnglish, newExtra, slideIndex);
  }

  /// 한 장 고치기의 보조·추가 보조 칸 이름. 지금 고른 언어·역본 이름을 붙인다.
  String _subFieldLabel(bool isBible) => isBible
      ? '보조 역본${_style.bibleSubVersion.isEmpty ? '' : ' · ${_style.bibleSubVersion}'} (비워도 됩니다)'
      : '보조 · ${_style.subLanguage} 가사 (비워도 됩니다)';

  String _extraFieldLabel(bool isBible) {
    final name = isBible ? _style.bibleExtraVersion : _style.extraLanguage;
    final kind = isBible ? '추가 역본' : '추가 보조';
    return name.isEmpty ? '$kind (비워도 됩니다)' : '$kind · $name (비워도 됩니다)';
  }

  Future<void> _applySlideEdit(
    _SlideInfo info,
    String newMain,
    String newEnglish,
    String newExtra,
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
        pairs[info.pageIndexInItem] = (
          korean: newMain,
          english: newEnglish,
          extra: newExtra,
        );
      }

      newItem = SongStagingItem(_songWithPages(song, pairs));
    } else if (item is BibleStagingItem) {
      newItem = BibleStagingItem(
        reference: item.reference,
        text: newMain,
        subText: newEnglish,
        extraText: newExtra,
      );
    } else if (item is BlankStagingItem) {
      newItem = BlankStagingItem(
        mainText: newMain,
        englishText: newEnglish,
        extraText: newExtra,
        media: item.media,
      );
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
    if (item is BlankStagingItem && item.media != null) {
      return _editMediaPage(uid, item);
    }
    if (item is SongStagingItem) return _editStagedSongLyrics(uid, item.song);

    final (mainText, subText, extraText, isBible) = switch (item) {
      SongStagingItem(:final song) => (
        song.lyrics,
        song.englishLyrics,
        song.extraLyrics,
        false,
      ),
      BibleStagingItem(:final text, :final subText, :final extraText) => (
        text,
        subText,
        extraText,
        true,
      ),
      BlankStagingItem(:final mainText, :final englishText, :final extraText) =>
        (mainText, englishText, extraText, false),
      _ => ('', '', '', false),
    };

    final result = await showDialog<(String, String, String)?>(
      context: context,
      builder: (_) => _SlideQuickEditDialog(
        mainText: mainText,
        englishText: subText,
        extraText: extraText,
        extraLabel: _extraFieldLabel(isBible),
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
    final (newMain, newSub, newExtra) = result;

    final StagingItem newItem = switch (item) {
      SongStagingItem(:final song) => SongStagingItem(
        song.copyWith(
          lyrics: normalizeEditableLyrics(newMain),
          englishLyrics: normalizeEditableLyrics(newSub),
          extraLyrics: normalizeEditableLyrics(newExtra),
        ),
      ),
      BibleStagingItem(:final reference) => BibleStagingItem(
        reference: reference,
        text: newMain,
        subText: newSub,
        extraText: newExtra,
      ),
      BlankStagingItem(:final media) => BlankStagingItem(
        mainText: newMain,
        englishText: newSub,
        extraText: newExtra,
        media: media,
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

  /// 곡은 가사 수정 창(페이지 표)으로 고친다. 언어는 담을 때 확정된 것이라 이름만 보여 준다.
  Future<void> _editStagedSongLyrics(int uid, PraiseSong song) async {
    final extra =
        _style.extraLanguage.isNotEmpty &&
            _style.extraLanguage != _style.subLanguage
        ? _style.extraLanguage
        : (song.extraLyrics.isNotEmpty ? '추가 보조' : '');
    final result = await showDialog<SongEditResult>(
      context: context,
      builder: (_) => LyricsEditorDialog(
        song: song,
        subLanguage: _style.subLanguage,
        extraLanguage: extra,
        style: _style,
        contiOnly: true,
      ),
    );
    if (result == null || !mounted) return;
    final index = _stagingItems.indexWhere((e) => e.uid == uid);
    if (index == -1) return;
    setState(() {
      _stagingItems[index] = (uid: uid, item: SongStagingItem(result.$1));
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

  void _deleteSlide(int slideIndex) => _deleteSlides([slideIndex]);

  /// 발표 보기에서 여러 장을 골라 Delete 로 지울 때도 같은 길을 탄다.
  void _deleteSlides(List<int> slideIndexes) {
    final slides = _allSlides;
    final targets = {
      for (final i in slideIndexes)
        if (i >= 0 &&
            i < slides.length &&
            slides[i].stagingUid != _leadingBlankUid)
          i,
    };
    if (targets.isEmpty) return;
    // 현재 페이지보다 앞이 지워진 만큼 당겨야 관객 화면이 엉뚱한 장으로 안 바뀐다.
    final shift = targets.where((i) => i < _currentSlideIndex).length;
    setState(() {
      for (final i in targets) {
        if (slides[i].isAutoSpacer) {
          _noSpacerUids.add(slides[i].stagingUid);
        } else {
          _deletedSlideKeys.add(
            _slideKey(slides[i].stagingUid, slides[i].pageIndexInItem),
          );
        }
      }
      _currentSlideIndex -= shift;
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

  /// F5 = 발표 시작 (PowerPoint 와 같다). 발표 전에는 포커스가 발표 FocusScope 밖
  /// (검색창·리본 등)에 있을 수 있어 FocusScope 가 아니라 전역 키 핸들러로 받는다.
  /// 다이얼로그가 떠 있을 땐 무시한다.
  bool _handleStartKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.f5 ||
        _isPresentationOpen ||
        ModalRoute.of(context)?.isCurrent == false) {
      return false;
    }
    _openPresentation();
    return true;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isPresentationOpen) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // 발표 종료는 Ctrl+F4 만(macOS 는 ⌃F4 를 시스템이 가져가므로 ⌘F4 도). ESC 는 잘못 눌러
    // 발표가 꺼지는 일이 잦아서 번호 입력 취소만 한다. 글자를 안 쓰는 키라 입력칸에 있어도 받는다.
    final keyboard = HardwareKeyboard.instance;
    if (key == LogicalKeyboardKey.f4 &&
        (keyboard.isControlPressed ||
            (Platform.isMacOS && keyboard.isMetaPressed))) {
      _closePresentation();
      return KeyEventResult.handled;
    }

    if (_isTextFieldFocused) return KeyEventResult.ignored;

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
      if (_slideJumpBuffer.isEmpty) return KeyEventResult.ignored;
      setState(() => _slideJumpBuffer = '');
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

  /// 찬양 검색 목록에서 더블클릭·끌어 놓기로 곡을 콘티 맨 끝에 담는다.
  /// 이미 담긴 곡도 다시 담는다(같은 곡 재창).
  Future<void> _addSongToStaging(PraiseSong song) async {
    final staged = await _withSubLyrics(song);
    if (!mounted) return;
    setState(() {
      _stagingItems.add((uid: _nextUid++, item: SongStagingItem(staged)));
    });
  }

  /// '콘티 한번에 넣기': 콘티 글을 붙여 넣어 줄마다 찾은 곡을 콘티 맨 끝에 순서대로 담는다.
  Future<void> _importContiText() async {
    final songs = await ContiTextImportDialog.show(
      context,
      loadSongs: () => _repository.searchSongs(''),
    );
    if (songs == null || songs.isEmpty) return;
    // 보조 언어를 다 입힌 뒤 한 번에 넣는다 — 중간에 그리면 순서대로 하나씩 늘어나 보인다.
    // 보조 가사를 못 읽은 곡(DB 잠김 등)도 원본 가사로는 담는다. 고른 곡을 통째로 잃지 않게.
    final staged = <PraiseSong>[];
    var noSubLyrics = 0;
    for (final song in songs) {
      try {
        staged.add(await _withSubLyrics(song));
      } catch (e, st) {
        AppLogger.instance.error(
          '[conti-text] 보조 가사 읽기 실패: ${song.title}',
          e,
          st,
        );
        staged.add(song);
        noSubLyrics++;
      }
    }
    if (!mounted) return;
    setState(() {
      for (final song in staged) {
        _stagingItems.add((uid: _nextUid++, item: SongStagingItem(song)));
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          noSubLyrics == 0
              ? '${staged.length}곡을 콘티에 담았습니다.'
              : '${staged.length}곡을 콘티에 담았습니다. '
                    '$noSubLyrics곡은 보조 가사를 읽지 못해 원본 가사만 담았습니다.',
        ),
      ),
    );
  }

  void _addBibleItem(BibleStagingItem item) {
    setState(() {
      final uid = _nextUid++;
      _stagingItems.add((uid: uid, item: item));
      _previewStagingUid = uid;
    });
  }

  /// 편집 탭 '새 페이지'가 들어갈 자리: 고른 항목 뒤, 없으면 맨 끝.
  int _indexAfterSelectedItem() {
    final selectedIndex = _stagingItems.indexWhere(
      (e) => e.uid == _previewStagingUid,
    );
    return selectedIndex >= 0 ? selectedIndex + 1 : _stagingItems.length;
  }

  /// 발표 보기 '새 페이지'가 들어갈 자리: 현재 슬라이드가 속한 항목 바로 뒤.
  /// 맨 앞 자동 빈 페이지(또는 빈 콘티)면 맨 앞.
  int _indexAfterCurrentSlide() {
    final slides = _allSlides;
    final currentUid = slides.isEmpty
        ? null
        : slides[_currentSlideIndex.clamp(0, slides.length - 1)].stagingUid;
    return _stagingItems.indexWhere((e) => e.uid == currentUid) + 1;
  }

  void _addBlankItem() {
    setState(() {
      final uid = _nextUid++;
      _stagingItems.insert(_indexAfterSelectedItem(), (
        uid: uid,
        item: const BlankStagingItem(),
      ));
      _previewStagingUid = uid;
    });
  }

  /// 발표 보기 '새 페이지': 현재 슬라이드가 속한 항목 바로 뒤에 빈 페이지를 넣고 바로 편집한다.
  /// 곡 중간 페이지를 보고 있어도 곡을 쪼갤 수는 없으니 그 곡 뒤에 들어간다.
  /// 현재 슬라이드보다 뒤에 들어가므로 관객 화면과 현재 위치는 그대로다.
  Future<void> _addBlankAfterCurrentSlide() async {
    final uid = _nextUid++;
    setState(() {
      _stagingItems.insert(_indexAfterCurrentSlide(), (
        uid: uid,
        item: const BlankStagingItem(),
      ));
    });
    final index = _allSlides.indexWhere((s) => s.stagingUid == uid);
    if (index >= 0) await _editSlide(index);
  }

  // ── 설교 제목 페이지 ──────────────────────────────────────────────────
  //
  // 문구를 넣은 빈 페이지 + 항목별 배경 오버라이드(글꼴·크기·색까지 담은 것)다.
  // 헌금송처럼 렌더러 네 곳은 따로 아는 게 없다 — withBackground 가 만든 style 을 받을 뿐이다.

  Future<_SermonPageResult?> _showSermonDialog({
    String title = '',
    String subtitle = '',
    String extraText = '',
    SlideBackground? design,
  }) {
    var initial =
        design ?? _sermonDesign ?? SlideBackground.sermonDefault(_style);
    // 배경 모음에서 지운 이미지면 색만 남긴다(지난번 디자인이 가리키던 파일일 수 있다).
    if (initial.hasImage && !File(initial.imagePath!).existsSync()) {
      initial = initial.copyWith(imagePath: null);
    }
    return showDialog<_SermonPageResult>(
      context: context,
      builder: (_) => _SermonPageDialog(
        initialTitle: title,
        initialSubtitle: subtitle,
        extraText: extraText,
        initialDesign: initial,
        canRevert: design != null,
        globalStyle: _style,
        swatches: _swatches,
        imageLibrary: _backgroundImages,
      ),
    );
  }

  Future<void> _addSermonPage(int Function() insertAt) async {
    final result = await _showSermonDialog();
    final design = result?.design;
    if (result == null || design == null || !mounted) return;
    final uid = _nextUid++;
    setState(() {
      _stagingItems.insert(insertAt(), (
        uid: uid,
        item: BlankStagingItem(
          mainText: result.title,
          englishText: result.subtitle,
        ),
      ));
      _itemBackgrounds[uid] = design;
      _previewStagingUid = uid;
    });
    await _rememberSermonDesign(design);
    await _sendCurrentSlide();
  }

  Future<void> _editSermonPage(int uid) async {
    final entry = _stagingItems.where((e) => e.uid == uid).firstOrNull;
    final item = entry?.item;
    if (item is! BlankStagingItem) return;
    final result = await _showSermonDialog(
      title: item.mainText,
      subtitle: item.englishText,
      extraText: item.extraText,
      design: _itemBackgrounds[uid],
    );
    if (result == null || !mounted) return;
    final index = _stagingItems.indexWhere((e) => e.uid == uid);
    if (index < 0) return;
    setState(() {
      final design = result.design;
      _stagingItems[index] = (
        uid: uid,
        // 일반 빈 페이지로 되돌리면 부제는 본문 아래 줄로 합친다. 보조 줄에 두면
        // 보조 언어 스위치를 따라 안내 없이 사라지거나 영어 가사 모양으로 나온다.
        item: design == null
            ? BlankStagingItem(
                mainText: [
                  result.title,
                  result.subtitle,
                ].where((t) => t.isNotEmpty).join('\n'),
                extraText: item.extraText,
              )
            : BlankStagingItem(
                mainText: result.title,
                englishText: result.subtitle,
                extraText: item.extraText,
              ),
      );
      if (design == null) {
        _itemBackgrounds.remove(uid); // 일반 빈 페이지로 되돌림
      } else {
        _itemBackgrounds[uid] = design;
      }
      _previewStagingUid = uid;
    });
    if (result.design != null) await _rememberSermonDesign(result.design!);
    await _sendCurrentSlide();
  }

  // ── 동영상·음악·유튜브 페이지 ─────────────────────────────────────────
  //
  // 빈 페이지 + SlideMedia 다. 발표 창은 페이지를 평소처럼 그리고 그 위 미디어 레이어에서
  // 재생한다(음악은 소리만이라 문구·배경이 보인다). 저장·복사·나누기는 빈 페이지와 같다.

  Future<void> _addPage(
    _AddPageKind kind,
    int Function() insertAt, {
    required FutureOr<void> Function() onBlank,
  }) async {
    final media = kind.media;
    if (kind == _AddPageKind.blank) {
      await onBlank();
    } else if (kind == _AddPageKind.sermon) {
      await _addSermonPage(insertAt);
    } else if (media != null) {
      final result = await _showMediaDialog(kind: media);
      if (result == null || !mounted) return;
      final uid = _nextUid++;
      setState(() {
        _stagingItems.insert(insertAt(), (
          uid: uid,
          item: BlankStagingItem(mainText: result.text, media: result.media),
        ));
        _previewStagingUid = uid;
      });
      await _sendCurrentSlide();
    }
  }

  Future<({SlideMedia media, String text})?> _showMediaDialog({
    required MediaKind kind,
    SlideMedia? initial,
    String text = '',
  }) {
    return showDialog(
      context: context,
      builder: (_) => _MediaPageDialog(
        kind: kind,
        videoLibrary: _backgroundVideos,
        initial:
            initial ??
            SlideMedia(
              kind: kind,
              source: '',
              fadeIn: _style.mediaFadeIn,
              fadeOut: _style.mediaFadeOut,
            ),
        initialText: text,
      ),
    );
  }

  Future<void> _editMediaPage(int uid, BlankStagingItem item) async {
    final media = item.media!;
    final result = await _showMediaDialog(
      kind: media.kind,
      initial: media,
      text: item.mainText,
    );
    if (result == null || !mounted) return;
    final index = _stagingItems.indexWhere((e) => e.uid == uid);
    if (index < 0) return;
    setState(() {
      _stagingItems[index] = (
        uid: uid,
        item: BlankStagingItem(
          mainText: result.text,
          englishText: item.englishText,
          extraText: item.extraText,
          media: result.media,
        ),
      );
    });
    await _sendCurrentSlide();
  }

  /// 발표 보기 미디어 버튼: 재생 중이면 페이드 아웃 후 멈춤, 멈춰 있으면 페이드 인.
  Future<void> _toggleMedia() async {
    if (!_isPresentationOpen) return;
    try {
      await _presentationChannel.invokeMethod('mediaToggle');
    } catch (_) {}
  }

  /// 리본 '글자·위치 기본값': 찬양·말씀·제목의 글꼴·크기·정렬·세로 위치·미세 조정과
  /// 설교 제목·헌금송 기본 디자인의 글꼴·크기·위치를 처음 값으로 되돌린다.
  /// 색·배경·제목 표시·보조 언어 같은 설정은 그대로 둔다.
  Future<void> _resetTextLayout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('글자 크기·위치를 기본값으로'),
        content: const Text(
          '찬양·말씀·제목의 글꼴, 글자 크기, 정렬, 위치와\n'
          '설교 제목·헌금송 기본 디자인의 글꼴·크기·위치를 처음 설정으로 되돌립니다.\n\n'
          '색·배경·제목 표시·보조 언어 설정은 그대로입니다.\n'
          '이미 콘티에 넣은 설교 제목·헌금송 페이지는 바뀌지 않습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('되돌리기'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    const d = _defaultStyle;
    final style = _style.copyWith(
      fontFamily: d.fontFamily,
      fontSize: d.fontSize,
      bibleFontSize: d.bibleFontSize,
      textPosition: d.textPosition,
      bibleTextPosition: d.bibleTextPosition,
      textOffsetY: d.textOffsetY,
      bibleTextOffsetY: d.bibleTextOffsetY,
      lyricsTextAlign: d.lyricsTextAlign,
      bibleTextAlign: d.bibleTextAlign,
      titleFontSize: d.titleFontSize,
      bibleTitleFontSize: d.bibleTitleFontSize,
      titleHorizontalPosition: d.titleHorizontalPosition,
      titleVerticalPosition: d.titleVerticalPosition,
      bibleTitleHorizontalPosition: d.bibleTitleHorizontalPosition,
      bibleTitleVerticalPosition: d.bibleTitleVerticalPosition,
      titleOffsetY: d.titleOffsetY,
      bibleTitleOffsetY: d.bibleTitleOffsetY,
    );

    final sermon = _sermonDesign;
    if (sermon != null) {
      await _rememberSermonDesign(
        sermon.withSermonDefaultText(style, includeColors: false),
      );
    }

    if (_offeringRegistered) {
      const od = OfferingDesign();
      final offering = _offeringDesign.copyWith(
        fontFamily: od.fontFamily,
        labelFontSize: od.labelFontSize,
        accountFontSize: od.accountFontSize,
        bandCenterY: od.bandCenterY,
        lyricsGap: od.lyricsGap,
      );
      if (offering != _offeringDesign) {
        setState(() => _offeringDesign = offering);
        await _offeringStore.save(offering);
      }
    }

    await _updateStyle(style);
  }

  Future<void> _rememberSermonDesign(SlideBackground design) async {
    _sermonDesign = design;
    await _sermonStore.save(design);
  }

  /// 발표 보기 ⌘/Ctrl+C. 고른 페이지를 콘티 항목으로 떠 둔다.
  void _copySlides(List<int> slideIndexes) {
    final slides = _allSlides;
    final picked = [
      for (final i in _pickMovableSlides(slides, slideIndexes)) slides[i],
    ];
    final copied = _slidesToPieces(picked);
    if (copied.isEmpty) return;
    _slideClipboard = copied;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${picked.length}장을 복사했습니다. ⌘/Ctrl+V 로 붙여 넣으세요.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 복사·옮기기 대상이 될 수 있는 페이지 번호만 순서대로 고른다(맨 앞 빈 페이지·자동 여백 제외).
  List<int> _pickMovableSlides(
    List<_SlideInfo> slides,
    List<int> slideIndexes,
  ) => [
    for (final i in slideIndexes.toSet().toList()..sort())
      if (i >= 0 &&
          i < slides.length &&
          !slides[i].isAutoSpacer &&
          slides[i].stagingUid != _leadingBlankUid)
        i,
  ];

  /// 고른 페이지를 콘티 항목 조각으로 만든다. 같은 항목의 페이지는 한 항목으로 묶는다 —
  /// 곡 페이지를 한 장씩 따로 만들면 사이사이에 자동 여백이 끼기 때문이다.
  List<_SlidePiece> _slidesToPieces(List<_SlideInfo> picked) {
    final groups = <List<_SlideInfo>>[];
    for (final info in picked) {
      if (groups.isNotEmpty &&
          groups.last.first.stagingUid == info.stagingUid) {
        groups.last.add(info);
      } else {
        groups.add([info]);
      }
    }
    final result = <_SlidePiece>[];
    for (final group in groups) {
      final uid = group.first.stagingUid;
      final entry = _stagingItems.where((e) => e.uid == uid).firstOrNull;
      if (entry == null) continue;
      final byPage = {for (final s in group) s.pageIndexInItem: s};
      final pieces = itemsFromPages(entry.item, byPage.keys.toList());
      for (var k = 0; k < pieces.length; k++) {
        result.add((
          item: pieces[k].item,
          background: _itemBackgrounds[uid],
          // 한 항목에서 나온 조각(곡 + 끝 빈 페이지)은 여백 없이 잇는다.
          joinNext: k < pieces.length - 1,
          pages: [for (final j in pieces[k].from) byPage[j]!],
        ));
      }
    }
    return result;
  }

  /// 콘티 [index] 항목을 [parts](각각 원래 페이지 번호 목록)로 다시 만든다. 나누기·옮기기에서 쓴다.
  /// 첫 조각이 원래 uid 를 이어받고 나머지는 새 uid 다. 한 part 안의 조각끼리는 여백 없이 잇고,
  /// 원래 항목의 '여백 없음'은 마지막 조각이 이어받는다. part 사이 여백은 부른 쪽이 정한다.
  /// 배경·메모·지운 표시는 새 자리로 옮기고, 바뀐 슬라이드 키(`uid:페이지:자동여백`)를
  /// [renamed] 에 적는다. part 에 없는 페이지의 메모·지운 표시는 버린다.
  /// part 마다 그 조각들의 uid 를 돌려준다.
  List<List<int>> _rebuildItem(
    int index,
    List<List<int>> parts,
    Map<String, String> renamed,
  ) {
    final (:uid, :item) = _stagingItems[index];
    final total = _pageCount(item);
    final background = _itemBackgrounds[uid];
    final group = _mediaGroupOf(uid);
    final wasJoined = _noSpacerUids.remove(uid);
    // 뒤에 자동 여백이 붙어 있던 항목인지(곡·PPT 이고, 마지막 항목이 아니고, 이어 붙이지 않았음).
    final hadSpacer = !wasJoined && index < _stagingItems.length - 1;
    final oldNotes = <int, String>{};
    final oldDeleted = <int>{};
    for (var j = 0; j <= total; j++) {
      final note = _slideNotes.remove(_slideKey(uid, j));
      if (note != null) oldNotes[j] = note;
      if (_deletedSlideKeys.remove(_slideKey(uid, j))) oldDeleted.add(j);
    }

    final partUids = <List<int>>[];
    final placed = <({int uid, StagingItem item})>[];
    for (final part in parts) {
      final uids = <int>[];
      final pieces = itemsFromPages(item, part);
      for (var k = 0; k < pieces.length; k++) {
        final pieceUid = placed.isEmpty ? uid : _nextUid++;
        placed.add((uid: pieceUid, item: pieces[k].item));
        uids.add(pieceUid);
        if (k < pieces.length - 1) _noSpacerUids.add(pieceUid);
        if (pieceUid != uid) {
          if (background != null) _itemBackgrounds[pieceUid] = background;
          _mediaGroups[pieceUid] = group;
        }
        final from = pieces[k].from;
        for (var p = 0; p < from.length; p++) {
          final to = _slideKey(pieceUid, p);
          final note = oldNotes[from[p]];
          if (note != null) _slideNotes[to] = note;
          if (oldDeleted.contains(from[p])) _deletedSlideKeys.add(to);
          renamed['${_slideKey(uid, from[p])}:false'] = '$to:false';
        }
      }
      partUids.add(uids);
    }
    if (placed.isEmpty) return partUids;
    // 곡 끝 빈 페이지를 떼어 빈 페이지 항목으로 끝나면 자동 여백이 안 붙는다. 여백이 있던 자리면
    // 그 자리에 빈 페이지를 하나 더 둬서 장 수를 지킨다.
    final String spacerKey;
    // 자동 여백 메모가 갈 자리. 여백이 없는 빈 페이지 항목으로 끝나면 null(그 페이지 메모를 덮지 않게).
    String? spacerNoteKey;
    if (placed.last.item is BlankStagingItem) {
      if (hadSpacer && item is! BlankStagingItem) {
        final spacerUid = _nextUid++;
        placed.add((uid: spacerUid, item: const BlankStagingItem()));
        partUids.last.add(spacerUid);
        if (background != null) _itemBackgrounds[spacerUid] = background;
        spacerNoteKey = _slideKey(spacerUid, 0);
      }
      spacerKey = '${_slideKey(placed.last.uid, 0)}:false';
    } else {
      spacerNoteKey = _slideKey(placed.last.uid, _pageCount(placed.last.item));
      spacerKey = '$spacerNoteKey:true';
    }
    final spacerNote = oldNotes[total];
    if (spacerNote != null && spacerNoteKey != null) {
      _slideNotes[spacerNoteKey] = spacerNote;
    }
    _stagingItems[index] = placed.first;
    _stagingItems.insertAll(index + 1, placed.skip(1));

    // 뒤 자동 여백은 마지막 조각 뒤로 간다.
    if (wasJoined) _noSpacerUids.add(placed.last.uid);
    renamed['${_slideKey(uid, total)}:true'] = spacerKey;
    return partUids;
  }

  /// 발표 보기 ⌘/Ctrl+V. 현재 슬라이드 바로 뒤에 넣는다. 현재 위치·관객 화면은 그대로다.
  void _pasteSlides() {
    if (_slideClipboard.isEmpty) return;
    final slides = _allSlides;
    setState(() {
      _insertItemsAfterSlide(
        slides,
        _currentSlideIndex.clamp(0, slides.isEmpty ? 0 : slides.length - 1),
        _slideClipboard,
        {},
      );
    });
    // 다음 페이지가 바뀌었을 수 있다(싱어 화면의 '다음').
    _sendCurrentSlide();
  }

  // ── 성경 음성 검색 (발표 보기) ─────────────────────────────────────────
  //
  // 켜 두면 계속 듣다가 "다니엘 3장 1절에서 10절" 같은 말을 들으면 그 구절 페이지를
  // 현재 페이지 바로 뒤에 넣는다(붙여 넣기와 같은 자리). 관객 화면은 그대로다.
  // "개역개정" 처럼 역본을 말하면 그 뒤로는 그 역본으로 찾는다(기본 새번역).

  Future<void> _toggleVoice() async {
    if (_voice.value != null) {
      await _stopVoice();
      return;
    }
    final versions = await _bibleRepository.getVersions();
    if (!mounted) return;
    if (versions.isEmpty) {
      _showSnack('성경 데이터를 먼저 가져와 주세요.');
      return;
    }
    _voiceVersions = versions;
    // DB 이름이 자모가 풀린 꼴(NFD)일 수 있어 합쳐서 비교한다.
    _voiceVersion = versions.firstWhere(
      (v) => composeHangul(v) == '새번역',
      orElse: () => versions.first,
    );
    _voiceBook = null;
    _voiceChapter = null;
    _voiceRecent.clear();
    _voiceBooks.clear();
    _voiceChain = null;
    _voiceUndo = null;
    _speech
      ..onPartial = (text) {
        final v = _voice.value;
        if (v != null) _voice.value = v.copyWith(heard: text);
      }
      ..onFinal = (text) {
        // 하나가 실패해도 다음 마디는 처리되게 오류를 여기서 받는다.
        _voiceQueue = _voiceQueue
            .then((_) => _onVoiceHeard(text))
            .catchError(
              (Object e, StackTrace st) =>
                  AppLogger.instance.error('[voice] 처리 실패: $text', e, st),
            );
      }
      ..onError = (message) {
        if (_voice.value == null) return;
        AppLogger.instance.info('[voice] 멈춤: $message');
        setState(() => _voice.value = null);
        _showSnack('성경 음성 검색이 꺼졌습니다: $message');
      };
    setState(() {
      _voice.value = _VoiceState(
        version: _voiceVersion,
        message: '구절을 말하면 다음 장에 넣습니다',
      );
    });
    final error = await _speech.start(
      grammar: bibleVoiceGrammar(versions),
      hints: [...bibleCanonKorean, ...versions, '장', '절', '편'],
    );
    if (error == null) {
      // 권한 창이 떠 있는 사이에 다시 눌러 껐으면 켜진 마이크를 끈다.
      if (_voice.value == null || !mounted) await _speech.stop();
      return;
    }
    if (!mounted) return;
    AppLogger.instance.info('[voice] 못 켬: $error');
    setState(() => _voice.value = null);
    _showSnack('음성 인식을 켤 수 없습니다: $error');
  }

  Future<void> _stopVoice() async {
    setState(() => _voice.value = null);
    await _speech.stop();
  }

  void _voiceMessage(String message, {bool error = false}) {
    final v = _voice.value;
    if (v == null) return;
    _voice.value = _VoiceState(
      version: _voiceVersion,
      message: message,
      isError: error,
      // 마지막에 넣은 것은 다음에 넣거나 되돌릴 때까지 띄우기·되돌리기 버튼을 남긴다.
      insertedUids: v.insertedUids,
      label: v.label,
    );
  }

  Future<void> _onVoiceHeard(String text) async {
    if (_voice.value == null || !mounted) return;
    final command = parseBibleVoice(text, _voiceVersions);
    if (command == null) {
      _voice.value = _voice.value!.copyWith(heard: '');
      return;
    }
    AppLogger.instance.info('[voice] "$text" → $command');
    if (command.version != null) _voiceVersion = command.version!;
    if (!command.hasReference) {
      _voiceMessage('역본: $_voiceVersion');
      return;
    }
    final bookIndex = command.book ?? _voiceBook;
    final chapter = command.chapter ?? _voiceChapter;
    if (bookIndex == null || chapter == null) {
      _voiceMessage('"$text" — 어느 책인지 말해 주세요', error: true);
      return;
    }
    final version = _voiceVersion;
    final books = _voiceBooks[version] ??= await _bibleRepository
        .getBookNamesForVersion(version);
    final canonName = bibleCanonKorean[bookIndex];
    final book = books.length == bibleCanonKorean.length
        ? books[bookIndex]
        : books.where((b) => composeHangul(b) == canonName).firstOrNull;
    if (book == null) {
      _voiceMessage('$version 에 $canonName 이(가) 없습니다', error: true);
      return;
    }
    var verses = await _bibleRepository.getVerses(
      version: version,
      bookName: book,
      chapter: chapter,
    );
    final from = command.fromVerse;
    if (from != null) {
      final to = command.toVerse ?? from;
      verses = [
        for (final v in verses)
          if (v.verse >= from && v.verse <= to) v,
      ];
    }
    if (!mounted || _voice.value == null) return;
    if (verses.isEmpty) {
      _voiceMessage('"$text" — $book $chapter장에 그런 절이 없습니다', error: true);
      return;
    }
    _voiceBook = bookIndex;
    _voiceChapter = chapter;

    final label = _buildReference(version, book, chapter, [
      for (final v in verses) v.verse,
    ]);
    final last = _voiceRecent[label];
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(minutes: 10)) {
      _voiceMessage('이미 넣은 구절: $label');
      return;
    }
    _voiceRecent[label] = now; // 기다리는 사이 같은 구절이 또 와도 막히게 먼저 적는다
    final items = await _bibleItemsFor(
      repository: _bibleRepository,
      version: version,
      verses: verses,
      perPage: _BibleSearchPanelState._versesPerPage,
      subVersion: _style.bibleSubVersion,
      extraVersion: _style.bibleExtraVersion,
    );
    if (!mounted || _voice.value == null || items.isEmpty) {
      _voiceRecent.remove(label);
      return;
    }
    final slides = _allSlides;
    final currentAt = _currentSlideIndex.clamp(
      0,
      slides.isEmpty ? 0 : slides.length - 1,
    );
    final currentKey = slides.isEmpty
        ? ''
        : _slideKey(
            slides[currentAt].stagingUid,
            slides[currentAt].pageIndexInItem,
          );
    // 페이지를 안 넘기고 또 말했으면 지난번에 넣은 항목의 마지막 페이지 뒤에 잇는다.
    var at = currentAt;
    final chain = _voiceChain;
    if (chain != null && chain.currentKey == currentKey) {
      final last = slides.lastIndexWhere(
        (s) => s.stagingUid == chain.lastUid && !s.isAutoSpacer,
      );
      if (last >= 0) at = last;
    }
    final undo = _VoiceUndo.capture(this);
    late final List<int> uids;
    setState(() {
      uids = _insertItemsAfterSlide(slides, at, [
        for (final item in items)
          (item: item, background: null, joinNext: false, pages: const []),
      ], {});
    });
    _voiceChain = (currentKey: currentKey, lastUid: uids.last);
    _voiceUndo = undo
      ..slideIndex = at
      ..after = _VoiceUndo.capture(this);
    _voice.value = _VoiceState(
      version: version,
      message:
          '다음 장에 넣음: $label${items.length > 1 ? ' (${items.length}장)' : ''}',
      insertedUids: uids,
      label: label,
    );
    // 다음 페이지가 바뀌었다(싱어 화면의 '다음').
    _sendCurrentSlide();
  }

  /// 음성으로 넣은 페이지로 넘긴다(관객 화면에 띄우기).
  void _showVoiceInsert() {
    final uids = _voice.value?.insertedUids ?? const [];
    if (uids.isEmpty) return;
    final index = _allSlides.indexWhere((s) => s.stagingUid == uids.first);
    if (index >= 0) _goToSlide(index);
  }

  /// 음성으로 넣은 페이지를 뺀다(잘못 알아들었을 때).
  void _undoVoiceInsert() {
    final v = _voice.value;
    final uids = (v?.insertedUids ?? const []).toSet();
    if (v == null || uids.isEmpty) return;
    _voiceRecent.remove(v.label);
    final undo = _voiceUndo;
    _voiceUndo = null;
    _voiceChain = null;
    final before = _allSlides;
    final first = before.indexWhere((s) => uids.contains(s.stagingUid));
    final last = before.lastIndexWhere((s) => uids.contains(s.stagingUid));
    setState(() {
      // 넣은 뒤로 아무것도 안 바뀌었으면 곡을 나눈 것까지 통째로 되돌린다.
      // 그 사이 다른 걸 고쳤으면 고친 걸 지우지 않게 넣은 항목만 뺀다.
      if (undo == null || !undo.restore(this)) {
        _removeStagingWhere((e) => uids.contains(e.uid));
      }
      // 관객 화면이 보던 페이지를 지킨다: 넣은 페이지보다 뒤였으면 빠진 장 수(곡을 나누며 생긴 여백 포함)만큼
      // 당기고, 넣은 페이지(또는 그 앞 여백)를 보고 있었으면 넣기 직전 기준 페이지로.
      final removed = before.length - _allSlides.length;
      final anchor = undo?.slideIndex ?? first - 1;
      if (first >= 0) {
        if (_currentSlideIndex > last) {
          _currentSlideIndex -= removed;
        } else if (_currentSlideIndex > anchor) {
          _currentSlideIndex = anchor;
        }
      }
      if (_currentSlideIndex < 0) _currentSlideIndex = 0;
      _clampCurrentSlideIndex();
    });
    _voice.value = _VoiceState(version: _voiceVersion, message: '되돌렸습니다');
    _sendCurrentSlide();
  }

  /// [slides] 의 [slideIndex] 페이지 바로 뒤에 [pieces] 를 새 콘티 항목으로 넣고 그 uid 들을 돌려준다.
  /// 곡·PPT 중간 페이지면 그 항목을 그 페이지에서 둘로 나눠 사이에 넣는다(외부 PPT 중간에 찬양·말씀 넣기).
  /// 나누느라 바뀐 슬라이드 키는 [renamed] 에 적는다. setState 안에서 부른다.
  List<int> _insertItemsAfterSlide(
    List<_SlideInfo> slides,
    int slideIndex,
    List<_SlidePiece> pieces,
    Map<String, String> renamed,
  ) {
    // 빈 콘티면 맨 앞에 넣는다.
    final current = slideIndex < slides.length ? slides[slideIndex] : null;
    final at = _stagingItems.indexWhere((e) => e.uid == current?.stagingUid);
    // 같은 곡(같은 PPT)끼리 맞닿는 자리만 자동 여백을 빼 이어 붙인다. 다른 곡이면 여백을 둔다.
    final onPage = at >= 0 && !current!.isAutoSpacer;
    // 원래 다음 항목과 이어져 있던 자리(앞서 곡 중간에 붙여 넣은 자리 등)
    final wasJoined = onPage && _noSpacerUids.contains(current.stagingUid);
    final tailAt = onPage
        ? _splitStagingItem(at, current.pageIndexInItem + 1, renamed)
        : null;
    var insertAt = tailAt ?? at + 1;
    final next = insertAt < _stagingItems.length
        ? _stagingItems[insertAt].item
        : null;
    if (onPage) {
      // 나눴으면 앞부분의 마지막 조각, 아니면 놓은 페이지의 항목
      final head = _stagingItems[insertAt - 1];
      if (_sameSource(head.item, pieces.first.item)) {
        _noSpacerUids.add(head.uid);
      } else {
        _noSpacerUids.remove(head.uid);
      }
    }
    final uids = <int>[];
    for (final c in pieces) {
      final uid = _nextUid++;
      uids.add(uid);
      _stagingItems.insert(insertAt++, (uid: uid, item: c.item));
      if (c.background != null) _itemBackgrounds[uid] = c.background!;
      if (c.joinNext) _noSpacerUids.add(uid);
    }
    // 뒤 항목과 같은 곡·같은 PPT 면 이어 붙인다(나눈 자리·이어져 있던 자리, 또는 여백 뒤 = 그 곡 맨 앞).
    // 항목 끝(여백 앞)에 놓았으면 사용자가 둔 여백을 그대로 둔다(같은 곡을 다시 부르는 사이 등).
    if ((tailAt != null || wasJoined || !onPage) &&
        next != null &&
        _sameSource(pieces.last.item, next)) {
      _noSpacerUids.add(uids.last);
    }
    return uids;
  }

  /// 발표 보기 썸네일 끌어 놓기. [slideIndexes] 페이지를 [afterIndex] 페이지 바로 뒤로 옮긴다.
  /// 외부 PPT 중간에 찬양·말씀을 끼워 넣거나 PPT 안 페이지 순서를 바꾸는 데 쓴다.
  /// 옮긴 페이지만 원래 항목에서 실제로 빼고(숨기지 않는다) 놓은 자리에 새 항목으로 넣는다.
  /// 나머지 페이지는 그대로 남는다. 메모는 따라가고, 관객 화면은 보던 페이지 그대로다.
  void _moveSlides(List<int> slideIndexes, int afterIndex) {
    final slides = _allSlides;
    if (afterIndex < 0 || afterIndex >= slides.length) return;
    final pickedIndexes = _pickMovableSlides(slides, slideIndexes);
    if (pickedIndexes.isEmpty) return;
    if (pickedIndexes.contains(afterIndex)) return;
    final picked = [for (final i in pickedIndexes) slides[i]];
    // 이어진 페이지를 바로 앞 페이지 뒤로 옮기는 건 제자리다.
    final contiguous =
        pickedIndexes.last - pickedIndexes.first == pickedIndexes.length - 1;
    if (contiguous && afterIndex == pickedIndexes.first - 1) return;

    String keyOf(_SlideInfo s) =>
        '${_slideKey(s.stagingUid, s.pageIndexInItem)}:${s.isAutoSpacer}';
    final pieces = _slidesToPieces(picked);
    final movedKeys = {for (final s in picked) keyOf(s)};
    final currentAt = _currentSlideIndex.clamp(0, slides.length - 1);
    final current = slides[currentAt];
    // 놓을 자리가 옮기느라 사라지면(통째로 옮긴 곡의 자동 여백 등) 그 앞 페이지 뒤에 넣는다.
    final anchors = [
      for (var i = afterIndex; i >= 0; i--)
        if (!movedKeys.contains(keyOf(slides[i]))) keyOf(slides[i]),
    ];
    final notes = <String, String>{
      for (final s in picked)
        keyOf(s): ?_slideNotes.remove(
          _slideKey(s.stagingUid, s.pageIndexInItem),
        ),
    };
    // 빼는 단계에서 원래 항목이 사라질 수 있으므로 미리 읽어 둔다.
    final groups = [
      for (final p in pieces) _mediaGroupOf(p.pages.first.stagingUid),
    ];
    final movedPages = <int, Set<int>>{};
    for (final s in picked) {
      (movedPages[s.stagingUid] ??= {}).add(s.pageIndexInItem);
    }

    setState(() {
      // 단계마다 바뀐 슬라이드 키. 옮긴 페이지는 [placed], 나머지는 단계를 차례로 따라간다.
      final takenOut = <String, String>{};
      final split = <String, String>{};
      final placed = <String, String>{};
      String resolve(String key) =>
          placed[key] ?? split[takenOut[key] ?? key] ?? takenOut[key] ?? key;

      // 1) 옮긴 페이지만 원래 항목에서 뺀다. 남은 페이지가 없는 항목은 항목째 뺀다(여백만 남지 않게).
      //    빈 항목을 먼저 빼야 다시 만드는 항목이 '마지막 항목인지'(자동 여백이 있었는지)를 바로 본다.
      final emptied = {
        for (final MapEntry(key: uid, value: moved) in movedPages.entries)
          if (!_keepsPages(uid, moved)) uid,
      };
      _removeStagingWhere((e) => emptied.contains(e.uid), prune: false);
      for (final uid in emptied) {
        _itemBackgrounds.remove(uid);
        _deletedSlideKeys.removeWhere((k) => k.startsWith('$uid:'));
        _slideNotes.removeWhere((k, _) => k.startsWith('$uid:'));
      }
      for (final MapEntry(key: uid, value: moved) in movedPages.entries) {
        if (!emptied.contains(uid)) _takePagesOut(uid, moved, takenOut);
      }

      // 2) 놓을 자리 뒤에 넣는다.
      final remaining = _allSlides;
      final remainingAt = {
        for (var i = 0; i < remaining.length; i++) keyOf(remaining[i]): i,
      };
      var target = 0;
      for (final key in anchors) {
        final i = remainingAt[takenOut[key] ?? key];
        if (i != null) {
          target = i;
          break;
        }
      }
      final uids = _insertItemsAfterSlide(remaining, target, pieces, split);
      _pruneSourceWatches();

      // 3) 옮긴 페이지의 새 키·메모. 미디어 묶음도 따라가 재생 중인 동영상이 끊기지 않는다.
      for (var g = 0; g < pieces.length; g++) {
        final pages = pieces[g].pages;
        _mediaGroups[uids[g]] = groups[g];
        for (var j = 0; j < pages.length; j++) {
          final to = _slideKey(uids[g], j);
          placed[keyOf(pages[j])] = '$to:false';
          final note = notes[keyOf(pages[j])];
          if (note != null) _slideNotes[to] = note;
        }
      }

      // 4) 보던 페이지를 다시 찾는다. 없어졌으면(옮긴 곡의 자동 여백 등) 옮기지 않은
      //    앞쪽 페이지, 없으면 뒤쪽 — 앞쪽은 보통 앞 곡의 여백이라 화면이 크게 안 바뀐다.
      final result = _allSlides;
      final indexOfKey = {
        for (var i = 0; i < result.length; i++) keyOf(result[i]): i,
      };
      int find(_SlideInfo s) => indexOfKey[resolve(keyOf(s))] ?? -1;

      var found = find(current);
      for (final i in [
        for (var i = currentAt - 1; i >= 0; i--) i,
        for (var i = currentAt + 1; i < slides.length; i++) i,
      ]) {
        if (found >= 0) break;
        if (movedKeys.contains(keyOf(slides[i]))) continue;
        found = find(slides[i]);
      }
      _currentSlideIndex = found >= 0 ? found : 0;
      _clampCurrentSlideIndex();
      if (_currentSlideIndex < result.length) {
        _previewStagingUid = result[_currentSlideIndex].stagingUid;
      }
    });
    _sendCurrentSlide();
  }

  /// 항목 [uid] 에서 [moved] 페이지를 빼고 남은 페이지(전부 [moved] 아닌 쪽 번호).
  List<int> _keptPages(int uid, Set<int> moved) {
    final index = _stagingItems.indexWhere((e) => e.uid == uid);
    if (index < 0) return const [];
    return [
      for (var j = 0; j < _pageCount(_stagingItems[index].item); j++)
        if (!moved.contains(j)) j,
    ];
  }

  /// [moved] 를 빼도 지우지 않은 페이지가 남는지.
  bool _keepsPages(int uid, Set<int> moved) => _keptPages(
    uid,
    moved,
  ).any((j) => !_deletedSlideKeys.contains(_slideKey(uid, j)));

  /// 곡·PPT 항목 [uid] 에서 [moved] 페이지를 빼고 남은 페이지로 항목을 다시 만든다.
  /// 바뀐 슬라이드 키를 [renamed] 에 적는다. 남는 페이지가 있는지는 [_keepsPages] 로 먼저 본다.
  void _takePagesOut(int uid, Set<int> moved, Map<String, String> renamed) {
    final index = _stagingItems.indexWhere((e) => e.uid == uid);
    if (index < 0) return;
    _rebuildItem(index, [_keptPages(uid, moved)], renamed);
  }

  /// 같은 곡(제목)·같은 PPT 파일에서 나온 항목인지. 붙여 넣을 때 여백을 뺄지 정한다.
  static bool _sameSource(StagingItem a, StagingItem b) => switch ((a, b)) {
    (SongStagingItem(song: final x), SongStagingItem(song: final y)) =>
      x.title == y.title,
    (
      ImageStagingItem(sourceName: final x),
      ImageStagingItem(sourceName: final y),
    ) =>
      x == y,
    _ => false,
  };

  /// 항목을 콘티에서 뺀다. 앞 항목의 '여백 없음'은 빠진 항목도 뒤와 이어져 있었을 때만
  /// 남긴다 — 아니면 앞 항목이 엉뚱한 다음 곡과 여백 없이 붙는다.
  /// [prune] 이 false 면 PPT 원본 감시를 그대로 둔다(같은 항목을 곧바로 다시 넣을 때).
  void _removeStagingWhere(
    bool Function(({int uid, StagingItem item})) test, {
    bool prune = true,
  }) {
    for (var i = _stagingItems.length - 1; i >= 0; i--) {
      final e = _stagingItems[i];
      if (!test(e)) continue;
      final joined = _noSpacerUids.remove(e.uid);
      if (!joined && i > 0) _noSpacerUids.remove(_stagingItems[i - 1].uid);
      _mediaGroups.remove(e.uid);
      _stagingItems.removeAt(i);
    }
    if (prune) _pruneSourceWatches();
  }

  /// 곡·PPT 항목 [index] 를 [cut] 페이지 앞에서 둘로 나누고 뒷부분이 들어간 자리를 돌려준다.
  /// 배경·메모·지운 페이지 표시도 같이 옮기고, 바뀐 슬라이드 키를 [renamed] 에 적는다.
  /// 뒤에 남은(지우지 않은) 페이지가 없으면 null.
  int? _splitStagingItem(int index, int cut, Map<String, String> renamed) {
    final entry = _stagingItems[index];
    if (entry.item is! SongStagingItem && entry.item is! ImageStagingItem) {
      return null;
    }
    final length = _pageCount(entry.item);
    final hasTail = [
      for (var j = cut; j < length; j++) _slideKey(entry.uid, j),
    ].any((k) => !_deletedSlideKeys.contains(k));
    if (!hasTail) return null;
    final parts = _rebuildItem(index, [
      [for (var j = 0; j < cut; j++) j],
      [for (var j = cut; j < length; j++) j],
    ], renamed);
    return _stagingItems.indexWhere((e) => e.uid == parts.last.first);
  }

  static PraiseSong _songWithPages(PraiseSong song, List<LyricsPage> pages) =>
      song.copyWith(
        lyrics: encodePages(pages.map((p) => p.korean)),
        englishLyrics: encodePages(pages.map((p) => p.english)),
        extraLyrics: encodePages(pages.map((p) => p.extra)),
      );

  /// 콘티 항목 하나의 배경만 따로 지정한다(헌금송만 다른 배경 등).
  /// 다이얼로그에서 "전역 배경 사용"으로 되돌리면 오버라이드가 지워진다.
  Future<void> _editItemBackground(int uid) async {
    if (_itemBackgrounds[uid]?.isSermon == true) return _editSermonPage(uid);
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
        videoLibrary: _backgroundVideos,
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
            extraText: slide.extraText,
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
    await _insertPptImages(paths);
  }

  /// [paths] 를 차례로 구워 고른 항목 뒤에 넣는다. LibreOffice 가 없어 못 구운 파일이
  /// 있으면 설치를 권하고, 설치되면 그 파일들만 다시 굽는다.
  Future<void> _insertPptImages(List<String> paths) async {
    final progress = ValueNotifier<String>('변환 중…');
    _showProgressDialog(progress);

    final items = <ImageStagingItem>[];
    String? errorMessage;
    // LibreOffice 가 없어 못 구운 파일. 뒤의 PDF 등은 그대로 계속 굽는다.
    final missing = <String>[];
    try {
      for (var i = 0; i < paths.length; i++) {
        progress.value = paths.length == 1
            ? '${p.basename(paths[i])} 변환 중…'
            : '${paths.length}개 중 ${i + 1}번째 변환 중…';
        try {
          items.add(await _pythonBridge.renderPptToImages(paths[i]));
        } on LibreOfficeMissingException {
          missing.add(paths[i]);
        }
      }
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

    if (missing.isNotEmpty) {
      final installed = await _showLibreofficeDialog(
        reason:
            'PPT를 이미지로 바꾸려면 LibreOffice가 설치되어 있어야 합니다.\n'
            'PDF 파일은 LibreOffice 없이도 넣을 수 있습니다.',
      );
      if (installed && mounted) {
        await _insertPptImages(missing);
      }
    }
  }

  /// PPT 항목의 원본 파일을 기본 프로그램(PowerPoint 등)으로 열고, 저장되면 다시 굽도록 지켜본다.
  Future<void> _openImageSource(int uid) async {
    final path = _imageSourcePath(uid);
    if (path == null) return;
    String? failure;
    try {
      if (Platform.isWindows) {
        // explorer 는 경로의 쉼표를 구분자로 읽어 엉뚱한 폴더를 연다 → 네이티브 ShellExecuteW.
        final opened = await _presentationChannel.invokeMethod<bool>(
          'openFile',
          {'path': path},
        );
        if (opened != true) failure = '연결된 프로그램이 없습니다';
      } else {
        final result = await Process.run(
          Platform.isMacOS ? 'open' : 'xdg-open',
          [path],
        );
        if (result.exitCode != 0) {
          final stderr = '${result.stderr}'.trim();
          failure = stderr.isEmpty ? '종료 코드 ${result.exitCode}' : stderr;
        }
      }
      if (failure != null) {
        await AppLogger.instance.error('원본 파일 열기 실패: $path', failure);
      }
    } catch (error, stack) {
      await AppLogger.instance.error('원본 파일 열기 실패: $path', error, stack);
      failure = '$error';
    }
    if (failure != null) {
      _showSnack('원본 파일을 열지 못했습니다. 이 파일을 열 프로그램이 있는지 확인해 주세요. ($failure)');
      return;
    }
    await _sourceWatcher.watch(path);
    _showSnack('${p.basename(path)} 을(를) 열었습니다. 고친 뒤 저장하면 자동으로 다시 불러옵니다.');
  }

  /// 원본 파일 경로. 항목에 원본이 없거나 파일이 사라졌으면 알리고 null.
  String? _imageSourcePath(int uid) {
    final item = _stagingItems.where((e) => e.uid == uid).firstOrNull?.item;
    if (item is! ImageStagingItem) return null;
    final path = item.sourcePath;
    if (path == null) {
      _showSnack('원본 파일 정보가 없는 항목입니다. 파일을 다시 추가해 주세요.');
      return null;
    }
    if (!File(path).existsSync()) {
      _showSnack('원본 파일을 찾을 수 없습니다: $path');
      return null;
    }
    return path;
  }

  /// 콘티에 더는 없는 원본은 지켜보지 않는다. 남겨 두면 나중에 같은 파일을 쓰는 다른
  /// 콘티를 불러왔을 때, 그 파일을 저장하는 것만으로 항목이 멋대로 다시 구워진다.
  void _pruneSourceWatches() {
    final used = {
      for (final e in _stagingItems)
        if (e.item case ImageStagingItem(:final sourcePath?)) sourcePath,
    };
    for (final path in _sourceWatcher.watchedPaths.toList()) {
      if (!used.contains(path)) _sourceWatcher.unwatch(path);
    }
  }

  /// [path] 를 원본으로 하는 모든 PPT 항목을 다시 굽는다.
  /// [automatic] 은 저장 감지로 불린 경우 — 진행 창 없이 안내만 띄운다.
  Future<void> _reloadImageSource(
    String path, {
    required bool automatic,
  }) async {
    bool usesPath(({int uid, StagingItem item}) e) =>
        e.item is ImageStagingItem &&
        (e.item as ImageStagingItem).sourcePath == path;
    if (!_stagingItems.any(usesPath)) {
      _sourceWatcher.unwatch(path);
      return;
    }
    final name = p.basename(path);
    if (!_reloadingSources.add(path)) {
      // 굽는 중에 또 저장됐거나 버튼을 눌렀다. 끝나면 한 번 더 굽는다.
      _reloadAgainSources.add(path);
      if (!automatic) {
        _showSnack('$name 을(를) 이미 다시 불러오는 중입니다. 끝나면 한 번 더 불러옵니다.');
      }
      return;
    }

    final progress = automatic
        ? null
        : ValueNotifier<String>('$name 다시 불러오는 중…');
    if (progress != null) {
      _showProgressDialog(progress);
    } else {
      _showSnack('$name 이(가) 바뀌어 다시 불러오는 중…', replace: false);
    }

    ImageStagingItem? rendered;
    String? errorMessage;
    try {
      rendered = await _pythonBridge.renderPptToImages(path);
    } on LibreOfficeMissingException catch (error) {
      errorMessage = error.toString();
    } catch (error, stack) {
      await AppLogger.instance.error('원본 다시 불러오기 실패', error, stack);
      errorMessage = '다시 불러오기 실패: $error';
    } finally {
      _reloadingSources.remove(path);
    }

    if (progress != null) {
      progress.dispose();
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (!mounted) return;
    if (rendered == null) {
      _showSnack(errorMessage ?? '다시 불러오기 실패');
    } else {
      await _applyReloadedSource(path, rendered, automatic: automatic);
    }
    if (_reloadAgainSources.remove(path)) {
      await _reloadImageSource(path, automatic: true);
    }
  }

  /// 다시 구운 [rendered] 로 [path] 를 원본으로 하는 항목을 모두 바꾼다.
  ///
  /// 항목 uid 는 그대로라 배경·헌금송·여백 설정은 남는다. 보고 있던 슬라이드는 번호가 아니라
  /// (항목, 페이지) 로 다시 찾는다 — 앞 항목의 장 수가 바뀌어도 관객 화면이 멋대로 넘어가지 않게.
  /// 장 수가 그대로면 지운 페이지·메모를 그대로 두고, 바뀌었으면 페이지 대응을 알 수 없으므로
  /// 지운 페이지 표시는 풀고(안내한다) 범위 밖 메모만 버린다. 자동 여백의 메모는 여백을 따라간다.
  Future<void> _applyReloadedSource(
    String path,
    ImageStagingItem rendered, {
    required bool automatic,
  }) async {
    final newCount = rendered.imagePaths.length;
    final slides = _allSlides;
    final current = slides.isEmpty
        ? null
        : slides[_currentSlideIndex.clamp(0, slides.length - 1)];
    var restoredPages = false;

    setState(() {
      for (var i = 0; i < _stagingItems.length; i++) {
        final entry = _stagingItems[i];
        final item = entry.item;
        if (item is! ImageStagingItem || item.sourcePath != path) continue;
        _stagingItems[i] = (uid: entry.uid, item: rendered);
        if (remapReloadedPages(
          uid: entry.uid,
          oldCount: item.imagePaths.length,
          newCount: newCount,
          deletedKeys: _deletedSlideKeys,
          notes: _slideNotes,
        )) {
          restoredPages = true;
        }
      }

      if (current != null) {
        _currentSlideIndex = _findSlideAfterReload(current, newCount, path);
      }
      _clampCurrentSlideIndex();
    });
    await _sendCurrentSlide();
    _showSnack(
      restoredPages
          ? '${p.basename(path)} 을(를) 다시 불러왔습니다 ($newCount장). 장 수가 바뀌어 지웠던 페이지가 다시 보입니다.'
          : '${p.basename(path)} 을(를) 다시 불러왔습니다 ($newCount장).',
      replace: !automatic,
    );
  }

  /// 다시 불러오기 전에 보던 슬라이드 [before] 가 지금 몇 번째인지.
  /// 다시 구운 항목 안이었으면 같은 페이지(줄었으면 마지막 페이지), 여백이었으면 여백으로 간다.
  int _findSlideAfterReload(_SlideInfo before, int newCount, String path) {
    final slides = _allSlides;
    final reloaded = _stagingItems.any(
      (e) =>
          e.uid == before.stagingUid &&
          e.item is ImageStagingItem &&
          (e.item as ImageStagingItem).sourcePath == path,
    );
    final page = !reloaded || before.isAutoSpacer
        ? before.pageIndexInItem
        : before.pageIndexInItem.clamp(0, newCount - 1);
    int? sameItem;
    for (var i = 0; i < slides.length; i++) {
      final s = slides[i];
      if (s.stagingUid != before.stagingUid) continue;
      if (before.isAutoSpacer) {
        if (s.isAutoSpacer) return i;
        continue;
      }
      if (!s.isAutoSpacer && s.pageIndexInItem == page) return i;
      // 그 페이지를 지워 둔 경우 항목 안에서 가장 가까운 앞 페이지.
      if (!s.isAutoSpacer && s.pageIndexInItem < page) sameItem = i;
    }
    return sameItem ?? _currentSlideIndex;
  }

  /// [replace] 가 true 면 떠 있는 안내를 바로 닫고 띄운다. 저장 감지처럼 사용자가 누르지 않은
  /// 안내는 false 로 — 떠 있던 오류 안내를 읽기도 전에 지우면 안 된다.
  void _showSnack(String message, {bool replace = true}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (replace) messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  /// 닫기는 호출한 쪽에서 `Navigator.of(context, rootNavigator: true).pop()`.
  void _showProgressDialog(
    ValueNotifier<String> progress, {
    VoidCallback? onCancel,
  }) {
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
            actions: [
              if (onCancel != null)
                TextButton(onPressed: onCancel, child: const Text('취소')),
            ],
          ),
        ),
      ),
    );
  }

  // ── 악보 가사 추출 ──────────────────────────────────────────────────

  /// 악보 파일(이미지·PDF)을 골라 오선 아래 가사만 읽어 오고, 그대로 새 곡으로 만든다.
  /// [fromClipboard] 면 파일 대신 클립보드의 그림을 읽는다.
  Future<void> _importSheetMusic({bool fromClipboard = false}) async {
    // null = 클립보드
    final List<String?> paths;
    if (fromClipboard) {
      paths = const [null];
    } else {
      await FilePicker.skipEntitlementsChecks();
      final picked = await FilePicker.pickFiles(
        dialogTitle: '가사를 추출할 악보 파일 선택 (이미지 · PDF)',
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'bmp', 'tif', 'tiff', 'pdf'],
        allowMultiple: true,
      );
      paths = picked?.paths.whereType<String>().toList() ?? const [];
    }
    if (paths.isEmpty || !mounted) return;

    final progress = ValueNotifier<String>('가사 읽는 중…');
    // 취소하면 창만 닫고 결과를 버린다(돌고 있는 ppt_tool 은 끝까지 돌다 끝난다).
    var cancelled = false;
    _showProgressDialog(
      progress,
      onCancel: () {
        // 닫히는 동안 한 번 더 누르면 두 번째 pop 이 메인 화면을 닫는다.
        if (cancelled) return;
        cancelled = true;
        Navigator.of(context, rootNavigator: true).pop();
      },
    );

    final texts = <String>[];
    String? errorMessage;
    var tesseractMissing = false;
    try {
      for (var i = 0; i < paths.length && !cancelled; i++) {
        progress.value = paths.length == 1
            ? '${p.basename(paths[i] ?? '클립보드')} 읽는 중…'
            : '${paths.length}개 중 ${i + 1}번째 읽는 중…';
        final result = await _pythonBridge.extractSheetLyrics(paths[i]);
        if (result.lyrics.trim().isNotEmpty) {
          texts.add(result.lyrics.trim());
        }
      }
    } on TesseractMissingException {
      tesseractMissing = true;
    } on ClipboardEmptyException catch (error) {
      errorMessage = error.toString();
    } catch (error, stack) {
      await AppLogger.instance.error('악보 가사 추출 실패', error, stack);
      errorMessage = '가사 추출 실패: $error';
    }

    progress.dispose();
    if (cancelled || !mounted) return;
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

    final title = paths.first == null
        ? '붙여넣은 악보'
        : p.basenameWithoutExtension(paths.first!);
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
      _removeStagingWhere((e) => e.uid == uid);
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
      final entry = _stagingItems[oldIndex];
      _removeStagingWhere((e) => e.uid == entry.uid);
      _stagingItems.insert(newIndex, entry);
      // 옮긴 자리 앞 항목과는 여백을 둔다.
      if (newIndex > 0) _noSpacerUids.remove(_stagingItems[newIndex - 1].uid);
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

    final libreofficeMissing = await _importFolder(folder, subLanguage);
    // 설치되면 같은 폴더를 다시 가져온다. 이미 들어간 곡(.pptx)은 중복으로 건너뛰고 .ppt 만 새로 들어간다.
    if (libreofficeMissing && mounted && await _showLibreofficeDialog()) {
      if (mounted) await _importFolder(folder, subLanguage);
    }
  }

  /// 폴더를 가져와 저장한다. LibreOffice 가 없어 .ppt 를 건너뛰었으면 true.
  Future<bool> _importFolder(String folder, String subLanguage) async {
    var libreofficeMissing = false;
    setState(() {
      _selectedFolder = folder;
      _isImporting = true;
      _importTotalCount = 0;
      _importSavedCount = 0;
      _importStatusText = '폴더를 분석하는 중입니다.';
    });

    try {
      final result = await _pythonBridge.importFolder(folder);
      libreofficeMissing = result.libreofficeMissing;
      if (!mounted) return false;
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
        if (!mounted) return libreofficeMissing;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.songs.isEmpty
                  ? '가져올 PPT/PPTX 파일을 찾지 못했습니다.'
                  : '$subLanguage 가사 $saved곡을 제목 기준으로 저장했습니다.',
            ),
          ),
        );
        return libreofficeMissing;
      }
      var insertedCount = 0;
      var duplicateCount = 0;
      var updatedCount = 0;
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
        updatedCount = saveResult.updatedCount;
      }
      await _loadSongs();
      if (!mounted) return libreofficeMissing;
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            updatedCount == 0 ? message : '$message (가사 나누기 고침 $updatedCount개)',
          ),
        ),
      );
    } catch (error, stack) {
      await AppLogger.instance.error('찬양 폴더 가져오기 실패', error, stack);
      if (!mounted) return libreofficeMissing;
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
    return libreofficeMissing;
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
            .map(
              (e) => (
                item: e.item,
                background: _itemBackgrounds[e.uid],
                noSpacer: _noSpacerUids.contains(e.uid),
              ),
            )
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
        noSpacerUids: _noSpacerUids,
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

  // 다른 PC 로 옮길 콘티 파일(.wsconti). 이미지까지 한 파일에 담긴다.
  Future<void> _exportContiFile(WorshipConti conti) async {
    const ext = WorshipContiRepository.contiFileExtension;
    final fileName = '${conti.name}.$ext';
    String? outPath;
    if (Platform.isMacOS) {
      try {
        outPath = await _savePanelChannel.invokeMethod<String>(
          'showPptxSavePanel',
          {'title': '콘티 내보내기', 'fileName': fileName, 'extension': ext},
        );
      } on MissingPluginException {
        outPath = null;
      }
    } else {
      await FilePicker.skipEntitlementsChecks();
      outPath = await FilePicker.saveFile(
        dialogTitle: '콘티 내보내기',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: [ext],
      );
    }
    if (outPath == null || !mounted) return;
    if (p.extension(outPath).toLowerCase() != '.$ext') {
      outPath = p.setExtension(outPath, '.$ext');
    }
    try {
      await _contiRepository.exportContiFile(conti.id, outPath);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('콘티 내보내기 완료: $outPath')));
    } catch (error, stack) {
      await AppLogger.instance.error('콘티 내보내기 실패', error, stack);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('콘티 내보내기 실패: $error')));
    }
  }

  /// 콘티 파일을 이 PC 의 콘티 목록에 넣는다. 성공하면 새 목록을 돌려준다.
  Future<List<WorshipConti>?> _importContiFile() async {
    await FilePicker.skipEntitlementsChecks();
    final picked = await FilePicker.pickFiles(
      dialogTitle: '가져올 콘티 파일 선택',
      type: FileType.custom,
      allowedExtensions: [WorshipContiRepository.contiFileExtension],
    );
    final path = picked?.paths.firstOrNull;
    if (path == null || !mounted) return null;
    try {
      await _contiRepository.importContiFile(path);
      return await _contiRepository.listContis();
    } catch (error, stack) {
      await AppLogger.instance.error('콘티 가져오기 실패', error, stack);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('콘티 가져오기 실패: $error')));
      }
      return null;
    }
  }

  /// 작업 중인 콘티를 [items] 로 통째로 바꾼다. 저장한 콘티는 건드리지 않는다.
  void _replaceConti(
    List<({int uid, StagingItem item})> items, {
    Set<int> noSpacerUids = const {},
    Map<String, String> notes = const {},
    Map<int, SlideBackground> backgrounds = const {},
  }) {
    // 불러온 콘티의 원본은 '원본 열어 수정' 을 누르기 전까지 지켜보지 않는다.
    _sourceWatcher.unwatchAll();
    setState(() {
      _stagingItems
        ..clear()
        ..addAll(items);
      _deletedSlideKeys.clear();
      _noSpacerUids
        ..clear()
        ..addAll(noSpacerUids);
      _mediaGroups.clear();
      _slideNotes
        ..clear()
        ..addAll(notes);
      _itemBackgrounds
        ..clear()
        ..addAll(backgrounds);
      _nextUid += items.length;
      _previewStagingUid = items.isEmpty ? null : items.first.uid;
      _currentSlideIndex = 0;
    });
  }

  /// '새 콘티' 버튼: 담긴 항목을 한 번에 비운다. 관객 화면이 끊기지 않게 발표 중에는 막는다.
  Future<void> _newConti() async {
    if (_isPresentationOpen) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('발표 중에는 새 콘티를 만들 수 없습니다. 발표를 끝낸 뒤 눌러 주세요.')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('새 콘티'),
        content: Text(
          '담긴 ${_stagingItems.length}개 항목을 모두 지울까요?\n'
          '저장하지 않은 내용은 사라집니다. 저장한 콘티는 그대로 남습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('새 콘티'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _replaceConti(const []);
  }

  Future<void> _loadContiDialog() async {
    final contis = await _contiRepository.listContis();
    if (!mounted) return;

    final selected = await showDialog<WorshipConti>(
      context: context,
      builder: (ctx) => _ContiListDialog(
        contis: contis,
        onDelete: (conti) async {
          await _contiRepository.deleteConti(conti.id);
        },
        onExport: _exportContiFile,
        onImport: _importContiFile,
        onUploadToCloud: _sync.status.value.enabled
            ? _uploadContiToCloud
            : null,
        onCancelCloud: _sync.cancel,
        onOpenCloud: _sync.status.value.enabled ? _openCloudContis : null,
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

    _replaceConti(
      result.items,
      noSpacerUids: result.noSpacerUids,
      notes: result.notes,
      backgrounds: result.backgrounds,
    );
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

  // ── 동기화 (모두 손으로) ─────────────────────────────────────────────

  void _openSyncDialog() => SyncDialog.show(
    context,
    service: _sync,
    onSyncSongs: _syncSongs,
    onOpenCloudContis: _openCloudContis,
  );

  void _openCloudContis() => CloudContiDialog.show(context, _sync);

  /// '찬양 동기화' 버튼: 다른 PC 의 새 찬양·바뀐 찬양을 받고 이 PC 찬양을 올린다.
  Future<void> _syncSongs() async {
    final result = await _sync.syncSongs();
    if (!mounted) return;
    final status = _sync.status.value;
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status.lastError == null
                ? '찬양 동기화를 취소했습니다.'
                : '찬양 동기화 실패: ${status.lastError}',
          ),
        ),
      );
      return;
    }
    final warning = status.warning == null ? '' : '\n${status.warning}';
    if (result.changed) {
      await _loadSongs();
      await _loadSubLanguages();
      if (!mounted) return;
    }
    final parts = [
      if (result.addedCount > 0) '새 찬양 ${result.addedCount}곡',
      if (result.updatedCount > 0) '바뀐 찬양 ${result.updatedCount}곡',
      if (result.deletedCount > 0) '지운 찬양 ${result.deletedCount}곡',
    ];
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          parts.isEmpty
              ? '받을 새 찬양이 없습니다. 이 PC 의 찬양은 올렸습니다.$warning'
              : '찬양 동기화 완료: ${parts.join(' · ')}$warning',
        ),
      ),
    );
  }

  /// 콘티를 클라우드에 올린다. 실패하면 이유를 담아 던진다(콘티 목록 창이 보여 준다).
  Future<void> _uploadContiToCloud(WorshipConti conti) async {
    try {
      await _sync.uploadConti(conti);
    } catch (error, stack) {
      await AppLogger.instance.error('콘티 올리기 실패', error, stack);
      rethrow;
    }
  }

  /// 켤 때 한 번: 서버에 새 찬양·바뀐 찬양·새 콘티가 있으면 알리고 고르게 한다(DB 는 그대로 본다).
  Future<void> _checkServerOnStartup() async {
    if (!_sync.status.value.enabled) return;
    final check = await _sync.checkForUpdates();
    if (check == null || !check.hasAnything || !mounted) return;
    final songs = check.songs;
    final lines = [
      if (check.localChanges) '이 PC 에서 고친 찬양을 아직 안 올렸습니다',
      if (songs.addedCount > 0) '새 찬양 ${songs.addedCount}곡',
      if (songs.updatedCount > 0) '바뀐 찬양 ${songs.updatedCount}곡',
      if (songs.deletedCount > 0) '다른 PC 에서 지운 찬양 ${songs.deletedCount}곡',
      if (check.newContis.isNotEmpty) '새 콘티 ${check.newContis.length}개',
    ];
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('서버에 새 내용이 있습니다'),
        content: Text(
          '${lines.map((l) => '· $l').join('\n')}\n\n지금 받을까요? 나중에 \'찬양·콘티 동기화\' 에서 받아도 됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('나중에'),
          ),
          if (check.newContis.isNotEmpty)
            OutlinedButton(
              onPressed: () => Navigator.of(ctx).pop('contis'),
              child: const Text('콘티 보기'),
            ),
          if (songs.changed || check.localChanges)
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop('songs'),
              child: const Text('찬양 동기화'),
            ),
        ],
      ),
    );
    // 한 번 알린 콘티는 다음에 켤 때 다시 알리지 않는다(클라우드 콘티 창에는 그대로 있다).
    await _sync.markContisSeen(check.newContis.map((c) => c.uid));
    if (!mounted) return;
    if (choice == 'songs') await _syncSongs();
    if (choice == 'contis' && mounted) _openCloudContis();
  }

  // ── 곡 관리 ──────────────────────────────────────────────────────────

  Future<void> _clearAllSongs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('전체 초기화'),
        content: Text(
          _sync.status.value.enabled
              ? '저장된 찬양 DB를 모두 삭제합니다.\n동기화를 쓰고 있어, 다음에 \'찬양 동기화\'를 누르면 다른 PC 의 찬양도 지워집니다. 계속할까요?'
              : '저장된 찬양 DB를 모두 삭제합니다. 계속할까요?',
        ),
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
      _removeStagingWhere((e) {
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

  /// 찬양 검색 목록의 삭제 아이콘: 그 곡 하나만 DB 에서 지운다.
  /// 콘티에 담긴 항목은 가사 스냅샷이라 그대로 둔다(그대로 발표할 수 있다).
  Future<void> _deleteSong(PraiseSong song) async {
    final id = song.id;
    if (id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('곡 삭제'),
        content: Text('「${song.displayTitle}」을 DB에서 삭제합니다. 계속할까요?'),
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

    await _repository.deleteSongsByIds([id]);
    await _loadSongs();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('「${song.displayTitle}」을 삭제했습니다.')));
  }

  Future<void> _openSongEditor(PraiseSong? song) async {
    final translations = song == null
        ? const <String, String>{}
        : await _repository.translationsForTitle(song.title);
    if (!mounted) return;
    final result = await showDialog<SongEditResult>(
      context: context,
      builder: (context) => LyricsEditorDialog(
        song: song,
        translations: translations,
        languages: _subLanguages,
        subLanguage: _style.subLanguage,
        extraLanguage: _style.extraLanguage,
        style: _style,
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

  /// LibreOffice 안내 + 자동 설치. 설치까지 끝나면 true — 하던 작업을 다시 시도하면 된다.
  Future<bool> _showLibreofficeDialog({
    String reason =
        '.ppt 파일을 읽으려면 LibreOffice가 설치되어 있어야 합니다.\n'
        '.pptx 파일은 LibreOffice 없이도 정상적으로 가져올 수 있습니다.',
  }) {
    return LibreOfficeInstallDialog.show(
      context,
      reason: reason,
      onOpenDownloadPage: () => _openUrl(LibreOfficeInstaller.downloadPage),
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
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
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
                          // 탭 글자가 잘리지 않게 글자 폭대로 둔다(isScrollable).
                          tabs: SizedBox(
                            width: 200,
                            child: TabBar(
                              controller: _mainTabController,
                              isScrollable: true,
                              tabAlignment: TabAlignment.start,
                              dividerColor: Colors.transparent,
                              tabs: const [
                                Tab(text: '편집'),
                                Tab(text: '발표 보기'),
                              ],
                            ),
                          ),
                          actions: _appBarActions(slides),
                          isImporting: _isImporting,
                          isBibleImporting: _isBibleImporting,
                          onImportPressed: _pickAndImportFolder,
                          onBibleImportPressed: _pickAndImportBible,
                          onImportPptPressed: _addPptImages,
                          onImportSheetPressed: _importSheetMusic,
                          onPasteSheetPressed: () =>
                              _importSheetMusic(fromClipboard: true),
                          onExportSongsPressed: _exportSongBundle,
                          onImportSongsPressed: _importSongBundle,
                          onSyncPressed: _openSyncDialog,
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
                              onOpenSource: _openImageSource,
                              onReloadSource: (uid) {
                                final path = _imageSourcePath(uid);
                                if (path != null) {
                                  _reloadImageSource(path, automatic: false);
                                }
                              },
                              onReorder: _onStagingReorder,
                              onRemove: _removeFromStaging,
                              onDropSong: _addSongToStaging,
                              onImportText: _importContiText,
                              isCollapsed: _isStagingCollapsed,
                              onToggleCollapsed: () => setState(
                                () =>
                                    _isStagingCollapsed = !_isStagingCollapsed,
                              ),
                              onNewConti: _newConti,
                              onSaveConti: _saveConti,
                              onLoadConti: _loadContiDialog,
                              onAddBlank: (kind) => _addPage(
                                kind,
                                _indexAfterSelectedItem,
                                onBlank: _addBlankItem,
                              ),
                              onSelect: (uid) {
                                setState(() {
                                  _previewStagingUid = uid;
                                  _currentSlideIndex =
                                      _findFirstSlideForStaging(uid);
                                });
                                _sendCurrentSlide();
                              },
                              overflowCounts: _overflowCounts(),
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
                                // 휴대폰 리모컨 메모도 바뀌게.
                                _scheduleRemoteSync();
                              },
                              onSlideSelected: _goToSlide,
                              onSlideEdit: _editSlide,
                              onSlideDelete: _deleteSlide,
                              onSlidesDelete: _deleteSlides,
                              onSlidesCopy: _copySlides,
                              onPaste: _pasteSlides,
                              onSlidesMove: _moveSlides,
                              onAddPage: (kind) => _addPage(
                                kind,
                                _indexAfterCurrentSlide,
                                onBlank: _addBlankAfterCurrentSlide,
                              ),
                              onToggleMedia: _toggleMedia,
                              mediaPlayback: _mediaPlayback,
                              onSeekMedia: _seekMedia,
                              onPrev: _prevSlide,
                              onNext: _nextSlide,
                              onToggleBlackout: _toggleBlackout,
                              isSingerOpen: _isSingerOpen,
                              onToggleSinger: _toggleSingerWindow,
                              isMobileSingerOn: _singerWeb.isRunning,
                              onShowMobileSinger: _showMobileSinger,
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
                              isActive: _mainTabController.index == 1,
                              voice: _voice,
                              onToggleVoice: _toggleVoice,
                              onShowVoiceInsert: _showVoiceInsert,
                              onUndoVoiceInsert: _undoVoiceInsert,
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
                              onStageSong: _addSongToStaging,
                              onDeleteSong: _deleteSong,
                              onClearAll: _clearAllSongs,
                              onAddSong: () => _openSongEditor(null),
                              onEditSong: _openSongEditor,
                              onImportFolder: _pickAndImportFolder,
                              bibleRepository: _bibleRepository,
                              bibleVerseCount: _bibleVerseCount,
                              bibleDataRevision: _bibleDataRevision,
                              onAddBibleItem: _addBibleItem,
                              bibleSubVersion: _style.bibleSubVersion,
                              bibleExtraVersion: _style.bibleExtraVersion,
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
                              offeringDesign: _offeringDesign,
                              onEditOffering: _editOfferingDesign,
                              imageLibrary: _backgroundImages,
                              videoLibrary: _backgroundVideos,
                              onResetTextLayout: _resetTextLayout,
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
                        const SizedBox(height: 6),
                        _StatusBar(
                          storedCount: _storedCount,
                          bibleVerseCount: _bibleVerseCount,
                          selectedFolder: _selectedFolder,
                          importStatusText: _importStatusText,
                          importTotalCount: _importTotalCount,
                          importSavedCount: _importSavedCount,
                          packageInfo: _packageInfo,
                          syncStatus: _sync.status,
                          onSyncPressed: _openSyncDialog,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 앱 바 오른쪽 끝: PPTX 저장 + 발표 시작(발표 중이면 진행 표시 + 종료).
  List<Widget> _appBarActions(List<_SlideInfo> slides) {
    final cs = Theme.of(context).colorScheme;
    return [
      OutlinedButton.icon(
        onPressed: _isExporting ? null : _exportPresentation,
        icon: _isExporting
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.file_download_outlined, size: 17),
        label: Text(_isExporting ? '생성 중' : 'PPTX 저장'),
      ),
      const SizedBox(width: 8),
      Builder(
        builder: (anchor) => IconButton(
          tooltip: '화면 모니터 선택 (관객·싱어)',
          icon: const Icon(Icons.desktop_windows_outlined, size: 19),
          onPressed: () => _showScreenMenu(anchor),
        ),
      ),
      const SizedBox(width: 4),
      if (_isPresentationOpen) ...[
        const Icon(Icons.circle, size: 8, color: AppColors.live),
        const SizedBox(width: 6),
        Text(
          _slideJumpBuffer.isEmpty
              ? '발표 중 ${_currentSlideIndex + 1} / ${slides.length}'
              : '이동 → $_slideJumpBuffer',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 10),
        FilledButton.icon(
          onPressed: _closePresentation,
          icon: const Icon(Icons.stop_rounded, size: 17),
          label: const Text('발표 종료'),
          style: FilledButton.styleFrom(
            backgroundColor: cs.errorContainer,
            foregroundColor: cs.onErrorContainer,
          ),
        ),
      ] else
        FilledButton.icon(
          onPressed: slides.isEmpty ? null : _openPresentation,
          icon: const Icon(Icons.play_arrow_rounded, size: 18),
          label: const Text('발표 시작'),
        ),
    ];
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

/// 앱 바 한 줄: 제목 · 편집/발표 보기 탭 · 가져오기 메뉴 · 업데이트 · [actions](PPTX 저장, 발표 시작).
/// 보관함 정보(곡 수·폴더·진행률)는 아래 [_StatusBar] 로 내렸다.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.tabs,
    required this.actions,
    required this.isImporting,
    required this.isBibleImporting,
    required this.onImportPressed,
    required this.onBibleImportPressed,
    required this.onImportPptPressed,
    required this.onImportSheetPressed,
    required this.onPasteSheetPressed,
    required this.onExportSongsPressed,
    required this.onImportSongsPressed,
    required this.onSyncPressed,
    required this.onExtractLogsPressed,
    required this.isCheckingUpdate,
    required this.hasUpdate,
    required this.onCheckUpdate,
  });

  final Widget tabs;
  final List<Widget> actions;
  final bool isImporting;
  final bool isBibleImporting;
  final VoidCallback onImportPressed;
  final VoidCallback onBibleImportPressed;
  final VoidCallback onImportPptPressed;
  final VoidCallback onImportSheetPressed;
  final VoidCallback onPasteSheetPressed;
  final VoidCallback onExportSongsPressed;
  final VoidCallback onImportSongsPressed;
  final VoidCallback onSyncPressed;
  final VoidCallback onExtractLogsPressed;
  final bool isCheckingUpdate;
  final bool hasUpdate;
  final VoidCallback onCheckUpdate;

  PopupMenuItem<VoidCallback> _item(
    VoidCallback action,
    IconData icon,
    String title, {
    String? subtitle,
    bool enabled = true,
  }) {
    return PopupMenuItem(
      value: action,
      enabled: enabled,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, size: 18),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final busy = isImporting || isBibleImporting;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Text(
            '예배 슬라이드',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(width: 20),
          tabs,
          const Spacer(),
          // 매주 쓰는 것(위)과 처음 한 번·가끔 쓰는 것(구분선 아래)을 한 메뉴로.
          PopupMenuButton<VoidCallback>(
            tooltip: '가져오기',
            onSelected: (action) => action(),
            itemBuilder: (context) => [
              _item(
                onImportPptPressed,
                Icons.slideshow_rounded,
                'PPT · PDF 가져오기',
              ),
              _item(
                onImportSheetPressed,
                Icons.music_note_rounded,
                '악보에서 가사 읽기',
              ),
              _item(
                onPasteSheetPressed,
                Icons.content_paste_rounded,
                '악보 붙여넣기',
                subtitle: '캡처·복사한 악보 그림',
              ),
              const PopupMenuDivider(),
              _item(
                onImportPressed,
                Icons.folder_open_rounded,
                isImporting ? '찬양 폴더 읽는 중' : '찬양 폴더 가져오기',
                enabled: !isImporting,
              ),
              _item(
                onBibleImportPressed,
                Icons.menu_book_rounded,
                isBibleImporting ? '성경 저장 중' : '성경 불러오기',
                enabled: !isBibleImporting,
              ),
              _item(
                onExportSongsPressed,
                Icons.file_upload_outlined,
                '곡 모음 내보내기',
              ),
              _item(
                onImportSongsPressed,
                Icons.file_download_outlined,
                '곡 모음 가져오기',
                subtitle: '같은 제목은 건너뜁니다',
              ),
              _item(
                onSyncPressed,
                Icons.sync_rounded,
                '찬양·콘티 동기화',
                subtitle: '구글 드라이브로 여러 PC',
              ),
              const PopupMenuDivider(),
              _item(onExtractLogsPressed, Icons.description_outlined, '로그 추출'),
            ],
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: Border.all(color: cs.outline),
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(Icons.add_rounded, size: 18, color: cs.onSurface),
                  const SizedBox(width: 6),
                  const Text(
                    '가져오기',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.expand_more_rounded,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          PopupMenuButton<AppThemeKind>(
            tooltip: '테마',
            onSelected: setThemeKind,
            icon: Icon(
              Icons.palette_outlined,
              size: 18,
              color: cs.onSurfaceVariant,
            ),
            itemBuilder: (_) => [
              for (final k in AppThemeKind.values)
                PopupMenuItem(
                  value: k,
                  height: 36,
                  child: Row(
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: k.swatch,
                          shape: BoxShape.circle,
                          border: Border.all(color: cs.outline),
                        ),
                        child: Icon(Icons.circle, size: 8, color: k.accent),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(k.label)),
                      if (k == appThemeKind.value)
                        Icon(
                          Icons.check_rounded,
                          size: 16,
                          color: cs.secondary,
                        ),
                    ],
                  ),
                ),
            ],
          ),
          if (!hasUpdate)
            IconButton(
              tooltip: '업데이트 확인',
              onPressed: isCheckingUpdate ? null : onCheckUpdate,
              color: cs.onSurfaceVariant,
              icon: isCheckingUpdate
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 18),
            ),
          const SizedBox(width: 8),
          ...actions,
        ],
      ),
    );
  }
}

/// 맨 아래 한 줄: 보관함 정보와 가져오기 진행률, 버전.
class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.storedCount,
    required this.bibleVerseCount,
    required this.selectedFolder,
    required this.importStatusText,
    required this.importTotalCount,
    required this.importSavedCount,
    required this.packageInfo,
    required this.syncStatus,
    required this.onSyncPressed,
  });

  final int storedCount;
  final int bibleVerseCount;
  final String? selectedFolder;
  final String? importStatusText;
  final int importTotalCount;
  final int importSavedCount;
  final Future<PackageInfo> packageInfo;
  final ValueListenable<SyncStatus> syncStatus;
  final VoidCallback onSyncPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 11, color: cs.onSurfaceVariant);
    final status = importStatusText == null
        ? null
        : importTotalCount > 0
        ? '$importStatusText  $importSavedCount / $importTotalCount'
        : importStatusText!;
    return SizedBox(
      height: 22,
      child: Row(
        children: [
          Text('곡 $storedCount', style: style),
          const SizedBox(width: 12),
          Text('성경 $bibleVerseCount절', style: style),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              status ?? selectedFolder ?? '찬양 폴더를 아직 가져오지 않았습니다',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: status == null
                  ? style
                  : style.copyWith(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
            ),
          ),
          ValueListenableBuilder<SyncStatus>(
            valueListenable: syncStatus,
            builder: (context, sync, _) {
              if (!sync.enabled) return const SizedBox.shrink();
              final failed = sync.lastError != null;
              final label = sync.syncing
                  ? '동기화 중'
                  : failed
                  ? '동기화 실패'
                  : sync.warning != null
                  ? '동기화 확인 필요'
                  : sync.hasLocalChanges
                  ? '동기화 안 한 찬양 있음'
                  : sync.lastSyncAt == null
                  ? '동기화'
                  : '동기화 ${syncAgo(sync.lastSyncAt!)}';
              final color = failed ? cs.error : cs.onSurfaceVariant;
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Tooltip(
                  message: sync.lastError ?? sync.warning ?? sync.folder!,
                  child: InkWell(
                    onTap: onSyncPressed,
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    child: Row(
                      children: [
                        Icon(
                          failed
                              ? Icons.sync_problem_rounded
                              : Icons.sync_rounded,
                          size: 13,
                          color: color,
                        ),
                        const SizedBox(width: 4),
                        Text(label, style: style.copyWith(color: color)),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          FutureBuilder<PackageInfo>(
            future: packageInfo,
            builder: (context, snapshot) => Text(
              snapshot.hasData ? 'v${snapshot.data!.version}' : '',
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// 콘티 항목 종류(성경·빈 페이지·이미지). 찬양은 기본이라 표시하지 않는다.
class _KindTag extends StatelessWidget {
  const _KindTag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outline),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 가사 상자를 넘는 페이지가 있다는 빨간 표시('넘침 2'). 발표는 막지 않고 알리기만 한다.
class _OverflowChip extends StatelessWidget {
  const _OverflowChip(this.label, {this.tooltip});

  final String label;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final chip = Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: cs.onErrorContainer,
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
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
    required this.onOpenSource,
    required this.onReloadSource,
    required this.onReorder,
    required this.onRemove,
    required this.onDropSong,
    required this.onImportText,
    required this.onSelect,
    required this.isCollapsed,
    required this.onToggleCollapsed,
    required this.onNewConti,
    required this.onSaveConti,
    required this.onLoadConti,
    required this.onAddBlank,
    this.overflowCounts = const {},
  });

  final List<({int uid, StagingItem item})> stagingItems;

  /// 항목 uid → 가사 상자를 넘는 페이지 수. 0 인 항목은 없다.
  final Map<int, int> overflowCounts;
  final int? selectedUid;
  // 항목별 배경 오버라이드. 키가 있는 항목만 전역 배경 대신 이 배경으로 나간다.
  final Map<int, SlideBackground> backgrounds;
  final ValueChanged<int> onEditBackground;
  // 찬양(또는 빈 페이지)을 헌금송 배경으로 표시
  final ValueChanged<int> onOffering;
  final ValueChanged<int> onEditText;
  // PPT 항목: 원본을 PowerPoint 등으로 열어 고치기 / 원본에서 다시 굽기
  final ValueChanged<int> onOpenSource;
  final ValueChanged<int> onReloadSource;
  final void Function(int oldIndex, int newIndex) onReorder;
  final void Function(int uid) onRemove;
  // 찬양 검색 목록에서 끌어 온 곡 (콘티 맨 끝에 담는다)
  final ValueChanged<PraiseSong> onDropSong;
  // 콘티 글을 붙여 넣어 곡을 한꺼번에 담기
  final VoidCallback onImportText;
  final ValueChanged<int> onSelect;
  final bool isCollapsed;
  final VoidCallback onToggleCollapsed;
  final VoidCallback onNewConti;
  final VoidCallback onSaveConti;
  final VoidCallback onLoadConti;
  final ValueChanged<_AddPageKind> onAddBlank;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 찬양 검색 목록에서 끈 곡을 받는다. 타입이 PraiseSong 이라 발표 보기 썸네일
    // 끌기(_ThumbDrag)·콘티 순서 바꾸기와 섞이지 않는다. 놓은 자리와 상관없이 맨 끝에 담는다.
    return DragTarget<PraiseSong>(
      onAcceptWithDetails: (details) => onDropSong(details.data),
      builder: (context, candidates, _) {
        final card = _buildCard(context, cs);
        if (candidates.isEmpty) return card;
        return Container(
          foregroundDecoration: BoxDecoration(
            border: Border.all(color: cs.primary, width: 2),
            borderRadius: BorderRadius.circular(AppRadius.panel),
          ),
          child: card,
        );
      },
    );
  }

  Widget _buildCard(BuildContext context, ColorScheme cs) {
    // 좁은 패널에서도 넘치지 않게 아이콘 버튼 기본 48px 탭 타깃을 32px로 줄인다.
    // (그러지 않으면 저장/불러오기 버튼이 오른쪽으로 잘려 사라진다)
    final compactIcon = IconButton.styleFrom(
      minimumSize: const Size(32, 32),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

    if (isCollapsed) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '예배 콘티',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
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
      child: Padding(
        padding: const EdgeInsets.all(16),
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
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  '${stagingItems.length}개',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
                const SizedBox(width: 4),
                PopupMenuButton<_AddPageKind>(
                  icon: const Icon(Icons.add_box_outlined, size: 18),
                  tooltip: '새 페이지 추가',
                  style: compactIcon,
                  iconColor: cs.onSurfaceVariant,
                  onSelected: onAddBlank,
                  itemBuilder: (_) => _addPageMenuItems,
                ),
                IconButton(
                  icon: const Icon(Icons.playlist_add_rounded, size: 18),
                  tooltip: '콘티 한번에 넣기 (콘티 글 붙여 넣기)',
                  style: compactIcon,
                  color: cs.onSurfaceVariant,
                  onPressed: onImportText,
                ),
                IconButton(
                  icon: const Icon(Icons.note_add_outlined, size: 18),
                  tooltip: '새 콘티 (담긴 항목 모두 지우기)',
                  style: compactIcon,
                  color: cs.onSurfaceVariant,
                  onPressed: stagingItems.isEmpty ? null : onNewConti,
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
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.queue_music_rounded,
                            size: 36,
                            color: cs.outline,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '찬양은 더블클릭하거나 여기로 끌어 놓고,\n성경 구절은 골라 담으면 순서대로 담깁니다',
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.5,
                              color: cs.onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
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
                            borderRadius: BorderRadius.circular(
                              AppRadius.control,
                            ),
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
                              ? cs.secondaryContainer
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(
                            AppRadius.control,
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(
                              AppRadius.control,
                            ),
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
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: cs.onSurfaceVariant,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
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
                                            if (isBible) const _KindTag('성경'),
                                            if (isBlank)
                                              _KindTag(
                                                background?.isSermon == true
                                                    ? '설교 제목'
                                                    : '빈 페이지',
                                              ),
                                            if (item is ImageStagingItem)
                                              const _KindTag('이미지'),
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
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ),
                                            if (overflowCounts[entry.uid]
                                                case final count?)
                                              _OverflowChip(
                                                '넘침 $count',
                                                tooltip:
                                                    '가사 상자를 넘는 페이지가 $count장 있습니다. '
                                                    '페이지를 나누거나 글자 크기를 줄여 주세요.',
                                              ),
                                          ],
                                        ),
                                        if (item.previewText.isNotEmpty)
                                          Text(
                                            item.previewText,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: cs.onSurfaceVariant,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  if (item is ImageStagingItem &&
                                      item.sourcePath != null)
                                    PopupMenuButton<bool>(
                                      icon: const Icon(
                                        Icons.edit_note_rounded,
                                        size: 20,
                                      ),
                                      tooltip: '원본 PPT 수정',
                                      style: compactIcon,
                                      onSelected: (reloadOnly) => reloadOnly
                                          ? onReloadSource(entry.uid)
                                          : onOpenSource(entry.uid),
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                          value: false,
                                          child: ListTile(
                                            leading: Icon(Icons.open_in_new),
                                            title: Text('원본 열어 수정'),
                                            subtitle: Text(
                                              '저장하면 자동으로 다시 불러옵니다',
                                            ),
                                            dense: true,
                                          ),
                                        ),
                                        PopupMenuItem(
                                          value: true,
                                          child: ListTile(
                                            leading: Icon(Icons.refresh),
                                            title: Text('원본에서 다시 불러오기'),
                                            dense: true,
                                          ),
                                        ),
                                      ],
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
                                  // 설교 제목 페이지는 헌금송 배경을 걸면 글꼴·색이 사라지므로 뺀다.
                                  if (item is SongStagingItem ||
                                      (item is BlankStagingItem &&
                                          background?.isSermon != true))
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
                                        : background.isSermon
                                        ? '설교 제목 디자인 수정'
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
                                    child: Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: Icon(
                                        Icons.drag_handle_rounded,
                                        color: cs.outline,
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
    required this.onStageSong,
    required this.onDeleteSong,
    required this.onClearAll,
    required this.onAddSong,
    required this.onEditSong,
    required this.onImportFolder,
    required this.bibleRepository,
    required this.bibleVerseCount,
    required this.bibleDataRevision,
    required this.onAddBibleItem,
    required this.bibleSubVersion,
    this.bibleExtraVersion = '',
    required this.onCollapse,
    required this.searchInTitle,
    required this.searchInLyrics,
    required this.onSearchInTitleChanged,
    required this.onSearchInLyricsChanged,
  });

  final TextEditingController searchController;
  final List<PraiseSong> songs;
  final ValueChanged<PraiseSong> onStageSong;
  final ValueChanged<PraiseSong> onDeleteSong;
  final VoidCallback onClearAll;
  final VoidCallback onAddSong;
  final ValueChanged<PraiseSong> onEditSong;
  final VoidCallback onImportFolder;
  final BibleRepository bibleRepository;
  final int bibleVerseCount;
  final int bibleDataRevision;
  final void Function(BibleStagingItem) onAddBibleItem;
  final String bibleSubVersion;
  final String bibleExtraVersion;
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
                  onStageSong: widget.onStageSong,
                  onDeleteSong: widget.onDeleteSong,
                  onClearAll: widget.onClearAll,
                  onAddSong: widget.onAddSong,
                  onEditSong: widget.onEditSong,
                  onImportFolder: widget.onImportFolder,
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
                  extraVersion: widget.bibleExtraVersion,
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
    required this.onStageSong,
    required this.onDeleteSong,
    required this.onClearAll,
    required this.onAddSong,
    required this.onEditSong,
    required this.onImportFolder,
    required this.searchInTitle,
    required this.searchInLyrics,
    required this.onSearchInTitleChanged,
    required this.onSearchInLyricsChanged,
  });

  final TextEditingController controller;
  final List<PraiseSong> songs;
  // 곡 줄 더블클릭 → 콘티에 담기 (끌어 놓기는 콘티 패널의 DragTarget 이 받는다)
  final ValueChanged<PraiseSong> onStageSong;
  final ValueChanged<PraiseSong> onDeleteSong;
  final VoidCallback onClearAll;
  final VoidCallback onAddSong;
  final ValueChanged<PraiseSong> onEditSong;
  final VoidCallback onImportFolder;
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
                      borderRadius: BorderRadius.circular(AppRadius.control),
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
                ? Center(
                    child: controller.text.trim().isNotEmpty
                        ? Text(
                            '검색 결과가 없습니다',
                            style: TextStyle(color: cs.onSurfaceVariant),
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '저장된 찬양이 없습니다',
                                style: TextStyle(color: cs.onSurfaceVariant),
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: onImportFolder,
                                icon: const Icon(
                                  Icons.folder_open_rounded,
                                  size: 17,
                                ),
                                label: const Text('찬양 폴더 가져오기'),
                              ),
                            ],
                          ),
                  )
                : ListView.separated(
                    itemCount: songs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final song = songs[index];
                      // 더블클릭 = 담기, 끌기 = 콘티 패널에 놓아 담기. 한 번 클릭은 아무것도 안 한다
                      // (예전 체크박스는 콘티 상태를 따라가서 '선택 삭제'가 콘티 곡을 지웠다).
                      // 아이콘 버튼은 GestureDetector 밖에 둔다 — 안에 두면 더블탭 인식이
                      // 첫 클릭을 붙잡아 버튼이 늦게 눌린다.
                      return Row(
                        children: [
                          Expanded(
                            child: Draggable<PraiseSong>(
                              data: song,
                              dragAnchorStrategy: pointerDragAnchorStrategy,
                              feedback: Material(
                                elevation: 4,
                                color: cs.surface,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.control,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  child: Text(
                                    song.title,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: cs.onSurface,
                                    ),
                                  ),
                                ),
                              ),
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onDoubleTap: () => onStageSong(song),
                                child: ListTile(
                                  dense: true,
                                  visualDensity: VisualDensity.compact,
                                  mouseCursor: SystemMouseCursors.grab,
                                  title: Text(song.title),
                                  subtitle: Text(
                                    song.pages.join(' / '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            tooltip: '가사 수정',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => onEditSong(song),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 20,
                            ),
                            tooltip: '곡 삭제',
                            visualDensity: VisualDensity.compact,
                            color: cs.onSurfaceVariant,
                            onPressed: () => onDeleteSong(song),
                          ),
                        ],
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
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: value ? cs.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(
            color: value ? cs.secondaryContainer : cs.outlineVariant,
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

/// 고른 절 → 콘티에 담을 성경 항목들(페이지마다 하나). 성경 검색 탭 담기와 발표 보기 음성 검색이 같이 쓴다.
/// 보조·추가 역본 본문은 장(章)마다 한 번씩 통째로 읽어 절 번호로 붙인다.
Future<List<BibleStagingItem>> _bibleItemsFor({
  required BibleRepository repository,
  required String version,
  required List<BibleVerse> verses,
  required int perPage,
  required String subVersion,
  required String extraVersion,
}) async {
  final items = <BibleStagingItem>[];
  final subTextsByChapter = <(String, int), Map<int, String>?>{};
  final extraTextsByChapter = <(String, int), Map<int, String>?>{};
  for (final page in bibleVersePages(verses, perPage)) {
    final first = page.first;
    final key = (first.bookName, first.chapter);
    if (!subTextsByChapter.containsKey(key)) {
      subTextsByChapter[key] = await _loadOtherVersionVerses(
        repository,
        subVersion,
        version,
        first.bookName,
        first.chapter,
      );
      extraTextsByChapter[key] = extraVersion == subVersion
          ? null
          : await _loadOtherVersionVerses(
              repository,
              extraVersion,
              version,
              first.bookName,
              first.chapter,
            );
    }
    items.add(
      BibleStagingItem(
        reference: _buildReference(
          version,
          first.bookName,
          first.chapter,
          page.map((v) => v.verse).toList(),
        ),
        text: page.map((v) => '${v.verse}. ${v.text}').join('\n'),
        subText: versesText(page, subTextsByChapter[key]),
        extraText: versesText(page, extraTextsByChapter[key]),
      ),
    );
  }
  return items;
}

/// 다른 역본([sub], 보조·추가 역본)의 같은 장을 {절 번호: 본문} 으로.
/// 고르지 않았거나 본문과 같은 역본이거나 못 찾으면 null.
Future<Map<int, String>?> _loadOtherVersionVerses(
  BibleRepository repository,
  String sub,
  String version,
  String bookName,
  int chapter,
) async {
  if (sub.isEmpty || sub == version) return null;
  final book = await repository.mapBookName(
    bookName: bookName,
    fromVersion: version,
    inVersion: sub,
  );
  if (book == null) return null;
  final verses = await repository.getVerses(
    version: sub,
    bookName: book,
    chapter: chapter,
  );
  return {for (final v in verses) v.verse: v.text};
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

class _BibleSearchPanel extends StatefulWidget {
  const _BibleSearchPanel({
    required this.bibleRepository,
    required this.bibleVerseCount,
    required this.bibleDataRevision,
    required this.onAddItem,
    required this.subVersion,
    this.extraVersion = '',
  });

  final BibleRepository bibleRepository;
  final int bibleVerseCount;
  final int bibleDataRevision;
  final void Function(BibleStagingItem) onAddItem;

  /// 본문 아래 함께 담을 보조 역본. 빈 문자열이면 담지 않는다.
  final String subVersion;

  /// 보조 역본 아래 세 번째로 담을 추가 역본. 빈 문자열이면 담지 않는다.
  final String extraVersion;

  @override
  State<_BibleSearchPanel> createState() => _BibleSearchPanelState();
}

/// 성경 검색 방식: 책·장·절로 찾기 / 본문 낱말로 찾기.
enum _BibleSearchMode {
  reference('장절'),
  text('본문');

  const _BibleSearchMode(this.label);
  final String label;
}

class _BibleSearchPanelState extends State<_BibleSearchPanel>
    with AutomaticKeepAliveClientMixin {
  // 탭 전환 시 상태 유지
  @override
  bool get wantKeepAlive => true;

  // 본문 검색 결과는 앞에서부터 이만큼만 보여 준다 (흔한 낱말은 수천 절).
  static const _textResultLimit = 200;

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
  // 발표 보기 성경 음성 검색도 이 값으로 나눈다(패널은 하나뿐이라 static).
  static int _versesPerPage = 2;
  // 장절 검색 중 (본문 검색은 수십 ms 라 진행 표시 없이 옛 결과를 두었다가 바꾼다).
  bool _isSearching = false;
  // 고른 절을 콘티에 담는 중. 보조 역본을 장마다 읽느라 기다리는 사이 다시 눌러 두 번 담기지 않게.
  bool _isAddingVerses = false;
  bool _isSyncingBookController = false;
  Timer? _searchDebounce;

  _BibleSearchMode _mode = _BibleSearchMode.reference;
  final TextEditingController _textQueryController = TextEditingController();
  BibleSearchScope _scope = BibleSearchScope.all;
  String? _scopeBook;
  BibleSearchResult _textResult = BibleSearchResult.empty;
  List<String> _textTerms = const [];
  // 마지막으로 검색을 건 검색어. 커서만 움직이거나 조합 중인 값은 다시 찾지 않는다.
  String _queuedTextQuery = '';
  // 늦게 끝난 옛 검색이 새 결과·다른 화면을 덮지 않게. 올리면 진행 중인 본문 검색이 무효가 된다.
  int _textSearchSeq = 0;
  // 책 입력칸(Autocomplete)은 처음 만들 때만 글자를 받으므로, 밖에서 책을 바꾸면 새로 만든다.
  int _bookFieldRevision = 0;
  final ScrollController _verseScroll = ScrollController();
  final GlobalKey _focusVerseKey = GlobalKey();
  // '이 장 보기' 로 넘어왔을 때 보여 줄 절.
  int? _focusVerseId;

  bool get _isTextMode => _mode == _BibleSearchMode.text;

  /// 지금 목록에 보이는 절 (장절 결과 / 본문 결과).
  List<BibleVerse> get _shownVerses =>
      _isTextMode ? _textResult.verses : _verses;

  bool get _canSplitTestaments =>
      BibleSearchScope.canSplitTestaments(_bookNames);

  @override
  void initState() {
    super.initState();
    _chapterController.addListener(_onBibleInputChanged);
    _verseController.addListener(_onBibleInputChanged);
    _textQueryController.addListener(_onTextQueryChanged);
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
    _textQueryController.removeListener(_onTextQueryChanged);
    _textQueryController.dispose();
    _verseScroll.dispose();
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
        _fixScopeForBooks();
      });
      _setBookText(selectedBook ?? '');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
    if (_isTextMode) _searchText();
  }

  /// 역본이 바뀌어 지금 범위가 뜻이 없어졌으면 맞춘다 (setState 안에서 부른다).
  void _fixScopeForBooks() {
    if (_scopeBook != null && !_bookNames.contains(_scopeBook)) {
      _scopeBook = null;
    }
    final testament =
        _scope == BibleSearchScope.oldTestament ||
        _scope == BibleSearchScope.newTestament;
    if (testament && !_canSplitTestaments) _scope = BibleSearchScope.all;
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

  // onChanged 가 아니라 listener 다: 한글 조합이 끝날 때는 글자가 그대로라 onChanged 가 다시 안 불려서,
  // '사랑' 을 치고 멈추면 마지막 글자 '랑' 이 검색되지 않았다. listener 는 조합이 끝날 때도 불린다.
  void _onTextQueryChanged() {
    final value = _textQueryController.value;
    if (_isComposing(value) || value.text == _queuedTextQuery) return;
    _queuedTextQuery = value.text;
    setState(() {}); // 지우기 버튼 보이기/숨기기
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _searchText();
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

  /// 본문 검색. 검색어가 짧거나 범위의 책을 아직 안 골랐으면 결과를 비운다.
  Future<void> _searchText() async {
    final seq = ++_textSearchSeq;
    final version = _selectedVersion;
    final query = _textQueryController.text;
    final books = _scope.booksOf(_bookNames, book: _scopeBook);

    void clear() => setState(() {
      _textResult = BibleSearchResult.empty;
      _textTerms = const [];
      _selectedVerseIds.clear();
      _lastSelectedVerseIndex = null;
    });

    if (version == null ||
        !isSearchableBibleQuery(query) ||
        (books != null && books.isEmpty)) {
      clear();
      return;
    }

    // 수십 ms 라 진행 표시 없이 옛 결과를 두었다가 바꾼다 (칠 때마다 목록이 깜빡이지 않게).
    try {
      final result = await widget.bibleRepository.searchVerses(
        version: version,
        query: query,
        books: books,
        limit: _textResultLimit,
      );
      if (!mounted || seq != _textSearchSeq) return;
      setState(() {
        _textResult = result;
        _textTerms = bibleSearchTerms(query);
        _selectedVerseIds.clear();
        _lastSelectedVerseIndex = null;
      });
      if (_verseScroll.hasClients) _verseScroll.jumpTo(0);
    } catch (e) {
      if (!mounted || seq != _textSearchSeq) return;
      clear();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('검색 실패: $e')));
    }
  }

  void _setMode(_BibleSearchMode mode) {
    if (mode == _mode) return;
    _searchDebounce?.cancel();
    _textSearchSeq++;
    setState(() {
      _mode = mode;
      _selectedVerseIds.clear();
      _lastSelectedVerseIndex = null;
      _focusVerseId = null;
    });
    if (mode == _BibleSearchMode.text) _searchText();
  }

  void _setScope(BibleSearchScope scope) {
    if (scope == _scope) return;
    setState(() {
      _scope = scope;
      // 책 범위로 처음 바꿀 때는 장절 검색에서 보던 책부터.
      if (scope == BibleSearchScope.book) _scopeBook ??= _selectedBook;
    });
    _searchText();
  }

  /// 본문 결과 한 절의 장 전체를 장절 검색으로 열고 그 절을 골라 둔다 (앞뒤 문맥 보기).
  Future<void> _openChapter(BibleVerse verse) async {
    _searchDebounce?.cancel();
    _textSearchSeq++;
    _isSyncingBookController = true;
    _chapterController.text = '${verse.chapter}';
    _verseController.text = '';
    _isSyncingBookController = false;
    _setBookText(verse.bookName);
    setState(() {
      _mode = _BibleSearchMode.reference;
      _selectedBook = verse.bookName;
      _bookFieldRevision++;
    });
    await _search(showMessages: false);
    if (!mounted) return;
    final index = _verses.indexWhere((v) => v.id == verse.id);
    if (index < 0) return;
    setState(() {
      _selectedVerseIds.add(verse.id);
      _lastSelectedVerseIndex = index;
      _focusVerseId = verse.id;
    });
    _scrollToFocusedVerse();
  }

  // 목록은 줄을 모두 만들어 두므로(_buildVerseList) 그 절의 줄로 바로 맞출 수 있다.
  void _scrollToFocusedVerse() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _focusVerseKey.currentContext;
      if (target == null || !target.mounted) return;
      Scrollable.ensureVisible(target, alignment: 0.3);
    });
  }

  Future<void> _addSelected() async {
    if (_isAddingVerses) return;
    setState(() => _isAddingVerses = true);
    try {
      await _addSelectedVerses();
    } finally {
      if (mounted) setState(() => _isAddingVerses = false);
    }
  }

  Future<void> _addSelectedVerses() async {
    final version = _selectedVersion;
    if (_selectedVerseIds.isEmpty) return;
    if (version == null) return;
    final selected = _shownVerses
        .where((v) => _selectedVerseIds.contains(v.id))
        .toList();
    if (selected.isEmpty) return;

    // 본문 검색에서는 여러 책·장을 같이 고를 수 있다. 페이지는 한 장 안에서만 만든다.
    final items = await _bibleItemsFor(
      repository: widget.bibleRepository,
      version: version,
      verses: selected,
      perPage: _versesPerPage,
      subVersion: widget.subVersion,
      extraVersion: widget.extraVersion,
    );
    items.forEach(widget.onAddItem);
    if (!mounted) return;
    setState(() => _selectedVerseIds.clear());

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${items.length}페이지 추가됨')));
  }

  int get _selectedBiblePageCount {
    if (_selectedVerseIds.isEmpty) return 0;
    final selected = _shownVerses
        .where((v) => _selectedVerseIds.contains(v.id))
        .toList();
    return bibleVersePages(selected, _versesPerPage).length;
  }

  bool get _isShiftPressed {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
  }

  void _toggleVerseSelection(int index, bool isSelected) {
    final verses = _shownVerses;
    final lastIndex = _lastSelectedVerseIndex;
    final shouldSelectRange =
        isSelected && _isShiftPressed && lastIndex != null;

    setState(() {
      if (shouldSelectRange) {
        final start = lastIndex < index ? lastIndex : index;
        final end = lastIndex < index ? index : lastIndex;
        for (var i = start; i <= end; i++) {
          _selectedVerseIds.add(verses[i].id);
        }
      } else if (isSelected) {
        _selectedVerseIds.add(verses[index].id);
      } else {
        _selectedVerseIds.remove(verses[index].id);
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
      _textResult = BibleSearchResult.empty;
      _selectedVerseIds.clear();
      _lastSelectedVerseIndex = null;
    });
    _setBookText('');
    final books = await widget.bibleRepository.getBookNamesForVersion(version);
    if (!mounted) return;
    setState(() {
      _bookNames = books;
      _fixScopeForBooks();
    });
    if (_isTextMode) _searchText();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 필수

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_hasData) {
      final muted = Theme.of(context).colorScheme.onSurfaceVariant;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.menu_book_rounded,
              size: 36,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 10),
            Text(
              '성경 데이터가 없습니다\n위쪽 가져오기 메뉴에서 \'성경 불러오기\'를 고르세요',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, height: 1.5),
            ),
          ],
        ),
      );
    }

    final shown = _shownVerses;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _OptionSegments<_BibleSearchMode>(
                values: _BibleSearchMode.values,
                selected: _mode,
                labelOf: (mode) => mode.label,
                onSelected: _setMode,
              ),
              const Spacer(),
              if (_isTextMode && _textResult.totalCount > 0)
                Text(
                  _textResult.totalCount > _textResult.verses.length
                      ? '${_textResult.totalCount}절 중 ${_textResult.verses.length}절 표시'
                      : '${_textResult.totalCount}절',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_isTextMode) ...[
            _buildTextSearchRow(),
            const SizedBox(height: 8),
            _buildScopeRow(),
          ] else
            _buildReferenceSearchRow(),
          const SizedBox(height: 8),
          // 결과 목록
          Expanded(
            child: _isSearching && !_isTextMode
                ? const Center(child: CircularProgressIndicator())
                : shown.isEmpty
                ? Center(
                    child: Text(
                      _emptyMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : _buildVerseList(shown),
          ),
          // 추가 버튼
          if (shown.isNotEmpty) ...[
            if (_threeVersions && _versesPerPage > 1) ...[
              const SizedBox(height: 8),
              _buildThreeVersionsHint(),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('페이지당'),
                const SizedBox(width: 8),
                SizedBox(
                  width: 92,
                  child: DropdownButtonFormField<int>(
                    // '1절로 바꾸기' 로 밖에서 바꿀 때 다시 그리게.
                    key: ValueKey(_versesPerPage),
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
                    onPressed: _selectedVerseIds.isEmpty || _isAddingVerses
                        ? null
                        : _addSelected,
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

  /// 보조·추가 역본을 둘 다 담는가(한 페이지에 역본 세 개).
  bool get _threeVersions =>
      widget.subVersion.isNotEmpty &&
      widget.extraVersion.isNotEmpty &&
      widget.extraVersion != widget.subVersion;

  /// 역본 세 개를 한 페이지에 담으면 글이 많아 가사 상자를 넘기 쉽다 — 1절씩 권한다.
  Widget _buildThreeVersionsHint() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 16,
            color: cs.onTertiaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '역본 3개를 함께 담아 한 페이지에 글이 많습니다. 페이지당 1절을 권장합니다.',
              style: TextStyle(fontSize: 12, color: cs.onTertiaryContainer),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _versesPerPage = 1),
            child: const Text('1절로 바꾸기'),
          ),
        ],
      ),
    );
  }

  String get _emptyMessage {
    if (!_isTextMode) {
      return _selectedBook == null
          ? '성경과 장 번호를 입력해 주세요.'
          : '장 번호를 입력하면 절을 불러옵니다.';
    }
    if (_scope == BibleSearchScope.book && _scopeBook == null) {
      return '찾을 책을 골라 주세요.';
    }
    if (!isSearchableBibleQuery(_textQueryController.text)) {
      return '본문에서 찾을 말을 2글자 이상 입력해 주세요.\n띄어쓰기는 무시하고, 여러 낱말은 모두 들어간 절을 찾습니다.';
    }
    return '검색 결과가 없습니다.';
  }

  // 버전·검색·장·절 네 칸 높이를 같게: 세로 패딩을 통일하고 검색 아이콘이 높이를 키우지 않게 한다
  static const _inputPadding = EdgeInsets.symmetric(
    horizontal: 12,
    vertical: 14,
  );

  Widget _buildVersionDropdown() {
    return DropdownButtonFormField<String>(
      initialValue: _selectedVersion,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '버전',
        border: OutlineInputBorder(),
        contentPadding: _inputPadding,
      ),
      items: _versionNames
          .map((v) => DropdownMenuItem(value: v, child: Text(v)))
          .toList(),
      onChanged: _selectVersion,
    );
  }

  Widget _buildReferenceSearchRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(flex: 2, child: _buildVersionDropdown()),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: Autocomplete<String>(
            key: ValueKey('$_selectedVersion/$_bookFieldRevision'),
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
                      prefixIconConstraints: BoxConstraints(minWidth: 40),
                      contentPadding: _inputPadding,
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
        const SizedBox(width: 8),
        SizedBox(
          width: 96,
          child: TextField(
            controller: _chapterController,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            textAlignVertical: TextAlignVertical.center,
            decoration: const InputDecoration(
              labelText: '장',
              border: OutlineInputBorder(),
              contentPadding: _inputPadding,
            ),
            onSubmitted: (_) => _search(),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 96,
          child: TextField(
            controller: _verseController,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            textAlignVertical: TextAlignVertical.center,
            decoration: const InputDecoration(
              labelText: '절',
              border: OutlineInputBorder(),
              contentPadding: _inputPadding,
            ),
            onSubmitted: (_) => _search(),
          ),
        ),
      ],
    );
  }

  Widget _buildTextSearchRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(flex: 2, child: _buildVersionDropdown()),
        const SizedBox(width: 8),
        Expanded(
          flex: 5,
          child: TextField(
            controller: _textQueryController,
            textAlignVertical: TextAlignVertical.center,
            decoration: InputDecoration(
              labelText: '본문 검색',
              hintText: '예: 독생자 영생',
              prefixIcon: const Icon(Icons.search_rounded),
              prefixIconConstraints: const BoxConstraints(minWidth: 40),
              border: const OutlineInputBorder(),
              contentPadding: _inputPadding,
              suffixIcon: _textQueryController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
                      tooltip: '지우기',
                      onPressed: () {
                        _textQueryController.clear();
                        _searchDebounce?.cancel();
                        _searchText();
                      },
                    ),
            ),
            onSubmitted: (_) {
              _searchDebounce?.cancel();
              _searchText();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildScopeRow() {
    final scopes = [
      BibleSearchScope.all,
      if (_canSplitTestaments) ...[
        BibleSearchScope.oldTestament,
        BibleSearchScope.newTestament,
      ],
      BibleSearchScope.book,
    ];
    return Row(
      children: [
        Flexible(
          child: _OptionSegments<BibleSearchScope>(
            values: scopes,
            selected: _scope,
            labelOf: (scope) => scope.label,
            onSelected: _setScope,
          ),
        ),
        if (_scope == BibleSearchScope.book) ...[
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<String>(
              // initialValue 는 처음 만들 때만 읽으므로 역본이 바뀌면 새로 만든다.
              // 역본이 바뀌어 고른 책이 비워질 때도(_fixScopeForBooks) 새로 만들어야 옛 값이 안 남는다.
              key: ValueKey('scope-book/$_selectedVersion/$_scopeBook'),
              initialValue: _scopeBook,
              isExpanded: true,
              isDense: true,
              hint: const Text('책 선택'),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
              items: _bookNames
                  .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                  .toList(),
              onChanged: (book) {
                if (book == null || book == _scopeBook) return;
                setState(() => _scopeBook = book);
                _searchText();
              },
            ),
          ),
        ],
      ],
    );
  }

  /// 절 목록. ListView 처럼 보이는 줄만 만들지 않고 모두 만든다 — 그래야 '이 장 보기' 가 줄 높이를
  /// 어림하지 않고 그 절로 정확히 스크롤한다(감긴 줄이 많은 긴 장에서 어림이 크게 빗나갔다).
  /// 한 장은 많아야 176절(시 119편), 본문 결과는 200절까지라 다 만들어도 가볍다.
  Widget _buildVerseList(List<BibleVerse> verses) {
    return SingleChildScrollView(
      controller: _verseScroll,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < verses.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _buildVerseTile(verses[i], i),
          ],
        ],
      ),
    );
  }

  Widget _buildVerseTile(BibleVerse v, int index) {
    final cs = Theme.of(context).colorScheme;
    final labelStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: cs.primary,
    );
    const bodyStyle = TextStyle(fontSize: 13);
    return CheckboxListTile(
      key: v.id == _focusVerseId ? _focusVerseKey : null,
      value: _selectedVerseIds.contains(v.id),
      onChanged: (val) => _toggleVerseSelection(index, val ?? false),
      controlAffinity: ListTileControlAffinity.leading,
      title: RichText(
        text: TextSpan(
          style: DefaultTextStyle.of(context).style,
          children: [
            TextSpan(
              text: _isTextMode
                  ? '${v.bookName} ${v.chapter}:${v.verse}  '
                  : '${v.verse}절  ',
              style: labelStyle,
            ),
            if (_isTextMode)
              ..._highlightedSpans(v.text, bodyStyle, cs)
            else
              TextSpan(text: v.text, style: bodyStyle),
          ],
        ),
      ),
      secondary: _isTextMode
          ? IconButton(
              icon: const Icon(Icons.menu_book_outlined, size: 18),
              tooltip: '이 장 보기',
              visualDensity: VisualDensity.compact,
              onPressed: () => _openChapter(v),
            )
          : null,
      contentPadding: EdgeInsets.zero,
      dense: true,
    );
  }

  /// 찾은 말을 굵게·강조색으로.
  List<TextSpan> _highlightedSpans(
    String text,
    TextStyle style,
    ColorScheme cs,
  ) {
    final highlight = style.copyWith(
      fontWeight: FontWeight.w700,
      color: cs.primary,
      backgroundColor: cs.primaryContainer,
    );
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final (start, end) in bibleMatchRanges(text, _textTerms)) {
      if (start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, start), style: style));
      }
      spans.add(TextSpan(text: text.substring(start, end), style: highlight));
      cursor = end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor), style: style));
    }
    return spans;
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
    required this.offeringDesign,
    required this.onEditOffering,
    required this.imageLibrary,
    required this.videoLibrary,
    required this.onResetTextLayout,
  });

  final ExportStyle style;
  final List<Color> swatches;
  final List<Color> textSwatches;

  /// 모든 글꼴·글자 크기·위치를 기본값으로(확인을 받는다).
  final VoidCallback onResetTextLayout;

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

  /// 등록된 헌금송 디자인(계좌 등). '공통' 탭의 헌금송 묶음에서 연다.
  final OfferingDesign offeringDesign;
  final VoidCallback onEditOffering;

  /// 공통 배경 이미지 모음. '공통' 탭의 전체 배경 이미지를 여기서 고른다.
  final BackgroundImageLibrary imageLibrary;

  /// 공통 배경 영상 모음. '공통' 탭에서 등록하고 동영상 페이지에서 고른다.
  final BackgroundImageLibrary videoLibrary;

  @override
  State<_DesignRibbon> createState() => _DesignRibbonState();
}

class _DesignRibbonState extends State<_DesignRibbon> {
  // 3줄 + 줄 사이 + 묶음 이름. 리본 내용 높이가 이 값으로 고정된다.
  static const double _contentHeight = 118;
  static const double _columnWidth = 236;
  // 색 칸 셋(원본·보조·추가)이 한 줄에 들어가는 열. 칸마다 이름이 잘리지 않게 넓힌다.
  static const double _threeColorColumnWidth = 280;
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
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(cs),
            if (!widget.isCollapsed) ...[
              Divider(height: 1, color: cs.outlineVariant),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
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
          const SizedBox(width: 14),
          Icon(Icons.palette_outlined, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          const Text(
            '디자인',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 14),
          for (final tab in _RibbonTab.values)
            _RibbonTabButton(
              tab: tab,
              isSelected: !widget.isCollapsed && tab == _tab,
              onTap: () => _selectTab(tab),
            ),
          const Spacer(),
          TextButton.icon(
            onPressed: widget.onResetTextLayout,
            icon: const Icon(Icons.restart_alt_rounded, size: 16),
            label: const Text('글자 크기·위치 기본값'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: cs.onSurfaceVariant,
              textStyle: const TextStyle(fontSize: 12),
            ),
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
        label: '미디어 페이드 (PPT 동영상 · 새 미디어 페이지)',
        columns: [
          _column([
            _PropertyRow(
              label: '페이드 인',
              child: _ValueSlider(
                value: _style.mediaFadeIn,
                min: 0,
                max: SlideMedia.maxFade,
                divisions: (SlideMedia.maxFade * 2).round(),
                digits: 1,
                onChanged: (v) => _update(_style.copyWith(mediaFadeIn: v)),
              ),
            ),
            _PropertyRow(
              label: '페이드 아웃',
              child: _ValueSlider(
                value: _style.mediaFadeOut,
                min: 0,
                max: SlideMedia.maxFade,
                divisions: (SlideMedia.maxFade * 2).round(),
                digits: 1,
                onChanged: (v) => _update(_style.copyWith(mediaFadeOut: v)),
              ),
            ),
            _PropertyRow(
              label: '배경 영상',
              child: _BackgroundVideoButton(library: widget.videoLibrary),
            ),
          ], width: 240),
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
                      caption: '원본',
                      dialogTitle: '원본 가사 색상',
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
                  const SizedBox(width: 6),
                  Expanded(child: _extraColorField()),
                ],
              ),
            ),
            _PropertyRow(
              label: '보조 언어',
              child: _subLanguageSwitchRow(
                _DenseDropdown(
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
            ),
          ], width: _threeColorColumnWidth),
          _column([
            _PropertyRow(
              label: '추가 보조',
              child: _extraSwitchRow(
                _DenseDropdown(
                  // 보조 언어를 바꾸면 고를 수 있는 목록이 달라지므로 새로 만든다.
                  key: ValueKey(
                    'extra:${_style.subLanguage}:${_style.extraLanguage}',
                  ),
                  value:
                      widget.subLanguages.contains(_style.extraLanguage) &&
                          _style.extraLanguage != _style.subLanguage
                      ? _style.extraLanguage
                      : '',
                  items: [
                    for (final language in widget.subLanguages)
                      if (language != _style.subLanguage) language,
                  ],
                  noneLabel: '없음',
                  onChanged: (language) =>
                      _update(_style.copyWith(extraLanguage: language ?? '')),
                ),
              ),
            ),
            _ratioRow(
              '보조 크기',
              _style.subFontRatio,
              (v) => _style.copyWith(subFontRatio: v),
            ),
            _ratioRow(
              '추가 크기',
              _style.extraFontRatio,
              (v) => _style.copyWith(extraFontRatio: v),
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
              label: '색상',
              child: Row(
                children: [
                  Expanded(
                    child: _ColorField(
                      caption: '본문',
                      dialogTitle: '본문 색상',
                      color: _style.bibleTextColor,
                      colors: widget.textSwatches,
                      onSelected: (c) =>
                          _update(_style.copyWith(bibleTextColor: c)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // 보조·추가 색은 찬양과 같은 값이다(렌더러가 한 키로 읽는다).
                  Expanded(
                    child: _ColorField(
                      caption: '보조',
                      dialogTitle: '보조 역본 색상 (찬양과 공통)',
                      color: _style.englishTextColor,
                      colors: widget.textSwatches,
                      onSelected: (c) =>
                          _update(_style.copyWith(englishTextColor: c)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(child: _extraColorField()),
                ],
              ),
            ),
            _PropertyRow(
              label: '보조 역본',
              child: widget.bibleVersions.isEmpty
                  ? const _HintText('성경을 먼저 가져와 주세요.')
                  : _subLanguageSwitchRow(
                      _DenseDropdown(
                        value:
                            widget.bibleVersions.contains(
                              _style.bibleSubVersion,
                            )
                            ? _style.bibleSubVersion
                            : '',
                        items: widget.bibleVersions,
                        noneLabel: '표시 안 함',
                        onChanged: (version) => _update(
                          _style.copyWith(bibleSubVersion: version ?? ''),
                        ),
                      ),
                    ),
            ),
          ], width: _threeColorColumnWidth),
          _column([
            _PropertyRow(
              label: '추가 역본',
              child: widget.bibleVersions.isEmpty
                  ? const _HintText('성경을 먼저 가져와 주세요.')
                  : _extraSwitchRow(
                      _DenseDropdown(
                        key: ValueKey(
                          'bible-extra:${_style.bibleSubVersion}:'
                          '${_style.bibleExtraVersion}',
                        ),
                        value:
                            widget.bibleVersions.contains(
                                  _style.bibleExtraVersion,
                                ) &&
                                _style.bibleExtraVersion !=
                                    _style.bibleSubVersion
                            ? _style.bibleExtraVersion
                            : '',
                        items: [
                          for (final version in widget.bibleVersions)
                            if (version != _style.bibleSubVersion) version,
                        ],
                        noneLabel: '표시 안 함',
                        onChanged: (version) => _update(
                          _style.copyWith(bibleExtraVersion: version ?? ''),
                        ),
                      ),
                    ),
            ),
            _ratioRow(
              '보조 크기',
              _style.bibleSubFontRatio,
              (v) => _style.copyWith(bibleSubFontRatio: v),
            ),
            _ratioRow(
              '추가 크기',
              _style.bibleExtraFontRatio,
              (v) => _style.copyWith(bibleExtraFontRatio: v),
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

  /// 리본 한 줄 높이에 맞춘 작은 스위치.
  Widget _compactSwitch(bool value, ValueChanged<bool> onChanged) {
    return FittedBox(
      child: Switch(
        value: value,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onChanged: onChanged,
      ),
    );
  }

  /// 보조 언어(가사 아래 둘째 줄) 표시 스위치 + 언어/역본 선택.
  /// 렌더러 네 곳이 읽는 `include_english_lyrics` 하나라 찬양·성경 탭이 같은 값을 쓴다.
  /// 끄면 담아 둔 보조 가사는 그대로 두고 화면·PPTX 에서만 숨긴다(다시 켜면 바로 돌아온다).
  Widget _subLanguageSwitchRow(Widget selector) {
    final on = _style.includeEnglishLyrics;
    return Row(
      children: [
        Tooltip(
          message: on ? '보조 언어 끄기' : '보조 언어 켜기',
          child: SizedBox(
            height: 26,
            child: _compactSwitch(
              on,
              (v) => _update(_style.copyWith(includeEnglishLyrics: v)),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: IgnorePointer(
            ignoring: !on,
            child: Opacity(opacity: on ? 1 : 0.38, child: selector),
          ),
        ),
      ],
    );
  }

  /// 추가 보조(셋째 줄) 표시 스위치 + 언어/역본 선택. `include_extra_lyrics` 하나라
  /// 찬양·성경 탭이 같은 값을 쓴다([_subLanguageSwitchRow] 와 같은 방식).
  Widget _extraSwitchRow(Widget selector) {
    final on = _style.includeExtraLyrics;
    return Row(
      children: [
        Tooltip(
          message: on ? '추가 보조 끄기' : '추가 보조 켜기',
          child: SizedBox(
            height: 26,
            child: _compactSwitch(
              on,
              (v) => _update(_style.copyWith(includeExtraLyrics: v)),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: IgnorePointer(
            ignoring: !on,
            child: Opacity(opacity: on ? 1 : 0.38, child: selector),
          ),
        ),
      ],
    );
  }

  /// 추가 보조 색(찬양·성경 공통).
  Widget _extraColorField() {
    return _ColorField(
      caption: '추가',
      dialogTitle: '추가 보조 색상 (찬양·성경 공통)',
      color: _style.extraTextColor,
      colors: widget.textSwatches,
      onSelected: (c) => _update(_style.copyWith(extraTextColor: c)),
    );
  }

  /// 보조·추가 보조 글자 크기(본문 대비 %). 본문 크기를 바꾸면 같이 따라간다.
  Widget _ratioRow(
    String label,
    double ratio,
    ExportStyle Function(double ratio) apply,
  ) {
    return _PropertyRow(
      label: '$label %',
      child: _ValueSlider(
        value: ratio * 100,
        min: 40,
        max: 120,
        divisions: 16,
        onChanged: (v) => _update(apply(v / 100)),
      ),
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
                child: _compactSwitch(visible, onVisible),
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
    final color = isSelected ? cs.onSurface : cs.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isSelected ? cs.secondary : Colors.transparent,
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

/// 리본의 한 묶음: 왼쪽 위 묶음 이름 + 설정 열들.
class _RibbonGroup extends StatelessWidget {
  const _RibbonGroup({required this.label, required this.columns});

  final String label;
  final List<Widget> columns;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
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
                fontSize: 12,
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
    final radius = BorderRadius.circular(AppRadius.control);
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
              borderRadius: BorderRadius.circular(AppRadius.control),
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
                fontSize: 12,
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
    this.digits = 0,
  });

  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final int digits;

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
        _ValueBadge(text: value.toStringAsFixed(digits)),
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
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.control),
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
            Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12),
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
    super.key,
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
      ).textTheme.bodyMedium?.copyWith(fontSize: 12, color: cs.onSurface),
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
          borderRadius: BorderRadius.circular(AppRadius.control),
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
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
    final String sampleExtraText;
    final String? titleText;
    final bool isBible;
    String? imagePath;

    switch (previewItem) {
      case ImageStagingItem(:final imagePaths):
        sampleText = '';
        sampleEnglishText = '';
        sampleExtraText = '';
        titleText = null;
        isBible = false;
        imagePath = imagePaths.isEmpty ? null : imagePaths.first;
      case SongStagingItem(:final song):
        final first = song.pairedPages.firstOrNull;
        sampleText = first?.korean ?? song.displayTitle;
        sampleEnglishText = first?.english ?? '';
        sampleExtraText = first?.extra ?? '';
        titleText = song.displayTitle;
        isBible = false;
      case BibleStagingItem(
        :final text,
        :final reference,
        :final subText,
        :final extraText,
      ):
        sampleText = text;
        sampleEnglishText = subText;
        sampleExtraText = extraText;
        titleText = reference;
        isBible = true;
      case BlankStagingItem(
        :final mainText,
        :final englishText,
        :final extraText,
      ):
        sampleText = mainText;
        sampleEnglishText = englishText;
        sampleExtraText = extraText;
        titleText = null;
        isBible = false;
      case null:
        sampleText = '선택한 항목이 여기에 미리보기로 보입니다.';
        sampleEnglishText = '';
        sampleExtraText = '';
        titleText = null;
        isBible = false;
    }

    return AspectRatio(
      aspectRatio: 13.333 / 7.5,
      // 테두리: 어두운 테마에서 검은 슬라이드가 패널에 묻히지 않게.
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.control),
          child: SlideRenderView(
            data: SlidePageData(
              mainText: sampleText,
              englishText: sampleEnglishText,
              extraText: sampleExtraText,
              title: titleText,
              isBible: isBible,
              pageIndex: 0,
              totalPages: 1,
              style: style,
              imagePath: imagePath,
            ),
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
        borderRadius: BorderRadius.circular(AppRadius.control),
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

/// 원본을 다시 구워 PPT 항목 [uid] 의 장 수가 [oldCount] → [newCount] 로 바뀔 때
/// 지운 페이지 표시(`uid:페이지`)와 메모를 맞춘다. 지운 페이지 표시가 풀렸으면 true.
///
/// 장 수가 같으면 페이지가 그대로 대응한다고 보고 아무것도 안 건드린다. 다르면 어느 페이지가
/// 어디로 갔는지 알 수 없으므로 지운 표시는 풀고, 메모는 남는 범위 안의 것만 둔다.
/// 자동 여백은 항목 끝(`uid:장수`)에 붙으므로 그 표시·메모는 새 끝으로 옮긴다 —
/// 안 옮기면 장 수가 늘 때 여백 메모가 실제 페이지에 붙는다.
@visibleForTesting
bool remapReloadedPages({
  required int uid,
  required int oldCount,
  required int newCount,
  required Set<String> deletedKeys,
  required Map<String, String> notes,
}) {
  if (oldCount == newCount) return false;
  String key(int page) => '$uid:$page';

  var restored = false;
  for (var j = 0; j < oldCount; j++) {
    if (deletedKeys.remove(key(j))) restored = true;
  }
  if (deletedKeys.remove(key(oldCount))) deletedKeys.add(key(newCount));

  final spacerNote = notes.remove(key(oldCount));
  for (var j = newCount; j < oldCount; j++) {
    notes.remove(key(j));
  }
  if (spacerNote != null) notes[key(newCount)] = spacerNote;
  return restored;
}

/// 번역 때문에 곡 [uid] 의 장 수가 [oldCount] → [newCount] 로 바뀔 때. 번역은 끝에만 붙거나 빠지므로
/// 앞 페이지 번호는 그대로다 — 지운 표시·메모는 두고([remapReloadedPages] 와 달리 풀지 않는다),
/// 자동 여백(`uid:장수`) 것만 새 끝으로 옮기고 줄어든 범위 밖 것은 버린다.
@visibleForTesting
void remapTrailingPages({
  required int uid,
  required int oldCount,
  required int newCount,
  required Set<String> deletedKeys,
  required Map<String, String> notes,
}) {
  if (oldCount == newCount) return;
  String key(int page) => '$uid:$page';
  final spacerDeleted = deletedKeys.remove(key(oldCount));
  final spacerNote = notes.remove(key(oldCount));
  for (var j = newCount; j < oldCount; j++) {
    deletedKeys.remove(key(j));
    notes.remove(key(j));
  }
  if (spacerDeleted) deletedKeys.add(key(newCount));
  if (spacerNote != null) notes[key(newCount)] = spacerNote;
}

/// [item] 의 [pages](원래 페이지 번호, 오름차순)만 담은 항목들. 나누기·복사·옮기기가 같이 쓴다.
/// 곡 끝의 빈 페이지는 가사로 담으면 사라지므로 빈 페이지 항목으로 뗀다(가사가 하나도 없으면
/// 전부 빈 페이지 항목). [from] 은 각 항목에 들어간 원래 페이지 번호.
/// 페이지 전부면 원래 항목을 그대로 돌려준다(PPT 원본 경로가 남게). 원본의 일부만 담은 PPT 는
/// 다시 구우면 전 페이지가 들어오므로 원본 경로를 뺀다.
@visibleForTesting
List<({StagingItem item, List<int> from})> itemsFromPages(
  StagingItem item,
  List<int> pages,
) {
  if (pages.isEmpty) return const [];
  if (pages.length == _PraiseHomePageState._pageCount(item)) {
    return [(item: item, from: pages)];
  }
  switch (item) {
    case SongStagingItem(:final song):
      final all = song.pairedPages;
      bool isEmpty(int j) => all[j].isEmptyPage;
      var end = pages.length;
      while (end > 0 && isEmpty(pages[end - 1])) {
        end--;
      }
      return [
        if (end > 0)
          (
            item: SongStagingItem(
              _PraiseHomePageState._songWithPages(song, [
                for (final j in pages.take(end)) all[j],
              ]),
            ),
            from: pages.sublist(0, end),
          ),
        for (final j in pages.skip(end))
          (item: const BlankStagingItem(), from: [j]),
      ];
    case ImageStagingItem(:final sourceName, :final imagePaths):
      return [
        (
          item: ImageStagingItem(
            sourceName: sourceName,
            imagePaths: [for (final j in pages) imagePaths[j]],
          ),
          from: pages,
        ),
      ];
    default:
      return [(item: item, from: pages)];
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
    // 넘친 비율(관객 화면 기준). 안 넘치면 null.
    final ratio = SlideTextLayout.cachedOverflowRatio(widget.data);
    final overflow = ratio > SlideTextLayout.overflowThreshold ? ratio : null;

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
                  // 선택: 진한 테두리 + 안쪽 바탕색 틈. 슬라이드가 어두워도
                  // 테두리가 슬라이드에 묻히지 않게 틈을 둔다.
                  Container(
                    padding: EdgeInsets.all(widget.isSelected ? 2 : 0),
                    decoration: BoxDecoration(
                      color: widget.isSelected ? cs.surface : null,
                      borderRadius: BorderRadius.circular(AppRadius.control),
                      border: Border.all(
                        color: widget.isSelected
                            ? cs.primary
                            : cs.outlineVariant,
                        width: widget.isSelected ? 3.5 : 1,
                      ),
                      boxShadow: widget.isSelected
                          ? [
                              BoxShadow(
                                color: cs.primary.withValues(alpha: 0.5),
                                blurRadius: 10,
                                spreadRadius: 2,
                              ),
                            ]
                          : null,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.control),
                      child: AspectRatio(
                        aspectRatio: _aspectRatio,
                        child: SlideRenderView(data: widget.data),
                      ),
                    ),
                  ),
                  if (overflow != null) ...[
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: cs.error, width: 2),
                            borderRadius: BorderRadius.circular(
                              AppRadius.control,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 4,
                      right: 4,
                      child: Tooltip(
                        message:
                            '관객 화면에서 가사가 상자를 넘습니다 '
                            '(${SlideTextLayout.overflowLabel(overflow)})',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: cs.error,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '넘침',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: cs.onError,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
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
                                borderRadius: BorderRadius.circular(
                                  AppRadius.control,
                                ),
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
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.control,
                                  ),
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
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: widget.isSelected
                  ? BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(8),
                    )
                  : null,
              child: Text(
                '${widget.index + 1}',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.3,
                  color: widget.isSelected ? cs.onPrimary : cs.onSurfaceVariant,
                  fontWeight: widget.isSelected
                      ? FontWeight.w700
                      : FontWeight.normal,
                ),
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
    this.extraText = '',
    required this.isBible,
    this.title,
    this.heading = '슬라이드 수정',
    this.helper,
    this.subLabel,
    this.extraLabel,
    this.mainMaxLines = 7,
  });

  final String mainText;
  final String englishText;

  /// 추가 보조 줄(관객 화면 셋째 줄).
  final String extraText;
  final bool isBible;
  final String? title;
  final String heading;
  final String? helper;
  // 보조 칸 라벨. 콘티 임시 수정은 어느 언어 칸인지 이름으로 알려 준다.
  final String? subLabel;
  final String? extraLabel;
  final int mainMaxLines;

  @override
  State<_SlideQuickEditDialog> createState() => _SlideQuickEditDialogState();
}

class _SlideQuickEditDialogState extends State<_SlideQuickEditDialog> {
  late final TextEditingController _mainCtrl;
  late final TextEditingController _englishCtrl;
  late final TextEditingController _extraCtrl;

  @override
  void initState() {
    super.initState();
    // 커서를 맨 앞에 둔다. 선택이 없으면 데스크탑은 포커스 때 끝으로 보내서
    // 긴 가사가 마지막 줄까지 스크롤된 채로 열린다.
    _mainCtrl = TextEditingController.fromValue(
      TextEditingValue(
        text: widget.mainText,
        selection: const TextSelection.collapsed(offset: 0),
      ),
    );
    _englishCtrl = TextEditingController.fromValue(
      TextEditingValue(
        text: widget.englishText,
        selection: const TextSelection.collapsed(offset: 0),
      ),
    );
    _extraCtrl = TextEditingController.fromValue(
      TextEditingValue(
        text: widget.extraText,
        selection: const TextSelection.collapsed(offset: 0),
      ),
    );
  }

  @override
  void dispose() {
    _mainCtrl.dispose();
    _englishCtrl.dispose();
    _extraCtrl.dispose();
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
              const SizedBox(height: 12),
              TextField(
                controller: _extraCtrl,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText:
                      widget.extraLabel ??
                      (widget.isBible ? '추가 역본 본문 (선택)' : '추가 보조 가사 (선택)'),
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
          onPressed: () => Navigator.pop(context, (
            _mainCtrl.text,
            _englishCtrl.text,
            _extraCtrl.text,
          )),
          child: const Text('적용'),
        ),
      ],
    );
  }
}

// ── ContiListDialog ───────────────────────────────────────────────────────

class _ContiListDialog extends StatefulWidget {
  const _ContiListDialog({
    required this.contis,
    required this.onDelete,
    required this.onExport,
    required this.onImport,
    this.onUploadToCloud,
    this.onOpenCloud,
    this.onCancelCloud,
  });

  final List<WorshipConti> contis;
  final Future<void> Function(WorshipConti) onDelete;
  final Future<void> Function(WorshipConti) onExport;
  final Future<List<WorshipConti>?> Function() onImport;

  /// 동기화 접속 키를 넣었을 때만 — 콘티를 클라우드에 올리기 / 클라우드 콘티 목록 열기.
  final Future<void> Function(WorshipConti)? onUploadToCloud;
  final VoidCallback? onOpenCloud;

  /// 올리는 중인 것을 끊는다(오래 걸리면 손으로).
  final VoidCallback? onCancelCloud;

  @override
  State<_ContiListDialog> createState() => _ContiListDialogState();
}

class _ContiListDialogState extends State<_ContiListDialog> {
  late final List<WorshipConti> _contis;

  /// 올리는 중(버튼을 막는다 — 오래 걸려서 여러 번 누르기 쉽다)·이번에 올린 콘티 id.
  final _uploading = <int>{};
  final _uploaded = <int>{};

  Future<void> _upload(WorshipConti conti) async {
    setState(() => _uploading.add(conti.id));
    try {
      await widget.onUploadToCloud!(conti);
      if (mounted) setState(() => _uploaded.add(conti.id));
    } catch (error) {
      if (!mounted || isCancelled(error)) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('클라우드에 올리지 못했습니다'),
          content: Text(
            error is FileSystemException ? error.message : '$error',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('확인'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _uploading.remove(conti.id));
    }
  }

  @override
  void initState() {
    super.initState();
    _contis = List.of(widget.contis);
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

  Future<void> _import() async {
    final contis = await widget.onImport();
    if (contis == null || !mounted) return;
    setState(
      () => _contis
        ..clear()
        ..addAll(contis),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('예배 콘티 불러오기'),
      contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
      content: SizedBox(
        width: 420,
        child: _contis.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '저장된 콘티가 없습니다',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
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
                      '${formatContiDate(conti.createdAt)}  ·  ${conti.itemCount}개',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.onUploadToCloud != null)
                          IconButton(
                            icon: _uploading.contains(conti.id)
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    _uploaded.contains(conti.id)
                                        ? Icons.cloud_done_rounded
                                        : Icons.cloud_upload_outlined,
                                    size: 20,
                                  ),
                            tooltip: _uploading.contains(conti.id)
                                ? '올리는 중 — 누르면 취소'
                                : _uploaded.contains(conti.id)
                                ? '클라우드에 올렸습니다(다시 누르면 덮어쓰기)'
                                : '클라우드에 올리기',
                            onPressed: _uploading.contains(conti.id)
                                ? widget.onCancelCloud
                                : () => _upload(conti),
                          ),
                        IconButton(
                          icon: const Icon(Icons.ios_share_rounded, size: 20),
                          tooltip: '파일로 내보내기 (다른 PC 로 옮기기)',
                          onPressed: () => widget.onExport(conti),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 20,
                          ),
                          tooltip: '삭제',
                          color: Colors.red.shade300,
                          onPressed: () => _delete(conti),
                        ),
                      ],
                    ),
                    onTap: () => Navigator.of(context).pop(conti),
                  );
                },
              ),
      ),
      actions: [
        if (widget.onOpenCloud != null)
          TextButton.icon(
            onPressed: () {
              // 받은 콘티가 목록에 보이도록 이 창은 닫고 클라우드 창을 연다.
              Navigator.of(context).pop();
              widget.onOpenCloud!();
            },
            icon: const Icon(Icons.cloud_download_outlined, size: 18),
            label: const Text('클라우드에서 내려받기'),
          ),
        TextButton.icon(
          onPressed: _import,
          icon: const Icon(Icons.file_open_outlined, size: 18),
          label: const Text('파일에서 가져오기'),
        ),
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
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(AppRadius.control),
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
                fontSize: 12,
                color: hasImage ? cs.onSurface : cs.onSurfaceVariant,
                fontWeight: hasImage ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          if (hasImage)
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.control),
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

/// 리본 '공통' 탭의 배경 영상 모음 관리. 등록해 둔 영상은 동영상 페이지에서 바로 고른다.
class _BackgroundVideoButton extends StatelessWidget {
  const _BackgroundVideoButton({required this.library});

  final BackgroundImageLibrary library;

  Future<void> _open(BuildContext context) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('배경 영상 모음'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '여기 등록한 영상은 콘티의 \'새 페이지 추가 → 동영상\'에서 바로 고를 수 있습니다.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              BackgroundImageGallery(
                library: library,
                selected: null,
                showNone: false,
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('닫기'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _FieldBox(
      onTap: () => _open(context),
      child: Row(
        children: [
          Icon(Icons.movie_outlined, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            '등록 / 관리',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
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
                  fontSize: 12,
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
        borderRadius: BorderRadius.circular(AppRadius.control),
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
/// 편집 탭·발표 보기 '새 페이지 추가' 메뉴에서 고르는 페이지 종류.
enum _AddPageKind {
  blank,
  sermon,
  video,
  audio,
  youtube;

  MediaKind? get media => switch (this) {
    video => MediaKind.video,
    audio => MediaKind.audio,
    youtube => MediaKind.youtube,
    _ => null,
  };
}

const List<PopupMenuEntry<_AddPageKind>> _addPageMenuItems = [
  PopupMenuItem(
    value: _AddPageKind.blank,
    child: ListTile(
      leading: Icon(Icons.crop_landscape_outlined),
      title: Text('빈 페이지'),
      subtitle: Text('찬양 디자인을 따라갑니다'),
      dense: true,
    ),
  ),
  PopupMenuItem(
    value: _AddPageKind.sermon,
    child: ListTile(
      leading: Icon(Icons.title_rounded),
      title: Text('설교 제목 페이지'),
      subtitle: Text('글꼴·배경·색·크기를 따로 정합니다'),
      dense: true,
    ),
  ),
  PopupMenuDivider(),
  PopupMenuItem(
    value: _AddPageKind.video,
    child: ListTile(
      leading: Icon(Icons.movie_outlined),
      title: Text('동영상 페이지'),
      subtitle: Text('동영상 파일을 화면 가득 재생합니다'),
      dense: true,
    ),
  ),
  PopupMenuItem(
    value: _AddPageKind.audio,
    child: ListTile(
      leading: Icon(Icons.music_note_outlined),
      title: Text('음악 페이지'),
      subtitle: Text('음악을 틀고 화면엔 문구·배경을 띄웁니다'),
      dense: true,
    ),
  ),
  PopupMenuItem(
    value: _AddPageKind.youtube,
    child: ListTile(
      leading: Icon(Icons.smart_display_outlined),
      title: Text('유튜브 페이지'),
      subtitle: Text('유튜브 영상을 화면 가득 재생합니다 (인터넷 필요)'),
      dense: true,
    ),
  ),
];

/// design == null: 설교 디자인을 떼고 일반 빈 페이지로 되돌린다(고칠 때만).
typedef _SermonPageResult = ({
  String title,
  String subtitle,
  SlideBackground? design,
});

/// 설교 제목 페이지 만들기/고치기. 찬양 디자인과 따로 글꼴·위치·배경과
/// 주제·부제(본문 말씀 등) 각각의 크기·색을 정한다. 부제는 렌더러의 보조 줄 자리에 들어간다.
/// 고른 디자인은 다음 설교 페이지의 시작값으로 남는다(sermon_design.json).
class _SermonPageDialog extends StatefulWidget {
  const _SermonPageDialog({
    required this.initialTitle,
    required this.initialSubtitle,
    this.extraText = '',
    required this.initialDesign,
    required this.canRevert,
    required this.globalStyle,
    required this.swatches,
    required this.imageLibrary,
  });

  final String initialTitle;
  final String initialSubtitle;

  /// 페이지에 이미 든 추가 보조 줄. 이 창에서 고치지는 않고 미리보기에만 그린다.
  final String extraText;
  final SlideBackground initialDesign;
  final bool canRevert;
  final ExportStyle globalStyle;
  final List<Color> swatches;
  final BackgroundImageLibrary imageLibrary;

  @override
  State<_SermonPageDialog> createState() => _SermonPageDialogState();
}

class _SermonPageDialogState extends State<_SermonPageDialog> {
  late final TextEditingController _titleController = TextEditingController(
    text: widget.initialTitle,
  );
  late final TextEditingController _subtitleController = TextEditingController(
    text: widget.initialSubtitle,
  );
  late SlideBackground _design = widget.initialDesign;

  // 입력칸은 글자를 칠 때 다시 그리지 않는다 — 미리보기·적용 버튼만 이 리스너로 갱신한다.
  // 칠 때마다 다이얼로그를 통째로 다시 그리던 때 macOS 에서 한글이 자음·모음으로 갈라졌다.
  late final Listenable _texts = Listenable.merge([
    _titleController,
    _subtitleController,
  ]);

  String get _titleNow => _titleController.text.trim();
  String get _subtitleNow => _subtitleController.text.trim();

  @override
  void dispose() {
    _titleController.dispose();
    _subtitleController.dispose();
    super.dispose();
  }

  ExportStyle get _style => widget.globalStyle.withBackground(_design);

  /// 글꼴·크기·색·위치를 처음 값(SlideBackground.sermonDefault)으로. 배경은 그대로 둔다.
  void _resetText() => setState(
    () => _design = _design.withSermonDefaultText(widget.globalStyle),
  );

  Future<Color?> _pickColor(String title, Color initial) => showDialog<Color>(
    context: context,
    builder: (ctx) => _HexColorDialog(
      title: title,
      initialColor: initial,
      colors: widget.swatches,
      inputFormatter: _hexInputFormatter,
    ),
  );

  Widget _colorRow(String label, Color color, ValueChanged<Color> onPicked) {
    final cs = Theme.of(context).colorScheme;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
      onPressed: () async {
        final picked = await _pickColor(label, color);
        if (picked != null && mounted) onPicked(picked);
      },
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: cs.onSurface)),
          ),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(AppRadius.control),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            colorToHex(color),
            style: TextStyle(
              color: cs.primary,
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labelStyle = TextStyle(fontSize: 12, color: cs.onSurfaceVariant);
    return AlertDialog(
      title: const Text('설교 제목 페이지'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListenableBuilder(
                listenable: _texts,
                builder: (_, _) => _PreviewBox(
                  style: _style,
                  previewItem: BlankStagingItem(
                    mainText: _titleNow.isEmpty ? '설교 주제' : _titleNow,
                    englishText: _subtitleNow,
                    extraText: widget.extraText,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _titleController,
                autofocus: true,
                // 예전 설교 페이지는 제목에 구절까지 여러 줄로 넣었다 — 한 줄 칸이면 둘째 줄이 안 보인다.
                // 높이가 자라는 칸(minLines)은 쓰지 않는다. 기존 입력칸처럼 높이를 고정해 둔다
                // (자라는 칸에서 macOS 한글 조합이 갈라진다는 보고가 있었다).
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '주제',
                  hintText: '예) 복음통일',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _subtitleController,
                decoration: const InputDecoration(
                  labelText: '부제 (비워도 됩니다)',
                  hintText: '예) 히브리서 11장 1절',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _resetText,
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  label: const Text('글자 기본값으로'),
                ),
              ),
              Text('글꼴', style: labelStyle),
              const SizedBox(height: 6),
              _FontFamilyPicker(
                selected: _style.fontFamily,
                onChanged: (family) => setState(
                  () => _design = _design.copyWith(fontFamily: family),
                ),
              ),
              const SizedBox(height: 12),
              Text('주제 글자 크기 ${_style.fontSize.round()}pt', style: labelStyle),
              Slider(
                min: 20,
                max: 120,
                divisions: 100,
                value: _style.fontSize.clamp(20, 120).toDouble(),
                onChanged: (v) => setState(
                  () => _design = _design.copyWith(fontSize: v.roundToDouble()),
                ),
              ),
              Text(
                '부제 글자 크기 ${_style.effectiveEnglishFontSize.round()}pt',
                style: labelStyle,
              ),
              Slider(
                min: 14,
                max: 100,
                divisions: 86,
                value: _style.effectiveEnglishFontSize
                    .clamp(14, 100)
                    .toDouble(),
                onChanged: (v) => setState(
                  () => _design = _design.copyWith(
                    subFontSize: v.roundToDouble(),
                  ),
                ),
              ),
              Text('세로 위치', style: labelStyle),
              const SizedBox(height: 6),
              SegmentedButton<VerticalTextPosition>(
                segments: [
                  for (final v in VerticalTextPosition.values)
                    ButtonSegment(value: v, label: Text(v.label)),
                ],
                selected: {_style.textPosition},
                onSelectionChanged: (v) => setState(
                  () => _design = _design.copyWith(lyricsPosition: v.first),
                ),
              ),
              const SizedBox(height: 12),
              _colorRow(
                '주제 글자 색상',
                _style.textColor,
                (c) => setState(() => _design = _design.copyWith(textColor: c)),
              ),
              const SizedBox(height: 8),
              _colorRow(
                '부제 글자 색상',
                _style.englishTextColor,
                (c) =>
                    setState(() => _design = _design.copyWith(subTextColor: c)),
              ),
              const SizedBox(height: 8),
              _colorRow(
                '배경 색상',
                _design.color,
                (c) => setState(() => _design = _design.copyWith(color: c)),
              ),
              const SizedBox(height: 8),
              Text('배경 이미지 (공통 모음)', style: labelStyle),
              const SizedBox(height: 6),
              BackgroundImageGallery(
                library: widget.imageLibrary,
                selected: _design.imagePath,
                emptyColor: _design.color,
                onChanged: (path) =>
                    setState(() => _design = _design.copyWith(imagePath: path)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.canRevert)
          TextButton(
            onPressed: () => Navigator.of(context).pop<_SermonPageResult>((
              title: _titleNow,
              subtitle: _subtitleNow,
              design: null,
            )),
            child: const Text('일반 빈 페이지로 되돌리기'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        ListenableBuilder(
          listenable: _texts,
          builder: (_, _) => FilledButton(
            onPressed: _titleNow.isEmpty
                ? null
                : () => Navigator.of(context).pop((
                    title: _titleNow,
                    subtitle: _subtitleNow,
                    // 글꼴·크기·색·위치를 모두 박아 둔다 — 나중에 찬양 디자인을 바꿔도
                    // 설교 페이지는 그대로여야 한다.
                    design: _design.copyWith(
                      fontFamily: _style.fontFamily,
                      fontSize: _style.fontSize,
                      textColor: _style.textColor,
                      subFontSize: _style.effectiveEnglishFontSize,
                      subTextColor: _style.englishTextColor,
                      lyricsPosition: _style.textPosition,
                      lyricsOffsetY: _design.lyricsOffsetY ?? 0.0,
                      offering: null,
                      isSermon: true,
                    ),
                  )),
            child: const Text('적용'),
          ),
        ),
      ],
    );
  }
}

class _ItemBackgroundDialog extends StatefulWidget {
  const _ItemBackgroundDialog({
    required this.item,
    required this.initial,
    required this.globalStyle,
    required this.swatches,
    required this.imageLibrary,
    required this.videoLibrary,
  });

  final StagingItem item;
  final SlideBackground? initial;
  final ExportStyle globalStyle;
  final List<Color> swatches;
  final BackgroundImageLibrary imageLibrary;
  final BackgroundImageLibrary videoLibrary;

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
                            borderRadius: BorderRadius.circular(
                              AppRadius.control,
                            ),
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
                                borderRadius: BorderRadius.circular(
                                  AppRadius.control,
                                ),
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
                      // PPT 이미지는 원본 그대로 나가므로 배경 영상을 깔지 않는다.
                      if (widget.item is! ImageStagingItem) ...[
                        const SizedBox(height: 14),
                        Text(
                          '배경 영상 (공통 모음 · 발표 화면에서만 반복 재생)',
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 6),
                        BackgroundImageGallery(
                          library: widget.videoLibrary,
                          selected: _background.videoPath,
                          emptyColor: _background.color,
                          onChanged: (path) => setState(
                            () => _background = _background.copyWith(
                              videoPath: path,
                            ),
                          ),
                        ),
                        if (_background.hasVideo) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Text(
                                '영상 어둡게',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              Expanded(
                                child: Slider(
                                  value: _background.videoDim,
                                  max: SlideBackground.maxVideoDim,
                                  divisions: 14,
                                  label:
                                      '${(_background.videoDim * 100).round()}%',
                                  onChanged: (v) => setState(
                                    () => _background = _background.copyWith(
                                      videoDim: v,
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 40,
                                child: Text(
                                  '${(_background.videoDim * 100).round()}%',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Text(
                            '미리보기·PPTX 에는 위 배경 이미지(없으면 색)가 쓰입니다. '
                            '콘티 파일·클라우드 콘티에는 영상이 실리지 않습니다.',
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
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
                // 더는 헌금송 배경이 아니므로 떼어 낸다. 배경 영상만 고친 것은 손댄 게 아니다.
                : _background.copyWith(
                        videoPath: widget.initial?.videoPath,
                        videoDim:
                            widget.initial?.videoDim ??
                            SlideBackground.defaultVideoDim,
                      ) ==
                      widget.initial
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

/// 이 페이지에 깔 배경 영상(항목 배경의 영상). 페이지 자체 미디어·PPT 이미지 페이지에는 깔지 않는다.
/// [checkFile] 이면 영상 파일이 아직 있는지도 본다(발표 창에 보낼 때만 — 썸네일마다 stat 하지 않게).
SlideBackdrop? _backdropFor(_SlideInfo? slide, {bool checkFile = false}) {
  final background = slide?.background;
  if (background == null || !background.hasVideo) return null;
  if (slide!.media != null || slide.imagePath != null) return null;
  if (checkFile && !File(background.videoPath!).existsSync()) return null;
  return SlideBackdrop(
    videoPath: background.videoPath!,
    dim: background.videoDim,
  );
}

// 발표자 보기의 "화면을 떠나도 남아야 하는" 값들. 콘솔은 탭을 옮기거나
// 모든 페이지 보기로 바꾸면 통째로 트리에서 빠지기 때문에, State 안에 두면
// 예배 도중에 경과 시간이 00:00 으로 리셋된다.
class PresenterViewState {
  // 발표를 시작·끝낼 때 홈 화면이 start/stop 하고, 바뀌면 싱어 화면에 다시 보낸다.
  final PresentationTimer timer = PresentationTimer();
  double splitRatio = 0.68;
  // 아래 썸네일 줄 높이. 현재 슬라이드와 썸네일 사이 막대를 끌어 바꾼다.
  double stripHeight = _PresenterConsoleState._defaultStripHeight;
  bool showAllPages = false;
  double gridThumbW = 140;
  // 곡 찾기 범위. 예배 도중 탭을 오가도 고른 범위가 유지되게 여기에 둔다.
  SlideSearchScope searchScope = SlideSearchScope.title;
}

/// 발표 보기 곡 찾기 범위: 제목만 / 가사(원본·보조 언어)만.
enum SlideSearchScope { title, lyrics }

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
    required this.onSlidesDelete,
    required this.onSlidesCopy,
    required this.onPaste,
    required this.onSlidesMove,
    required this.onAddPage,
    required this.onToggleMedia,
    required this.mediaPlayback,
    required this.onSeekMedia,
    required this.onPrev,
    required this.onNext,
    required this.onToggleBlackout,
    required this.isSingerOpen,
    required this.onToggleSinger,
    required this.isMobileSingerOn,
    required this.onShowMobileSinger,
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
    required this.isActive,
    required this.voice,
    required this.onToggleVoice,
    required this.onShowVoiceInsert,
    required this.onUndoVoiceInsert,
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
  final ValueChanged<List<int>> onSlidesDelete;
  final ValueChanged<List<int>> onSlidesCopy;
  final VoidCallback onPaste;
  // 썸네일 끌어 놓기: (옮길 페이지들, 이 페이지 바로 뒤로)
  final void Function(List<int> slideIndexes, int afterIndex) onSlidesMove;
  final ValueChanged<_AddPageKind> onAddPage;
  final VoidCallback onToggleMedia;
  final ValueListenable<MediaPlayback?> mediaPlayback;
  final ValueChanged<double> onSeekMedia;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToggleBlackout;
  final bool isSingerOpen;
  final VoidCallback onToggleSinger;
  final bool isMobileSingerOn;
  final VoidCallback onShowMobileSinger;
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
  // 발표 보기 탭이 보이는 중인지. 숨은 탭(IndexedStack)도 살아 있으므로
  // Ctrl+F 같은 전역 단축키는 이 값으로 거른다.
  final bool isActive;
  // 성경 음성 검색. 값이 null 이면 꺼짐.
  final ValueListenable<_VoiceState?> voice;
  final VoidCallback onToggleVoice;
  final VoidCallback onShowVoiceInsert;
  final VoidCallback onUndoVoiceInsert;

  @override
  State<_PresenterConsole> createState() => _PresenterConsoleState();
}

class _PresenterConsoleState extends State<_PresenterConsole> {
  final _noteController = TextEditingController();
  final _stripScrollController = ScrollController();
  final _gridScrollController = ScrollController();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  // 검색으로 찾은 페이지. 썸네일에 테두리만 두르고 현재 슬라이드는 바꾸지 않는다.
  int? _foundIndex;
  // ⌘/Ctrl·Shift+클릭으로 고른 페이지(지울 대상). 현재 슬라이드는 바꾸지 않는다.
  // 인덱스라서 슬라이드 목록이 바뀌면 비운다.
  final Set<int> _marked = {};
  int? _markAnchor;
  // 썸네일을 끄는 중인지. 줄·격자 가장자리에 가면 저절로 스크롤한다.
  bool _isDragging = false;
  String _noteKey = '';
  // 마지막으로 현재 페이지를 가운데 맞춘 배치(크기·열 수). 배치가 바뀌면
  // (줄 높이를 끌거나, +/- 확대, 창 크기 변경, 화면 전환) 다시 맞춘다.
  String? _stripLayoutKey;
  String? _gridLayoutKey;
  PresenterViewState get _view => widget.viewState;

  static const double _thumbAspect = 13.333 / 7.5;
  static const double _defaultStripHeight = 104;
  static const double _minStripHeight = 80;
  // 썸네일을 키워도 현재 슬라이드 쪽에 이만큼은 남긴다.
  static const double _minStageHeight = 180;
  static const double _stripHandleHeight = 14;
  static const double _stripSpacing = 8;
  static const double _stripPadding = 8;
  static const double _gridSpacing = 8;
  static const double _gridPad = 10;

  // 마지막으로 그린 모든 페이지 격자의 열 수·칸 높이. 자동 스크롤이 쓴다.
  ({int cols, double cellH})? _gridLayout;

  // 마지막으로 그린 썸네일 줄 높이(창 크기에 맞춰 줄어든 값). 자동 스크롤이 쓴다.
  double _renderedStripHeight = _defaultStripHeight;

  // 썸네일 아래 번호 줄(26) 을 뺀 높이가 슬라이드 높이다.
  static double _thumbWidthFor(double stripHeight) =>
      (stripHeight - 26) * _thumbAspect;

  @override
  void initState() {
    super.initState();
    _syncNote();
    HardwareKeyboard.instance.addHandler(_handleFindKey);
    HardwareKeyboard.instance.addHandler(_handleEditKey);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollStripToCurrent(),
    );
  }

  @override
  void didUpdateWidget(_PresenterConsole oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 콘티를 재정렬하면 인덱스·개수는 그대로여도 슬라이드가 바뀐다. 키 비교는 안에서 한다.
    _syncNote();
    if (oldWidget.slides.length != widget.slides.length) {
      _marked.clear();
      _markAnchor = null;
    }
    // 찾은 자리가 다른 슬라이드가 됐으면(개수 변화·재정렬) 다음 찾기는 처음부터 다시.
    final found = _foundIndex;
    if (found != null &&
        (found >= widget.slides.length ||
            found >= oldWidget.slides.length ||
            widget.slides[found].stagingUid !=
                oldWidget.slides[found].stagingUid ||
            widget.slides[found].pageIndexInItem !=
                oldWidget.slides[found].pageIndexInItem)) {
      _foundIndex = null;
    }
    if (oldWidget.currentIndex != widget.currentIndex ||
        oldWidget.slides.length != widget.slides.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollStripToCurrent();
        _scrollGridToCurrent();
      });
    }
  }

  @override
  void dispose() {
    _noteController.dispose();
    _stripScrollController.dispose();
    _gridScrollController.dispose();
    HardwareKeyboard.instance.removeHandler(_handleFindKey);
    HardwareKeyboard.instance.removeHandler(_handleEditKey);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Ctrl+F (macOS 는 ⌘F) = 곡 찾기 입력칸으로. 발표 중엔 포커스가 콘솔 바깥
  /// FocusScope 에 있어서 Shortcuts 위젯으로는 못 받으므로 전역 핸들러로 받는다.
  /// F3 = 입력된 검색어로 다음 찾기, F2(또는 Shift+F3) = 이전 찾기.
  /// 메모 등 다른 입력칸에 있을 땐 넘긴다.
  /// 발표 보기 탭이 숨어 있거나 다이얼로그가 떠 있으면 무시한다.
  bool _handleFindKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        !widget.isActive ||
        ModalRoute.of(context)?.isCurrent == false) {
      return false;
    }
    if ((event.logicalKey == LogicalKeyboardKey.f3 ||
            event.logicalKey == LogicalKeyboardKey.f2) &&
        _searchController.text.trim().isNotEmpty) {
      final focus = FocusManager.instance.primaryFocus;
      if (focus != _searchFocus &&
          focus?.context?.findAncestorWidgetOfExactType<EditableText>() !=
              null) {
        return false;
      }
      _searchSlides(
        _searchController.text,
        backward:
            event.logicalKey == LogicalKeyboardKey.f2 ||
            HardwareKeyboard.instance.isShiftPressed,
      );
      return true;
    }
    if (event.logicalKey != LogicalKeyboardKey.keyF) return false;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed && !keyboard.isMetaPressed) return false;
    _searchFocus.requestFocus();
    // 이전 검색어를 통째로 골라 두어 바로 덮어쓸 수 있게 한다.
    _searchController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchController.text.length,
    );
    return true;
  }

  /// 썸네일 클릭. ⌘/Ctrl = 하나씩 골라 담기, Shift = 범위로 담기, 그냥 클릭 = 그 페이지로.
  void _onThumbTap(int i) {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed) {
      final anchor = _markAnchor ?? widget.currentIndex;
      setState(() {
        final (a, b) = anchor <= i ? (anchor, i) : (i, anchor);
        _marked.addAll([for (var k = a; k <= b; k++) k]);
      });
      return;
    }
    if (keyboard.isMetaPressed || keyboard.isControlPressed) {
      setState(() {
        if (!_marked.remove(i)) _marked.add(i);
        _markAnchor = i;
      });
      return;
    }
    if (_marked.isNotEmpty || _markAnchor != null) {
      setState(() {
        _marked.clear();
        _markAnchor = null;
      });
    }
    widget.onSlideSelected(i);
  }

  /// 썸네일 편집 단축키. ⌘/Ctrl+C = 고른 페이지(없으면 현재 페이지) 복사,
  /// ⌘/Ctrl+V = 붙여 넣기, Delete/Backspace = 고른 페이지 삭제, ESC = 고르기 취소.
  /// 고른 게 없으면 Delete 는 아무것도 안 한다 — 지금 띄운 페이지가 실수로 지워지면 안 된다.
  bool _handleEditKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        widget.slides.isEmpty ||
        !widget.isActive ||
        ModalRoute.of(context)?.isCurrent == false) {
      return false;
    }
    // 메모·찾기 입력칸에서는 글자 복사·지우기로 넘긴다.
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final withCmd = keyboard.isControlPressed || keyboard.isMetaPressed;

    if (withCmd && key == LogicalKeyboardKey.keyC) {
      widget.onSlidesCopy(
        _marked.isEmpty ? [widget.currentIndex] : _marked.toList(),
      );
      return true;
    }
    if (withCmd && key == LogicalKeyboardKey.keyV) {
      widget.onPaste();
      return true;
    }
    if (_marked.isEmpty) return false;
    if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _marked.clear();
        _markAnchor = null;
      });
      return true;
    }
    if (key != LogicalKeyboardKey.delete &&
        key != LogicalKeyboardKey.backspace) {
      return false;
    }
    final indexes = _marked.toList();
    setState(() {
      _marked.clear();
      _markAnchor = null;
    });
    widget.onSlidesDelete(indexes);
    return true;
  }

  void _endDrag() {
    if (_isDragging) setState(() => _isDragging = false);
  }

  /// 썸네일 [i] 를 끌면 옮길 페이지들. 골라 담은 페이지를 끌면 고른 것 전부, 아니면 그 한 장.
  List<int> _dragSourcesFor(int i) =>
      _marked.contains(i) ? (_marked.toList()..sort()) : [i];

  // 끌기 시작할 때 옮길 페이지. 번호가 아니라 키로 들고 있다가 놓을 때 지금 번호를 다시 찾는다 —
  // 끄는 사이 원본 PPT 를 다시 구우면(저장 감지) 같은 번호가 다른 페이지가 된다(이미지 경로가 바뀐다).
  // 가사 글자는 키에 넣지 않는다 — 끄는 사이 보조 언어를 바꾸면 놓기가 조용히 사라진다.
  List<String> _dragKeys = const [];

  static String _dragKey(_SlideInfo s) =>
      '${s.stagingUid}:${s.pageIndexInItem}:${s.isAutoSpacer}:${s.imagePath}';

  /// 썸네일 끌어 놓기. 맨 앞 빈 페이지·자동 여백은 끌 수 없고 놓을 자리로만 쓴다.
  Widget _dragDrop(int i, ColorScheme cs, double thumbW, Widget child) {
    final slide = widget.slides[i];
    final canDrag = !slide.isAutoSpacer && slide.stagingUid >= 0;
    return _ThumbDragDrop(
      canDrag: canDrag,
      // 끌 때만 만든다(썸네일마다 미리 그리지 않게).
      feedbackBuilder: (_) => _dragFeedback(i, cs, thumbW),
      // 맨 앞 빈 페이지 앞에는 넣을 수 없다.
      allowBefore: i > 0,
      onDragStateChanged: (dragging) {
        if (dragging) {
          _dragKeys = [
            for (final j in _dragSourcesFor(i)) _dragKey(widget.slides[j]),
          ];
        }
        if (_isDragging != dragging) setState(() => _isDragging = dragging);
      },
      onDrop: (after) {
        final afterIndex = after ? i : i - 1;
        final slides = widget.slides;
        final at = {
          for (var j = 0; j < slides.length; j++) _dragKey(slides[j]): j,
        };
        final sources = [for (final k in _dragKeys) ?at[k]];
        setState(() {
          _isDragging = false;
          _marked.clear();
          _markAnchor = null;
        });
        // 끄는 사이 페이지가 바뀌었으면(다시 굽기 등) 옮기지 않는다.
        if (sources.length != _dragKeys.length) return;
        widget.onSlidesMove(sources, afterIndex);
      },
      child: child,
    );
  }

  Widget _dragFeedback(int i, ColorScheme cs, double thumbW) {
    final count = _dragSourcesFor(i).length;
    final w = thumbW.clamp(80.0, 160.0);
    return Opacity(
      opacity: 0.85,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(AppRadius.control),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: w,
          height: w / _thumbAspect,
          child: Stack(
            fit: StackFit.expand,
            children: [
              SlideRenderView(data: _pageDataFor(i)),
              if (count > 1)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$count장',
                      style: TextStyle(
                        color: cs.onPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
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

  /// 골라 담은 썸네일에 체크 표시와 테두리를 두른다.
  Widget _markedMark(int i, ColorScheme cs, Widget child) {
    if (!_marked.contains(i)) return child;
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: cs.secondary.withValues(alpha: 0.18),
                border: Border.all(color: cs.secondary, width: 3),
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.check_circle_rounded,
                    size: 18,
                    color: cs.secondary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _setSearchScope(SlideSearchScope scope) {
    setState(() {
      _view.searchScope = scope;
      // 범위가 바뀌면 처음부터 다시 찾는다.
      _foundIndex = null;
    });
  }

  /// [query] 가 든 다음 결과로 썸네일만 스크롤한다.
  /// - 제목: 곡 제목·성경 구절이 맞는 항목의 첫 페이지
  /// - 가사: 원본·보조 언어 가사가 맞는 바로 그 페이지
  /// 발표 화면이 바뀌면 안 되므로 현재 슬라이드(onSlideSelected)는 건드리지 않는다.
  /// 같은 검색어로 다시 누르면 그다음 결과로([backward] 면 그 앞 결과로) 넘어간다.
  void _searchSlides(String query, {bool backward = false}) {
    String norm(String v) => v.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    final q = norm(query);
    // 입력칸에서 포커스를 빼야 ←/→ 발표 단축키가 다시 먹는다.
    _searchFocus.unfocus();
    if (q.isEmpty) {
      setState(() => _foundIndex = null);
      return;
    }
    final slides = widget.slides;
    bool matches(int i) {
      final slide = slides[i];
      if (slide.isAutoSpacer) return false;
      return switch (_view.searchScope) {
        // 한 곡의 여러 페이지 중 첫 페이지만 결과로 친다.
        SlideSearchScope.title =>
          slide.pageIndexInItem == 0 && norm(slide.title ?? '').contains(q),
        SlideSearchScope.lyrics => norm(
          '${slide.mainText} ${slide.englishText} ${slide.extraText}',
        ).contains(q),
      };
    }

    final step = backward ? -1 : 1;
    final start = _foundIndex == null
        ? (backward ? slides.length - 1 : 0)
        : _foundIndex! + step;
    int? found;
    for (var k = 0; k < slides.length; k++) {
      final i = (start + step * k) % slides.length;
      if (matches(i)) {
        found = i;
        break;
      }
    }
    setState(() => _foundIndex = found);
    if (found == null) return;
    _scrollStripTo(found);
    _scrollGridTo(found);
  }

  /// 검색으로 찾은 썸네일에 테두리를 두른다.
  Widget _foundMark(int i, ColorScheme cs, Widget child) {
    if (i != _foundIndex) return child;
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: cs.tertiary, width: 3),
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
            ),
          ),
        ),
      ],
    );
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

  /// 하단 썸네일 줄에서 현재 페이지를 가운데로. 페이지를 넘길 때는 부드럽게,
  /// 배치가 바뀔 때(줄 높이 끌기·창 크기)는 그 자리에서 바로 맞춘다.
  void _scrollStripToCurrent({bool animate = true}) =>
      _scrollStripTo(widget.currentIndex, animate: animate);

  void _scrollStripTo(int index, {bool animate = true}) {
    if (!_stripScrollController.hasClients || widget.slides.isEmpty) return;
    final tw = _thumbWidthFor(_renderedStripHeight);
    final target = _stripPadding + index * (tw + _stripSpacing) + tw / 2;
    _scrollToCenter(_stripScrollController, target, animate: animate);
  }

  /// 모든 페이지 보기에서 현재 페이지가 있는 줄을 가운데로.
  void _scrollGridToCurrent({bool animate = true}) =>
      _scrollGridTo(widget.currentIndex, animate: animate);

  void _scrollGridTo(int index, {bool animate = true}) {
    final g = _gridLayout;
    if (!_gridScrollController.hasClients || g == null) return;
    final row = index ~/ g.cols;
    final target = _gridPad + row * (g.cellH + _gridSpacing) + g.cellH / 2;
    _scrollToCenter(_gridScrollController, target, animate: animate);
  }

  /// [center] 위치(스크롤 내용 기준)가 화면 가운데 오도록 스크롤한다. 양 끝에서는 멈춘다.
  void _scrollToCenter(
    ScrollController controller,
    double center, {
    required bool animate,
  }) {
    final position = controller.position;
    final offset = (center - position.viewportDimension / 2).clamp(
      0.0,
      position.maxScrollExtent,
    );
    if (animate) {
      controller.animateTo(
        offset,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    } else {
      controller.jumpTo(offset);
    }
  }

  SlidePageData _pageDataFor(int i) {
    final info = widget.slides[i];
    return SlidePageData(
      mainText: info.mainText,
      englishText: info.englishText,
      extraText: info.extraText,
      title: info.title,
      isBible: info.isBible,
      pageIndex: i,
      totalPages: widget.slides.length,
      style: widget.style.withBackground(info.background),
      imagePath: info.imagePath,
      media: info.media,
      backdrop: _backdropFor(info),
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

  /// 발표 중 지금 페이지에서 재생 중인 미디어. 있으면 헤더 아래 재생바가 붙는다.
  SlideMedia? get _currentMedia {
    if (!widget.isPresentationOpen || widget.slides.isEmpty) return null;
    return widget
        .slides[widget.currentIndex.clamp(0, widget.slides.length - 1)]
        .media;
  }

  /// 썸네일 줄이 가질 수 있는 가장 큰 높이. 헤더와 현재 슬라이드 최소 높이를 뺀 나머지.
  double _maxStripHeight(BoxConstraints constraints) {
    final headerHeight =
        58.0 +
        (_currentMedia != null ? _MediaBar.height : 0) +
        (widget.voice.value != null
            ? _VoiceBar.height
            : 0); // 헤더(+재생바·음성 줄) + 아래 여백
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
    final media = _currentMedia;
    return Column(
      children: [
        _header(cs),
        if (media != null)
          _MediaBar(
            media: media,
            playback: widget.mediaPlayback,
            onToggle: widget.onToggleMedia,
            onSeek: widget.onSeekMedia,
          ),
        if (widget.voice.value != null)
          _VoiceBar(
            voice: widget.voice,
            onShow: widget.onShowVoiceInsert,
            onUndo: widget.onUndoVoiceInsert,
          ),
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
              // 가운데 맞추기는 _thumbStrip 이 배치가 바뀐 것을 보고 한다.
              setState(() => _view.stripHeight = next);
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

  static String get _findShortcutLabel => Platform.isMacOS ? '⌘F' : 'Ctrl+F';

  /// 곡 찾기 범위(제목 / 가사) 고르기.
  Widget _searchScopeToggle() {
    return SegmentedButton<SlideSearchScope>(
      segments: const [
        ButtonSegment(value: SlideSearchScope.title, label: Text('제목')),
        ButtonSegment(value: SlideSearchScope.lyrics, label: Text('가사')),
      ],
      selected: {_view.searchScope},
      showSelectedIcon: false,
      onSelectionChanged: (s) => _setSearchScope(s.first),
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
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
        if (_view.showAllPages) ...[
          const SizedBox(width: 16),
          _sectionLabel(cs, '모든 페이지 · ${widget.slides.length}장'),
          const SizedBox(width: 4),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => _changeGridZoom(-30),
            icon: const Icon(Icons.remove_rounded, size: 18),
            tooltip: '작게',
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => _changeGridZoom(30),
            icon: const Icon(Icons.add_rounded, size: 18),
            tooltip: '크게',
          ),
        ],
        const Spacer(),
        // 곡 찾기: Enter 를 누르면 썸네일만 그 곡으로 스크롤한다(발표 화면은 그대로).
        _searchScopeToggle(),
        const SizedBox(width: 6),
        Tooltip(
          message: '다음 찾기 F3 · 이전 찾기 F2',
          child: SizedBox(
            width: 200,
            child: CallbackShortcuts(
              // ESC 는 발표 종료가 아니라 입력칸에서 빠져나오기만.
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): () =>
                    _searchFocus.unfocus(),
              },
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocus,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText:
                      '${_view.searchScope == SlideSearchScope.title ? '제목' : '가사'}'
                      ' 찾기 ($_findShortcutLabel)',
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  prefixIconConstraints: const BoxConstraints(minWidth: 34),
                  border: const OutlineInputBorder(),
                ),
                // 검색어를 바꾸면 처음 곡부터 다시 찾는다.
                onChanged: (_) {
                  if (_foundIndex != null) setState(() => _foundIndex = null);
                },
                onSubmitted: _searchSlides,
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
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
        PopupMenuButton<_AddPageKind>(
          icon: const Icon(Icons.note_add_outlined),
          tooltip: '새 페이지 추가 (현재 항목 뒤)',
          onSelected: widget.onAddPage,
          itemBuilder: (_) => _addPageMenuItems,
        ),
        IconButton(
          onPressed: widget.onToggleVoice,
          icon: Icon(
            widget.voice.value != null
                ? Icons.record_voice_over_rounded
                : Icons.record_voice_over_outlined,
          ),
          tooltip: widget.voice.value != null
              ? '성경 음성 검색 끄기'
              : '성경 음성 검색 (말한 구절을 다음 장에 넣기)',
          color: widget.voice.value != null ? cs.primary : null,
        ),
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
        if (open)
          IconButton(
            onPressed: widget.onToggleSinger,
            icon: Icon(
              widget.isSingerOpen ? Icons.mic_rounded : Icons.mic_none_rounded,
            ),
            tooltip: widget.isSingerOpen
                ? '싱어 화면 닫기'
                : '싱어 화면 열기 (현재 + 다음 페이지)',
            color: widget.isSingerOpen ? cs.primary : null,
          ),
        if (open)
          IconButton(
            onPressed: widget.onShowMobileSinger,
            icon: const Icon(Icons.phone_iphone_rounded),
            tooltip: widget.isMobileSingerOn
                ? '휴대폰 싱어 화면 (켜짐 — 주소 보기·끄기)'
                : '휴대폰에서 싱어 화면 보기 (같은 와이파이)',
            color: widget.isMobileSingerOn ? cs.primary : null,
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
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: cs.outlineVariant),
                        borderRadius: BorderRadius.circular(AppRadius.control),
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
          _ElapsedClock(
            isRunning: widget.isPresentationOpen,
            timer: _view.timer,
          ),
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
          borderRadius: BorderRadius.circular(AppRadius.control),
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
  // 장 수와 +/- 버튼은 발표 상태 머리줄(_header)에 같이 둔다.
  void _changeGridZoom(double delta) {
    setState(
      () => _view.gridThumbW = (_view.gridThumbW + delta).clamp(70.0, 460.0),
    );
  }

  Widget _allPagesGrid(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent &&
                  (HardwareKeyboard.instance.isControlPressed ||
                      HardwareKeyboard.instance.isMetaPressed)) {
                _changeGridZoom(-event.scrollDelta.dy * 0.6);
              }
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                const spacing = _gridSpacing;
                const labelH = 20.0;
                const pad = _gridPad;
                final avail = (constraints.maxWidth - pad * 2).clamp(
                  1.0,
                  double.infinity,
                );
                final cols = ((avail + spacing) / (_view.gridThumbW + spacing))
                    .floor()
                    .clamp(1, widget.slides.length.clamp(1, 9999));
                final tw = (avail - (cols - 1) * spacing) / cols;
                final cellH = tw / _thumbAspect + labelH;
                _gridLayout = (cols: cols, cellH: cellH);

                // 처음 열 때·확대/축소·창 크기를 바꿀 때 현재 페이지를 가운데로.
                final layoutKey =
                    '$cols/${cellH.toStringAsFixed(1)}/${constraints.maxHeight}';
                if (!_gridScrollController.hasClients) _gridLayoutKey = null;
                if (layoutKey != _gridLayoutKey) {
                  _gridLayoutKey = layoutKey;
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _scrollGridToCurrent(animate: false),
                  );
                }

                return _EdgeAutoScroll(
                  controller: _gridScrollController,
                  axis: Axis.vertical,
                  isActive: _isDragging,
                  onPointerEnd: _endDrag,
                  child: GridView.builder(
                    controller: _gridScrollController,
                    padding: const EdgeInsets.all(pad),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      crossAxisSpacing: spacing,
                      mainAxisSpacing: spacing,
                      childAspectRatio: (tw / cellH).clamp(0.1, 100.0),
                    ),
                    itemCount: widget.slides.length,
                    itemBuilder: (context, i) => _dragDrop(
                      i,
                      cs,
                      tw,
                      _foundMark(
                        i,
                        cs,
                        _markedMark(
                          i,
                          cs,
                          _SlideThumbnail(
                            data: _pageDataFor(i),
                            isSelected: i == widget.currentIndex,
                            index: i,
                            isEditable: !widget.slides[i].isAutoSpacer,
                            // 누른 페이지로 넘기기만 한다. 보기 전환은 버튼으로만.
                            onTap: () => _onThumbTap(i),
                            onEdit: () => widget.onSlideEdit(i),
                            onDelete: () => widget.onSlideDelete(i),
                          ),
                        ),
                      ),
                    ),
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
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 줄 높이를 끌어 썸네일이 커지거나, 창 크기가 바뀌거나, 모든 페이지
          // 보기에서 돌아오면 현재 페이지를 다시 가운데로 맞춘다.
          final layoutKey =
              '${stripHeight.toStringAsFixed(1)}/${constraints.maxWidth}';
          if (!_stripScrollController.hasClients) _stripLayoutKey = null;
          if (layoutKey != _stripLayoutKey) {
            _stripLayoutKey = layoutKey;
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _scrollStripToCurrent(animate: false),
            );
          }
          return _thumbList(cs, thumbW);
        },
      ),
    );
  }

  Widget _thumbList(ColorScheme cs, double thumbW) {
    return _EdgeAutoScroll(
      controller: _stripScrollController,
      axis: Axis.horizontal,
      isActive: _isDragging,
      onPointerEnd: _endDrag,
      child: ListView.builder(
        controller: _stripScrollController,
        scrollDirection: Axis.horizontal,
        // 오른쪽 여백은 마지막 썸네일의 간격(_stripSpacing)이 대신한다.
        padding: const EdgeInsets.fromLTRB(_stripPadding, 6, 0, 6),
        // 폭을 고정해야 멀리 있는 페이지까지의 스크롤 길이가 정확하다. 안 그러면
        // 아직 안 그린 썸네일 길이를 어림해서 가운데 맞추기가 중간에 멈춘다.
        itemExtent: thumbW + _stripSpacing,
        itemCount: widget.slides.length,
        itemBuilder: (context, i) {
          final hasNote = (widget.notes[_keyAt(i)] ?? '').isNotEmpty;
          return Padding(
            padding: const EdgeInsets.only(right: _stripSpacing),
            child: _dragDrop(
              i,
              cs,
              thumbW,
              _foundMark(
                i,
                cs,
                SizedBox(
                  width: thumbW,
                  child: Stack(
                    children: [
                      // 편집 탭의 슬라이드 순서와 같은 썸네일. 마우스를 올리면
                      // 수정·삭제 버튼이 그대로 나온다.
                      _markedMark(
                        i,
                        cs,
                        _SlideThumbnail(
                          data: _pageDataFor(i),
                          isSelected: i == widget.currentIndex,
                          index: i,
                          isEditable: !widget.slides[i].isAutoSpacer,
                          onTap: () => _onThumbTap(i),
                          onEdit: () => widget.onSlideEdit(i),
                          onDelete: () => widget.onSlideDelete(i),
                        ),
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
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 썸네일 끌기 표지. 옮길 페이지는 부모가 들고 있다.
class _ThumbDrag {
  const _ThumbDrag();
}

/// 발표 보기 썸네일 하나를 끌 수 있고, 다른 썸네일을 그 앞·뒤에 놓을 수 있게 한다.
/// 놓을 자리는 마우스가 썸네일의 왼쪽 절반이면 앞, 오른쪽 절반이면 뒤다(세로 막대로 보여 준다).
class _ThumbDragDrop extends StatefulWidget {
  const _ThumbDragDrop({
    required this.canDrag,
    required this.feedbackBuilder,
    required this.allowBefore,
    required this.onDragStateChanged,
    required this.onDrop,
    required this.child,
  });

  // false 면 끌 수 없다(놓을 자리로만 쓴다). 옮길 페이지는 끌기 시작할 때(onDragStateChanged) 부모가 정한다.
  final bool canDrag;
  final WidgetBuilder feedbackBuilder;
  final bool allowBefore;
  final ValueChanged<bool> onDragStateChanged;
  final void Function(bool after) onDrop;
  final Widget child;

  @override
  State<_ThumbDragDrop> createState() => _ThumbDragDropState();
}

class _ThumbDragDropState extends State<_ThumbDragDrop> {
  // 끌고 있는 것이 이 썸네일 위에 있을 때 놓을 자리. null = 위에 없음.
  bool? _after;

  bool _afterFor(Offset global) {
    if (!widget.allowBefore) return true;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return true;
    return box.globalToLocal(global).dx > box.size.width / 2;
  }

  void _setAfter(bool? after) {
    if (_after != after) setState(() => _after = after);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final target = DragTarget<_ThumbDrag>(
      onMove: (d) => _setAfter(_afterFor(d.offset)),
      onLeave: (_) => _setAfter(null),
      onAcceptWithDetails: (d) {
        final after = _afterFor(d.offset);
        _setAfter(null);
        widget.onDrop(after);
      },
      builder: (context, candidates, rejected) {
        final after = _after;
        if (after == null || candidates.isEmpty) return widget.child;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            widget.child,
            Positioned(
              top: 0,
              bottom: 0,
              left: after ? null : -5,
              right: after ? -5 : null,
              child: IgnorePointer(
                child: Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    if (!widget.canDrag) return target;
    return Draggable<_ThumbDrag>(
      data: const _ThumbDrag(),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Transform.translate(
        offset: const Offset(-24, -24),
        child: Builder(builder: widget.feedbackBuilder),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: target),
      onDragStarted: () => widget.onDragStateChanged(true),
      // 끄는 동안 자동 스크롤로 이 썸네일이 목록에서 빠지면 불리지 않는다 —
      // 그래서 목록의 _EdgeAutoScroll 이 손을 뗄 때도 끈다.
      onDragEnd: (_) => widget.onDragStateChanged(false),
      child: target,
    );
  }
}

/// 썸네일을 끄는 동안([isActive]) 마우스가 목록 가장자리에 가면 그쪽으로 저절로 스크롤한다.
/// Draggable 은 스스로 스크롤하지 않아서, 멀리 있는 PPT 중간으로 옮기려면 필요하다.
class _EdgeAutoScroll extends StatefulWidget {
  const _EdgeAutoScroll({
    required this.controller,
    required this.axis,
    required this.isActive,
    required this.onPointerEnd,
    required this.child,
  });

  final ScrollController controller;
  final Axis axis;
  final bool isActive;
  // 손을 떼면(놓기·취소 어느 쪽이든) 부른다. 끄던 썸네일이 사라져 onDragEnd 가 안 와도 끄기를 끝낸다.
  final VoidCallback onPointerEnd;
  final Widget child;

  @override
  State<_EdgeAutoScroll> createState() => _EdgeAutoScrollState();
}

class _EdgeAutoScrollState extends State<_EdgeAutoScroll> {
  static const double _edge = 48;
  static const double _maxStep = 18;
  Timer? _timer;
  double _step = 0;
  PointerMoveEvent? _lastMove;

  @override
  void didUpdateWidget(_EdgeAutoScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isActive) _stop();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _step = 0;
    _lastMove = null;
  }

  void _onMove(PointerMoveEvent event) {
    if (!widget.isActive) return;
    _lastMove = event;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final local = box.globalToLocal(event.position);
    final pos = widget.axis == Axis.horizontal ? local.dx : local.dy;
    final size = widget.axis == Axis.horizontal
        ? box.size.width
        : box.size.height;
    // 가장자리에 가까울수록 빠르게.
    if (pos < _edge) {
      _step = -_maxStep * ((_edge - pos) / _edge).clamp(0.2, 1.0);
    } else if (pos > size - _edge) {
      _step = _maxStep * ((pos - (size - _edge)) / _edge).clamp(0.2, 1.0);
    } else {
      _stop();
      return;
    }
    _timer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final c = widget.controller;
      if (!c.hasClients || _step == 0) return;
      final pos = c.position;
      final before = pos.pixels;
      c.jumpTo(
        (pos.pixels + _step).clamp(pos.minScrollExtent, pos.maxScrollExtent),
      );
      // Draggable 은 마우스가 움직일 때만 밑에 있는 썸네일을 다시 찾는다. 마우스를 멈춘 채 목록만
      // 흘러가면 스크롤 전 썸네일에 놓이거나(그게 사라졌으면) 놓기가 없어지므로, 같은 자리에서
      // 움직인 것처럼 알려 다시 찾게 한다.
      final last = _lastMove;
      if (last != null && pos.pixels != before) {
        GestureBinding.instance.handlePointerEvent(
          last.copyWith(delta: Offset.zero, timeStamp: last.timeStamp),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerMove: _onMove,
      onPointerUp: (_) {
        _stop();
        widget.onPointerEnd();
      },
      onPointerCancel: (_) {
        _stop();
        widget.onPointerEnd();
      },
      child: widget.child,
    );
  }
}

// 경과 시간만 따로 뗀 이유: 1초마다 setState 를 하면 콘솔 전체(슬라이드 미리보기
// 두 장 + 썸네일 전부)가 매초 다시 그려진다. 시계만 다시 그리게 가둔다.
// 값은 [PresentationTimer] 가 들고 있다(탭을 옮겨도 계속 흘러야 한다). 이 위젯은 1초마다 다시 그리기만 한다.
class _ElapsedClock extends StatefulWidget {
  const _ElapsedClock({required this.isRunning, required this.timer});

  final bool isRunning;
  final PresentationTimer timer;

  @override
  State<_ElapsedClock> createState() => _ElapsedClockState();
}

class _ElapsedClockState extends State<_ElapsedClock> {
  Timer? _ticker;
  late final _targetController = TextEditingController(
    text: widget.timer.targetMinutes.toString(),
  );

  PresentationTimer get _timer => widget.timer;

  @override
  void initState() {
    super.initState();
    // 현재 시각도 보여 주므로 발표 중이 아니어도 돈다.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _targetController.dispose();
    super.dispose();
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final elapsed = _timer.elapsed;
    final target = _timer.target;
    final ratio = target.inSeconds == 0
        ? 0.0
        : (elapsed.inSeconds / target.inSeconds).clamp(0.0, 1.0);
    final over = elapsed > target;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
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
            const Spacer(),
            Tooltip(
              message: '싱어 화면에 시계·경과 시간 표시',
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(
                  () => _timer.setShowOnSinger(!_timer.showOnSinger),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.mic_external_on_rounded,
                        size: 14,
                        color: _timer.showOnSinger
                            ? cs.primary
                            : cs.onSurfaceVariant.withValues(alpha: 0.5),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        _timer.showOnSinger ? '싱어 표시' : '싱어 숨김',
                        style: TextStyle(
                          fontSize: 11,
                          color: _timer.showOnSinger
                              ? cs.primary
                              : cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              _fmt(elapsed),
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
                    setState(() => _timer.setTargetMinutes(n));
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
              onPressed: () => setState(
                () => _timer.togglePause(presenting: widget.isRunning),
              ),
              icon: Icon(
                _timer.isPaused
                    ? Icons.play_arrow_rounded
                    : Icons.pause_rounded,
                size: 19,
              ),
              tooltip: _timer.isPaused ? '계속' : '일시정지',
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(_timer.reset),
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

/// 누르면 [text] 를 클립보드에 넣고 2초 동안 체크 표시로 바뀌는 작은 버튼.
class _CopyTextButton extends StatefulWidget {
  const _CopyTextButton({required this.text});

  final String text;

  @override
  State<_CopyTextButton> createState() => _CopyTextButtonState();
}

class _CopyTextButtonState extends State<_CopyTextButton> {
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: _reset == null ? '주소 복사' : '복사됨',
    icon: Icon(_reset == null ? Icons.copy_rounded : Icons.check, size: 18),
    onPressed: () async {
      await Clipboard.setData(ClipboardData(text: widget.text));
      if (!mounted) return;
      _reset?.cancel();
      setState(() {
        _reset = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => _reset = null);
        });
      });
    },
  );
}

/// 휴대폰 싱어 다이얼로그 안의 cloudflared 자동 설치. LibreOffice 와 같은 설치기(winget·Homebrew)를 쓴다.
/// 수십 MB 라 따로 다이얼로그를 띄우지 않고 그 자리에서 진행 상황만 보여 준다.
class _CloudflaredInstallButton extends StatefulWidget {
  const _CloudflaredInstallButton({
    required this.onInstalled,
    required this.onOpenDownloadPage,
  });

  final VoidCallback onInstalled;
  final VoidCallback onOpenDownloadPage;

  @override
  State<_CloudflaredInstallButton> createState() =>
      _CloudflaredInstallButtonState();
}

class _CloudflaredInstallButtonState extends State<_CloudflaredInstallButton> {
  late final _manager = LibreOfficeInstaller.findPackageManager(
    wingetId: 'Cloudflare.cloudflared',
    brewArgs: const ['install', 'cloudflared'],
  );
  // 다이얼로그를 닫았다 다시 열어도 설치를 겹쳐 돌리지 않게 진행 중인 설치는 클래스에 둔다.
  static Future<bool>? _inFlight;
  bool _installing = false;
  bool _failed = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    final running = _inFlight;
    if (running != null) {
      _installing = true;
      _status = '설치하는 중…';
      _await(running);
    }
  }

  void _install(LibreOfficePackageManager manager) {
    setState(() {
      _installing = true;
      _failed = false;
      _status = '${manager.label}로 설치를 시작합니다…';
    });
    final run = _inFlight = LibreOfficeInstaller.install(
      manager,
      tag: 'cloudflared',
      installed: () async => await SingerWebServer.findCloudflared() != null,
      onProgress: (line) {
        if (mounted) setState(() => _status = line);
      },
    );
    run.then((ok) {
      _inFlight = null;
      if (ok) widget.onInstalled(); // 다이얼로그를 닫았어도 터널은 띄운다
    });
    _await(run);
  }

  Future<void> _await(Future<bool> run) async {
    final ok = await run;
    if (mounted) {
      setState(() {
        _installing = false;
        _failed = !ok;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    if (_installing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(
            _status,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall,
          ),
        ],
      );
    }
    return FutureBuilder<LibreOfficePackageManager?>(
      future: _manager,
      builder: (context, snap) {
        final manager = snap.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_failed)
              Text(
                '설치를 끝내지 못했습니다. 자세한 내용은 로그에 남겼습니다.',
                style: textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              )
            else if (snap.connectionState == ConnectionState.done &&
                manager == null)
              Text(
                '이 PC에는 자동 설치 도구(${Platform.isWindows ? 'winget' : 'Homebrew'})가 없습니다. '
                '다운로드 페이지에서 직접 설치해 주세요.',
                style: textTheme.bodySmall,
              ),
            Wrap(
              spacing: 8,
              children: [
                if (manager != null)
                  FilledButton.icon(
                    onPressed: () => _install(manager),
                    icon: const Icon(Icons.download_rounded),
                    label: Text(_failed ? '다시 시도' : '자동 설치'),
                  ),
                TextButton(
                  onPressed: widget.onOpenDownloadPage,
                  child: const Text('다운로드 페이지'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// 동영상·음악·유튜브 페이지 만들기/고치기: 파일(또는 유튜브 주소) + 페이드 인/아웃 시간.
/// 음악 페이지는 재생 중 화면에 띄울 문구도 받는다(빈 페이지 본문 자리).
class _MediaPageDialog extends StatefulWidget {
  const _MediaPageDialog({
    required this.kind,
    required this.videoLibrary,
    required this.initial,
    required this.initialText,
  });

  final MediaKind kind;
  final BackgroundImageLibrary videoLibrary;
  final SlideMedia initial;
  final String initialText;

  @override
  State<_MediaPageDialog> createState() => _MediaPageDialogState();
}

class _MediaPageDialogState extends State<_MediaPageDialog> {
  static const _audioExtensions = ['mp3', 'm4a', 'aac', 'wav'];

  late String _source = widget.initial.source;
  late double _fadeIn = widget.initial.fadeIn;
  late double _fadeOut = widget.initial.fadeOut;
  late final _urlController = TextEditingController(
    text: widget.kind == MediaKind.youtube ? widget.initial.source : '',
  );
  late final _textController = TextEditingController(text: widget.initialText);

  bool get _isYoutube => widget.kind == MediaKind.youtube;

  String? get _error {
    if (_isYoutube) {
      final url = _urlController.text.trim();
      if (url.isEmpty) return null;
      return youtubeId(url) == null ? '유튜브 영상 주소가 아닙니다' : null;
    }
    if (_source.isEmpty) return null;
    return File(_source).existsSync() ? null : '파일을 찾을 수 없습니다';
  }

  bool get _canSave =>
      _error == null &&
      (_isYoutube ? _urlController.text.trim().isNotEmpty : _source.isNotEmpty);

  @override
  void dispose() {
    _urlController.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    await FilePicker.skipEntitlementsChecks();
    final picked = await FilePicker.pickFiles(
      dialogTitle: widget.kind == MediaKind.video ? '동영상 파일 선택' : '음악 파일 선택',
      type: FileType.custom,
      allowedExtensions: widget.kind == MediaKind.video
          ? BackgroundImageLibrary.videoExtensions
          : _audioExtensions,
    );
    final path = picked?.paths.whereType<String>().firstOrNull;
    if (path != null && mounted) setState(() => _source = path);
  }

  Widget _fadeRow(String label, double value, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 84, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            max: SlideMedia.maxFade,
            divisions: (SlideMedia.maxFade * 2).round(),
            label: '${value.toStringAsFixed(1)}초',
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 48, child: Text('${value.toStringAsFixed(1)}초')),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = switch (widget.kind) {
      MediaKind.video => '동영상 페이지',
      MediaKind.audio => '음악 페이지',
      MediaKind.youtube => '유튜브 페이지',
    };
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_isYoutube)
              TextField(
                controller: _urlController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '유튜브 주소',
                  hintText: 'https://www.youtube.com/watch?v=…',
                  helperText:
                      '주소의 시작 위치(t=90)도 따릅니다. 발표 PC 가 인터넷에 연결돼 있어야 합니다.',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _source.isEmpty ? '파일을 고르세요' : p.basename(_source),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _error != null ? cs.error : null),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _pick,
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                    label: const Text('파일 선택'),
                  ),
                ],
              ),
            if (!_isYoutube && _error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _error!,
                  style: TextStyle(color: cs.error, fontSize: 12),
                ),
              ),
            if (widget.kind == MediaKind.video) ...[
              const SizedBox(height: 12),
              Text(
                '배경 영상 모음',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              BackgroundImageGallery(
                library: widget.videoLibrary,
                selected: _source.isEmpty ? null : _source,
                showNone: false,
                onChanged: (path) => setState(() => _source = path ?? ''),
              ),
            ],
            const SizedBox(height: 16),
            _fadeRow('페이드 인', _fadeIn, (v) => setState(() => _fadeIn = v)),
            _fadeRow('페이드 아웃', _fadeOut, (v) => setState(() => _fadeOut = v)),
            Text(
              '페이드 아웃은 다음 페이지로 넘길 때, 끝나기 직전, 발표 보기의 미디어 버튼으로 멈출 때 걸립니다.',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            if (widget.kind == MediaKind.audio) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _textController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '화면 문구 (비워도 됩니다)',
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
          onPressed: _canSave
              ? () => Navigator.pop(context, (
                  media: SlideMedia(
                    kind: widget.kind,
                    source: _isYoutube ? _urlController.text.trim() : _source,
                    fadeIn: _fadeIn,
                    fadeOut: _fadeOut,
                  ),
                  text: widget.kind == MediaKind.audio
                      ? _textController.text.trim()
                      : '',
                ))
              : null,
          child: const Text('확인'),
        ),
      ],
    );
  }
}

/// 발표 보기 재생바: 멈춤/재생(페이드) · 10초 앞뒤 · 끌어서 위치 옮기기.
/// 관객 화면에는 아무것도 안 보인다 — 조작만 발표 창 미디어 레이어로 보낸다.
/// 발표 보기 성경 음성 검색 상태 줄: 듣는 중 · 들리는 말 · 마지막에 넣은 구절 + 띄우기/되돌리기.
class _VoiceBar extends StatelessWidget {
  const _VoiceBar({
    required this.voice,
    required this.onShow,
    required this.onUndo,
  });

  static const height = 36.0;

  final ValueListenable<_VoiceState?> voice;
  final VoidCallback onShow;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.bodySmall;
    return SizedBox(
      height: height,
      child: ValueListenableBuilder<_VoiceState?>(
        valueListenable: voice,
        builder: (context, v, _) {
          if (v == null) return const SizedBox.shrink();
          return Row(
            children: [
              Icon(Icons.fiber_manual_record, size: 10, color: cs.error),
              const SizedBox(width: 6),
              Text('듣는 중 · ${v.version}', style: text),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  v.heard.isNotEmpty ? v.heard : v.message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text?.copyWith(
                    color: v.heard.isNotEmpty
                        ? cs.onSurfaceVariant
                        : v.isError
                        ? cs.error
                        : cs.onSurface,
                  ),
                ),
              ),
              if (v.insertedUids.isNotEmpty) ...[
                TextButton(onPressed: onShow, child: const Text('바로 띄우기')),
                TextButton(onPressed: onUndo, child: const Text('되돌리기')),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _MediaBar extends StatefulWidget {
  const _MediaBar({
    required this.media,
    required this.playback,
    required this.onToggle,
    required this.onSeek,
  });

  static const double height = 44;

  final SlideMedia media;
  final ValueListenable<MediaPlayback?> playback;
  final VoidCallback onToggle;
  final ValueChanged<double> onSeek;

  @override
  State<_MediaBar> createState() => _MediaBarState();
}

class _MediaBarState extends State<_MediaBar> {
  // 끄는 동안의 값. 놓을 때만 보낸다 — 끄는 중에 보내면 소리가 드드득 끊긴다.
  double? _dragging;

  static String _time(double seconds) {
    final s = seconds.isFinite ? seconds.round() : 0;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    final mmss =
        '${m.toString().padLeft(h > 0 ? 2 : 1, '0')}:'
        '${sec.toString().padLeft(2, '0')}';
    return h > 0 ? '$h:$mmss' : mmss;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 슬라이더가 포커스를 가져가면 ←/→ 가 슬라이드 대신 슬라이더를 움직인다(리본과 같은 이유).
    return ExcludeFocus(
      child: SizedBox(
        height: _MediaBar.height,
        child: ValueListenableBuilder<MediaPlayback?>(
          valueListenable: widget.playback,
          builder: (context, state, _) {
            final duration = state?.duration ?? 0;
            final canSeek = duration > 0; // 유튜브 생방송·불러오는 중엔 0
            final position = (_dragging ?? state?.position ?? 0)
                .clamp(0.0, canSeek ? duration : 0.0)
                .toDouble();
            void jump(double delta) => widget.onSeek(
              (position + delta).clamp(0.0, duration).toDouble(),
            );
            return Row(
              children: [
                Icon(
                  SlideRenderView.mediaIcon(widget.media.kind),
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
                IconButton(
                  onPressed: canSeek ? () => jump(-10) : null,
                  icon: const Icon(Icons.replay_10_rounded),
                  tooltip: '10초 뒤로',
                ),
                IconButton(
                  onPressed: state == null ? null : widget.onToggle,
                  icon: Icon(
                    state?.playing == true
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                  tooltip: state?.playing == true
                      ? '멈춤 (페이드 아웃 ${widget.media.fadeOut}초)'
                      : '재생 (페이드 인 ${widget.media.fadeIn}초)',
                ),
                IconButton(
                  onPressed: canSeek ? () => jump(10) : null,
                  icon: const Icon(Icons.forward_10_rounded),
                  tooltip: '10초 앞으로',
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    state == null ? '--:--' : _time(position),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: position,
                    max: canSeek ? duration : 1,
                    onChanged: canSeek
                        ? (v) => setState(() => _dragging = v)
                        : null,
                    onChangeEnd: canSeek
                        ? (v) {
                            widget.onSeek(v);
                            // 레이어가 새 위치를 보내오기 전까지 놓은 자리에 둔다.
                            Future.delayed(
                              const Duration(milliseconds: 400),
                              () {
                                if (mounted) setState(() => _dragging = null);
                              },
                            );
                          }
                        : null,
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    state == null
                        ? '재생 준비 중'
                        : canSeek
                        ? _time(duration)
                        : '--:--',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
