import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_colors.dart';
import '../data/claude_translator.dart';
import '../data/praise_repository.dart';
import '../domain/chord_lyrics.dart';
import '../domain/export_style.dart';
import '../domain/praise_song.dart';
import 'chord_edit_widgets.dart';
import 'chord_sheet_view.dart';
import 'lyrics_page_grid.dart';
import 'slide_page_data.dart';
import 'slide_render_view.dart';
import 'slide_text_layout.dart';

/// 곡 편집 결과: 곡 본체 + 언어별 보조 가사 ('영어' 는 song.englishLyrics).
typedef SongEditResult = (PraiseSong song, Map<String, String> subLyrics);

enum _EditorView { table, whole }

/// 가사 수정 창. 좌 원본 · 가운데 보조 · 우 추가 보조를 **페이지 표**(한 행 = 관객 화면 한 장)로
/// 고친다. '통째로' 보기는 예전처럼 언어별 큰 입력칸이고, 두 보기는 저장 형식(빈 줄 = 페이지)이
/// 같아서 오가도 잃는 게 없다.
///
/// **코드 모드**(머리줄 '코드' 스위치): 원본 열 칸이 코드 글(`[G]주 은[D/F#]혜`)이 된다. 표 연산이
/// 코드를 글자와 함께 옮기고, 저장할 때 원본 가사 = `stripChords(코드 글)` 이다(코드만 고쳤으면
/// 가사는 한 글자도 안 바뀐다). 결과 곡의 chordLyrics·chordKey 에 코드가 실린다.
class LyricsEditorDialog extends StatefulWidget {
  const LyricsEditorDialog({
    super.key,
    this.song,
    this.translations = const {},
    this.languages = const [PraiseRepository.defaultSubLanguage],
    this.subLanguage = PraiseRepository.defaultSubLanguage,
    this.extraLanguage = '',
    required this.style,
    this.contiOnly = false,
  });

  /// 콘티에 담긴 곡만 고친다(저장된 곡은 그대로). 제목·언어는 못 바꾸고, 보조·추가 보조 칸은
  /// [song] 의 englishLyrics·extraLyrics 를 [subLanguage]·[extraLanguage] 이름으로 보여 준다.
  /// 결과는 고친 song 하나(subLyrics 는 비어 있다).
  final bool contiOnly;

  final PraiseSong? song;

  /// 영어를 뺀 언어별 가사 (DB 에서 읽어 온 것).
  final Map<String, String> translations;

  /// 드롭다운에 띄울 언어 목록.
  final List<String> languages;

  /// 처음 보여 줄 보조 · 추가 보조 언어(디자인에서 고른 것). 추가 보조 '' = 없음.
  final String subLanguage;
  final String extraLanguage;

  /// 미리보기·넘침 측정에 쓰는 지금 디자인.
  final ExportStyle style;

  @override
  State<LyricsEditorDialog> createState() => _LyricsEditorDialogState();
}

class _LyricsEditorDialogState extends State<LyricsEditorDialog> {
  /// 마지막으로 쓴 보기. 앱이 켜져 있는 동안 기억한다.
  static _EditorView _lastView = _EditorView.table;

  late final TextEditingController _titleController;
  late _EditorView _view = _lastView;

  /// 언어별 저장 형식 글. 원본은 [_original].
  late String _original;
  late Map<String, String> _texts;
  late String _subLanguage;
  late String _extraLanguage; // '' = 없음

  late LyricsPageGrid _grid;
  List<List<TextEditingController>> _cells = const [];
  List<List<FocusNode>> _focus = const [];
  ({int row, int column})? _focused;
  int _selectedRow = 0;

  /// 페이지 번호를 눌러 고른 행들(복사용). Shift = 범위, ⌘/Ctrl = 하나씩.
  final Set<int> _pickedRows = {};
  int? _pickAnchor;

  /// 세 언어째 복사한 페이지들. 창을 닫아도 남아 다른 곡에 붙여 넣을 수 있다.
  static List<List<String>> _pageClipboard = const [];

  /// '코드 복사'로 담은 한 페이지 코드 글. 붙여 넣으면 가사는 그대로 두고 코드 자리만 옮긴다.
  static String? _chordClipboard;

  /// 페이지를 고르면 입력칸 대신 표가 포커스를 받아 ⌘/Ctrl+C·V 를 페이지 복사·붙여 넣기로 쓴다.
  final FocusNode _tableFocus = FocusNode(debugLabel: 'lyrics table');

  /// '통째로' 보기 입력칸(원본·보조·추가 보조).
  final List<ChordTextController> _whole = List.generate(
    LyricsPageGrid.columnCount,
    (_) => ChordTextController()..highlight = false,
  );

  /// 붙여 넣기로 나눈 직후 되돌리기용.
  ({LyricsPageGrid before, String message})? _undo;

  bool _previewSub = true;
  bool _previewExtra = true;
  bool _translating = false;

  // ── 코드 ──
  bool _chordMode = false;

  /// 코드 글 전체(원본 가사 + 코드). null = 아직 코드를 쓴 적 없음.
  String? _chordText;

  /// 원래 조. null = 모름(첫 코드로 추정).
  String? _chordKey;

  /// 코드 모드 알림(대괄호 이스케이프·다시 맞춤).
  String? _chordNotice;

  /// 평소 모드에서 가사를 고쳤는데 코드를 확실히 다시 맞추지 못했을 때 — 저장 전에 묻는 배너.
  ChordRealign? _realignOffer;

  /// '코드 위 가사' 꼴을 붙여 넣었을 때 바꿀지 묻는 배너(S1c). [before] = 붙여 넣기 전 표.
  ({int row, LyricsPageGrid before, String converted})? _pasteOffer;

  @override
  void initState() {
    super.initState();
    final song = widget.song;
    _titleController = TextEditingController(text: song?.title ?? '');
    _original = song?.lyrics ?? '';
    _chordText = song?.chordLyrics;
    _chordKey = song?.chordKey;
    if (widget.contiOnly) {
      _texts = {
        widget.subLanguage: song?.englishLyrics ?? '',
        if (widget.extraLanguage.isNotEmpty)
          widget.extraLanguage: song?.extraLyrics ?? '',
      };
      _subLanguage = widget.subLanguage;
      _extraLanguage = widget.extraLanguage;
      _loadGrid();
      _loadWhole();
      return;
    }
    _texts = {
      PraiseRepository.defaultSubLanguage: song?.englishLyrics ?? '',
      for (final language in widget.languages)
        if (language != PraiseRepository.defaultSubLanguage)
          language: widget.translations[language] ?? '',
      ...widget.translations,
    };
    _subLanguage = _texts.containsKey(widget.subLanguage)
        ? widget.subLanguage
        : PraiseRepository.defaultSubLanguage;
    _extraLanguage =
        widget.extraLanguage != _subLanguage &&
            _texts.containsKey(widget.extraLanguage)
        ? widget.extraLanguage
        : '';
    _loadGrid();
    _loadWhole();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _tableFocus.dispose();
    _disposeCells();
    for (final c in _whole) {
      c.dispose();
    }
    super.dispose();
  }

  // ── 글 ↔ 표 ────────────────────────────────────────────────────────────

  bool get _hasExtra => _extraLanguage.isNotEmpty;

  List<String> get _columnTexts => [
    _chordMode ? (_chordText ?? '') : _original,
    _texts[_subLanguage] ?? '',
    _hasExtra ? (_texts[_extraLanguage] ?? '') : '',
  ];

  void _storeColumnTexts(List<String> texts) {
    if (_chordMode) {
      _chordText = normalizeEditableLyrics(texts[0]);
      _original = stripChords(_chordText!);
    } else {
      _original = normalizeEditableLyrics(texts[0]);
    }
    _texts[_subLanguage] = normalizeEditableLyrics(texts[1]);
    if (_hasExtra) _texts[_extraLanguage] = normalizeEditableLyrics(texts[2]);
  }

  /// 지금 보기의 글을 언어별 글([_original]·[_texts])에 되돌려 넣는다.
  void _commit() {
    if (_view == _EditorView.table) {
      _storeColumnTexts(_grid.toTexts());
    } else {
      _storeColumnTexts([for (final c in _whole) c.text]);
    }
  }

  void _loadGrid() {
    _grid = LyricsPageGrid.fromTexts(_columnTexts);
    _rebuildCells();
  }

  void _loadWhole() {
    final texts = _columnTexts;
    for (var c = 0; c < _whole.length; c++) {
      _whole[c].text = lyricsToEditText(texts[c]);
    }
    _whole[0].highlight = _chordMode;
  }

  void _disposeCells() {
    final cells = _cells;
    final focus = _focus;
    void dispose() {
      for (final row in cells) {
        for (final c in row) {
          c.dispose();
        }
      }
      for (final row in focus) {
        for (final f in row) {
          f.dispose();
        }
      }
    }

    // 표를 다시 만들 때는 지금 화면의 입력칸이 아직 옛 것을 쥐고 있다 — 다음 화면 뒤에 버린다.
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => dispose());
    } else {
      dispose();
    }
  }

  /// 표 구조(행 수)가 바뀌면 칸 컨트롤러를 새로 만든다. [focus] 칸에 커서를 둔다.
  void _rebuildCells({
    ({int row, int column})? focus,
    bool caretAtEnd = false,
  }) {
    _disposeCells();
    _cells = [
      for (var r = 0; r < _grid.length; r++)
        [
          for (var c = 0; c < LyricsPageGrid.columnCount; c++)
            c == 0 && _chordMode
                ? ChordTextController(text: _grid.cell(r, c))
                : TextEditingController(text: _grid.cell(r, c)),
        ],
    ];
    _focus = [
      for (var r = 0; r < _grid.length; r++)
        [
          for (var c = 0; c < LyricsPageGrid.columnCount; c++)
            FocusNode()..addListener(() => _onFocusChanged(r, c)),
        ],
    ];
    _selectedRow = _selectedRow.clamp(0, _grid.length - 1);
    _pickedRows.clear(); // 행 번호가 바뀌었으니 고른 것도 푼다
    _pickAnchor = null;
    if (focus == null) return;
    final row = focus.row.clamp(0, _grid.length - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || row >= _focus.length) return;
      final controller = _cells[row][focus.column];
      controller.selection = TextSelection.collapsed(
        offset: caretAtEnd ? controller.text.length : 0,
      );
      _focus[row][focus.column].requestFocus();
    });
  }

  void _onFocusChanged(int row, int column) {
    if (!mounted || row >= _focus.length) return;
    final hasFocus = _focus[row][column].hasFocus;
    setState(() {
      if (hasFocus) {
        _focused = (row: row, column: column);
        _selectedRow = row;
      } else if (_focused == (row: row, column: column)) {
        _focused = null;
      }
    });
  }

  // ── 표 조작 ────────────────────────────────────────────────────────────

  void _onCellChanged(int row, int column, String text) {
    final before = _grid.copy();
    // 코드 모드 원본 칸에 '코드 줄 + 가사 줄' 악보를 붙여 넣었으면 바꿀지 묻는다(S1c).
    // 이미 그 꼴이던 칸을 고치는 중이면 다시 묻지 않는다.
    final offer = _chordMode && column == 0
        ? chordOverLyricsToInline(text)
        : null;
    final offerNew =
        offer != null && chordOverLyricsToInline(before.cell(row, 0)) == null;
    if (offerNew) {
      _pasteOffer = (row: row, before: before, converted: offer);
    } else if (_pasteOffer != null && offer == null) {
      _pasteOffer = null;
    }
    _grid.setCell(row, column, text);
    // 빈 줄 = 페이지 구분. 붙여 넣거나 엔터를 두 번 치면 그 자리에서 다음 행으로 넘긴다.
    if (RegExp(r'\n[ \t]*\n').hasMatch(text.replaceAll('\r\n', '\n'))) {
      final pieces = _grid.splitCell(row, column);
      setState(() {
        // 되돌리기는 바로 앞 붙여 넣기만 — 그 뒤에 고친 것까지 지우지 않게 다른 입력이 오면 닫는다.
        _undo = pieces >= 3
            ? (
                before: before,
                message:
                    '${_columnName(column)} 칸에 붙여 넣은 가사를 빈 줄마다 나눠 '
                    '${row + 1}~${row + pieces}페이지에 넣었습니다.',
              )
            : null;
        _rebuildCells(focus: (row: row + pieces - 1, column: column));
      });
      return;
    }
    setState(() => _undo = null); // 행 높이·넘침 표시도 다시 잰다
  }

  void _mutate(void Function() change, {({int row, int column})? focus}) {
    setState(() {
      change();
      _undo = null;
      _rebuildCells(focus: focus);
    });
  }

  void _undoSplit() {
    final undo = _undo;
    if (undo == null) return;
    setState(() {
      _grid = undo.before;
      _undo = null;
      _rebuildCells();
    });
  }

  void _splitAtCursor() {
    final target = _cursorTarget();
    if (target != null) _splitAt(target);
  }

  /// 지금 커서가 있는 칸과 위치. 커서가 없으면 null.
  ({int row, int column, int offset})? _cursorTarget() {
    final focused = _focused;
    if (focused == null) return null;
    final offset = _cells[focused.row][focused.column].selection.baseOffset;
    return (
      row: focused.row,
      column: focused.column,
      offset: offset < 0 ? 0 : offset,
    );
  }

  void _splitAt(({int row, int column, int offset}) target) {
    // 코드 토큰 안·`\[` 사이에서 나누지 않게 토큰 앞으로 당긴다(토큰은 뒤 조각 맨 앞으로 간다).
    final offset = _chordMode && target.column == 0
        ? snapSplitOffset(_grid.cell(target.row, 0), target.offset)
        : target.offset;
    _mutate(
      () => _grid.splitAt(target.row, target.column, offset),
      focus: (row: target.row + 1, column: target.column),
    );
  }

  void _pickRow(int row) {
    final keyboard = HardwareKeyboard.instance;
    _tableFocus.requestFocus();
    setState(() {
      final anchor = _pickAnchor;
      if (keyboard.isShiftPressed && anchor != null) {
        _pickedRows
          ..clear()
          ..addAll([
            for (
              var r = anchor < row ? anchor : row;
              r <= (anchor < row ? row : anchor);
              r++
            )
              r,
          ]);
        return;
      }
      if (keyboard.isMetaPressed || keyboard.isControlPressed) {
        if (!_pickedRows.remove(row)) _pickedRows.add(row);
      } else {
        _pickedRows
          ..clear()
          ..add(row);
      }
      _pickAnchor = row;
    });
  }

  /// [row] 가 고른 행 안이면 고른 행 전부, 아니면 그 행만 (세 언어째) 복사한다.
  void _copyRows(int row) {
    final rows = _pickedRows.contains(row)
        ? (_pickedRows.toList()..sort())
        : [row];
    _pageClipboard = [for (final r in rows) _grid.row(r)];
    setState(() {});
  }

  /// 표에 포커스가 있을 때(입력칸 밖) ⌘/Ctrl+C = 고른 페이지 복사, ⌘/Ctrl+V = 고른 페이지 아래에 붙여 넣기.
  /// 입력칸 안에서는 평소처럼 글자 복사·붙여 넣기다.
  KeyEventResult _handleTableKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isMetaPressed && !keyboard.isControlPressed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyC && _pickedRows.isNotEmpty) {
      _copyRows(_pickedRows.first);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        _pageClipboard.isNotEmpty) {
      final at = _pickedRows.isEmpty
          ? _selectedRow + 1
          : _pickedRows.reduce((a, b) => a > b ? a : b) + 1;
      _pasteRows(at, keepTableFocus: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// [keepTableFocus] 면 입력칸으로 커서를 옮기지 않고 붙여 넣은 페이지를 골라 둔다(⌘V 를 이어 누르면 그 뒤에 또 붙는다).
  void _pasteRows(int at, {bool keepTableFocus = false}) {
    final before = _grid.copy();
    final count = _pageClipboard.length;
    setState(() {
      _grid.insertRows(at, _pageClipboard);
      final first = at.clamp(0, _grid.length - count);
      _undo = (
        before: before,
        message: '복사한 $count페이지를 ${first + 1}페이지부터 넣었습니다.',
      );
      if (keepTableFocus) {
        _rebuildCells();
        _pickedRows.addAll([for (var r = first; r < first + count; r++) r]);
        _pickAnchor = first;
        _selectedRow = first;
      } else {
        _rebuildCells(focus: (row: first, column: 0));
      }
    });
  }

  String _columnName(int column) => switch (column) {
    0 => '원본',
    1 => '보조',
    _ => '추가 보조',
  };

  // ── 언어 ───────────────────────────────────────────────────────────────

  void _switchLanguage(int column, String language) {
    setState(() {
      _commit();
      if (column == 1) {
        _subLanguage = language;
      } else {
        _extraLanguage = language;
      }
      _undo = null;
      _loadGrid();
      _loadWhole();
    });
  }

  Future<void> _addLanguage(int column) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _LanguagePrompt(),
    );
    final language = name?.trim() ?? '';
    if (language.isEmpty || !mounted) return;
    _texts.putIfAbsent(language, () => '');
    final other = column == 1 ? _extraLanguage : _subLanguage;
    if (language == other) return;
    _switchLanguage(column, language);
  }

  // ── 번역 · 변환 (Claude) ───────────────────────────────────────────────

  /// 원본 페이지마다 보조·추가 보조 칸을 채운다. 언어 이름에 '발음' 이 들면 발음을 영어 글자로,
  /// 아니면 그 언어로 번역한다. 이미 채운 칸이 있으면 빈 칸만 채울지 묻는다.
  Future<void> _translate() async {
    setState(_commit);
    // 코드 모드여도 Claude 에는 코드 뺀 원본 가사만 넘긴다(대괄호를 번역하지 않게).
    final grid = LyricsPageGrid.fromTexts(_plainColumnTexts);
    final columns = [1, if (_hasExtra) 2];
    final hasFilled = [
      for (final c in columns)
        for (var r = 0; r < grid.length; r++)
          if (grid.cell(r, 0).trim().isNotEmpty &&
              grid.cell(r, c).trim().isNotEmpty)
            r,
    ].isNotEmpty;
    var overwrite = false;
    if (hasFilled) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('번역·변환'),
          content: const Text('이미 입력된 페이지가 있습니다. 어떻게 할까요?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('빈 페이지만 채우기'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('모두 다시 채우기'),
            ),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      overwrite = choice;
    }
    final languages = {1: _subLanguage, if (_hasExtra) 2: _extraLanguage};
    final pages = [for (var r = 0; r < grid.length; r++) grid.cell(r, 0)];

    setState(() => _translating = true);
    try {
      final results = await Future.wait([
        for (final c in columns)
          ClaudeTranslator.translatePages(pages, languages[c]!),
      ]);
      if (!mounted) return;
      setState(() {
        for (var i = 0; i < columns.length; i++) {
          final c = columns[i];
          for (var r = 0; r < grid.length; r++) {
            final text = results[i][r];
            if (text.isEmpty) continue;
            if (overwrite || grid.cell(r, c).trim().isEmpty) {
              grid.setCell(r, c, text);
            }
          }
        }
        final texts = grid.toTexts();
        _texts[_subLanguage] = normalizeEditableLyrics(texts[1]);
        if (_hasExtra) {
          _texts[_extraLanguage] = normalizeEditableLyrics(texts[2]);
        }
        _undo = null;
        _loadGrid();
        _loadWhole();
      });
    } catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('번역·변환 실패'),
          content: Text('$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('닫기'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  /// 원본 열이 코드 뺀 가사인 열 글(번역·넘침 측정용).
  List<String> get _plainColumnTexts => [_original, ..._columnTexts.skip(1)];

  // ── 코드 ───────────────────────────────────────────────────────────────

  bool get _hasChordTokens =>
      _chordText != null && countChords(_chordText!) > 0;

  void _setChordMode(bool on) {
    if (on == _chordMode) return;
    setState(() {
      _commit();
      _undo = null;
      _pasteOffer = null;
      if (on) {
        _prepareChordText();
        _realignOffer = null;
      } else {
        _chordNotice = null;
      }
      _chordMode = on;
      _loadGrid();
      _loadWhole();
    });
  }

  /// 코드 모드로 들어갈 때 코드 글을 지금 가사에 맞춘다. 처음이면 가사를 이스케이프해 시작값으로,
  /// 가사가 코드 글과 어긋나 있으면 다시 맞춘다(지금 가사가 기준 — 저장하면 가사가 되돌아가지 않게).
  void _prepareChordText() {
    final lyrics = normalizeEditableLyrics(_original);
    final chord = _chordText;
    if (chord == null) {
      final n = countEscapedBrackets(lyrics);
      _chordText = escapeLyricsForChords(lyrics);
      _chordNotice = n == 0 ? null : '가사에 원래 있던 대괄호 $n개는 글자로 둡니다.';
      return;
    }
    if (stripChords(chord) == lyrics) return;
    final r = realignChords(chord, lyrics);
    if (stripChords(r.chordText) == lyrics) {
      _chordText = r.chordText;
      _chordNotice =
          '가사가 바뀌어 코드를 다시 맞췄습니다 — 그대로 ${r.kept}개 · 옮김 ${r.moved}개'
          '${r.dropped > 0 ? ' · 버림 ${r.dropped}개' : ''}. 위치를 확인해 주세요.';
    } else {
      _chordText = escapeLyricsForChords(lyrics);
      _chordNotice = '가사와 어긋난 코드를 다시 맞추지 못해 코드 없이 시작합니다.';
    }
  }

  /// 원본 칸 미리보기 글자를 눌렀을 때(S1b): 그 글자 앞에 코드를 넣거나 있던 코드를 바꾸고 지운다.
  Future<void> _pickChordAt(int row, int line, int offset) async {
    final cell = _grid.cell(row, 0);
    final slot = chordSlotAt(cell, line, offset);
    if (slot == null) return;
    final lines = parseChordPage(cell);
    final text = line < lines.length ? lines[line].text : '';
    final charLabel = offset < text.length ? text[offset] : '';
    final current = slot.tokens.isEmpty
        ? null
        : slot.tokens.map((t) => t.name).join(' ');
    final all = _chordModeText;
    final pick = await showDialog<ChordPick>(
      context: context,
      builder: (_) => ChordPickDialog(
        current: current,
        songChords: chordNamesIn(all),
        songKey: _chordKey ?? estimateKey(all),
        charLabel: charLabel.trim(),
      ),
    );
    if (pick == null || !mounted) return;
    final start = slot.tokens.isEmpty ? slot.insertAt : slot.tokens.first.start;
    final end = slot.tokens.isEmpty ? slot.insertAt : slot.tokens.last.end;
    final replaced = cell.replaceRange(
      start,
      end,
      pick.name == null ? '' : '[${pick.name}]',
    );
    setState(() {
      _grid.setCell(row, 0, replaced);
      _cells[row][0].text = replaced;
      _undo = null;
    });
    // Tab = 넣고 다음 글자로.
    if (pick.next && pick.name != null && offset < text.length) {
      await _pickChordAt(row, line, offset + 1);
    }
  }

  /// 코드 모드 표의 원본 열 전체(요약·빠른 버튼용).
  String get _chordModeText =>
      _view == _EditorView.table ? _grid.toTexts()[0] : _whole[0].text;

  bool _rowHasChords(int row) => countChords(_grid.cell(row, 0)) > 0;

  /// [row] 와 가사가 똑같은 다른 페이지(코드 모드 원본 칸 기준).
  List<int> _sameLyricsRows(int row) {
    final lyrics = stripChords(_grid.cell(row, 0));
    if (lyrics.isEmpty) return const [];
    return [
      for (var r = 0; r < _grid.length; r++)
        if (r != row && stripChords(_grid.cell(r, 0)) == lyrics) r,
    ];
  }

  /// [source] 코드 글을 [rows] 페이지에 옮겨 붙인다(가사 그대로). 되돌리기 배너를 띄운다.
  void _pasteChordsInto(String source, List<int> rows) {
    final before = _grid.copy();
    var done = 0;
    for (final r in rows) {
      final pasted = copyChordsToPage(source, _grid.cell(r, 0));
      if (pasted == null) continue;
      _grid.setCell(r, 0, pasted);
      done++;
    }
    setState(() {
      _undo = done == 0
          ? null
          : (before: before, message: '코드를 $done페이지에 넣었습니다. 위치를 확인해 주세요.');
      _rebuildCells();
    });
  }

  /// 붙여 넣을 페이지: [row] 가 고른 행 안이면 고른 행 전부, 아니면 그 행만.
  List<int> _targetRows(int row) =>
      _pickedRows.contains(row) ? (_pickedRows.toList()..sort()) : [row];

  void _applyPasteOffer() {
    final offer = _pasteOffer;
    if (offer == null) return;
    setState(() {
      _grid = offer.before.copy();
      _grid.setCell(offer.row, 0, offer.converted);
      final pieces = _grid.splitCell(offer.row, 0);
      _pasteOffer = null;
      _undo = (before: offer.before, message: '코드 위 가사를 코드 표기로 바꿨습니다.');
      _rebuildCells(focus: (row: offer.row + pieces - 1, column: 0));
    });
  }

  void _fixChordCase(int row, ({int start, int end, ChordIssue issue}) range) {
    final cell = _grid.cell(row, 0);
    final fixed = cell.replaceRange(
      range.start,
      range.end,
      range.issue.suggestion!,
    );
    setState(() {
      _grid.setCell(row, 0, fixed);
      _cells[row][0].text = fixed;
    });
  }

  // ── 보기 · 저장 ────────────────────────────────────────────────────────

  void _setView(_EditorView view) {
    if (view == _view) return;
    setState(() {
      _commit();
      _view = view;
      _lastView = view;
      _undo = null;
      if (view == _EditorView.table) {
        _loadGrid();
      } else {
        _loadWhole();
      }
    });
  }

  /// 저장. 코드가 있으면 결과 곡 chordLyrics·chordKey 에 싣는다(코드 토큰이 하나도 없으면 코드 없음).
  /// [keepChords] = 평소 모드에서 가사를 고쳤지만 코드는 옛 글 그대로 둔다(다시 맞추기 배너의 선택).
  Future<void> _save({bool keepChords = false}) async {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    setState(_commit);
    final song = widget.song;
    final lyrics = normalizeEditableLyrics(_original);
    var chord = _hasChordTokens ? _chordText : null;
    String? notice;
    // 평소 모드에서 가사를 고쳤으면 코드를 다시 맞춘다. 확실할 때만 저절로, 아니면 묻는다(§3-5).
    if (!_chordMode &&
        !keepChords &&
        chord != null &&
        lyrics != normalizeEditableLyrics(song?.lyrics ?? '') &&
        stripChords(chord) != lyrics) {
      final r = realignChords(chord, lyrics);
      if (r.confident && stripChords(r.chordText) == lyrics) {
        chord = r.chordText;
        notice =
            '코드 ${r.kept}개 그대로${r.moved > 0 ? ', ${r.moved}개 옮김' : ''} — 가사에 맞춰 저장했습니다.';
      } else {
        setState(() => _realignOffer = r);
        return;
      }
    }
    if (chord != null && !await _confirmChordWarnings(chord)) return;
    if (!mounted) return;
    if (notice != null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(notice)));
    }
    if (widget.contiOnly && song != null) {
      Navigator.of(context).pop((
        song.copyWith(
          lyrics: _original,
          englishLyrics: _texts[_subLanguage] ?? '',
          extraLyrics: _hasExtra
              ? _texts[_extraLanguage] ?? ''
              : song.extraLyrics,
          chordLyrics: chord,
          chordKey: _chordKey,
        ),
        const <String, String>{},
      ));
      return;
    }
    Navigator.of(context).pop((
      PraiseSong(
        id: song?.id,
        fileName: song?.fileName ?? title,
        title: title,
        lyrics: _original,
        englishLyrics: _texts[PraiseRepository.defaultSubLanguage] ?? '',
        chordLyrics: chord,
        chordKey: _chordKey,
      ),
      Map<String, String>.from(_texts),
    ));
  }

  /// 저장 전 확인(저장은 막지 않는다): 코드로 못 읽는 대괄호는 관객 화면에 글자로 나가고,
  /// 끝의 코드만 있는 페이지는 짝이 없어 안 보인다.
  Future<bool> _confirmChordWarnings(String chord) async {
    final issues = validateChordText(chord);
    final unreadable = issues
        .where((i) => i.kind != ChordIssueKind.trailingChordOnlyPage)
        .length;
    final trailing = issues.any(
      (i) => i.kind == ChordIssueKind.trailingChordOnlyPage,
    );
    if (unreadable == 0 && !trailing) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('코드 확인'),
        content: Text(
          [
            if (unreadable > 0)
              '코드로 못 읽는 대괄호가 $unreadable개 있습니다. 관객 화면에 글자로 나갑니다.',
            if (trailing) '마지막 페이지가 코드뿐입니다. 이 페이지 코드는 보이지 않습니다.',
          ].join('\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('돌아가 고치기'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('그대로 저장'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// 다시 맞추기 배너 '다시 맞춘 결과로 바꾸기' — 코드 모드로 열어 확인하게 한다.
  void _takeRealign() {
    final r = _realignOffer;
    if (r == null) return;
    setState(() {
      _realignOffer = null;
      if (stripChords(r.chordText) == normalizeEditableLyrics(_original)) {
        _chordText = r.chordText;
      }
    });
    _setChordMode(true);
    setState(
      () => _chordNotice =
          '다시 맞춘 코드입니다 — 그대로 ${r.kept}개 · 옮김 ${r.moved}개'
          '${r.dropped > 0 ? ' · 버림 ${r.dropped}개' : ''}. 위치를 확인한 뒤 저장하세요.',
    );
  }

  // ── 화면 ───────────────────────────────────────────────────────────────

  SlidePageData _pageData(int row, {bool forPreview = false}) {
    final texts = _grid.row(row);
    return SlidePageData(
      mainText: _chordMode ? stripChords(texts[0]) : texts[0].trim(),
      englishText: forPreview && !_previewSub ? '' : texts[1].trim(),
      extraText: !_hasExtra || (forPreview && !_previewExtra)
          ? ''
          : texts[2].trim(),
      title: _titleController.text.trim(),
      isBible: false,
      pageIndex: row,
      totalPages: _grid.length,
      style: widget.style,
    );
  }

  double _overflowAt(int row) =>
      SlideTextLayout.cachedOverflowRatio(_pageData(row));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isNew = widget.song?.id == null;
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 1240,
          maxHeight: size.height * 0.9,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showPreview =
                  _view == _EditorView.table && constraints.maxWidth >= 1000;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(isNew),
                  const SizedBox(height: 12),
                  if (_undo != null) _buildUndoBanner(cs),
                  if (_pasteOffer != null)
                    _banner(
                      cs,
                      icon: Icons.music_note_rounded,
                      message: '코드 위 가사 형식 같습니다.',
                      actions: [
                        TextButton(
                          onPressed: _applyPasteOffer,
                          child: const Text('코드 표기로 바꾸기'),
                        ),
                        TextButton(
                          onPressed: () => setState(() => _pasteOffer = null),
                          child: const Text('그대로 두기'),
                        ),
                      ],
                    ),
                  if (_realignOffer case final r?)
                    _banner(
                      cs,
                      icon: Icons.warning_amber_rounded,
                      warn: true,
                      message:
                          '코드 확인 필요 — 가사가 바뀐 페이지 '
                          '${hiddenChordPageCount(_chordText, _original)}곳은 코드가 숨겨집니다 '
                          '(다시 맞추면 옮김 ${r.moved}개 · 버림 ${r.dropped}개).',
                      actions: [
                        TextButton(
                          onPressed: _takeRealign,
                          child: const Text('다시 맞춘 결과로 바꾸기'),
                        ),
                        TextButton(
                          onPressed: () => _save(keepChords: true),
                          child: const Text('코드는 그대로 두고 저장'),
                        ),
                      ],
                      onClose: () => setState(() => _realignOffer = null),
                    ),
                  if (_chordMode && _chordNotice != null)
                    _banner(
                      cs,
                      icon: Icons.info_outline_rounded,
                      message: _chordNotice!,
                      onClose: () => setState(() => _chordNotice = null),
                    ),
                  Expanded(
                    child: _view == _EditorView.whole
                        ? _buildWhole(cs)
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _buildTable(cs)),
                              if (showPreview) ...[
                                const SizedBox(width: 18),
                                SizedBox(width: 300, child: _buildPreview(cs)),
                              ],
                            ],
                          ),
                  ),
                  const SizedBox(height: 12),
                  Divider(height: 1, color: cs.outlineVariant),
                  const SizedBox(height: 12),
                  _buildFooter(cs, isNew),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool isNew) {
    return Row(
      children: [
        Text(
          widget.contiOnly ? '이 콘티에서만 수정' : (isNew ? '새 곡 추가' : '가사 수정'),
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 14),
        if (widget.contiOnly)
          Expanded(
            child: Text(
              '${widget.song?.displayTitle ?? ''} · 저장된 곡은 그대로 두고 이번 콘티에만 적용됩니다',
              overflow: TextOverflow.ellipsis,
            ),
          )
        else
          Expanded(
            child: TextField(
              controller: _titleController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '제목',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
        const SizedBox(width: 14),
        Tooltip(
          message:
              '원본 가사 위에 코드(G, D/F#, Em7 …)를 넣습니다.\n'
              '코드는 싱어·휴대폰·발표 보기에서만 보이고 관객 화면·PPTX 에는 안 나갑니다.',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('코드', style: TextStyle(fontWeight: FontWeight.w600)),
              Switch(value: _chordMode, onChanged: _setChordMode),
            ],
          ),
        ),
        if (_chordMode) ...[const SizedBox(width: 6), _keyPicker()],
        const SizedBox(width: 14),
        Tooltip(
          message:
              '원본 가사로 보조·추가 보조 칸을 채웁니다 (Claude).\n'
              "언어 이름에 '발음'이 들어 있으면 한글 발음을 영어 글자로, 아니면 그 언어로 번역합니다.",
          child: OutlinedButton.icon(
            onPressed: _translating ? null : _translate,
            icon: _translating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.translate_rounded, size: 18),
            label: Text(_translating ? '번역 중…' : '번역·변환'),
          ),
        ),
        const SizedBox(width: 14),
        SegmentedButton<_EditorView>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: _EditorView.table, label: Text('페이지 표')),
            ButtonSegment(value: _EditorView.whole, label: Text('통째로')),
          ],
          selected: {_view},
          onSelectionChanged: (s) => _setView(s.first),
        ),
      ],
    );
  }

  /// 원래 조 고르기. 비워 두면 첫 코드로 추정한 조를 '(추정)'으로 보여 준다.
  Widget _keyPicker() {
    final estimated = estimateKey(_chordModeText);
    const majors = [
      'C',
      'Db',
      'D',
      'Eb',
      'E',
      'F',
      'F#',
      'G',
      'Ab',
      'A',
      'Bb',
      'B',
    ];
    const minors = [
      'Am',
      'Bbm',
      'Bm',
      'Cm',
      'C#m',
      'Dm',
      'Ebm',
      'Em',
      'Fm',
      'F#m',
      'Gm',
      'G#m',
    ];
    final key = _chordKey;
    final keys = [
      ...majors,
      ...minors,
      if (key != null &&
          isKeyName(key) &&
          !majors.contains(key) &&
          !minors.contains(key))
        key,
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('원래 조 '),
        DropdownButton<String>(
          value: key != null && isKeyName(key) ? key : '',
          isDense: true,
          items: [
            DropdownMenuItem(
              value: '',
              child: Text(estimated == null ? '모름' : '$estimated (추정)'),
            ),
            for (final k in keys) DropdownMenuItem(value: k, child: Text(k)),
          ],
          onChanged: (v) =>
              setState(() => _chordKey = v == null || v.isEmpty ? null : v),
        ),
      ],
    );
  }

  Widget _banner(
    ColorScheme cs, {
    required IconData icon,
    required String message,
    List<Widget> actions = const [],
    bool warn = false,
    VoidCallback? onClose,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: warn ? cs.tertiaryContainer : cs.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.panel),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 16,
            color: warn ? cs.onTertiaryContainer : cs.primary,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
          ...actions,
          if (onClose != null)
            IconButton(
              tooltip: '닫기',
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: onClose,
            ),
        ],
      ),
    );
  }

  Widget _buildUndoBanner(ColorScheme cs) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.panel),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.content_cut_rounded, size: 16, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(_undo!.message)),
          TextButton(onPressed: _undoSplit, child: const Text('되돌리기')),
          IconButton(
            tooltip: '닫기',
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () => setState(() => _undo = null),
          ),
        ],
      ),
    );
  }

  // ── 페이지 표 ──────────────────────────────────────────────────────────

  Widget _buildTable(ColorScheme cs) {
    return Focus(
      focusNode: _tableFocus,
      onKeyEvent: _handleTableKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _tableRow(
            leading: const SizedBox.shrink(),
            cells: [
              _columnHeader(cs, 0),
              _columnHeader(cs, 1),
              _columnHeader(cs, 2),
            ],
            trailing: const SizedBox.shrink(),
            crossAxisAlignment: CrossAxisAlignment.center,
          ),
          const SizedBox(height: 6),
          Divider(height: 1, color: cs.outlineVariant),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              itemCount: _grid.length + 1,
              itemBuilder: (context, row) => row == _grid.length
                  ? Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: () => _mutate(
                            () => _grid.insertRow(_grid.length),
                            focus: (row: _grid.length, column: 0),
                          ),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('페이지 추가'),
                        ),
                      ),
                    )
                  : _buildPageRow(cs, row),
            ),
          ),
        ],
      ),
    );
  }

  /// 페이지 번호 · 칸 세 개(추가 보조가 없으면 두 개) · 메뉴. 머리줄과 같은 너비로 맞춘다.
  Widget _tableRow({
    required Widget leading,
    required List<Widget> cells,
    required Widget trailing,
    CrossAxisAlignment crossAxisAlignment = CrossAxisAlignment.start,
  }) {
    return Row(
      crossAxisAlignment: crossAxisAlignment,
      children: [
        SizedBox(width: 34, child: leading),
        for (var c = 0; c < cells.length; c++) ...[
          if (c > 0) const SizedBox(width: 8),
          Expanded(child: cells[c]),
        ],
        SizedBox(width: 36, child: trailing),
      ],
    );
  }

  Widget _columnHeader(ColorScheme cs, int column) {
    final style = widget.style;
    final color = switch (column) {
      0 => style.textColor,
      1 => style.englishTextColor,
      _ => style.extraTextColor,
    };
    final dot = Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: cs.outline),
      ),
    );
    final label = Text(
      _columnName(column),
      style: const TextStyle(fontWeight: FontWeight.w700),
    );
    if (column == 0) {
      return Row(children: [dot, const SizedBox(width: 8), label]);
    }
    final current = column == 1 ? _subLanguage : _extraLanguage;
    final other = column == 1 ? _extraLanguage : _subLanguage;
    // 콘티에 담을 때 언어가 이미 정해졌다 — 이름만 보여 준다(바꾸려면 디자인 탭).
    if (widget.contiOnly) {
      return Row(
        children: [
          dot,
          const SizedBox(width: 8),
          label,
          const SizedBox(width: 8),
          Flexible(child: Text(current, overflow: TextOverflow.ellipsis)),
        ],
      );
    }
    return Row(
      children: [
        dot,
        const SizedBox(width: 8),
        label,
        const SizedBox(width: 8),
        Flexible(
          child: DropdownButton<String>(
            value: current,
            isDense: true,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            items: [
              if (column == 2)
                const DropdownMenuItem(value: '', child: Text('없음')),
              for (final language in _texts.keys)
                if (language != other)
                  DropdownMenuItem(value: language, child: Text(language)),
            ],
            onChanged: (language) {
              if (language != null && language != current) {
                _switchLanguage(column, language);
              }
            },
          ),
        ),
        TextButton(
          onPressed: () => _addLanguage(column),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: 6),
          ),
          child: const Text('＋ 언어'),
        ),
      ],
    );
  }

  Widget _buildPageRow(ColorScheme cs, int row) {
    final selected = row == _selectedRow;
    final picked = _pickedRows.contains(row);
    final blank = _grid.isBlankRow(row);
    final ratio = _overflowAt(row);
    final overflow = ratio > SlideTextLayout.overflowThreshold;
    final lines = [
      for (var c = 0; c < LyricsPageGrid.columnCount; c++)
        _grid.cell(row, c).split('\n').length,
    ].fold(2, (a, b) => a > b ? a : b);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(vertical: 6),
      // 선택이 바뀌어도 늘 같은 DecoratedBox — 위젯 구조가 바뀌면 입력칸이 새로 만들어져
      // 한글 조합(IME)이 끊긴다.
      decoration: BoxDecoration(
        color: picked
            ? cs.secondaryContainer
            : selected
            ? cs.surfaceContainerHigh
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.panel),
      ),
      child: _tableRow(
        leading: Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            children: [
              Tooltip(
                message:
                    '눌러서 페이지 고르기 (Shift = 범위, ⌘/Ctrl = 하나씩)\n'
                    '고른 뒤 ⌘/Ctrl+C·V 또는 ⋮ 메뉴로 세 언어째 복사·붙여 넣기',
                waitDuration: const Duration(milliseconds: 600),
                child: InkWell(
                  onTap: () => _pickRow(row),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${row + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: selected || picked
                            ? cs.primary
                            : cs.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ),
              if (!_chordMode && _chordPageRows.contains(row))
                Tooltip(
                  message: '이 페이지에 코드가 있습니다 (머리줄 코드 스위치로 보기)',
                  child: Text(
                    '♪',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
              if (overflow)
                Tooltip(
                  message:
                      '관객 화면에서 가사 상자를 넘습니다 '
                      '(${SlideTextLayout.overflowLabel(ratio)}). '
                      '페이지를 나누거나 디자인에서 글자 크기를 줄여 주세요.',
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: cs.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        cells: [
          for (var c = 0; c < (_hasExtra ? 3 : 2); c++)
            _buildCell(cs, row, c, lines: lines, blankRow: blank),
          if (!_hasExtra) _extraPlaceholder(cs, row),
        ],
        trailing: _rowMenu(row),
      ),
    );
  }

  Widget _extraPlaceholder(ColorScheme cs, int row) {
    if (row != 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        widget.contiOnly
            ? '디자인 탭에서 추가 보조 언어를 고른 뒤\n곡을 다시 담으면 세 번째 줄이 생깁니다.'
            : '추가 보조 언어를 고르면\n여기에서 세 번째 줄을 입력합니다.',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
    );
  }

  Widget _buildCell(
    ColorScheme cs,
    int row,
    int column, {
    required int lines,
    required bool blankRow,
  }) {
    final text = _grid.cell(row, column);
    final missing =
        column > 0 &&
        text.trim().isEmpty &&
        _grid.cell(row, 0).trim().isNotEmpty;
    final focused = _focused == (row: row, column: column);
    final hint = blankRow
        ? '빈 페이지'
        : missing
        ? '비어 있음 — 이 페이지는 ${_columnName(column)} 없이 나옵니다'
        : null;

    final field = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            _splitAtCursor,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true):
            _splitAtCursor,
      },
      child: TextField(
        controller: _cells[row][column],
        focusNode: _focus[row][column],
        // 높이가 자라는 칸(maxLines: null)은 macOS 한글 조합이 자모로 갈라진다(설교 페이지 창과 같은 문제).
        // 줄 수(엔터로만 바뀐다 — 엔터는 조합을 끝낸다)에 맞춘 고정 높이로 둔다.
        minLines: lines,
        maxLines: lines,
        keyboardType: TextInputType.multiline,
        style: const TextStyle(fontSize: 14, height: 1.5),
        onChanged: (value) => _onCellChanged(row, column, value),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintMaxLines: 2,
          hintStyle: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          filled: blankRow || missing,
          fillColor: blankRow
              ? cs.surfaceContainerHighest
              : cs.surfaceContainerLow,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 9,
          ),
          border: const OutlineInputBorder(),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(
              color: missing ? cs.tertiary : cs.outlineVariant,
            ),
          ),
        ),
      ),
    );
    // 언어 한 칸만 한 페이지씩 옮긴다 — 번역이 한 장 앞서거나 밀렸을 때.
    // 포커스와 상관없이 늘 Column 으로 감싼다(구조가 바뀌면 입력칸이 새로 만들어져 한글 조합이 끊긴다).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        field,
        if (_chordMode && column == 0) ..._chordCellExtras(cs, row, text),
        if (focused && column != 0) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            children: [
              if (row > 0)
                _cellTool(
                  Icons.arrow_upward_rounded,
                  '위로 당기기',
                  '이 칸부터 아래 ${_columnName(column)} 칸을 한 페이지씩 위로 올립니다',
                  () => _mutate(
                    () => _grid.pullUp(row, column),
                    focus: (row: row - 1, column: column),
                  ),
                ),
              _cellTool(
                Icons.arrow_downward_rounded,
                '아래로 밀기',
                '이 칸부터 아래 ${_columnName(column)} 칸을 한 페이지씩 내립니다',
                () => _mutate(
                  () => _grid.pushDown(row, column),
                  focus: (row: row + 1, column: column),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 코드 모드 원본 칸 아래: 못 읽는 대괄호 경고(+ 고치기)와 코드 악보 미리보기(글자를 눌러 코드 넣기).
  List<Widget> _chordCellExtras(ColorScheme cs, int row, String text) {
    final issues = chordIssueRanges(text);
    final lines = parseChordPage(text);
    final hasText = text.trim().isNotEmpty;
    return [
      for (final r in issues)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 14, color: cs.error),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  r.issue.kind == ChordIssueKind.nestedBracket
                      ? '대괄호 겹침: ${text.substring(r.start, r.end)} — 바깥 대괄호는 관객 화면에 글자로 나갑니다'
                      : '코드로 못 읽음: ${text.substring(r.start, r.end)} — 관객 화면에 글자로 나갑니다',
                  style: TextStyle(fontSize: 12, color: cs.error),
                ),
              ),
              if (r.issue.suggestion != null)
                TextButton(
                  onPressed: () => _fixChordCase(row, r),
                  child: Text('고치기 → ${r.issue.suggestion}'),
                ),
            ],
          ),
        ),
      if (hasText) ...[
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.control),
          child: ChordSheetView(
            lines: lines,
            fontSize: 15,
            fit: BoxFit.scaleDown,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            onTapChar: (line, offset) => _pickChordAt(row, line, offset),
          ),
        ),
        if (_rowHasChords(row)) ...() {
          // 후렴처럼 같은 가사가 또 나오는데 아직 코드가 다르면(없으면) 한 번에 넣는다.
          final same = [
            for (final r in _sameLyricsRows(row))
              if (_grid.cell(r, 0) != text) r,
          ];
          if (same.isEmpty) return const <Widget>[];
          return [
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: _cellTool(
                Icons.library_add_outlined,
                '같은 가사 ${same.length}페이지에도 넣기',
                '${same.map((r) => '${r + 1}').join(', ')}페이지에 이 페이지 코드를 그대로 넣습니다',
                () => _pasteChordsInto(text, same),
              ),
            ),
          ];
        }(),
      ],
    ];
  }

  /// 평소 모드에서 코드가 보일 페이지(행 번호에 ♪).
  Set<int> get _chordPageRows {
    if (!_hasChordTokens) return const {};
    final pages = matchedChordPages(_chordText, _original);
    return {
      for (var i = 0; i < pages.length; i++)
        if (pages[i] != null) i,
    };
  }

  Widget _cellTool(
    IconData icon,
    String label,
    String tooltip,
    VoidCallback onPressed,
  ) {
    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 26),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          visualDensity: VisualDensity.compact,
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        icon: Icon(icon, size: 14),
        label: Text(label),
      ),
    );
  }

  Widget _rowMenu(int row) {
    return PopupMenuButton<void Function()>(
      tooltip: '페이지 메뉴',
      icon: const Icon(Icons.more_vert_rounded, size: 18),
      onSelected: (action) => action(),
      // 메뉴가 열리면 입력칸이 포커스를 잃어 _focused 가 비므로, 나눌 칸·위치는 열 때 잡아 둔다.
      itemBuilder: (context) {
        final target = _cursorTarget();
        final copyCount = _pickedRows.contains(row) ? _pickedRows.length : 1;
        final pasteCount = _pageClipboard.length;
        return [
          PopupMenuItem(
            value: () => _copyRows(row),
            child: Text(
              copyCount > 1
                  ? '고른 $copyCount페이지 복사 (모든 언어)'
                  : '이 페이지 복사 (모든 언어)',
            ),
          ),
          PopupMenuItem(
            enabled: pasteCount > 0,
            value: () => _pasteRows(row + 1),
            child: Text(
              pasteCount > 0 ? '아래에 붙여 넣기 ($pasteCount페이지)' : '아래에 붙여 넣기',
            ),
          ),
          PopupMenuItem(
            enabled: pasteCount > 0,
            value: () => _pasteRows(row),
            child: Text(
              pasteCount > 0 ? '위에 붙여 넣기 ($pasteCount페이지)' : '위에 붙여 넣기',
            ),
          ),
          if (_chordMode) ...[
            const PopupMenuDivider(),
            PopupMenuItem(
              enabled: _rowHasChords(row),
              value: () => setState(() => _chordClipboard = _grid.cell(row, 0)),
              child: const Text('이 페이지 코드만 복사'),
            ),
            PopupMenuItem(
              enabled: _chordClipboard != null,
              value: () => _pasteChordsInto(_chordClipboard!, _targetRows(row)),
              child: Text(
                _targetRows(row).length > 1
                    ? '고른 ${_targetRows(row).length}페이지에 코드 붙여 넣기 (가사 그대로)'
                    : '코드 붙여 넣기 (가사 그대로)',
              ),
            ),
          ],
          const PopupMenuDivider(),
          PopupMenuItem(
            value: () => _mutate(
              () => _grid.insertRow(row),
              focus: (row: row, column: 0),
            ),
            child: const Text('위에 페이지 넣기'),
          ),
          PopupMenuItem(
            value: () => _mutate(
              () => _grid.insertRow(row + 1),
              focus: (row: row + 1, column: 0),
            ),
            child: const Text('아래에 페이지 넣기'),
          ),
          PopupMenuItem(
            enabled: row + 1 < _grid.length,
            value: () => _mutate(
              () => _grid.mergeWithNext(row),
              focus: (row: row, column: 0),
            ),
            child: const Text('다음 페이지와 합치기'),
          ),
          PopupMenuItem(
            enabled: target?.row == row,
            value: () {
              if (target != null) _splitAt(target);
            },
            child: const Text('커서 위치에서 나누기  (Ctrl/⌘+Enter)'),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: () => _mutate(() => _grid.clearRow(row)),
            child: const Text('빈 페이지로 만들기'),
          ),
          PopupMenuItem(
            value: () => _mutate(() => _grid.removeRow(row)),
            child: Text(
              '페이지 지우기 (세 칸 모두)',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ];
      },
    );
  }

  // ── 미리보기 ───────────────────────────────────────────────────────────

  Widget _buildPreview(ColorScheme cs) {
    final row = _selectedRow.clamp(0, _grid.length - 1);
    final page = _pageData(row, forPreview: true);
    final ratio = SlideTextLayout.overflowRatio(_pageData(row));
    final overflow = ratio > SlideTextLayout.overflowThreshold;
    final caption = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: cs.onSurfaceVariant,
    );
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('미리보기 · ${row + 1}페이지', style: caption)),
              if (overflow) _chip(cs, '넘침', error: true),
            ],
          ),
          const SizedBox(height: 8),
          AspectRatio(
            aspectRatio: SlideTextLayout.slideW / SlideTextLayout.slideH,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.control),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  SlideRenderView(data: page),
                  if (overflow)
                    CustomPaint(
                      painter: _LyricsBoxGuidePainter(
                        offsetY: clampTextOffsetY(widget.style.textOffsetY),
                        color: cs.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            overflow
                ? '가사가 상자(점선)를 ${SlideTextLayout.overflowLabel(ratio)} 채워 '
                      '관객 화면에서 잘리거나 겹칩니다. 페이지를 나누거나'
                      '(⋮ → 나누기) 디자인에서 글자 크기를 줄여 주세요.'
                : '고른 페이지가 관객 화면에 이렇게 나갑니다.',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: overflow ? cs.error : cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          Text('표시 언어 (이 미리보기만)', style: caption),
          const SizedBox(height: 4),
          _previewSwitch('보조', _previewSub, (v) => _previewSub = v),
          if (_hasExtra)
            _previewSwitch('추가 보조', _previewExtra, (v) => _previewExtra = v),
        ],
      ),
    );
  }

  Widget _previewSwitch(String label, bool value, ValueChanged<bool> set) {
    return Row(
      children: [
        Transform.scale(
          scale: 0.8,
          child: Switch(value: value, onChanged: (v) => setState(() => set(v))),
        ),
        Text(label),
      ],
    );
  }

  // ── 통째로 ─────────────────────────────────────────────────────────────

  Widget _buildWhole(ColorScheme cs) {
    final counts = [for (final c in _whole) splitEditablePages(c.text).length];
    final columns = _hasExtra ? 3 : 2;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var c = 0; c < columns; c++) ...[
          if (c > 0) const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: _columnHeader(cs, c)),
                    const SizedBox(width: 6),
                    _wholeCountChip(cs, counts, c),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: TextField(
                    controller: _whole[c],
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(fontSize: 14, height: 1.5),
                    decoration: const InputDecoration(
                      hintText: '페이지 구분: 빈 줄 (또는 ### / ====)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _wholeCountChip(ColorScheme cs, List<int> counts, int column) {
    final count = counts[column];
    if (column == 0) return _chip(cs, '$count페이지');
    final diff = count - counts[0];
    if (diff == 0 || count == 0) return _chip(cs, '$count페이지');
    return _chip(
      cs,
      '$count페이지 · 원본보다 ${diff.abs()} ${diff > 0 ? '많음' : '적음'}',
      warn: true,
    );
  }

  // ── 아래 줄 ────────────────────────────────────────────────────────────

  Widget _buildFooter(ColorScheme cs, bool isNew) {
    final chips = <Widget>[];
    if (_view == _EditorView.table) {
      final pages = _grid.filledCount(0);
      chips.add(_chip(cs, '원본 $pages페이지'));
      for (final column in [1, if (_hasExtra) 2]) {
        final missing = _grid.missingRows(column).length;
        final name = column == 1 ? _subLanguage : _extraLanguage;
        chips.add(
          _chip(
            cs,
            missing == 0
                ? '$name ${pages - missing} / $pages'
                : '$name ${pages - missing} / $pages · $missing페이지 비어 있음',
            warn: missing > 0,
          ),
        );
      }
      if (_chordMode) {
        final cells = [for (var r = 0; r < _grid.length; r++) _grid.cell(r, 0)];
        final chords = cells.fold(0, (n, c) => n + countChords(c));
        final noChord = cells
            .where((c) => c.trim().isNotEmpty && countChords(c) == 0)
            .length;
        final unreadable = cells.fold(
          0,
          (n, c) => n + chordIssueRanges(c).length,
        );
        chips.add(
          _chip(
            cs,
            [
              '코드 $chords개',
              if (noChord > 0) '코드 없는 페이지 $noChord',
              if (unreadable > 0) '못 읽음 $unreadable',
            ].join(' · '),
            warn: unreadable > 0,
          ),
        );
      }
      final overflowing = [
        for (var r = 0; r < _grid.length; r++)
          if (_overflowAt(r) > SlideTextLayout.overflowThreshold) r,
      ];
      if (overflowing.isNotEmpty) {
        chips.add(_chip(cs, '넘침 ${overflowing.length}페이지', error: true));
      }
    } else {
      chips.add(
        Text(
          '페이지 구분: 빈 줄 (또는 ### / ====) · 같은 번호 페이지끼리 한 장이 됩니다',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      );
    }
    return Row(
      children: [
        Expanded(child: Wrap(spacing: 6, runSpacing: 6, children: chips)),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: !widget.contiOnly && _titleController.text.trim().isEmpty
              ? null
              : _save,
          child: Text(isNew ? '추가' : '저장'),
        ),
      ],
    );
  }

  Widget _chip(
    ColorScheme cs,
    String label, {
    bool warn = false,
    bool error = false,
  }) {
    final (background, foreground) = error
        ? (cs.errorContainer, cs.onErrorContainer)
        : warn
        ? (cs.tertiaryContainer, cs.onTertiaryContainer)
        : (cs.surfaceContainerHighest, cs.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }
}

/// 넘친 페이지 미리보기 위의 가사 상자 점선(5.4인치)과 그 아래 넘친 자리 빗금.
class _LyricsBoxGuidePainter extends CustomPainter {
  _LyricsBoxGuidePainter({required this.offsetY, required this.color});

  final double offsetY;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / SlideTextLayout.slideW;
    final sy = size.height / SlideTextLayout.slideH;
    final box = Rect.fromLTWH(
      SlideTextLayout.lyricsBoxL * sx,
      (SlideTextLayout.lyricsBoxT + offsetY) * sy,
      SlideTextLayout.lyricsBoxW * sx,
      SlideTextLayout.lyricsBoxH * sy,
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    _dashedLine(canvas, box.topLeft, box.topRight, paint);
    _dashedLine(canvas, box.topRight, box.bottomRight, paint);
    _dashedLine(canvas, box.bottomRight, box.bottomLeft, paint);
    _dashedLine(canvas, box.bottomLeft, box.topLeft, paint);

    final hatch = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..strokeWidth = 3;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, box.bottom, size.width, size.height));
    for (var x = -size.height; x < size.width; x += 10) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        hatch,
      );
    }
    canvas.restore();
  }

  static void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 5.0;
    const gap = 4.0;
    final length = (b - a).distance;
    final dir = (b - a) / length;
    for (var d = 0.0; d < length; d += dash + gap) {
      final end = (d + dash).clamp(0.0, length);
      canvas.drawLine(a + dir * d, a + dir * end, paint);
    }
  }

  @override
  bool shouldRepaint(_LyricsBoxGuidePainter old) =>
      old.offsetY != offsetY || old.color != color;
}

class _LanguagePrompt extends StatefulWidget {
  const _LanguagePrompt();

  @override
  State<_LanguagePrompt> createState() => _LanguagePromptState();
}

class _LanguagePromptState extends State<_LanguagePrompt> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('언어 추가'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '언어',
          hintText: '예: 일본어, 중국어, 스페인어',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _submit, child: const Text('추가')),
      ],
    );
  }
}
