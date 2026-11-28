import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
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
import 'page_editor_ribbon.dart';
import 'page_rich_text.dart';
import 'page_template_dialog.dart';
import 'page_text_editor.dart';
import 'style_fields.dart';

/// 편집 창 결과: 페이지 이름(빈칸이면 자동 이름) + 요소 + 구운 PNG + 페이지 배경.
/// [imagePaths] = 클릭 단계마다 한 장([pageSteps], 애니메이션이 없으면 한 장). 틀 모드는 단계를 무시한 한 장(모든 요소, 썸네일).
typedef PageEditorResult = ({
  String name,
  List<PageElement> elements,
  List<String> imagePaths,
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
  final texts = elements.whereType<PageTextElement>().where(
    (e) => e is! PageShapeElement,
  );
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

/// '도형 ▾' 로 넣을 새 도형: 가운데 기본 크기(선·화살표는 가로선). 고른(없으면 마지막) 도형의
/// 채우기·테두리·글자 서식을 이어받고, 도형이 없으면 흰 채우기·테두리 없음·검정 40pt 가운데.
/// 선·화살표는 테두리가 없으면 안 보이니 흰 선으로 둔다.
@visibleForTesting
PageShapeElement newShape(
  List<PageElement> elements,
  String? selectedId,
  PageShapeKind kind,
) {
  // 선끼리·면 도형끼리만 이어받는다(선의 흰 테두리가 사각형으로 넘어가지 않게).
  final shapes = elements.whereType<PageShapeElement>().where(
    (e) => e.kind.isLine == kind.isLine,
  );
  final from =
      shapes.where((e) => e.id == selectedId).firstOrNull ?? shapes.lastOrNull;
  const w = 0.2, h = w * 16 / 9; // 화면에서 정사각형
  var shape = PageShapeElement(
    id: PageElement.newId(),
    rect: kind.isLine
        ? const Rect.fromLTWH(0.35, 0.5, 0.3, 0)
        : const Rect.fromLTWH(0.5 - w / 2, 0.5 - h / 2, w, h),
    kind: kind,
  );
  if (from != null) {
    shape = shape.copyWith(
      fill: from.fill,
      fillAlpha: from.fillAlpha,
      stroke: from.stroke,
      strokeWidth: from.strokeWidth,
      fontSize: from.fontSize,
      color: from.color,
      bold: from.bold,
      align: from.align,
      fontFamily: from.fontFamily,
      valign: from.valign,
    );
  }
  return kind.isLine && shape.stroke == null
      ? shape.copyWith(stroke: Colors.white)
      : shape;
}

/// 리본 도형 서식 하나를 도형에 적용한다. 선·화살표는 채우기·세로 맞춤이 없고 테두리를 '없음'으로 못 한다
/// (안 보이게 되니까) — 그런 값은 그대로 둔다.
@visibleForTesting
PageShapeElement applyShapeFormat(
  PageShapeElement e,
  String key,
  Object? value,
) {
  final line = e.kind.isLine;
  return switch (key) {
    'fill' when !line => e.copyWith(fill: value as Color?),
    'fill_alpha' when !line => e.copyWith(
      fillAlpha: (value as double).clamp(0.0, 1.0),
    ),
    'stroke' when value != null || !line => e.copyWith(stroke: value as Color?),
    'stroke_width' => e.copyWith(
      strokeWidth: (value as double).clamp(
        0.0,
        PageShapeElement.maxStrokeWidth,
      ),
    ),
    'valign' when !line => e.copyWith(valign: value as PageVAlign),
    _ => e,
  };
}

/// 빈 곳 끌기 범위([range], 슬라이드 비율)에 걸친 요소 id(모르는 요소 빼고, 목록 순서).
@visibleForTesting
List<String> pageElementsInRange(List<PageElement> elements, Rect range) => [
  for (final e in elements)
    if (e is! PageUnknownElement && e.rect.overlaps(range)) e.id,
];

/// 고른 요소들([ids])을 맞춘 목록. 하나면 슬라이드(0~1) 기준, 여럿이면 고른 것을 모두 감싸는 범위 기준.
@visibleForTesting
List<PageElement> alignPageElements(
  List<PageElement> elements,
  Set<String> ids,
  PageAlign align,
) {
  final picked = [
    for (final e in elements)
      if (ids.contains(e.id)) e,
  ];
  if (picked.isEmpty) return elements;
  final ref = picked.length == 1
      ? const Rect.fromLTWH(0, 0, 1, 1)
      : picked.map((e) => e.rect).reduce((a, b) => a.expandToInclude(b));
  return [
    for (final e in elements)
      if (!ids.contains(e.id))
        e
      else
        e.copyWith(
          rect: e.fitRect(
            e.rect.translate(
              switch (align) {
                PageAlign.left => ref.left - e.rect.left,
                PageAlign.center => ref.center.dx - e.rect.center.dx,
                PageAlign.right => ref.right - e.rect.right,
                _ => 0,
              },
              switch (align) {
                PageAlign.top => ref.top - e.rect.top,
                PageAlign.middle => ref.center.dy - e.rect.center.dy,
                PageAlign.bottom => ref.bottom - e.rect.bottom,
                _ => 0,
              },
            ),
          ),
        ),
  ];
}

/// 이름 칸을 비웠을 때 쓰는 이름: 첫 글 상자(도형 안 글 포함) 첫 줄 → '슬라이드 편집 페이지'.
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

/// 순서 바꾸기 종류(목록 뒤가 위).
enum PageOrder { toFront, forward, backward, toBack }

/// 고른 요소들([ids])의 순서를 바꾼 목록. 고른 것끼리의 순서는 지킨다.
@visibleForTesting
List<PageElement> reorderPageElements(
  List<PageElement> elements,
  Set<String> ids,
  PageOrder order,
) {
  bool picked(PageElement e) => ids.contains(e.id);
  switch (order) {
    case PageOrder.toFront:
      return [...elements.whereNot(picked), ...elements.where(picked)];
    case PageOrder.toBack:
      return [...elements.where(picked), ...elements.whereNot(picked)];
    case PageOrder.forward:
      final next = [...elements];
      for (var i = next.length - 2; i >= 0; i--) {
        if (picked(next[i]) && !picked(next[i + 1])) {
          next.insert(i + 1, next.removeAt(i));
        }
      }
      return next;
    case PageOrder.backward:
      final next = [...elements];
      for (var i = 1; i < next.length; i++) {
        if (picked(next[i]) && !picked(next[i - 1])) {
          next.insert(i - 1, next.removeAt(i));
        }
      }
      return next;
  }
}

extension<T> on Iterable<T> {
  Iterable<T> whereNot(bool Function(T) test) => where((e) => !test(e));
}

/// 슬라이드 편집 페이지 편집 창. 그림·글 상자를 끌어 옮기고 손잡이로 크기를 바꾸며,
/// 글은 캔버스 위 그 자리에서 고친다(더블클릭·Enter·F2, 위 리본 = 글자 서식).
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
    this.isNew = false,
  });

  /// 지금 페이지 이름(항목 `sourceName`). 자동 이름과 같으면 이름 칸을 비워 둔다.
  final String name;

  /// null 이면 새 페이지('제목' 글 상자 하나로 시작).
  final List<PageElement>? elements;
  final SlideBackground? background;
  final ExportStyle style;

  /// 요소를 [background] 위에 PNG 한 장으로 굽는다. 클릭 단계마다 한 번씩 부른다.
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

  /// [elements] 가 있어도 새 페이지로 연다(틀로 새로 넣기): 새 페이지 제목, 첫 빈 글 상자를 골라 둔다.
  final bool isNew;

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

  late final bool _isNew = widget.isNew || widget.elements == null;
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

  /// 캔버스 안 편집기 문서. 편집을 시작할 때 그 글 상자 글로 갈아 끼운다.
  final _quill = QuillController.basic();
  final _quillScroll = ScrollController();
  final _editorKey = GlobalKey<EditorState>();
  bool _syncingQuill = false;
  final _history = PageEditHistory();

  final _rootFocus = FocusNode(debugLabel: 'page-editor');
  final _canvasFocus = FocusNode(debugLabel: 'page-editor-canvas');
  final _textFocus = FocusNode(debugLabel: 'page-editor-text');

  Map<String, ui.Image> _images = {};
  ui.Image? _backgroundImage;

  /// 배경 그림을 다 읽었는지(읽는 중에는 '파일 없음' 안내를 띄우지 않는다).
  bool _backgroundLoaded = false;

  /// 고른 요소 id(고른 순서). 손잡이·위치 칸은 하나일 때만.
  List<String> _selection = const [];

  /// 캔버스 안에서 글을 고치는 글 상자(늘 [_selection] 의 하나뿐인 요소).
  String? _editingId;
  String? _hoverId;

  /// 끄는 요소들의 시작 자리와 누적 이동(px 이 아니라 비율).
  Map<String, Rect>? _dragStarts;
  Rect? _resizeStart;
  Offset _dragTotal = Offset.zero;
  bool _dragging = false;

  /// 선·화살표 끝점을 끌기 시작할 때의 두 점.
  (Offset, Offset)? _lineStart;

  /// 빈 곳 끌기 범위(슬라이드 비율)와 그 전에 골라 둔 것(Shift/⌘·Ctrl 이면 더한다).
  Offset? _marqueeFrom;
  Offset? _marqueeTo;
  List<String> _marqueeBase = const [];

  /// 누를 때 Shift/⌘·Ctrl 를 쥐고 있었는지(손을 뗄 때 여러 개 고르기를 하나로 줄이지 않게).
  bool _tapAdditive = false;

  /// 더블클릭한 자리 — 편집을 시작하면 그 자리에 커서를 놓는다.
  Offset? _doubleTapAt;

  /// 연달아 바뀌는 값(글 편집 하나, 위치 칸 등)의 되돌리기 묶음: 묶음 첫 변경에만 기록한다.
  bool _editSession = false;

  bool _pasting = false;
  bool _composing = false;
  bool _showCompactProperties = false;
  String? _message;
  bool _messageIsError = false;
  Timer? _messageTimer;

  @override
  void initState() {
    super.initState();
    _quill.addListener(_onQuillChanged);
    _loadImages();
    _loadBackgroundImage();
    final first =
        _initialElements
            .whereType<PageTextElement>()
            // 빈 도형(띠·자막 상자)은 '첫 빈 글 상자'가 아니다.
            .where(
              (e) =>
                  e is! PageShapeElement &&
                  e.holdsText &&
                  e.text.trim().isEmpty,
            )
            .firstOrNull ??
        _initialElements.where(_selectable).firstOrNull;
    if (_isNew && first != null) {
      _selection = [first.id];
      // 새 페이지 제목('제목')은 통째로 골라 두어 치면 바뀐다.
      if (first is PageTextElement) _startEdit(selectAll: true, inInit: true);
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
    _quill.dispose();
    _quillScroll.dispose();
    _rootFocus.dispose();
    _canvasFocus.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  // ── 상태 ────────────────────────────────────────────────────────────

  /// 이 판이 모르는 요소는 고를 수 없다(그리지도 않는다).
  static bool _selectable(PageElement e) => e is! PageUnknownElement;

  PageElement? _byId(String? id) =>
      id == null ? null : _elements.where((e) => e.id == id).firstOrNull;

  String? get _selectedId => _selection.length == 1 ? _selection.single : null;

  /// 하나만 골랐을 때 그 요소.
  PageElement? get _selected => _byId(_selectedId);

  List<PageElement> get _selectedElements => [
    for (final e in _elements)
      if (_selection.contains(e.id)) e,
  ];

  bool get _dirty =>
      !listEquals(_elements, _initialElements) ||
      _background != _initialBackground ||
      _nameController.text.trim() != _initialName;

  bool get _inTextField =>
      _textFocus.hasFocus ||
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

  /// 글 편집·위치 칸처럼 연달아 바뀌는 값: 묶음 첫 변경에만 기록한다.
  void _replaceInSession(PageElement element) {
    final record = !_editSession;
    _editSession = true;
    _replace(element, record: record);
  }

  void _select(Iterable<String> ids) {
    final next = ids.toList();
    if (_editingId != null && !(next.length == 1 && next[0] == _editingId)) {
      _exitEdit(focusCanvas: false);
    }
    _editSession = false;
    setState(() => _selection = next);
  }

  // ── 캔버스 안 글 편집 ───────────────────────────────────────────────

  /// 고른 글 상자 하나를 그 자리에서 편집한다. 커서는 [at](화면 좌표)이 있으면 그 자리, 아니면 글 끝.
  void _startEdit({Offset? at, bool selectAll = false, bool inInit = false}) {
    final e = _selected;
    if (e is! PageTextElement || !e.holdsText) return;
    // 편집 하나(시작~끝) = 창 되돌리기 한 묶음. 편집 중 ⌘Z 는 Quill 의 글자 단위 되돌리기다.
    _editSession = false;
    _syncingQuill = true;
    try {
      // fromJson: insert 로 만들면 그 삽입이 Quill undo 기록에 남아 ⌘Z 가 글을 지운다.
      _quill.document = pageEditorDocument(e);
    } finally {
      _syncingQuill = false;
    }
    final end = _quill.document.length - 1;
    _quill.updateSelection(
      selectAll
          ? TextSelection(baseOffset: 0, extentOffset: end)
          : TextSelection.collapsed(offset: end),
      ChangeSource.local,
    );
    if (inInit) {
      _editingId = e.id;
    } else {
      setState(() => _editingId = e.id);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _editingId != e.id) return;
      _textFocus.requestFocus();
      if (at != null) {
        _editorKey.currentState?.renderEditor.selectPositionAt(
          from: at,
          cause: SelectionChangedCause.tap,
        );
      }
    });
  }

  /// 편집을 끝낸다(상자는 고른 채).
  void _exitEdit({bool focusCanvas = true}) {
    if (_editingId == null) return;
    _editSession = false;
    setState(() => _editingId = null);
    if (focusCanvas) _canvasFocus.requestFocus();
  }

  /// 편집기에서 바뀐 글을 그 글 상자에 담는다(평문 + 서식 글).
  void _onQuillChanged() {
    if (_syncingQuill) return;
    final current = _byId(_editingId);
    if (current is! PageTextElement) return;
    _stripUnsupported();
    final r = pageRichOf(_quill.document);
    if (r.text == current.text &&
        (r.rich == current.rich ||
            r.rich == encodePageRich(pageRichLines(current)))) {
      setState(() {}); // 커서만 움직임 — 리본 값만 다시 그린다.
      return;
    }
    _replaceInSession(current.copyWith(text: r.text, rich: r.rich));
  }

  /// 굽기가 모르는 서식(Quill 단축키·붙여 넣기의 제목·코드·들여쓰기 등)을 편집기에서 바로 걷어 낸다
  /// — 편집 중 보이는 것과 구운 그림이 달라지지 않게.
  void _stripUnsupported() {
    final fixes = <(int, int, Attribute)>[];
    var offset = 0;
    for (final op in _quill.document.toDelta().toJson()) {
      final insert = op['insert'];
      final len = insert is String ? insert.length : 1;
      final a = op['attributes'];
      if (a is Map) {
        for (final MapEntry(:key, :value) in a.entries) {
          final ok =
              pageInlineKeys.contains(key) ||
              key == 'align' ||
              (key == 'list' && (value == 'bullet' || value == 'ordered'));
          if (ok) continue;
          final clear = Attribute.fromKeyValue(key as String, null);
          if (clear != null) fixes.add((offset, len, clear));
        }
      }
      offset += len;
    }
    if (fixes.isEmpty) return;
    _syncingQuill = true;
    try {
      for (final (index, len, attr) in fixes) {
        _quill.formatText(index, len, attr);
      }
    } finally {
      _syncingQuill = false;
    }
  }

  /// 편집 중 고른 글자(없으면 커서 자리)의 서식 덩어리들.
  List<Map<String, Object>> _editorRuns() {
    Map<String, Object> styleOf(Style s) => pageInlineAttrs({
      for (final MapEntry(:key, :value) in s.attributes.entries)
        key: value.value,
    });
    final sel = _quill.selection;
    final runs = <Map<String, Object>>[];
    if (!sel.isCollapsed) {
      var offset = 0;
      for (final op in _quill.document.toDelta().toJson()) {
        final insert = op['insert'];
        final len = insert is String ? insert.length : 1;
        final from = math.max(sel.start, offset);
        final to = math.min(sel.end, offset + len);
        if (insert is String &&
            from < to &&
            insert.substring(from - offset, to - offset).trim().isNotEmpty) {
          final a = op['attributes'];
          runs.add(a is Map ? pageInlineAttrs(a) : const {});
        }
        offset += len;
      }
    }
    return runs.isEmpty ? [styleOf(_quill.getSelectionStyle())] : runs;
  }

  /// 리본 줄 2 에 보일 서식. 글 상자를 안 골랐으면 null(비활성).
  PageTextFormat? get _ribbonFormat {
    final editing = _byId(_editingId);
    if (editing is PageTextElement) {
      final list = _quill.getSelectionStyle().attributes['list']?.value;
      return pageTextFormatOf(
        [for (final a in _editorRuns()) (editing, a)],
        [list is String ? list : null],
      );
    }
    final boxes = _selectedElements.whereType<PageTextElement>().where(
      (e) => e.holdsText,
    );
    return boxes.isEmpty ? null : pageBoxFormat(boxes);
  }

  /// 리본 줄 2 앞의 도형 서식: 고른 것 중 도형이 있고 글 상자가 없을 때(둘 다면 글자 서식만).
  PageShapeFormat? get _shapeFormat {
    final picked = _selectedElements;
    final shapes = picked.whereType<PageShapeElement>();
    if (shapes.isEmpty ||
        picked.any((e) => e is PageTextElement && e is! PageShapeElement)) {
      return null;
    }
    final s = shapes.first;
    return (
      fill: s.fill,
      fillAlpha: s.fillAlpha,
      stroke: s.stroke,
      strokeWidth: s.strokeWidth,
      valign: s.valign,
      holdsText: shapes.any((e) => e.holdsText),
    );
  }

  /// 리본 도형 서식을 고른 도형들에 적용한다. 투명도는 끄는 동안 한 묶음('begin' 에서 새 묶음).
  void _formatShape(String key, Object? value) {
    if (key == 'begin') {
      _editSession = false;
      return;
    }
    final record = key != 'fill_alpha' || !_editSession;
    _editSession = key == 'fill_alpha';
    final next = [
      for (final e in _elements)
        e is PageShapeElement && _selection.contains(e.id)
            ? applyShapeFormat(e, key, value)
            : e,
    ];
    if (!listEquals(next, _elements)) _commit(next, record: record);
  }

  /// 리본·단축키 서식. 편집 중이면 고른 글자에(Quill), 아니면 고른 글 상자 전체에.
  void _format(String key, Object? value) {
    if (_editingId != null) {
      _formatInEditor(key, value);
      return;
    }
    if (!_selectedElements.any((e) => e is PageTextElement && e.holdsText)) {
      return;
    }
    _editSession = false;
    _commit([
      for (final e in _elements)
        e is PageTextElement && e.holdsText && _selection.contains(e.id)
            ? applyBoxFormat(e, key, value)
            : e,
    ]);
  }

  /// ⌘/Ctrl+B·I·U: 지금 값을 뒤집는다.
  void _toggleFormat(String key) {
    final f = _ribbonFormat;
    if (f == null) return;
    _format(key, switch (key) {
      'bold' => !f.bold,
      'italic' => !f.italic,
      'underline' => !f.underline,
      _ => !f.strike,
    });
  }

  void _formatInEditor(String key, Object? value) {
    final e = _byId(_editingId);
    if (e is! PageTextElement) return;
    Attribute? attr(String k, Object? v) => Attribute.fromKeyValue(k, v);
    switch (key) {
      case 'align':
        // 정렬은 상자 하나다. 편집기 줄마다에도 넣어 바로 보이게 한다(저장되는 rich 에는 안 남는다).
        final align = value as TextAlign;
        _replaceInSession(e.copyWith(align: align));
        _quill.formatText(
          0,
          _quill.document.length,
          attr('align', switch (align) {
            TextAlign.center => 'center',
            TextAlign.right => 'right',
            _ => null,
          }),
        );
      case 'list':
        _quill.formatSelection(attr('list', value));
      case 'clear':
        for (final k in pageInlineKeys) {
          _quill.formatSelection(attr(k, null));
        }
      case 'step':
        final size = _ribbonFormat?.size ?? e.fontSize;
        _formatInEditor('size', pageSizeStep(size, value as int));
      case 'size':
        final v = value as double;
        _quill.formatSelection(
          attr(
            'size',
            v == e.fontSize
                ? null
                : v == v.roundToDouble()
                ? '${v.round()}'
                : '$v',
          ),
        );
      case 'color':
        final c = value as Color;
        _quill.formatSelection(
          attr('color', c == e.color ? null : colorToHex(c)),
        );
      case 'font':
        _quill.formatSelection(
          attr('font', value == e.fontFamily ? null : value),
        );
      case 'bold':
        // 상자 굵기와 같으면 직접 지정을 지운다(굵은 상자 안 보통 글자 = bold:false).
        _quill.formatSelection(attr('bold', value == e.bold ? null : value));
      default: // italic · underline · strike
        _quill.formatSelection(attr(key, value == true ? true : null));
    }
    // 크기 칸·색 창에서 돌아오면 편집기로 포커스를 돌려준다.
    if (!_textFocus.hasFocus) _textFocus.requestFocus();
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
      _select([added.last.id]);
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

  /// 새 글 상자를 넣고 바로 편집한다.
  void _addTextBox({String text = ''}) {
    final box = newTextBox(_elements, _selectedId ?? _editingId, text: text);
    _commit([..._elements, box]);
    _select([box.id]);
    _startEdit();
  }

  /// 새 도형을 가운데에 넣고 고른다(글은 더블클릭·Enter 로).
  void _addShape(PageShapeKind kind) {
    final shape = newShape(_elements, _selectedId, kind);
    _commit([..._elements, shape]);
    _select([shape.id]);
    _canvasFocus.requestFocus();
  }

  // ── 편집 ────────────────────────────────────────────────────────────

  void _align(PageAlign align) {
    final next = alignPageElements(_elements, _selection.toSet(), align);
    if (!listEquals(next, _elements)) _commit(next);
  }

  void _duplicate() {
    final copies = [
      for (final e in _selectedElements)
        e.copyWith(
          id: PageElement.newId(),
          rect: e.fitRect(e.rect.shift(const Offset(0.02, 0.02))),
        ),
    ];
    if (copies.isEmpty) return;
    _commit([..._elements, ...copies]);
    _select(copies.map((e) => e.id));
  }

  void _delete() {
    if (_selection.isEmpty) return;
    final ids = _selection.toSet();
    _select(const []);
    _commit([
      for (final e in _elements)
        if (!ids.contains(e.id)) e,
    ]);
  }

  /// 고른 요소들의 순서 바꾸기(목록 뒤가 위).
  void _reorder(PageOrder order) {
    final next = reorderPageElements(_elements, _selection.toSet(), order);
    if (!listEquals(next, _elements)) _commit(next);
  }

  VoidCallback? _reorderAction(PageOrder order) =>
      _selection.isNotEmpty &&
          !listEquals(
            reorderPageElements(_elements, _selection.toSet(), order),
            _elements,
          )
      ? () => _reorder(order)
      : null;

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
      _selection = [
        for (final id in _selection)
          if (_byId(id) != null) id,
      ];
    });
  }

  void _nudge(Offset delta, {bool resize = false}) {
    if (resize) {
      final e = _selected;
      // 선·화살표는 끝점 손잡이로만 크기를 바꾼다.
      if (e == null || (e is PageShapeElement && e.kind.isLine)) return;
      _replace(
        e.copyWith(rect: resizePageRect(e.rect, PageHandle.bottomRight, delta)),
      );
      return;
    }
    if (_selection.isEmpty) return;
    _commit([
      for (final e in _elements)
        _selection.contains(e.id)
            ? e.copyWith(rect: e.fitRect(e.rect.shift(delta)))
            : e,
    ]);
  }

  void _cycleSelection(bool backward) {
    final items = _elements.where(_selectable).toList();
    if (items.isEmpty) return;
    final i = items.indexWhere((e) => e.id == _selectedId);
    final n = items.length;
    _select([items[(i + (backward ? -1 : 1) + n) % n].id]);
  }

  // ── 끌기 ────────────────────────────────────────────────────────────

  void _startDrag(PageElement e) {
    if (!_selection.contains(e.id)) _select([e.id]);
    if (_editingId == null) _canvasFocus.requestFocus();
    _history.record(_elements);
    // 편집 중 상자를 옮겨도 그 뒤 치는 글은 새 묶음으로(옮기기와 따로 되돌아가게).
    _editSession = false;
    setState(() {
      _dragStarts = {for (final x in _selectedElements) x.id: x.rect};
      _dragTotal = Offset.zero;
      _dragging = true;
    });
  }

  void _updateDrag(DragUpdateDetails d, Size size) {
    final starts = _dragStarts;
    if (starts == null) return;
    _dragTotal += Offset(d.delta.dx / size.width, d.delta.dy / size.height);
    _commit([
      for (final e in _elements)
        if (starts[e.id] case final start?)
          e.copyWith(rect: e.fitRect(start.shift(_dragTotal)))
        else
          e,
    ], record: false);
  }

  void _endDrag() => setState(() {
    _dragStarts = null;
    _dragging = false;
  });

  // 빈 곳 끌기 = 범위로 고르기. [at] = 캔버스 안 비율 좌표.
  void _startMarquee(Offset at) {
    final kb = HardwareKeyboard.instance;
    final additive =
        kb.isShiftPressed || (_isMac ? kb.isMetaPressed : kb.isControlPressed);
    _marqueeBase = additive ? _selection : const [];
    _canvasFocus.requestFocus();
    setState(() => _marqueeFrom = _marqueeTo = at);
  }

  void _updateMarquee(Offset at) {
    final from = _marqueeFrom;
    if (from == null) return;
    _marqueeTo = at;
    final hit = pageElementsInRange(_elements, Rect.fromPoints(from, at));
    _select({..._marqueeBase, ...hit});
  }

  void _endMarquee() => setState(() => _marqueeFrom = _marqueeTo = null);

  // ── 키 ──────────────────────────────────────────────────────────────

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || _composing) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final cmd = _isMac ? keyboard.isMetaPressed : keyboard.isControlPressed;
    final shift = keyboard.isShiftPressed;
    // 글 편집 중이면 글자·지우기·방향키·⌘A·⌘Z 는 편집기 것이다(요소를 건드리지 않는다).
    final inText = _inTextField;

    if (cmd) {
      if (key == LogicalKeyboardKey.keyV) {
        if (inText) return KeyEventResult.ignored;
        if (event is KeyDownEvent) _paste();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyD) {
        if (event is KeyDownEvent && !inText) _duplicate();
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
      final style = switch (key) {
        LogicalKeyboardKey.keyB => 'bold',
        LogicalKeyboardKey.keyI => 'italic',
        LogicalKeyboardKey.keyU => 'underline',
        _ => null,
      };
      if (style != null) {
        if (inText) return KeyEventResult.ignored;
        if (event is KeyDownEvent) _toggleFormat(style);
        return KeyEventResult.handled;
      }
      // Shift 와 같이 누르면 글자가 `{` `}` 로 바뀌므로 자리로 본다.
      final front = event.physicalKey == PhysicalKeyboardKey.bracketRight;
      final back = event.physicalKey == PhysicalKeyboardKey.bracketLeft;
      if (front || back) {
        if (inText) return KeyEventResult.ignored;
        _reorder(switch ((front, shift)) {
          (true, true) => PageOrder.toFront,
          (true, false) => PageOrder.forward,
          (false, true) => PageOrder.toBack,
          (false, false) => PageOrder.backward,
        });
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.escape) {
      if (event is! KeyDownEvent) return KeyEventResult.handled;
      if (_editingId != null) {
        _exitEdit();
      } else if (inText) {
        _canvasFocus.requestFocus();
      } else if (_selection.isNotEmpty) {
        _select(const []);
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
    if (key == LogicalKeyboardKey.tab && _selection.isNotEmpty) {
      if (event is KeyDownEvent) _cycleSelection(shift);
      return KeyEventResult.handled;
    }
    final selected = _selected;
    final textBox = selected is PageTextElement && selected.holdsText;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.f2) {
      if (!textBox) return KeyEventResult.ignored;
      if (event is KeyDownEvent) _startEdit();
      return KeyEventResult.handled;
    }
    // 글 상자를 고른 채 글자를 치면 편집만 시작한다(커서는 글 끝). 그 글자는 넣지 않는다 —
    // 입력기에 안 붙은 캔버스가 받은 `character` 는 한글 입력기에서 'g' 같은 라틴 글자라
    // 넣으면 '한' 이 'g'+'ㅏㄴ' 으로 갈라진다. ponytail: 첫 글자를 다시 쳐야 한다 — 화면 밖 입력칸으로
    // 입력기를 붙여 두면 없앨 수 있다(qa-phase1.md 수정안 나).
    final char = event.character;
    if (textBox &&
        event is KeyDownEvent &&
        !keyboard.isAltPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isMetaPressed &&
        char != null &&
        char.isNotEmpty &&
        char.runes.every((r) => r >= 0x20 && r != 0x7F)) {
      _startEdit();
      return KeyEventResult.handled;
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
    // 빈 글 상자는 편집 창에서만 보이는 자리라 뺀다. 빈 단계는 당겨 같은 그림이 두 장 생기지 않게.
    final all = normalizeAppear(_elements);
    final elements = normalizeAppear([
      for (final e in _elements)
        if (e is! PageTextElement ||
            e is PageShapeElement ||
            e.text.trim().isNotEmpty)
          e,
    ]);
    setState(() {
      _composing = true;
      _message = null;
    });
    try {
      final paths = <String>[];
      // 틀은 썸네일 한 장(단계 무시 = 전부)만. 요소의 appear·disappear 는 남는다.
      for (final step
          in widget.templateMode ? [elements] : pageSteps(elements)) {
        paths.add(await widget.compose(step, _background));
        if (!mounted || !_composing) return;
      }
      Navigator.of(context).pop<PageEditorResult>((
        name: _nameController.text.trim().isEmpty
            ? pageAutoName(elements)
            : _nameController.text.trim(),
        elements: widget.templateMode ? all : elements,
        imagePaths: paths,
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
    // 창 폭(화면 - 좌우 여백 2.5%씩)이 좁으면 캔버스·속성을 번갈아 보인다.
    final compact = screen.width * 0.95 < 800;
    final editing = _editingId != null;
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
                  padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.templateMode
                              ? '틀 편집'
                              : _isNew
                              ? '슬라이드 편집 페이지'
                              : '슬라이드 편집 페이지 수정',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (compact)
                        TextButton.icon(
                          onPressed: () => setState(
                            () => _showCompactProperties =
                                !_showCompactProperties,
                          ),
                          icon: Icon(
                            _showCompactProperties
                                ? Icons.dashboard_outlined
                                : Icons.tune_rounded,
                            size: 18,
                          ),
                          label: Text(_showCompactProperties ? '캔버스' : '속성'),
                        ),
                    ],
                  ),
                ),
                _blockWhileComposing(
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(1),
                    child: PageInsertRow(
                      isMac: _isMac,
                      pasting: _pasting,
                      onPickImage: _pickImages,
                      onPaste: _paste,
                      onAddText: _addTextBox,
                      onAddShape: _addShape,
                      alignCount: _selection.length,
                      onAlign: _selection.isEmpty ? null : _align,
                      onDuplicate: _selection.isEmpty ? null : _duplicate,
                      onDelete: _selection.isEmpty ? null : _delete,
                      onToFront: _reorderAction(PageOrder.toFront),
                      onForward: _reorderAction(PageOrder.forward),
                      onBackward: _reorderAction(PageOrder.backward),
                      onToBack: _reorderAction(PageOrder.toBack),
                      // 편집 중에는 글자 단위(편집기), 아니면 창 되돌리기.
                      onUndo: editing
                          ? (_quill.hasUndo ? _quill.undo : null)
                          : (_history.canUndo ? _undo : null),
                      onRedo: editing
                          ? (_quill.hasRedo ? _quill.redo : null)
                          : (_history.canRedo ? _redo : null),
                    ),
                  ),
                ),
                _blockWhileComposing(
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(2),
                    // 리본을 눌러도 편집기 밖 누름으로 보지 않게(편집기와 같은 탭 영역 묶음).
                    child: TextFieldTapRegion(
                      child: PageFormatRow(
                        isMac: _isMac,
                        format: _ribbonFormat,
                        shape: _shapeFormat,
                        colors: [for (final (c, _) in _swatches) c],
                        onFormat: _format,
                        onShape: _formatShape,
                      ),
                    ),
                  ),
                ),
                Divider(height: 1, color: cs.outlineVariant),
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final canvas = _blockWhileComposing(
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(3),
                          child: _canvasArea(cs),
                        ),
                      );
                      final properties = _blockWhileComposing(
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(4),
                          child: _propertiesPanel(cs),
                        ),
                      );
                      if (compact) {
                        return _showCompactProperties ? properties : canvas;
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: canvas),
                          VerticalDivider(width: 1, color: cs.outlineVariant),
                          SizedBox(width: 280, child: properties),
                        ],
                      );
                    },
                  ),
                ),
                Divider(height: 1, color: cs.outlineVariant),
                FocusTraversalOrder(
                  order: const NumericFocusOrder(5),
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

  /// 캔버스 아래 상태 줄.
  String get _statusText {
    final mod = _isMac ? '⌘' : 'Ctrl+';
    ({int images, int texts, int shapes}) count(List<PageElement> list) => (
      images: list.whereType<PageImageElement>().length,
      shapes: list.whereType<PageShapeElement>().length,
      texts: list
          .where((e) => e is PageTextElement && e is! PageShapeElement)
          .length,
    );
    if (_editingId != null) {
      return '글 편집 중   ESC: 편집 끝내기 · 테두리를 끌어 옮기기 · 리본 서식은 고른 글자에만';
    }
    if (_selection.length > 1) {
      final picked = _selectedElements;
      final c = count(picked);
      return '요소 ${picked.length}개 고름 (글 상자 ${c.texts} · 도형 ${c.shapes} · 그림 ${c.images})   '
          '함께 끌어 옮기기 · Delete: 모두 지우기 · ${mod}D: 모두 복제';
    }
    if (_selected case PageShapeElement(:final kind)) {
      return kind.isLine
          ? '${kind.label} 고름   양 끝 손잡이: 방향·길이 · 방향키: 옮기기(Shift = 크게)'
          : '도형 1개 고름   더블클릭·Enter: 안에 글 쓰기 · 방향키: 옮기기(Shift = 크게)';
    }
    final c = count(_elements);
    return '그림 ${c.images} · 글 상자 ${c.texts} · 도형 ${c.shapes}   '
        '더블클릭: 글 고치기 · Shift/$mod+클릭: 여러 개 고르기 · 빈 곳 끌기: 범위로 고르기';
  }

  Widget _canvasArea(ColorScheme cs) {
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
                _select(const []);
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
              _statusText,
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
    final selected = _editingId == null ? _selected : null;
    final editing = _byId(_editingId);
    final picked = _selectedElements;
    Offset ratio(Offset local) =>
        Offset(local.dx / size.width, local.dy / size.height);
    final marquee = _marqueeFrom != null && _marqueeTo != null
        ? px(Rect.fromPoints(_marqueeFrom!, _marqueeTo!))
        : null;
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
                // 빈 곳(요소 덮개 밖) 끌기 = 범위로 고르기. 편집 중에는 글자 고르기와 겹치지 않게 끈다.
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // 범위는 누른 자리부터(기본은 끌기 문턱을 넘은 자리).
                  dragStartBehavior: DragStartBehavior.down,
                  onPanStart: editing != null
                      ? null
                      : (d) => _startMarquee(ratio(d.localPosition)),
                  onPanUpdate: editing != null
                      ? null
                      : (d) => _updateMarquee(ratio(d.localPosition)),
                  onPanEnd: editing != null ? null : (_) => _endMarquee(),
                  child: PageCanvas(
                    elements: _elements,
                    backgroundColor: _background.color,
                    backgroundImage: _backgroundImage,
                    images: _images,
                    editingId: editing?.id,
                    editor: editing is PageTextElement
                        ? PageTextEditor(
                            element: editing,
                            fontScale: PageCanvas.fontScale,
                            controller: _quill,
                            focusNode: _textFocus,
                            scrollController: _quillScroll,
                            editorKey: _editorKey,
                            onExit: _exitEdit,
                            onFormat: _toggleFormat,
                          )
                        : null,
                  ),
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
              // 편집 중인 상자는 안쪽을 비워(편집기가 받는다) 테두리 띠만 둔다.
              for (final e in _elements)
                if (e.id == _editingId)
                  _editingFrame(cs, e, px(e.rect), size)
                else if (_selectable(e))
                  Positioned.fromRect(
                    // 선은 높이 0 일 수 있어 덮개를 누를 만큼 넓힌다(누름은 선 가까이만 — _LineHitPainter).
                    rect: _isLine(e) ? _lineBox(px(e.rect)) : px(e.rect),
                    child: _elementOverlay(cs, e, size),
                  ),
              if (picked.length > 1)
                Positioned.fromRect(
                  rect: px(
                    picked
                        .map((e) => e.rect)
                        .reduce((a, b) => a.expandToInclude(b)),
                  ).inflate(6),
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _DashedBorderPainter(cs.secondary),
                    ),
                  ),
                ),
              if (selected is PageShapeElement && selected.kind.isLine)
                ..._lineHandles(cs, selected, size)
              else if (selected != null)
                ..._handles(cs, selected, px(selected.rect), size),
              if (marquee != null)
                Positioned.fromRect(
                  rect: marquee,
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: cs.secondary.withValues(alpha: 0.08),
                      child: CustomPaint(
                        painter: _DashedBorderPainter(cs.secondary),
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

  /// 편집 중인 글 상자: 점선 + 바깥 옅은 띠. 띠를 끌면 상자를 옮긴다(안쪽 끌기는 글자 고르기).
  Widget _editingFrame(ColorScheme cs, PageElement e, Rect box, Size size) {
    const band = 6.0;
    Widget strip(Positioned Function(Widget child) place) => place(
      MouseRegion(
        cursor: SystemMouseCursors.move,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => _startDrag(e),
          onPanUpdate: (d) => _updateDrag(d, size),
          onPanEnd: (_) => _endDrag(),
        ),
      ),
    );
    return Positioned.fromRect(
      key: const ValueKey('page-editing-frame'),
      rect: box.inflate(band),
      child: Semantics(
        label: '글 상자 편집 중',
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  // 어두운·밝은 슬라이드 모두 보이게: 옅은 surface 띠 + point(secondary) 점선.
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: cs.surface.withValues(alpha: 0.45),
                      width: band,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(band),
                    child: CustomPaint(
                      painter: _DashedBorderPainter(cs.secondary),
                    ),
                  ),
                ),
              ),
            ),
            strip(
              (c) =>
                  Positioned(left: 0, top: 0, right: 0, height: band, child: c),
            ),
            strip(
              (c) => Positioned(
                left: 0,
                bottom: 0,
                right: 0,
                height: band,
                child: c,
              ),
            ),
            strip(
              (c) =>
                  Positioned(left: 0, top: 0, bottom: 0, width: band, child: c),
            ),
            strip(
              (c) => Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: band,
                child: c,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _elementOverlay(ColorScheme cs, PageElement e, Size size) {
    final isSelected = _selection.contains(e.id);
    final missingImage = e is PageImageElement && !_images.containsKey(e.path);
    final emptyText =
        e is PageTextElement && e is! PageShapeElement && e.text.trim().isEmpty;
    final line = _isLine(e);
    String head(String t) => t.length > 20 ? t.substring(0, 20) : t;
    return Semantics(
      label: switch (e) {
        PageShapeElement(:final kind, :final text) =>
          '도형: ${kind.label}${text.trim().isEmpty ? '' : ' ${head(text)}'}',
        PageImageElement(:final path) =>
          '그림: ${BackgroundImageLibrary.displayName(path)}',
        PageTextElement(:final text) => '글 상자: ${head(text)}',
        PageUnknownElement(:final type) => '알 수 없는 요소: $type',
      },
      selected: isSelected,
      child: MouseRegion(
        hitTestBehavior: line ? HitTestBehavior.deferToChild : null,
        cursor: _dragging && isSelected
            ? SystemMouseCursors.grabbing
            : SystemMouseCursors.move,
        onEnter: (_) => setState(() => _hoverId = e.id),
        onExit: (_) {
          if (_hoverId == e.id) setState(() => _hoverId = null);
        },
        child: GestureDetector(
          behavior: line
              ? HitTestBehavior.deferToChild
              : HitTestBehavior.opaque,
          onTapDown: (_) {
            final kb = HardwareKeyboard.instance;
            _tapAdditive =
                kb.isShiftPressed ||
                (_isMac ? kb.isMetaPressed : kb.isControlPressed);
            if (_tapAdditive) {
              _select(
                isSelected
                    ? _selection.where((id) => id != e.id)
                    : [..._selection, e.id],
              );
            } else if (!isSelected) {
              _select([e.id]);
            }
            _canvasFocus.requestFocus();
          },
          // 여러 개 고른 중 하나를 (끌지 않고) 누르면 그것만 남긴다.
          onTap: () {
            if (!_tapAdditive && _selection.length > 1) _select([e.id]);
          },
          // 글을 못 담는 요소(선)는 두 번 누름 인식기를 아예 안 단다 — 달면 빠른 두 번 누름이 고르기를 푼다.
          onDoubleTapDown: e is PageTextElement && e.holdsText
              ? (d) => _doubleTapAt = d.globalPosition
              : null,
          onDoubleTap: e is PageTextElement && e.holdsText
              ? () {
                  _select([e.id]);
                  _startEdit(at: _doubleTapAt);
                }
              : null,
          onPanStart: (_) => _startDrag(e),
          onPanUpdate: (d) => _updateDrag(d, size),
          onPanEnd: (_) => _endDrag(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (e is PageShapeElement && line)
                LayoutBuilder(
                  builder: (context, box) => CustomPaint(
                    painter: _LineHitPainter(e.flipH != e.flipV, box.biggest),
                    // 고르거나 올리면 선을 따라 옅은 띠(손잡이는 양 끝).
                    foregroundPainter: isSelected || _hoverId == e.id
                        ? _LineHighlightPainter(e.flipH != e.flipV, cs.primary)
                        : null,
                  ),
                ),
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
              if (e.appear > 0 || e.disappear > 0)
                Positioned(
                  left: 2,
                  top: 2,
                  child: IgnorePointer(
                    child: _AppearBadge(e.appear, e.disappear),
                  ),
                ),
              if (line)
                const SizedBox.shrink()
              else if (isSelected)
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
                  _resizeStart = e.rect;
                  _dragTotal = Offset.zero;
                },
                onPanUpdate: (d) {
                  final start = _resizeStart;
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
                        // 그림은 비율 고정(Shift = 풀기), 도형은 Shift = 비율 고정(PowerPoint 와 같다).
                        keepAspect:
                            (current is PageImageElement) !=
                            HardwareKeyboard.instance.isShiftPressed,
                      ),
                    ),
                    record: false,
                  );
                },
                onPanEnd: (_) => _resizeStart = null,
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

  static bool _isLine(PageElement e) => e is PageShapeElement && e.kind.isLine;

  /// 선 덮개: 짧은 쪽을 화면 16px 까지 넓힌다(가운데 기준).
  static Rect _lineBox(Rect r) => Rect.fromCenter(
    center: r.center,
    width: math.max(r.width, 16),
    height: math.max(r.height, 16),
  );

  /// 선·화살표 양 끝 손잡이 2개: 끌면 그 끝점만 옮겨 방향·길이를 바꾼다.
  List<Widget> _lineHandles(ColorScheme cs, PageShapeElement e, Size size) {
    const hit = 20.0, mark = 9.0;
    final (a, b) = e.linePoints;
    return [
      for (final (end, point) in [(0, a), (1, b)])
        Positioned(
          key: ValueKey('page-line-end-$end'),
          left: point.dx * size.width - hit / 2,
          top: point.dy * size.height - hit / 2,
          width: hit,
          height: hit,
          child: MouseRegion(
            cursor: SystemMouseCursors.precise,
            child: Semantics(
              label: end == 0 ? '선 시작점' : '선 끝점',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) {
                  _history.record(_elements);
                  _lineStart = e.linePoints;
                  _dragTotal = Offset.zero;
                },
                onPanUpdate: (d) {
                  final start = _lineStart;
                  final current = _selected;
                  if (start == null || current is! PageShapeElement) return;
                  _dragTotal += Offset(
                    d.delta.dx / size.width,
                    d.delta.dy / size.height,
                  );
                  _replace(
                    end == 0
                        ? current.withLinePoints(
                            start.$1 + _dragTotal,
                            start.$2,
                          )
                        : current.withLinePoints(
                            start.$1,
                            start.$2 + _dragTotal,
                          ),
                    record: false,
                  );
                },
                onPanEnd: (_) => _lineStart = null,
                child: Center(
                  child: Container(
                    width: mark,
                    height: mark,
                    decoration: BoxDecoration(
                      color: cs.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: cs.primary, width: 1.5),
                    ),
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
    final hint = TextStyle(fontSize: 12, color: cs.onSurfaceVariant);
    final picked = _selectedElements;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: picked.length > 1
            ? [
                Text('요소 ${picked.length}개를 골랐습니다', style: label),
                const SizedBox(height: 8),
                Text('함께 옮기기·복제·삭제·순서가 됩니다. 크기는 하나만 골랐을 때 바꿉니다.', style: hint),
                const SizedBox(height: 16),
                _appearField(picked),
                if (picked
                        .where((e) => e is PageTextElement && e.holdsText)
                        .length
                    case final n when n > 0) ...[
                  const SizedBox(height: 8),
                  Text('리본 글자 서식은 고른 것 중 글 상자·도형 $n개에만 적용됩니다.', style: hint),
                ],
              ]
            : switch (e) {
                null || PageUnknownElement() => [
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
                  Text('요소를 누르면 위 리본에서 고칩니다.', style: hint),
                  if (pageStepCount(_elements) case final n when n > 1) ...[
                    const SizedBox(height: 8),
                    Text(
                      '클릭 단계 $n장 — 발표에서 넘길 때마다 번호 순서대로 나타나고 사라집니다.',
                      style: hint,
                    ),
                  ],
                  ..._backgroundProperties(cs, label),
                ],
                PageShapeElement(:final kind) => [
                  Text(kind.label, style: label),
                  const SizedBox(height: 12),
                  ..._rectProperties(e, label),
                  const SizedBox(height: 12),
                  Text(
                    kind.isLine
                        ? '색·두께는 위 리본에서 바꿉니다. 양 끝 손잡이를 끌어 방향·길이를 바꿉니다.'
                        : '채우기·테두리·글자 서식은 위 리본에서 바꿉니다. 더블클릭하거나 Enter 를 누르면 안에 글을 씁니다.',
                    style: hint,
                  ),
                  if (_textOverflows(e)) ...[
                    const SizedBox(height: 12),
                    Text(
                      '글이 도형보다 깁니다. 도형을 키우거나 글자를 줄여 주세요.',
                      style: TextStyle(fontSize: 12, color: cs.error),
                    ),
                  ],
                ],
                PageTextElement() => [
                  Text('글 상자', style: label),
                  const SizedBox(height: 12),
                  ..._rectProperties(e, label),
                  const SizedBox(height: 12),
                  Text(
                    '글자 서식은 위 리본에서 바꿉니다. 글을 고칠 때 고른 글자가 없으면 다음에 칠 글자에 적용됩니다.',
                    style: hint,
                  ),
                  if (_textOverflows(e)) ...[
                    const SizedBox(height: 12),
                    Text(
                      '글이 상자보다 깁니다. 상자를 키우거나 글자를 줄여 주세요.',
                      style: TextStyle(fontSize: 12, color: cs.error),
                    ),
                  ],
                ],
                PageImageElement() => _imageProperties(cs, e, label),
              },
      ),
    );
  }

  /// 위치·크기 숫자 칸(1920x1080 기준) + 나타나는 순서.
  List<Widget> _rectProperties(PageElement e, TextStyle? label) => [
    Text('위치·크기 (1920×1080 기준)', style: label),
    const SizedBox(height: 8),
    PageRectFields(
      key: ValueKey('rect-${e.id}'),
      rect: e.rect,
      clamp: e.fitRect,
      onChanged: (r) {
        final current = _byId(e.id);
        if (current != null) _replace(current.copyWith(rect: r));
      },
    ),
    const SizedBox(height: 16),
    _appearField([e]),
  ];

  /// '나타나는 순서'(처음부터 / k번째 클릭) + '사라지는 순서'(없음 / k번째 클릭). 번호는 지금 가장 큰 번호 + 1 까지,
  /// 사라짐은 고른 요소의 나타남보다 뒤만 고를 수 있다. 여럿이면 한꺼번에, 값이 섞이면 빈칸.
  /// 바꾸기 한 번 = 되돌리기 한 묶음.
  Widget _appearField(List<PageElement> picked) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _stepField(picked, gone: false),
      const SizedBox(height: 12),
      _stepField(picked, gone: true),
    ],
  );

  Widget _stepField(List<PageElement> picked, {required bool gone}) {
    int of(PageElement e) => gone ? e.disappear : e.appear;
    final values = picked.map(of).toSet();
    final value = values.length == 1 ? values.single : null;
    final last = math.min(
      _elements.fold(
            0,
            (a, e) => math.max(a, math.max(e.appear, e.disappear)),
          ) +
          1,
      PageElement.maxAppear,
    );
    // 사라짐은 고른 것 중 가장 늦은 나타남 뒤부터.
    final first = gone
        ? picked.fold(0, (a, e) => math.max(a, e.appear)) + 1
        : 1;
    return DropdownButtonFormField<int>(
      // 되돌리기·다른 요소 고르기로 값이 밖에서 바뀌면 다시 그리게.
      key: ValueKey((gone, picked.map((e) => e.id).join(','), value)),
      initialValue: value,
      isDense: true,
      decoration: InputDecoration(
        labelText: gone ? '사라지는 순서' : '나타나는 순서',
        helperText: gone ? null : '발표에서 클릭(넘기기)할 때마다 번호 순서대로 나타납니다.',
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        DropdownMenuItem(value: 0, child: Text(gone ? '없음' : '처음부터')),
        for (var k = first; k <= last; k++)
          DropdownMenuItem(value: k, child: Text('$k번째 클릭')),
      ],
      onChanged: (k) {
        if (k == null) return;
        final ids = {for (final e in picked) e.id};
        final next = [
          for (final e in _elements)
            if (!ids.contains(e.id))
              e
            else if (gone)
              e.copyWith(disappear: k)
            else
              // 나타남을 사라짐과 같거나 뒤로 옮기면 사라짐을 바로 다음 클릭으로 민다(상한이면 없앤다).
              e.copyWith(
                appear: k,
                disappear: e.disappear == 0 || e.disappear > k
                    ? e.disappear
                    : (k < PageElement.maxAppear ? k + 1 : 0),
              ),
        ];
        if (!listEquals(next, _elements)) _commit(next);
      },
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

  /// 굽기와 같은 글자 배치(1920x1080)로 재서 상자(도형은 안쪽 여백 뺀) 높이를 넘는지.
  bool _textOverflows(PageTextElement e) {
    if (e.text.isEmpty || !e.holdsText) return false;
    final shape = e is PageShapeElement;
    const k = PageCanvas.fontScale;
    final insetH = shape ? PageShapeElement.textInsetH * k * 2 : 0.0;
    final insetV = shape ? PageShapeElement.textInsetV * k * 2 : 0.0;
    return measurePageText(e, k, e.rect.width * PageCanvas.width - insetH) >
        e.rect.height * PageCanvas.height - insetV + 0.5;
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
      const SizedBox(height: 16),
      ..._rectProperties(e, label),
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

/// 요소 왼쪽 위 클릭 단계 번호(편집 창에서만 — 굽기엔 없다). 나타남 '1', 사라짐까지 '1→3', 사라짐만 '→3'.
class _AppearBadge extends StatelessWidget {
  const _AppearBadge(this.appear, this.disappear);

  final int appear;
  final int disappear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = [
      if (appear > 0) '$appear번째 클릭에 나타남',
      if (disappear > 0) '$disappear번째 클릭에 사라짐',
    ].join(', ');
    // 말풍선은 안 단다 — 배지는 IgnorePointer 안이라 요소 고르기·끌기를 막지 않아야 한다.
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minWidth: 20),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: cs.inverseSurface,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          [if (appear > 0) '$appear', if (disappear > 0) '→$disappear'].join(),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: cs.onInverseSurface,
          ),
        ),
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

/// 선 덮개의 누름 판정: 대각선(또는 가로·세로선)에서 화면 8px 안만 누른 것으로 본다.
/// [rising] = 왼쪽 아래 → 오른쪽 위 대각선(flipH 와 flipV 가 다를 때).
class _LineHitPainter extends CustomPainter {
  const _LineHitPainter(this.rising, this.size);

  final bool rising;
  final Size size;

  /// 덮개는 짧은 쪽을 넓혀 둔 것이라 그 축은 가운데 줄로 본다.
  static (Offset, Offset) lineIn(Size size, bool rising) {
    if (size.height <= 16.5) {
      return (Offset(0, size.height / 2), Offset(size.width, size.height / 2));
    }
    if (size.width <= 16.5) {
      return (Offset(size.width / 2, 0), Offset(size.width / 2, size.height));
    }
    return rising
        ? (Offset(0, size.height), Offset(size.width, 0))
        : (Offset.zero, Offset(size.width, size.height));
  }

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool hitTest(Offset position) {
    final (a, b) = lineIn(size, rising);
    final ab = b - a;
    final len2 = ab.distanceSquared;
    final t = len2 == 0
        ? 0.0
        : (((position - a).dx * ab.dx + (position - a).dy * ab.dy) / len2)
              .clamp(0.0, 1.0);
    return (position - (a + ab * t)).distance <= 8;
  }

  @override
  bool shouldRepaint(_LineHitPainter old) =>
      old.rising != rising || old.size != size;
}

/// 고른·올린 선을 따라 옅은 띠.
class _LineHighlightPainter extends CustomPainter {
  const _LineHighlightPainter(this.rising, this.color);

  final bool rising;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final (a, b) = _LineHitPainter.lineIn(size, rising);
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_LineHighlightPainter old) =>
      old.rising != rising || old.color != color;
}
