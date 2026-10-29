import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_colors.dart';
import '../data/praise_repository.dart';
import '../domain/export_style.dart';
import '../domain/praise_song.dart';
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

  /// '통째로' 보기 입력칸(원본·보조·추가 보조).
  final List<TextEditingController> _whole = List.generate(
    LyricsPageGrid.columnCount,
    (_) => TextEditingController(),
  );

  /// 붙여 넣기로 나눈 직후 되돌리기용.
  ({LyricsPageGrid before, String message})? _undo;

  bool _previewSub = true;
  bool _previewExtra = true;

  @override
  void initState() {
    super.initState();
    final song = widget.song;
    _titleController = TextEditingController(text: song?.title ?? '');
    _original = song?.lyrics ?? '';
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
    _disposeCells();
    for (final c in _whole) {
      c.dispose();
    }
    super.dispose();
  }

  // ── 글 ↔ 표 ────────────────────────────────────────────────────────────

  bool get _hasExtra => _extraLanguage.isNotEmpty;

  List<String> get _columnTexts => [
    _original,
    _texts[_subLanguage] ?? '',
    _hasExtra ? (_texts[_extraLanguage] ?? '') : '',
  ];

  void _storeColumnTexts(List<String> texts) {
    _original = normalizeEditableLyrics(texts[0]);
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
            TextEditingController(text: _grid.cell(r, c)),
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
    _mutate(
      () => _grid.splitAt(target.row, target.column, target.offset),
      focus: (row: target.row + 1, column: target.column),
    );
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

  void _save() {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    _commit();
    final song = widget.song;
    if (widget.contiOnly && song != null) {
      Navigator.of(context).pop((
        song.copyWith(
          lyrics: _original,
          englishLyrics: _texts[_subLanguage] ?? '',
          extraLyrics: _hasExtra
              ? _texts[_extraLanguage] ?? ''
              : song.extraLyrics,
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
      ),
      Map<String, String>.from(_texts),
    ));
  }

  // ── 화면 ───────────────────────────────────────────────────────────────

  SlidePageData _pageData(int row, {bool forPreview = false}) {
    final texts = _grid.row(row);
    return SlidePageData(
      mainText: texts[0].trim(),
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
    return Column(
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
        color: selected ? cs.surfaceContainerHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.panel),
      ),
      child: _tableRow(
        leading: Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            children: [
              Text(
                '${row + 1}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
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
        return [
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
