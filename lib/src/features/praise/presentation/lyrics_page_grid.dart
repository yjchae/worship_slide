import '../domain/lyrics_text.dart';
import '../domain/song_form.dart';

export '../domain/lyrics_text.dart' show normalizeEditableLyrics;

// 저장 형식이 편집 형식과 동일하므로 변환 불필요.
String lyricsToEditText(String stored) => stored;

// 페이지 목록 → 저장 형식 인코딩.
String encodePages(Iterable<String> pages) {
  final list = pages.toList();
  while (list.isNotEmpty && list.last.isEmpty) {
    list.removeLast();
  }
  return list.join('\n\n');
}

/// 페이지 구분 = 빈 줄(공백·탭만 있는 줄 포함).
final _pageBreak = RegExp(r'\n[ \t]*\n');

/// 편집 글자를 페이지로 나눈다. 빈 글이면 페이지 없음.
List<String> splitEditablePages(String raw) {
  final text = normalizeEditableLyrics(raw);
  if (text.isEmpty) return [];
  return text.split(_pageBreak).map((p) => p.trim()).toList();
}

/// 가사 수정 창의 페이지 표. 행 = 관객 화면 한 장, 열 = 언어(0 원본 · 1 보조 · 2 추가 보조).
/// 같은 행의 글이 같은 슬라이드에 나간다. 화면(위젯)과 떼어 둔 순수 모델이라 단위 테스트한다.
///
/// 행마다 글 칸 셋 뒤에 송폼 라벨 글(`V2,PC`, [labelsToText]) 한 칸이 더 붙어 다닌다 — 행을 옮기고 복사하고
/// 나누고 합칠 때 라벨이 같이 간다. 그 칸은 글이 아니라서 [isBlankRow]·[toTexts]·[row] 는 보지 않는다.
///
/// 어떤 조작도 글을 버리지 않는다 — 지우기는 [removeRow]·[clearRow] 처럼 이름에 드러날 때만.
class LyricsPageGrid {
  LyricsPageGrid._(this._rows);

  static const columnCount = 3;
  static const _formAt = columnCount;

  static List<String> _blank() =>
      List.filled(columnCount + 1, '', growable: true);

  /// 열마다 저장 형식 글(원본·보조·추가 보조)로 만든다. 모자란 칸은 빈 글, 최소 한 행.
  /// [forms] = 원본 페이지 번호별 라벨 글.
  factory LyricsPageGrid.fromTexts(
    List<String> texts, {
    List<String> forms = const [],
  }) {
    assert(texts.length == columnCount);
    final columns = [for (final text in texts) splitEditablePages(text)];
    final length = columns
        .map((c) => c.length)
        .fold(1, (a, b) => a > b ? a : b);
    return LyricsPageGrid._([
      for (var r = 0; r < length; r++)
        [
          for (final column in columns) r < column.length ? column[r] : '',
          r < forms.length ? forms[r] : '',
        ],
    ]);
  }

  final List<List<String>> _rows;

  int get length => _rows.length;

  String cell(int row, int column) => _rows[row][column];

  List<String> row(int row) => List.unmodifiable(_rows[row].take(columnCount));

  /// 글 칸 셋 + 라벨 글 — 행 복사(클립보드)용. [insertRows] 가 이 모양을 받는다.
  List<String> rowWithForm(int row) => List.unmodifiable(_rows[row]);

  /// 그 행의 송폼 라벨 글(`V2,PC`).
  String form(int row) => _rows[row][_formAt];

  List<SectionLabel> labels(int row) => labelsFromText(form(row));

  void setLabels(int row, Iterable<SectionLabel> labels) {
    _rows[row][_formAt] = labelsToText(labels);
  }

  /// 행마다 라벨 글(저장·다시 열기 사이 보관용).
  List<String> toForms() => [for (final r in _rows) r[_formAt]];

  /// [toForms] 로 떠 둔 라벨 글로 되돌린다(행 수가 그대로일 때만 쓴다).
  void restoreForms(List<String> forms) {
    for (var r = 0; r < _rows.length && r < forms.length; r++) {
      _rows[r][_formAt] = forms[r];
    }
  }

  bool isBlankRow(int row) =>
      _rows[row].take(columnCount).every((c) => c.trim().isEmpty);

  LyricsPageGrid copy() =>
      LyricsPageGrid._([for (final r in _rows) List.of(r)]);

  /// 열마다 저장 형식 글. 열 끝의 빈 페이지는 뗀다.
  List<String> toTexts() => [
    for (var c = 0; c < columnCount; c++)
      encodePages(_rows.map((r) => r[c].trim())),
  ];

  /// 그 열에 글이 든 페이지 수(빈 칸 제외).
  int filledCount(int column) =>
      _rows.where((r) => r[column].trim().isNotEmpty).length;

  /// 원본엔 글이 있는데 [column] 이 빈 행들.
  List<int> missingRows(int column) => [
    for (var r = 0; r < _rows.length; r++)
      if (_rows[r][0].trim().isNotEmpty && _rows[r][column].trim().isEmpty) r,
  ];

  void setCell(int row, int column, String text) {
    _rows[row][column] = text;
  }

  /// 칸에 빈 줄이 든 글(붙여 넣은 가사, 엔터 두 번)을 빈 줄마다 나눠 그 아래 행들로 보낸다.
  /// 그 열의 아래 칸들은 조각 수만큼 밀려 내려간다(덮어쓰지 않는다). 나눠졌으면 조각 수, 아니면 1.
  int splitCell(int row, int column) {
    final text = _rows[row][column].replaceAll('\r\n', '\n');
    if (!_pageBreak.hasMatch(text)) return 1;
    final pieces = text.split(_pageBreak).map((p) => p.trim()).toList();
    _rows[row][column] = pieces.first;
    for (var i = 1; i < pieces.length; i++) {
      _insertCell(row + i, column, pieces[i]);
      if (column == 0) _rows[row + i][_formAt] = _rows[row][_formAt];
    }
    return pieces.length;
  }

  /// [row] 앞에 세 칸 모두 빈 행을 넣는다.
  void insertRow(int row) {
    _rows.insert(row, _blank());
  }

  /// [row] 앞에 복사해 둔 행들(세 칸씩)을 통째로 넣는다. 그 자리가 빈 한 행뿐이면(새 곡) 그 행을 대신한다.
  void insertRows(int row, List<List<String>> rows) {
    if (rows.isEmpty) return;
    if (_rows.length == 1 && isBlankRow(0)) _rows.clear();
    _rows.insertAll(row.clamp(0, _rows.length), [
      for (final r in rows)
        [for (var c = 0; c <= columnCount; c++) c < r.length ? r[c] : ''],
    ]);
  }

  /// 행을 지운다(세 칸과 라벨). 마지막 한 행은 비우기만 한다.
  void removeRow(int row) {
    if (_rows.length == 1) {
      clearRow(row);
    } else {
      _rows.removeAt(row);
    }
  }

  void clearRow(int row) {
    for (var c = 0; c <= columnCount; c++) {
      _rows[row][c] = '';
    }
  }

  /// [row] 와 다음 행을 칸마다 줄을 이어 하나로 합친다.
  void mergeWithNext(int row) {
    if (row + 1 >= _rows.length) return;
    final next = _rows.removeAt(row + 1);
    for (var c = 0; c < columnCount; c++) {
      _rows[row][c] = _joinLines(_rows[row][c], next[c]);
    }
    _rows[row][_formAt] = labelsToText(
      mergeLabels(
        labelsFromText(_rows[row][_formAt]),
        labelsFromText(next[_formAt]),
      ),
    );
  }

  /// [column] 의 [offset] 위치에서 나눠, 뒷부분을 새 행(바로 아래)으로 보낸다.
  /// 다른 열은 그대로 위 행에 남는다.
  void splitAt(int row, int column, int offset) {
    final text = _rows[row][column];
    final at = offset.clamp(0, text.length);
    insertRow(row + 1);
    _rows[row][column] = text.substring(0, at).trimRight();
    _rows[row + 1][column] = text.substring(at).trimLeft();
    // 나누면 두 쪽 모두 같은 라벨(원본 열을 나눌 때만 — 번역 열만 나누면 같은 페이지의 다른 반쪽일 뿐이다).
    if (column == 0) _rows[row + 1][_formAt] = _rows[row][_formAt];
  }

  /// 그 열만 [row] 부터 한 페이지씩 아래로 민다(번역이 한 장 앞서 있을 때). [row] 칸은 비게 된다.
  void pushDown(int row, int column) => _insertCell(row, column, '');

  /// 그 열만 [row] 부터 한 페이지씩 위로 당긴다(번역이 한 장 밀려 있을 때).
  /// [row] 칸 글은 위 칸으로 간다 — 위 칸에 글이 있으면 그 뒤에 줄로 잇는다.
  void pullUp(int row, int column) {
    if (row <= 0) return;
    _rows[row - 1][column] = _joinLines(
      _rows[row - 1][column],
      _rows[row][column],
    );
    if (column == 0) {
      _rows[row - 1][_formAt] = labelsToText(
        mergeLabels(labels(row - 1), labels(row)),
      );
    }
    for (var r = row; r < _rows.length - 1; r++) {
      _rows[r][column] = _rows[r + 1][column];
      if (column == 0) _rows[r][_formAt] = _rows[r + 1][_formAt];
    }
    _rows.last[column] = '';
    if (column == 0) _rows.last[_formAt] = '';
    _dropTrailingBlankRows();
  }

  /// 그 열의 [row] 자리에 [text] 칸을 끼워 넣고 아래 칸들을 한 칸씩 내린다.
  void _insertCell(int row, int column, String text) {
    // 맨 아래 칸이 차 있으면 밀려날 자리부터 만든다.
    if (_rows.last[column].trim().isNotEmpty || row >= _rows.length) {
      _rows.add(_blank());
    }
    while (row >= _rows.length) {
      _rows.add(_blank());
    }
    for (var r = _rows.length - 1; r > row; r--) {
      _rows[r][column] = _rows[r - 1][column];
      if (column == 0) _rows[r][_formAt] = _rows[r - 1][_formAt];
    }
    _rows[row][column] = text;
    if (column == 0) _rows[row][_formAt] = '';
  }

  void _dropTrailingBlankRows() {
    while (_rows.length > 1 && isBlankRow(_rows.length - 1)) {
      _rows.removeLast();
    }
  }

  static String _joinLines(String a, String b) {
    if (a.trim().isEmpty) return b;
    if (b.trim().isEmpty) return a;
    return '${a.trimRight()}\n${b.trimLeft()}';
  }
}
