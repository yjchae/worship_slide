// 저장 형식이 편집 형식과 동일하므로 변환 불필요.
String lyricsToEditText(String stored) => stored;

// 편집 텍스트 → 저장 형식 정규화.
// 규칙: 빈 줄 1개(\n\n) = 페이지 구분, 빈 줄 N개 = 빈 페이지 N-1장.
// ###, ==== 은 명시적 페이지 구분자로 허용.
String normalizeEditableLyrics(String raw) {
  var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // ###, ==== → \n\n (주변 줄바꿈 포함 소비)
  text = text.replaceAll(RegExp(r'\n?[ \t]*(###|====)[ \t]*\n?'), '\n\n');
  // 분리 → 각 페이지 trim → 후행 빈 페이지 제거 → 재결합
  final pages = text.split(_pageBreak).map((p) => p.trim()).toList();
  while (pages.isNotEmpty && pages.last.isEmpty) {
    pages.removeLast();
  }
  return pages.join('\n\n');
}

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
/// 어떤 조작도 글을 버리지 않는다 — 지우기는 [removeRow]·[clearRow] 처럼 이름에 드러날 때만.
class LyricsPageGrid {
  LyricsPageGrid._(this._rows);

  static const columnCount = 3;

  /// 열마다 저장 형식 글(원본·보조·추가 보조)로 만든다. 모자란 칸은 빈 글, 최소 한 행.
  factory LyricsPageGrid.fromTexts(List<String> texts) {
    assert(texts.length == columnCount);
    final columns = [for (final text in texts) splitEditablePages(text)];
    final length = columns
        .map((c) => c.length)
        .fold(1, (a, b) => a > b ? a : b);
    return LyricsPageGrid._([
      for (var r = 0; r < length; r++)
        [for (final column in columns) r < column.length ? column[r] : ''],
    ]);
  }

  final List<List<String>> _rows;

  int get length => _rows.length;

  String cell(int row, int column) => _rows[row][column];

  List<String> row(int row) => List.unmodifiable(_rows[row]);

  bool isBlankRow(int row) => _rows[row].every((c) => c.trim().isEmpty);

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
    }
    return pieces.length;
  }

  /// [row] 앞에 세 칸 모두 빈 행을 넣는다.
  void insertRow(int row) {
    _rows.insert(row, List.filled(columnCount, '', growable: true));
  }

  /// 행을 지운다(세 칸 모두). 마지막 한 행은 비우기만 한다.
  void removeRow(int row) {
    if (_rows.length == 1) {
      clearRow(row);
    } else {
      _rows.removeAt(row);
    }
  }

  void clearRow(int row) {
    for (var c = 0; c < columnCount; c++) {
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
  }

  /// [column] 의 [offset] 위치에서 나눠, 뒷부분을 새 행(바로 아래)으로 보낸다.
  /// 다른 열은 그대로 위 행에 남는다.
  void splitAt(int row, int column, int offset) {
    final text = _rows[row][column];
    final at = offset.clamp(0, text.length);
    insertRow(row + 1);
    _rows[row][column] = text.substring(0, at).trimRight();
    _rows[row + 1][column] = text.substring(at).trimLeft();
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
    for (var r = row; r < _rows.length - 1; r++) {
      _rows[r][column] = _rows[r + 1][column];
    }
    _rows.last[column] = '';
    _dropTrailingBlankRows();
  }

  /// 그 열의 [row] 자리에 [text] 칸을 끼워 넣고 아래 칸들을 한 칸씩 내린다.
  void _insertCell(int row, int column, String text) {
    // 맨 아래 칸이 차 있으면 밀려날 자리부터 만든다.
    if (_rows.last[column].trim().isNotEmpty || row >= _rows.length) {
      _rows.add(List.filled(columnCount, '', growable: true));
    }
    while (row >= _rows.length) {
      _rows.add(List.filled(columnCount, '', growable: true));
    }
    for (var r = _rows.length - 1; r > row; r--) {
      _rows[r][column] = _rows[r - 1][column];
    }
    _rows[row][column] = text;
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
