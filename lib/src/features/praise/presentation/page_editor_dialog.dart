import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../data/app_logger.dart';
import '../data/background_image_library.dart';
import '../data/page_template_store.dart';
import '../domain/export_style.dart';
import '../domain/page_element.dart';
import '../domain/slide_background.dart';
import 'background_image_gallery.dart';
import 'page_canvas.dart';
import 'page_template_dialog.dart';
import 'style_fields.dart';

/// 편집 창 결과: 페이지 이름(빈칸이면 자동 이름) + 요소 + 구운 PNG + 페이지 배경.
typedef PageEditorResult = ({
  String name,
  List<PageElement> elements,
  String imagePath,
  SlideBackground background,
});

/// '글 상자 추가' 로 넣을 새 글 상자. 고른 글 상자(없으면 마지막 글 상자)의
/// 글꼴·크기·색·굵기·정렬을 이어받고, 글 상자가 없으면 기본값이다.
@visibleForTesting
PageTextElement newTextBox(
  List<PageElement> elements,
  String? selectedId, {
  String text = '',
}) {
  final texts = elements.whereType<PageTextElement>();
  final from =
      texts.where((e) => e.id == selectedId).firstOrNull ?? texts.lastOrNull;
  final box = PageTextElement(
    id: PageElement.newId(),
    rect: const Rect.fromLTWH(0.25, 0.4, 0.5, 0.2),
    text: text,
  );
  return from == null
      ? box
      : box.copyWith(
          fontSize: from.fontSize,
          color: from.color,
          bold: from.bold,
          align: from.align,
          fontFamily: from.fontFamily,
        );
}

/// 이름 칸을 비웠을 때 쓰는 이름: 첫 글 상자 첫 줄 → '슬라이드 편집 페이지'.
String pageAutoName(List<PageElement> elements) {
  for (final e in elements) {
    if (e is PageTextElement) {
      final line = e.text
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty, orElse: () => '');
      if (line.isNotEmpty) return line;
    }
  }
  return '슬라이드 편집 페이지';
}

/// 손잡이 8개. 이름 = 움직이는 변.
enum PageHandle {
  topLeft(movesLeft: true, movesTop: true),
  top(movesTop: true),
  topRight(movesRight: true, movesTop: true),
  right(movesRight: true),
  bottomRight(movesRight: true, movesBottom: true),
  bottom(movesBottom: true),
  bottomLeft(movesLeft: true, movesBottom: true),
  left(movesLeft: true);

  const PageHandle({
    this.movesLeft = false,
    this.movesTop = false,
    this.movesRight = false,
    this.movesBottom = false,
  });

  final bool movesLeft;
  final bool movesTop;
  final bool movesRight;
  final bool movesBottom;

  bool get isCorner => (movesLeft || movesRight) && (movesTop || movesBottom);

  /// 상자 위 자리(0~1).
  Offset get anchor => Offset(
    movesLeft ? 0 : (movesRight ? 1 : 0.5),
    movesTop ? 0 : (movesBottom ? 1 : 0.5),
  );

  MouseCursor get cursor => switch (this) {
    topLeft || bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
    topRight || bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
    left || right => SystemMouseCursors.resizeLeftRight,
    top || bottom => SystemMouseCursors.resizeUpDown,
  };
}

/// [start] 를 [handle] 로 [delta](슬라이드 비율)만큼 끈 결과. 반대쪽 변·모서리는 그대로다.
/// [keepAspect] 면(모서리일 때만) [start] 의 비율을 지킨다. 마지막에 [PageElement.clampRect].
@visibleForTesting
Rect resizePageRect(
  Rect start,
  PageHandle handle,
  Offset delta, {
  bool keepAspect = false,
}) {
  const min = PageElement.minSize;
  var l = start.left, t = start.top, r = start.right, b = start.bottom;
  if (handle.movesLeft) l = math.min(l + delta.dx, r - min);
  if (handle.movesRight) r = math.max(r + delta.dx, l + min);
  if (handle.movesTop) t = math.min(t + delta.dy, b - min);
  if (handle.movesBottom) b = math.max(b + delta.dy, t + min);
  if (keepAspect && handle.isCorner && start.height > 0) {
    final ratio = start.width / start.height;
    var w = r - l, h = b - t;
    // 더 많이 바뀐 쪽을 따라간다.
    if (w / start.width >= h / start.height) {
      h = w / ratio;
    } else {
      w = h * ratio;
    }
    if (w < min) (w, h) = (min, min / ratio);
    if (h < min) (w, h) = (min * ratio, min);
    if (handle.movesLeft) {
      l = r - w;
    } else {
      r = l + w;
    }
    if (handle.movesTop) {
      t = b - h;
    } else {
      b = t + h;
    }
  }
  return PageElement.clampRect(Rect.fromLTRB(l, t, r, b));
}

/// 새 그림 자리: 원래 비율, 슬라이드의 60% 안(키우지는 않음), 가운데에서 [index]×3% 오른쪽 아래.
@visibleForTesting
Rect newImageRect(Size pixels, int index) {
  const w = PageCanvas.width, h = PageCanvas.height;
  final scale = [
    1.0,
    0.6 * w / pixels.width,
    0.6 * h / pixels.height,
  ].reduce(math.min);
  final rw = pixels.width * scale / w, rh = pixels.height * scale / h;
  final shift = 0.03 * index;
  return PageElement.clampRect(
    Rect.fromLTWH((1 - rw) / 2 + shift, (1 - rh) / 2 + shift, rw, rh),
  );
}

/// '원래 비율로': 너비는 두고 높이를 그림 비율에 맞춘다.
@visibleForTesting
Rect originalAspectRect(Rect rect, Size pixels) => PageElement.clampRect(
  Rect.fromLTWH(
    rect.left,
    rect.top,
    rect.width,
    rect.width *
        PageCanvas.width /
        PageCanvas.height *
        pixels.height /
        pixels.width,
  ),
);

/// 편집 창 되돌리기 기록(요소 목록 통째로, 최대 [limit]개).
@visibleForTesting
class PageEditHistory {
  static const int limit = 50;
  final List<List<PageElement>> _undo = [];
  final List<List<PageElement>> _redo = [];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// 바꾸기 직전 상태를 남긴다. 다시 하기 기록은 버린다.
  void record(List<PageElement> before) {
    _undo.add(before);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
  }

  List<PageElement>? undo(List<PageElement> current) {
    if (_undo.isEmpty) return null;
    _redo.add(current);
    return _undo.removeLast();
  }

  List<PageElement>? redo(List<PageElement> current) {
    if (_redo.isEmpty) return null;
    _undo.add(current);
    return _redo.removeLast();
  }
}

/// 슬라이드 편집 페이지 편집 창. 그림·글 상자를 끌어 옮기고 손잡이로 크기를 바꾼다.
/// [확인] 을 누르면 [compose] 로 PNG 를 굽고(실패하면 창이 남는다) 결과를 돌려준다.
class PageEditorDialog extends StatefulWidget {
  const PageEditorDialog({
    super.key,
    this.name = '',
    this.elements,
    this.background,
    required this.style,
    required this.compose,
    required this.readClipboardImage,
    this.templates = const [],
    this.templateMode = false,
  });

  /// 지금 페이지 이름(항목 `sourceName`). 자동 이름과 같으면 이름 칸을 비워 둔다.
  final String name;

  /// null 이면 새 페이지('제목' 글 상자 하나로 시작).
  final List<PageElement>? elements;
  final SlideBackground? background;
  final ExportStyle style;

  /// 요소를 [background] 위에 굽는다.
  final Future<String> Function(
    List<PageElement> elements,
    SlideBackground background,
  )
  compose;

  /// 클립보드 그림 경로(없으면 null). `PythonBridge.clipboardImage`.
  final Future<String?> Function() readClipboardImage;

  /// '페이지 배경' 패널의 '틀 배경' 칩(색·그림만 가져온다). 비면 줄째 숨긴다.
  final List<PageTemplate> templates;

  /// 페이지 틀을 고친다: 이름 칸이 '틀 이름', 틀 칩 없음, 빈 글 상자도 결과에 남긴다
  /// (광고 내용·생일자 이름 자리 — 구운 썸네일에는 안 나온다).
  final bool templateMode;

  @override
  State<PageEditorDialog> createState() => _PageEditorDialogState();
}

class _PageEditorDialogState extends State<PageEditorDialog> {
  static const _pageImages = BackgroundImageLibrary.pages();

  /// 페이지 배경 이미지는 리본 '공통' 탭과 같은 공통 모음에서 고른다(`page_images/` 아님).
  static const _backgroundImages = BackgroundImageLibrary();
  static const _swatches = <(Color, String)>[
    (Color(0xFFFFFFFF), '흰색'),
    (Color(0xFFEDEDED), '밝은 회색'),
    (Color(0xFF9E9E9E), '회색'),
    (Color(0xFF424242), '짙은 회색'),
    (Color(0xFF000000), '검정'),
    (Color(0xFFFFF176), '노랑'),
  ];

  late final bool _isNew = widget.elements == null;
  late final List<PageElement> _initialElements =
      widget.elements ??
      [
        PageTextElement(
          id: PageElement.newId(),
          rect: const Rect.fromLTWH(0.05, 0.06, 0.9, 0.15),
          text: '제목',
          fontSize: 48,
        ),
      ];
  late List<PageElement> _elements = _initialElements;

  /// 페이지 배경(색·그림). 되돌리기에는 넣지 않는다.
  late final SlideBackground _initialBackground =
      widget.background ?? SlideBackground.fromStyle(widget.style);
  late SlideBackground _background = _initialBackground;
  late final String _initialName = widget.name == pageAutoName(_initialElements)
      ? ''
      : widget.name;
  late final _nameController = TextEditingController(text: _initialName);
  final _textController = TextEditingController();
  final _sizeController = TextEditingController();
  final _history = PageEditHistory();

  final _rootFocus = FocusNode(debugLabel: 'page-editor');
  final _canvasFocus = FocusNode(debugLabel: 'page-editor-canvas');
  final _textFocus = FocusNode(debugLabel: 'page-editor-text');

  Map<String, ui.Image> _images = {};
  ui.Image? _backgroundImage;

  /// 배경 그림을 다 읽었는지(읽는 중에는 '파일 없음' 안내를 띄우지 않는다).
  bool _backgroundLoaded = false;
  String? _selectedId;
  String? _hoverId;

  /// 지금 끄는 요소의 시작 자리와 누적 이동(px 이 아니라 비율).
  Rect? _dragStart;
  Offset _dragTotal = Offset.zero;
  bool _dragging = false;

  /// 입력칸·슬라이더 편집 묶음: 포커스가 머무는 동안 되돌리기 기록은 한 번.
  bool _editSession = false;

  bool _pasting = false;
  bool _composing = false;
  String? _message;
  bool _messageIsError = false;
  Timer? _messageTimer;

  @override
  void initState() {
    super.initState();
    _textFocus.addListener(() {
      if (!_textFocus.hasFocus) _editSession = false;
    });
    _loadImages();
    _loadBackgroundImage();
    if (_isNew) {
      _selectedId = _initialElements.first.id;
      _syncFields();
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusText());
    }
  }

  Future<void> _loadImages() async {
    final loaded = await PageComposer.loadImages([
      for (final e in _elements)
        if (e is PageImageElement) e.path,
    ]);
    if (!mounted) {
      for (final image in loaded.values) {
        image.dispose();
      }
      return;
    }
    setState(() => _images = {..._images, ...loaded});
  }

  /// 지금 배경 그림을 읽는다. 그 사이 배경이 또 바뀌었으면 읽은 것을 버린다.
  Future<void> _loadBackgroundImage() async {
    final path = _background.imagePath;
    final image = path == null || path.isEmpty
        ? null
        : (await PageComposer.loadImages([path]))[path];
    if (!mounted || _background.imagePath != path) {
      image?.dispose();
      return;
    }
    _disposeAfterFrame(_backgroundImage);
    setState(() {
      _backgroundImage = image;
      _backgroundLoaded = true;
    });
  }

  /// 지난 프레임이 아직 그리고 있을 수 있어 다음 프레임 뒤에 놓는다.
  void _disposeAfterFrame(ui.Image? image) {
    if (image == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
  }

  void _setBackground(SlideBackground next) {
    final reload = next.imagePath != _background.imagePath;
    setState(() {
      _background = next;
      if (reload) {
        _disposeAfterFrame(_backgroundImage);
        _backgroundImage = null;
        _backgroundLoaded = false;
      }
    });
    if (reload) _loadBackgroundImage();
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    for (final image in {..._images.values, ?_backgroundImage}) {
      image.dispose();
    }
    _images.clear(); // 닫힌 뒤 끝나는 _addImageFiles 가 두 번 해제하지 않게
    _nameController.dispose();
    _textController.dispose();
    _sizeController.dispose();
    _rootFocus.dispose();
    _canvasFocus.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  // ── 상태 ────────────────────────────────────────────────────────────

  PageElement? get _selected =>
      _elements.where((e) => e.id == _selectedId).firstOrNull;

  int get _selectedIndex => _elements.indexWhere((e) => e.id == _selectedId);

  bool get _dirty =>
      !listEquals(_elements, _initialElements) ||
      _background != _initialBackground ||
      _nameController.text.trim() != _initialName;

  bool get _inTextField =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  bool get _isMac => Platform.isMacOS;

  /// 요소 목록을 바꾼다. [record] 면 바꾸기 전 상태를 되돌리기에 남긴다.
  void _commit(List<PageElement> next, {bool record = true}) {
    if (record) _history.record(_elements);
    setState(() => _elements = next);
  }

  void _replace(PageElement element, {bool record = true}) => _commit([
    for (final e in _elements) e.id == element.id ? element : e,
  ], record: record);

  /// 입력칸·슬라이더처럼 연달아 바뀌는 값: 묶음 첫 변경에만 기록한다.
  void _replaceInSession(PageElement element) {
    final record = !_editSession;
    _editSession = true;
    _replace(element, record: record);
  }

  void _select(String? id) {
    _editSession = false;
    setState(() => _selectedId = id);
    _syncFields();
  }

  /// 고른 글 상자 값을 입력칸에 옮긴다(고르기·되돌리기 뒤).
  void _syncFields() {
    final e = _selected;
    if (e is PageTextElement) {
      if (_textController.text != e.text) _textController.text = e.text;
      _sizeController.text = e.fontSize.round().toString();
    }
  }

  void _focusText() {
    if (_selected is! PageTextElement) return;
    _textFocus.requestFocus();
    _textController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _textController.text.length,
    );
  }

  void _showMessage(String text, {bool error = false, bool autoClear = false}) {
    _messageTimer?.cancel();
    setState(() {
      _message = text;
      _messageIsError = error;
    });
    if (autoClear) {
      _messageTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _message = null);
      });
    }
  }

  // ── 넣기 ────────────────────────────────────────────────────────────

  /// 그림 파일들을 `page_images/` 로 복사해 요소로 넣는다. 못 읽은 파일은 이름을 알린다.
  Future<void> _addImageFiles(List<String> sources) async {
    final added = <PageElement>[];
    final failed = <String>[];
    for (final source in sources) {
      try {
        final copy = await _pageImages.register(source);
        final image = (await PageComposer.loadImages([copy]))[copy];
        if (image == null) {
          failed.add(p.basename(source));
          continue;
        }
        _images[copy] = image;
        added.add(
          PageImageElement(
            id: PageElement.newId(),
            rect: newImageRect(
              Size(image.width.toDouble(), image.height.toDouble()),
              added.length,
            ),
            path: copy,
          ),
        );
      } catch (e, st) {
        await AppLogger.instance.error('[page] 그림 넣기 실패: $source', e, st);
        failed.add(p.basename(source));
      }
    }
    if (!mounted) {
      // 닫힌 뒤 넣은 그림은 dispose 가 못 봤다(그 전 것은 dispose 가 해제하고 비웠다).
      for (final e in added) {
        _images.remove((e as PageImageElement).path)?.dispose();
      }
      return;
    }
    if (added.isNotEmpty) {
      _commit([..._elements, ...added]);
      _select(added.last.id);
      _canvasFocus.requestFocus();
    }
    if (failed.isNotEmpty) {
      _showMessage(
        '그림을 읽지 못했습니다: ${failed.first}'
        '${failed.length > 1 ? ' 외 ${failed.length - 1}개' : ''}',
        error: true,
      );
    }
  }

  Future<void> _pickImages() async {
    await FilePicker.skipEntitlementsChecks();
    final picked = await FilePicker.pickFiles(
      dialogTitle: '그림 추가',
      type: FileType.custom,
      allowedExtensions: BackgroundImageLibrary.pageImageExtensions,
      allowMultiple: true,
    );
    final paths = picked?.paths.whereType<String>().toList() ?? const [];
    if (paths.isNotEmpty) await _addImageFiles(paths);
  }

  /// 그림이 있으면 그림, 없으면 글자를 새 글 상자로.
  Future<void> _paste() async {
    if (_pasting || _composing) return;
    setState(() => _pasting = true);
    var imageError = false;
    try {
      String? path;
      try {
        path = await widget.readClipboardImage();
      } catch (e, st) {
        // 그림을 못 읽어도 글자가 있으면 글 상자로 넣는다.
        await AppLogger.instance.error('[page] 클립보드 그림 읽기 실패', e, st);
        imageError = true;
      }
      if (path != null) {
        // macOS 는 늘 같은 임시 파일이라 바로 복사해 둔다(_addImageFiles 가 register).
        await _addImageFiles([path]);
        return;
      }
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (!mounted) return;
      if (text != null && text.trim().isNotEmpty) {
        _addTextBox(text: text.trim());
        return;
      }
      if (imageError) {
        _showMessage(
          '클립보드 그림을 읽지 못했습니다. 그림 파일로 저장한 뒤 [그림 추가]로 넣어 주세요.',
          error: true,
        );
      } else {
        _showMessage(
          '붙여 넣을 그림이 없습니다. 화면을 캡처하거나 그림을 복사한 뒤 다시 붙여 넣어 주세요.',
          autoClear: true,
        );
      }
    } finally {
      if (mounted) setState(() => _pasting = false);
    }
  }

  void _addTextBox({String text = ''}) {
    final box = newTextBox(_elements, _selectedId, text: text);
    _commit([..._elements, box]);
    _select(box.id);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusText());
  }

  // ── 편집 ────────────────────────────────────────────────────────────

  void _duplicate() {
    final e = _selected;
    if (e == null) return;
    final copy = e.copyWith(
      id: PageElement.newId(),
      rect: PageElement.clampRect(e.rect.shift(const Offset(0.02, 0.02))),
    );
    _commit([..._elements, copy]);
    _select(copy.id);
  }

  void _delete() {
    if (_selected == null) return;
    _commit([
      for (final e in _elements)
        if (e.id != _selectedId) e,
    ]);
    _select(null);
  }

  /// 순서 바꾸기. [to] = 새 자리(0 = 맨 뒤).
  void _reorder(int to) {
    final from = _selectedIndex;
    if (from < 0) return;
    to = to.clamp(0, _elements.length - 1);
    if (to == from) return;
    final next = [..._elements];
    next.insert(to, next.removeAt(from));
    _commit(next);
  }

  void _undo() {
    final prev = _history.undo(_elements);
    if (prev == null) return;
    _applyHistory(prev);
  }

  void _redo() {
    final next = _history.redo(_elements);
    if (next == null) return;
    _applyHistory(next);
  }

  void _applyHistory(List<PageElement> elements) {
    _editSession = false;
    setState(() {
      _elements = elements;
      if (_selected == null) _selectedId = null;
    });
    _syncFields();
  }

  void _nudge(Offset delta, {bool resize = false}) {
    final e = _selected;
    if (e == null) return;
    final rect = resize
        ? resizePageRect(e.rect, PageHandle.bottomRight, delta)
        : PageElement.clampRect(e.rect.shift(delta));
    _replace(e.copyWith(rect: rect));
  }

  void _cycleSelection(bool backward) {
    if (_elements.isEmpty) return;
    final i = _selectedIndex;
    final n = _elements.length;
    _select(_elements[(i + (backward ? -1 : 1) + n) % n].id);
  }

  // ── 키 ──────────────────────────────────────────────────────────────

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || _composing) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final cmd = _isMac ? keyboard.isMetaPressed : keyboard.isControlPressed;
    final shift = keyboard.isShiftPressed;
    final inText = _inTextField;

    if (cmd) {
      if (key == LogicalKeyboardKey.keyV) {
        if (inText) return KeyEventResult.ignored;
        if (event is KeyDownEvent) _paste();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyD) {
        if (event is KeyDownEvent) _duplicate();
        return KeyEventResult.handled;
      }
      final redo =
          (key == LogicalKeyboardKey.keyZ && shift) ||
          (!_isMac && key == LogicalKeyboardKey.keyY);
      if (key == LogicalKeyboardKey.keyZ || redo) {
        if (inText) return KeyEventResult.ignored;
        redo ? _redo() : _undo();
        return KeyEventResult.handled;
      }
      // Shift 와 같이 누르면 글자가 `{` `}` 로 바뀌므로 자리로 본다.
      final front = event.physicalKey == PhysicalKeyboardKey.bracketRight;
      final back = event.physicalKey == PhysicalKeyboardKey.bracketLeft;
      if (front || back) {
        if (inText) return KeyEventResult.ignored;
        final i = _selectedIndex;
        if (front) _reorder(shift ? _elements.length - 1 : i + 1);
        if (back) _reorder(shift ? 0 : i - 1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.escape) {
      if (event is! KeyDownEvent) return KeyEventResult.handled;
      if (inText) {
        _canvasFocus.requestFocus();
      } else if (_selectedId != null) {
        _select(null);
        _canvasFocus.requestFocus();
      } else {
        _requestClose();
      }
      return KeyEventResult.handled;
    }
    if (inText || !_canvasFocus.hasPrimaryFocus) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      if (event is KeyDownEvent) _delete();
      return KeyEventResult.handled;
    }
    final step = shift ? 0.05 : 0.01;
    final arrow = switch (key) {
      LogicalKeyboardKey.arrowLeft => Offset(-step, 0),
      LogicalKeyboardKey.arrowRight => Offset(step, 0),
      LogicalKeyboardKey.arrowUp => Offset(0, -step),
      LogicalKeyboardKey.arrowDown => Offset(0, step),
      _ => null,
    };
    if (arrow != null) {
      _nudge(
        keyboard.isAltPressed ? arrow / step * 0.01 : arrow,
        resize: keyboard.isAltPressed,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab && _selectedId != null) {
      if (event is KeyDownEvent) _cycleSelection(shift);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_selected is PageTextElement) {
        _focusText();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.space) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  // ── 닫기·확인 ───────────────────────────────────────────────────────

  Future<void> _requestClose() async {
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('고친 내용을 버릴까요?'),
          content: const Text('저장하지 않은 변경이 있습니다.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('계속 편집'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('버리기'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    // 굽는 중에 닫아도 굽기는 끝까지 돌고 결과는 버린다.
    _composing = false;
    Navigator.of(context).pop();
  }

  Future<void> _confirm() async {
    if (_composing) return;
    // 빈 글 상자는 편집 창에서만 보이는 자리라 뺀다.
    final elements = [
      for (final e in _elements)
        if (e is! PageTextElement || e.text.trim().isNotEmpty) e,
    ];
    setState(() {
      _composing = true;
      _message = null;
    });
    try {
      final path = await widget.compose(elements, _background);
      if (!mounted || !_composing) return;
      Navigator.of(context).pop<PageEditorResult>((
        name: _nameController.text.trim().isEmpty
            ? pageAutoName(elements)
            : _nameController.text.trim(),
        elements: widget.templateMode ? _elements : elements,
        imagePath: path,
        background: _background,
      ));
    } catch (e, st) {
      await AppLogger.instance.error('[page] 편집 페이지 굽기 실패', e, st);
      if (!mounted) return;
      setState(() => _composing = false);
      _showMessage('페이지 그림을 만들지 못했습니다. 다시 확인을 눌러 주세요.', error: true);
    }
  }

  // ── 화면 ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final screen = MediaQuery.sizeOf(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: Dialog(
        insetPadding: EdgeInsets.symmetric(
          horizontal: screen.width * 0.025,
          vertical: screen.height * 0.025,
        ),
        clipBehavior: Clip.antiAlias,
        child: Focus(
          focusNode: _rootFocus,
          onKeyEvent: _onKey,
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Text(
                    _isNew ? '슬라이드 편집 페이지' : '슬라이드 편집 페이지 수정',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _blockWhileComposing(
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(1),
                    child: _toolbar(cs),
                  ),
                ),
                Divider(height: 1, color: cs.outlineVariant),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _blockWhileComposing(
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(2),
                            child: _canvasArea(cs),
                          ),
                        ),
                      ),
                      VerticalDivider(width: 1, color: cs.outlineVariant),
                      SizedBox(
                        width: 280,
                        child: _blockWhileComposing(
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(3),
                            child: _propertiesPanel(cs),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: cs.outlineVariant),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(4),
                  child: _bottomBar(cs),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _blockWhileComposing(Widget child) => IgnorePointer(
    ignoring: _composing,
    child: ExcludeFocus(excluding: _composing, child: child),
  );

  Widget _toolbar(ColorScheme cs) {
    final mod = _isMac ? '⌘' : 'Ctrl+';
    final selected = _selectedIndex >= 0;
    final atFront = _selectedIndex == _elements.length - 1;
    final atBack = _selectedIndex == 0;
    Widget button(IconData icon, String tooltip, VoidCallback? onPressed) =>
        IconButton(
          icon: Icon(icon, size: 20),
          tooltip: tooltip,
          onPressed: onPressed,
        );
    Widget divider() => SizedBox(
      height: 24,
      child: VerticalDivider(width: 17, color: cs.outlineVariant),
    );
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            button(
              Icons.add_photo_alternate_outlined,
              '그림 추가 (파일)',
              _pickImages,
            ),
            _pasting
                ? const SizedBox(
                    width: 40,
                    child: Center(
                      child: SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : button(
                    Icons.content_paste_rounded,
                    '붙여 넣기 (⌘V / Ctrl+V)',
                    _paste,
                  ),
            button(
              Icons.text_fields_rounded,
              '글 상자 추가 (고른 글 상자와 같은 글꼴·색)',
              _addTextBox,
            ),
            divider(),
            button(
              Icons.copy_all_outlined,
              '복제 (${mod}D)',
              selected ? _duplicate : null,
            ),
            button(
              Icons.delete_outline_rounded,
              '삭제 (Delete)',
              selected ? _delete : null,
            ),
            divider(),
            button(
              Icons.flip_to_front_outlined,
              '맨 앞으로 ($mod${_isMac ? '⇧' : 'Shift+'}])',
              selected && !atFront
                  ? () => _reorder(_elements.length - 1)
                  : null,
            ),
            button(
              Icons.arrow_upward_rounded,
              '앞으로 ($mod])',
              selected && !atFront ? () => _reorder(_selectedIndex + 1) : null,
            ),
            button(
              Icons.arrow_downward_rounded,
              '뒤로 ($mod[)',
              selected && !atBack ? () => _reorder(_selectedIndex - 1) : null,
            ),
            button(
              Icons.flip_to_back_outlined,
              '맨 뒤로 ($mod${_isMac ? '⇧' : 'Shift+'}[)',
              selected && !atBack ? () => _reorder(0) : null,
            ),
            divider(),
            button(
              Icons.undo_rounded,
              '되돌리기 (${mod}Z)',
              _history.canUndo ? _undo : null,
            ),
            button(
              Icons.redo_rounded,
              _isMac ? '다시 하기 (⌘⇧Z)' : '다시 하기 (Ctrl+Y)',
              _history.canRedo ? _redo : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _canvasArea(ColorScheme cs) {
    final images = _elements.whereType<PageImageElement>().length;
    final texts = _elements.length - images;
    return ColoredBox(
      color: cs.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: GestureDetector(
              // 틀 밖 회색을 눌러도 선택을 푼다. onTapDown 이 아니라 onTap — 요소를 꾹 누르면
              // 이쪽 tapDown 도 불려 방금 고른 것이 풀린다.
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _select(null);
                _canvasFocus.requestFocus();
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: LayoutBuilder(
                      builder: (context, box) => _canvas(cs, box.biggest),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              '그림 $images · 글 상자 $texts    '
              '끌어서 옮기고, 모서리를 끌어 크기를 바꿉니다. Shift: 비율 풀기    '
              '빈 곳 누르기: 페이지 배경',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _canvas(ColorScheme cs, Size size) {
    Rect px(Rect r) => Rect.fromLTWH(
      r.left * size.width,
      r.top * size.height,
      r.width * size.width,
      r.height * size.height,
    );
    final selected = _selected;
    return Focus(
      focusNode: _canvasFocus,
      autofocus: !_isNew,
      child: ListenableBuilder(
        listenable: _canvasFocus,
        builder: (context, child) => DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: Border.all(
              color: _canvasFocus.hasFocus ? cs.secondary : cs.outlineVariant,
              width: _canvasFocus.hasFocus ? 2 : 1,
            ),
          ),
          child: child,
        ),
        child: Semantics(
          label: '슬라이드 편집 영역, 요소 ${_elements.length}개',
          container: true,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: PageCanvas(
                  elements: _elements,
                  backgroundColor: _background.color,
                  backgroundImage: _backgroundImage,
                  images: _images,
                ),
              ),
              if (_elements.isEmpty)
                Center(
                  child: IgnorePointer(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 40,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(height: 8),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: cs.surface.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            child: Text(
                              '그림을 추가하거나 ${_isMac ? '⌘V' : 'Ctrl+V'} 로 붙여 넣으세요',
                              style: TextStyle(color: cs.onSurface),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // 요소 위 누르기·끌기 자리. 뒤 요소가 위라 목록 순서대로 쌓으면 위 요소가 먼저 눌린다.
              for (final e in _elements)
                Positioned.fromRect(
                  rect: px(e.rect),
                  child: _elementOverlay(cs, e, size),
                ),
              if (selected != null)
                ..._handles(cs, selected, px(selected.rect), size),
            ],
          ),
        ),
      ),
    );
  }

  Widget _elementOverlay(ColorScheme cs, PageElement e, Size size) {
    final isSelected = e.id == _selectedId;
    final missingImage = e is PageImageElement && !_images.containsKey(e.path);
    final emptyText = e is PageTextElement && e.text.trim().isEmpty;
    return Semantics(
      label: switch (e) {
        PageImageElement(:final path) =>
          '그림: ${BackgroundImageLibrary.displayName(path)}',
        PageTextElement(:final text) =>
          '글 상자: ${text.length > 20 ? text.substring(0, 20) : text}',
      },
      selected: isSelected,
      child: MouseRegion(
        cursor: _dragging && isSelected
            ? SystemMouseCursors.grabbing
            : SystemMouseCursors.move,
        onEnter: (_) => setState(() => _hoverId = e.id),
        onExit: (_) {
          if (_hoverId == e.id) setState(() => _hoverId = null);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) {
            if (!isSelected) _select(e.id);
            _canvasFocus.requestFocus();
          },
          onDoubleTap: e is PageTextElement ? _focusText : null,
          onPanStart: (_) {
            if (!isSelected) _select(e.id);
            _canvasFocus.requestFocus();
            _history.record(_elements);
            setState(() {
              _dragStart = e.rect;
              _dragTotal = Offset.zero;
              _dragging = true;
            });
          },
          onPanUpdate: (d) {
            final start = _dragStart;
            final current = _selected;
            if (start == null || current == null) return;
            _dragTotal += Offset(
              d.delta.dx / size.width,
              d.delta.dy / size.height,
            );
            _replace(
              current.copyWith(
                rect: PageElement.clampRect(start.shift(_dragTotal)),
              ),
              record: false,
            );
          },
          onPanEnd: (_) => setState(() {
            _dragStart = null;
            _dragging = false;
          }),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (emptyText)
                CustomPaint(
                  painter: _DashedBorderPainter(cs.outline),
                  child: Center(
                    child: Text(
                      '글 상자',
                      style: TextStyle(fontSize: 12, color: cs.outline),
                    ),
                  ),
                ),
              if (missingImage)
                ColoredBox(
                  color: cs.surfaceContainerHigh,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.broken_image_outlined,
                          color: cs.onSurfaceVariant,
                        ),
                        Text(
                          '그림 없음',
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (isSelected)
                // 흰·검정 배경 모두 보이게: 바깥 surface + 안쪽 primary.
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: cs.surface,
                        width: 3,
                        strokeAlign: BorderSide.strokeAlignOutside,
                      ),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: cs.primary, width: 1.5),
                      ),
                    ),
                  ),
                )
              else if (_hoverId == e.id)
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: cs.primary),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _handles(ColorScheme cs, PageElement e, Rect box, Size size) {
    const hit = 20.0, mark = 9.0;
    // 상자가 좁으면 변 손잡이는 모서리와 겹치니 숨긴다.
    final showEdges = box.width >= 24 && box.height >= 24;
    return [
      for (final h in PageHandle.values)
        if (h.isCorner || showEdges)
          Positioned(
            left: box.left + box.width * h.anchor.dx - hit / 2,
            top: box.top + box.height * h.anchor.dy - hit / 2,
            width: hit,
            height: hit,
            child: MouseRegion(
              cursor: h.cursor,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) {
                  _history.record(_elements);
                  _dragStart = e.rect;
                  _dragTotal = Offset.zero;
                },
                onPanUpdate: (d) {
                  final start = _dragStart;
                  final current = _selected;
                  if (start == null || current == null) return;
                  _dragTotal += Offset(
                    d.delta.dx / size.width,
                    d.delta.dy / size.height,
                  );
                  _replace(
                    current.copyWith(
                      rect: resizePageRect(
                        start,
                        h,
                        _dragTotal,
                        keepAspect:
                            current is PageImageElement &&
                            !HardwareKeyboard.instance.isShiftPressed,
                      ),
                    ),
                    record: false,
                  );
                },
                onPanEnd: (_) => _dragStart = null,
                child: Center(
                  child: Container(
                    width: mark,
                    height: mark,
                    decoration: BoxDecoration(
                      color: cs.surface,
                      border: Border.all(color: cs.primary, width: 1.5),
                    ),
                  ),
                ),
              ),
            ),
          ),
    ];
  }

  Widget _propertiesPanel(ColorScheme cs) {
    final e = _selected;
    final label = Theme.of(context).textTheme.labelMedium;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: switch (e) {
          null => [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: widget.templateMode ? '틀 이름' : '페이지 이름',
                hintText: pageAutoName(_elements),
                helperText: widget.templateMode
                    ? '새 페이지 추가 메뉴에 보이는 이름입니다.'
                    : '콘티 목록에 보이는 이름입니다. 관객 화면에는 나오지 않습니다.',
                helperMaxLines: 3,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _confirm(),
            ),
            const SizedBox(height: 16),
            Text(
              '요소를 누르면 여기서 고칩니다.',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            ..._backgroundProperties(cs, label),
          ],
          PageTextElement() => _textProperties(cs, e, label),
          PageImageElement() => _imageProperties(cs, e, label),
        },
      ),
    );
  }

  /// 미선택 패널의 '페이지 배경': 색 + 공통 배경 이미지 모음.
  List<Widget> _backgroundProperties(ColorScheme cs, TextStyle? label) {
    final missing =
        _background.hasImage && _backgroundLoaded && _backgroundImage == null;
    return [
      const SizedBox(height: 20),
      Divider(color: cs.outlineVariant),
      Text('페이지 배경', style: label),
      const SizedBox(height: 6),
      if (!widget.templateMode && widget.templates.isNotEmpty) ...[
        PageTemplateChips(
          templates: widget.templates,
          current: _background,
          hint: '틀의 배경 색·그림만 가져옵니다. 글 상자는 그대로입니다.',
          onSelected: (t) {
            final d = usableTemplateDesign(t.design);
            _setBackground(
              _background.copyWith(color: d.color, imagePath: d.imagePath),
            );
          },
        ),
        const SizedBox(height: 12),
      ],
      Text('색', style: label),
      const SizedBox(height: 6),
      ColorField(
        dialogTitle: '배경 색',
        color: _background.color,
        colors: [for (final (c, _) in _swatches) c],
        onSelected: (color) =>
            _setBackground(_background.copyWith(color: color)),
      ),
      const SizedBox(height: 12),
      Text('배경 이미지 (공통 모음)', style: label),
      const SizedBox(height: 6),
      BackgroundImageGallery(
        library: _backgroundImages,
        selected: _background.hasImage ? _background.imagePath : null,
        emptyColor: _background.color,
        onChanged: (path) =>
            _setBackground(_background.copyWith(imagePath: path)),
      ),
      if (missing) ...[
        const SizedBox(height: 8),
        Text(
          "배경 이미지 파일을 찾지 못했습니다. 다른 이미지를 고르거나 '없음'을 눌러 주세요.",
          style: TextStyle(fontSize: 12, color: cs.error),
        ),
      ],
      const SizedBox(height: 8),
      Text(
        '이미지는 화면을 가득 채우게 잘려 들어갑니다.',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
    ];
  }

  List<Widget> _textProperties(
    ColorScheme cs,
    PageTextElement e,
    TextStyle? label,
  ) {
    return [
      TextField(
        controller: _textController,
        focusNode: _textFocus,
        minLines: 3,
        maxLines: 10,
        decoration: const InputDecoration(
          labelText: '글',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: (text) {
          final current = _selected;
          if (current is PageTextElement) {
            _replaceInSession(current.copyWith(text: text));
          }
        },
      ),
      const SizedBox(height: 16),
      Text('글자 크기 ${e.fontSize.round()}pt', style: label),
      Row(
        children: [
          Expanded(
            child: Slider(
              value: e.fontSize.clamp(10, 120).toDouble(),
              min: 10,
              max: 120,
              onChangeStart: (_) => _editSession = false,
              onChanged: (v) {
                _replaceInSession(e.copyWith(fontSize: v.roundToDouble()));
                _sizeController.text = v.round().toString();
              },
              onChangeEnd: (_) => _editSession = false,
            ),
          ),
          SizedBox(
            width: 56,
            child: TextField(
              controller: _sizeController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (v) {
                final n = double.tryParse(v);
                if (n == null) return;
                _replace(
                  e.copyWith(
                    fontSize: n
                        .clamp(
                          PageTextElement.minFontSize,
                          PageTextElement.maxFontSize,
                        )
                        .toDouble(),
                  ),
                );
                _syncFields();
              },
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Text('색', style: label),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final (color, name) in _swatches)
            Tooltip(
              message: '$name ${colorToHex(color)}',
              child: InkResponse(
                radius: 14,
                onTap: () => _replace(e.copyWith(color: color)),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: color.toARGB32() == e.color.toARGB32()
                          ? cs.primary
                          : cs.outlineVariant,
                      width: color.toARGB32() == e.color.toARGB32() ? 2 : 1,
                    ),
                  ),
                ),
              ),
            ),
          TextButton(
            onPressed: () async {
              final picked = await showDialog<Color>(
                context: context,
                builder: (_) => HexColorDialog(
                  title: '글자 색',
                  initialColor: e.color,
                  colors: [for (final (c, _) in _swatches) c],
                  inputFormatter: hexInputFormatter,
                ),
              );
              final current = _selected;
              if (picked != null && current is PageTextElement) {
                _replace(current.copyWith(color: picked));
              }
            },
            child: const Text('직접 고르기'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          IconButton(
            icon: const Icon(Icons.format_bold_rounded),
            tooltip: '굵게',
            isSelected: e.bold,
            style: IconButton.styleFrom(
              backgroundColor: e.bold ? cs.secondaryContainer : null,
              foregroundColor: e.bold ? cs.onSecondaryContainer : null,
            ),
            onPressed: () => _replace(e.copyWith(bold: !e.bold)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SegmentedButton<TextAlign>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: TextAlign.left,
                  icon: Icon(Icons.format_align_left_rounded, size: 18),
                  tooltip: '왼쪽',
                ),
                ButtonSegment(
                  value: TextAlign.center,
                  icon: Icon(Icons.format_align_center_rounded, size: 18),
                  tooltip: '가운데',
                ),
                ButtonSegment(
                  value: TextAlign.right,
                  icon: Icon(Icons.format_align_right_rounded, size: 18),
                  tooltip: '오른쪽',
                ),
              ],
              selected: {e.align},
              onSelectionChanged: (s) => _replace(e.copyWith(align: s.first)),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Text('글꼴', style: label),
      const SizedBox(height: 6),
      FontFamilyPicker(
        selected: e.fontFamily,
        onChanged: (f) => _replace(e.copyWith(fontFamily: f)),
      ),
      if (_textOverflows(e)) ...[
        const SizedBox(height: 12),
        Text(
          '글이 상자보다 깁니다. 상자를 키우거나 글자를 줄여 주세요.',
          style: TextStyle(fontSize: 12, color: cs.error),
        ),
      ],
    ];
  }

  /// 굽기와 같은 글자 배치(1920x1080)로 재서 상자 높이를 넘는지.
  bool _textOverflows(PageTextElement e) {
    if (e.text.isEmpty) return false;
    final painter = TextPainter(
      text: TextSpan(
        text: e.text,
        style: TextStyle(
          fontFamily: e.fontFamily,
          fontSize: e.fontSize * PageCanvas.fontScale,
          fontWeight: e.bold ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      textAlign: e.align,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: e.rect.width * PageCanvas.width);
    final over = painter.height > e.rect.height * PageCanvas.height + 0.5;
    painter.dispose();
    return over;
  }

  List<Widget> _imageProperties(
    ColorScheme cs,
    PageImageElement e,
    TextStyle? label,
  ) {
    final image = _images[e.path];
    return [
      Text('그림', style: label),
      const SizedBox(height: 4),
      Text(
        BackgroundImageLibrary.displayName(e.path),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        icon: const Icon(Icons.aspect_ratio_rounded, size: 18),
        label: const Text('원래 비율로'),
        onPressed: image == null
            ? null
            : () => _replace(
                e.copyWith(
                  rect: originalAspectRect(
                    e.rect,
                    Size(image.width.toDouble(), image.height.toDouble()),
                  ),
                ),
              ),
      ),
      if (image == null) ...[
        const SizedBox(height: 12),
        Text(
          '그림 파일을 찾지 못했습니다. 지우고 다시 넣어 주세요.',
          style: TextStyle(fontSize: 12, color: cs.error),
        ),
      ],
    ];
  }

  Widget _bottomBar(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _composing ? '페이지를 만드는 중…' : (_message ?? ''),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: _messageIsError && !_composing
                    ? cs.error
                    : cs.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(onPressed: _requestClose, child: const Text('취소')),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _composing ? null : _confirm,
            child: _composing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('확인'),
          ),
        ],
      ),
    );
  }
}

/// 빈 글 상자 자리(편집 창에서만).
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    const dash = 5.0, gap = 4.0;
    void line(Offset a, Offset b) {
      final length = (b - a).distance;
      final dir = (b - a) / length;
      for (var d = 0.0; d < length; d += dash + gap) {
        canvas.drawLine(
          a + dir * d,
          a + dir * math.min(d + dash, length),
          paint,
        );
      }
    }

    final r = Offset.zero & size;
    line(r.topLeft, r.topRight);
    line(r.topRight, r.bottomRight);
    line(r.bottomRight, r.bottomLeft);
    line(r.bottomLeft, r.topLeft);
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}
