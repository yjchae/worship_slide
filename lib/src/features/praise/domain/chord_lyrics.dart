/// 코드(기타·건반 코드) 붙은 가사 — 순수 함수만 (기획 `planning/chord-lyrics/plan.md` §3·§5-3).
///
/// 코드 글은 ChordPro 인라인 표기다: `[G]주 은[D/F#]혜`. 코드는 바로 뒤 글자 위에 뜬다.
/// 무엇이 코드인지는 [isChordName] 문법 하나로만 정한다. 문법 밖 대괄호(`[후렴]`)는 글자다.
/// 코드 글 안의 `\[` 는 글자 `[` 다(이스케이프). 다른 곳의 `\` 는 그냥 글자다.
///
/// 화면·렌더러는 코드 글을 직접 풀지 않고 이 파일의 함수만 쓴다.
library;

import 'lyrics_text.dart';

enum ChordAccidental {
  auto(''),
  sharp('#'),
  flat('b');

  const ChordAccidental(this.dbValue);

  /// DB `worship_conti_items.song_chord_accidental` 값: '' / '#' / 'b'.
  final String dbValue;

  /// 모르는 값은 자동.
  static ChordAccidental fromDb(Object? value) => switch (value) {
    '#' => sharp,
    'b' => flat,
    _ => auto,
  };
}

/// strip 한 한 줄 + 그 줄 위 코드들. 싱어 JSON `{"t": text, "c": [[offset, name], ...]}` 와 1:1.
class ChordLine {
  const ChordLine(this.text, this.chords);

  /// 코드 뺀 줄 (코드만 있는 줄이면 '').
  final String text;

  /// offset = [text] 안 UTF-16 위치(0..text.length).
  final List<({int offset, String name})> chords;

  Map<String, Object> toJson() => {
    't': text,
    'c': [
      for (final c in chords) [c.offset, c.name],
    ],
  };

  @override
  bool operator ==(Object other) =>
      other is ChordLine &&
      other.text == text &&
      other.chords.length == chords.length &&
      [
        for (var i = 0; i < chords.length; i++) other.chords[i] == chords[i],
      ].every((e) => e);

  @override
  int get hashCode => Object.hash(text, Object.hashAll(chords));

  @override
  String toString() => 'ChordLine($text, $chords)';
}

// ── 문법 (§3-1) ─────────────────────────────────────────

const _root = r'[A-G](?:#|b|♯|♭)?';
const _qual = r'(?:maj|min|dim|aug|sus2|sus4|sus|m|M|°|ø|\+)';
const _ext =
    r'(?:\d{1,2}|(?:add|sus)\d{1,2}|[#b♯♭]\d{1,2}|\((?:[#b♯♭]?\d{1,2}|maj7|add\d{1,2})(?:,[#b♯♭]?\d{1,2})*\))';

/// 코드 이름 전체 일치(대소문자를 가린다).
final chordNamePattern = RegExp(
  '^(?:N\\.C\\.|$_root$_qual?$_ext*(?:/$_root)?)\$',
);

final _chordParts = RegExp('^($_root)(.*?)(?:/($_root))?\$');

/// 코드 이름 하나가 §3-1 문법에 맞는지 (대괄호 없이: 'D/F#').
bool isChordName(String name) => chordNamePattern.hasMatch(name);

/// 줄 안 낱개 조각: 글자 하나 / 이스케이프 `\[` / 코드 토큰.
/// [start]·[end] 는 코드 글 안 위치, [text] 는 strip 한 글에 나가는 글자(코드는 '').
typedef _Piece = ({int start, int end, String text, String? chord});

/// [line] 은 줄바꿈 없는 한 줄. 왼쪽부터 읽는다.
List<_Piece> _scanLine(String line) {
  final pieces = <_Piece>[];
  var i = 0;
  while (i < line.length) {
    final ch = line[i];
    if (ch == r'\' && i + 1 < line.length && line[i + 1] == '[') {
      pieces.add((start: i, end: i + 2, text: '[', chord: null));
      i += 2;
      continue;
    }
    if (ch == '[') {
      final name = _bracketContent(line, i);
      if (name != null && isChordName(name)) {
        final end = i + name.length + 2;
        pieces.add((start: i, end: end, text: '', chord: name));
        i = end;
        continue;
      }
    }
    pieces.add((start: i, end: i + 1, text: ch, chord: null));
    i++;
  }
  return pieces;
}

/// `line[i] == '['` 일 때 같은 줄의 다음 `]` 까지 글(사이에 `[` 가 없을 때만). 없으면 null.
String? _bracketContent(String line, int i) {
  for (var j = i + 1; j < line.length; j++) {
    final c = line[j];
    if (c == ']') return line.substring(i + 1, j);
    if (c == '[' || c == '\n') return null;
  }
  return null;
}

/// 한 줄 strip 결과. [chordOnly] = 코드가 있었는데 글자가 공백뿐.
typedef _StrippedLine = ({
  String text,
  List<({int offset, String name})> chords,
  bool chordOnly,
});

_StrippedLine _stripLine(String line) {
  final buffer = StringBuffer();
  final chords = <({int offset, String name})>[];
  for (final p in _scanLine(line)) {
    if (p.chord != null) {
      chords.add((offset: buffer.length, name: p.chord!));
    } else {
      buffer.write(p.text);
    }
  }
  var text = buffer.toString();
  if (chords.isEmpty) return (text: text, chords: chords, chordOnly: false);
  // 코드를 뺀 자리에 남은 줄 끝 공백만 지운다(코드 없는 줄은 손대지 않는다 —
  // stripChords(escapeLyricsForChords(x)) == normalizeEditableLyrics(x) 를 지키려고).
  text = text.replaceFirst(RegExp(r'[ \t]+$'), '');
  if (text.trim().isEmpty) {
    return (
      text: '',
      chords: [for (final c in chords) (offset: 0, name: c.name)],
      chordOnly: true,
    );
  }
  return (
    text: text,
    chords: [
      for (final c in chords)
        (offset: c.offset > text.length ? text.length : c.offset, name: c.name),
    ],
    chordOnly: false,
  );
}

/// 페이지 하나 strip (줄마다 코드 빼기, 코드만 있는 줄은 줄째 빼기, 페이지 trim).
String _stripPage(String page) {
  final lines = <String>[];
  for (final line in page.split('\n')) {
    final s = _stripLine(line);
    if (s.chordOnly) continue;
    lines.add(s.text);
  }
  return lines.join('\n').trim();
}

/// normalizeEditableLyrics 와 같은 규칙으로 페이지를 나눈다(끝 빈 페이지 포함, 각 페이지 trim).
List<String> _rawPages(String text) {
  var t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  t = t.replaceAll(RegExp(r'\n?[ \t]*(###|====)[ \t]*\n?'), '\n\n');
  return t.split(lyricsPageBreak).map((p) => p.trim()).toList();
}

/// 코드 글 → 원본 가사 (§3-1 strip 정의. 결과는 normalizeEditableLyrics 를 지난 모양).
String stripChords(String chordText) {
  if (chordText.isEmpty) return '';
  return normalizeEditableLyrics(
    _rawPages(chordText).map(_stripPage).join('\n\n'),
  );
}

/// 이스케이프할 `[` 자리(코드 토큰으로 읽힐 `[`, 또는 바로 앞이 `\` 인 `[`).
bool _needsEscape(String line, int i) {
  if (line[i] != '[') return false;
  if (i > 0 && line[i - 1] == r'\') return true;
  final name = _bracketContent(line, i);
  return name != null && isChordName(name);
}

/// 원본 가사 → 코드 글 시작값. 코드로 읽힐 '[' 앞에만 '\' 를 붙인다.
/// 늘 stripChords(escapeLyricsForChords(x)) == normalizeEditableLyrics(x).
///
/// 앞이 `\` 인 `[`(가사에 원래 `\[` 가 있음)에도 하나 더 붙인다 — `\\[` 는 글자 `\` + 글자 `[` 다.
String escapeLyricsForChords(String lyrics) {
  if (!lyrics.contains('[')) return lyrics;
  final buffer = StringBuffer();
  final lines = lyrics.split('\n');
  for (var l = 0; l < lines.length; l++) {
    if (l > 0) buffer.write('\n');
    final line = lines[l];
    for (var i = 0; i < line.length; i++) {
      if (_needsEscape(line, i)) buffer.write(r'\');
      buffer.write(line[i]);
    }
  }
  return buffer.toString();
}

/// 원래 가사에서 이스케이프가 붙는 대괄호 수(편집 창 배너: '원래 있던 대괄호 N개는 글자로 둡니다').
int countEscapedBrackets(String lyrics) {
  var n = 0;
  for (final line in lyrics.split('\n')) {
    for (var i = 0; i < line.length; i++) {
      if (_needsEscape(line, i)) n++;
    }
  }
  return n;
}

/// 코드 글을 페이지로 (PraiseSong 페이지 나누기와 같은 빈 줄 규칙, 끝 빈 페이지 유지 안 함).
/// 끝의 코드만 있는 페이지는 남긴다(strip 하면 떼어지지만 편집 창 경고에 쓴다).
List<String> chordPagesOf(String chordText) {
  if (chordText.isEmpty) return [];
  final pages = _rawPages(chordText);
  while (pages.isNotEmpty && pages.last.isEmpty) {
    pages.removeLast();
  }
  return pages;
}

/// 한 페이지 코드 글 → 줄 목록 (싱어·ChordSheetView 가 그대로 쓴다).
/// 코드만 있는 줄은 text '' 에 offset 0 코드들.
List<ChordLine> parseChordPage(String chordPage) {
  final lines = chordPage.trim().split('\n');
  final result = <ChordLine>[];
  for (final line in lines) {
    final s = _stripLine(line);
    result.add(ChordLine(s.text, s.chords));
  }
  // 페이지 trim 과 같게 첫 줄 앞·끝 줄 뒤 공백은 이미 trim 으로 빠졌다.
  return result;
}

/// 그 페이지에 코드 토큰이 하나라도 있는지.
bool _hasChordToken(String page) =>
    page.split('\n').any((l) => _scanLine(l).any((p) => p.chord != null));

/// 곡 단위 정합 (§3-5 '곡 상태'). 코드가 없으면 참(볼 게 없다).
bool chordsMatchLyrics(String? chordText, String lyrics) {
  if (chordText == null || chordText.isEmpty) return true;
  return stripChords(chordText) == normalizeEditableLyrics(lyrics);
}

List<String> _lyricsPages(String lyrics) => lyrics.isEmpty
    ? <String>[]
    : lyrics.split(lyricsPageBreak).map((p) => p.trim()).toList();

/// 표시용 페이지 짝 (§3-5 '표시'). 결과 길이 = lyrics 페이지 수, 짝 없는 페이지는 null.
/// 코드 토큰이 하나도 없는 페이지도 null 이다(보일 코드가 없다).
List<String?> matchedChordPages(String? chordText, String lyrics) {
  final lp = _lyricsPages(lyrics);
  final none = List<String?>.filled(lp.length, null);
  if (chordText == null || chordText.isEmpty) return none;
  final cp = chordPagesOf(chordText);
  final sp = [for (final p in cp) _stripPage(p)];
  var cLen = sp.length;
  while (cLen > 0 && sp[cLen - 1].isEmpty) {
    cLen--;
  }
  var lLen = lp.length;
  while (lLen > 0 && lp[lLen - 1].isEmpty) {
    lLen--;
  }
  if (cLen != lLen) return none;
  return [
    for (var i = 0; i < lp.length; i++)
      i < cLen && sp[i] == lp[i] && _hasChordToken(cp[i]) ? cp[i] : null,
  ];
}

/// 코드가 있는데 어긋나 숨긴 페이지 수('코드 확인 N' 의 N).
/// 페이지 수가 달라 모두 숨기면 코드가 든 페이지 수 전부.
int hiddenChordPageCount(String? chordText, String lyrics) {
  if (chordText == null || chordText.isEmpty) return 0;
  final cp = chordPagesOf(chordText);
  final withChords = [
    for (var i = 0; i < cp.length; i++)
      if (_hasChordToken(cp[i])) i,
  ];
  if (withChords.isEmpty) return 0;
  final shown = matchedChordPages(chordText, lyrics).whereType<String>().length;
  // 끝의 코드만 있는 페이지는 짝이 없어 늘 안 보인다 — 그것도 숨긴 것으로 센다.
  return withChords.length - shown;
}

// ── 편집 창 경고 ───────────────────────────────────────

enum ChordIssueKind {
  unreadableBracket,
  fixableCase,
  trailingChordOnlyPage,
  nestedBracket,
}

class ChordIssue {
  const ChordIssue(
    this.kind,
    this.page,
    this.start,
    this.end, {
    this.suggestion,
  });

  final ChordIssueKind kind;

  /// 0부터 ([chordPagesOf] 페이지 번호).
  final int page;

  /// 그 페이지 글 안 UTF-16 범위.
  final int start, end;

  /// fixableCase 일 때 '[G]'.
  final String? suggestion;

  @override
  String toString() => 'ChordIssue($kind, p$page, $start-$end, $suggestion)';
}

/// 대소문자만 고치면 코드가 되는지. 되면 고친 이름.
String? _caseFix(String name) {
  if (name.isEmpty) return null;
  String up(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
  final candidates = <String>{};
  for (final body in [name, name.toLowerCase()]) {
    final slash = body.indexOf('/');
    if (slash < 0) {
      candidates.add(up(body));
    } else {
      candidates.add(
        '${up(body.substring(0, slash))}/${up(body.substring(slash + 1))}',
      );
    }
  }
  for (final c in candidates) {
    if (c != name && isChordName(c)) return c;
  }
  return null;
}

/// 편집 창 경고용. 페이지는 [chordPagesOf] 기준.
List<ChordIssue> validateChordText(String chordText) {
  final issues = <ChordIssue>[];
  final pages = chordPagesOf(chordText);
  for (var p = 0; p < pages.length; p++) {
    final page = pages[p];
    var lineStart = 0;
    for (final line in page.split('\n')) {
      final pieces = _scanLine(line);
      for (var k = 0; k < pieces.length; k++) {
        final piece = pieces[k];
        if (piece.chord != null) {
          final before = k > 0 ? pieces[k - 1] : null;
          final after = k + 1 < pieces.length ? pieces[k + 1] : null;
          // `[[G]]`: 바깥 대괄호가 글자로 붙어 있다.
          if ((before != null &&
                  before.chord == null &&
                  before.end - before.start == 1 &&
                  before.text == '[') ||
              (after != null && after.chord == null && after.text == ']')) {
            issues.add(
              ChordIssue(
                ChordIssueKind.nestedBracket,
                p,
                lineStart + (before?.text == '[' ? before!.start : piece.start),
                lineStart + (after?.text == ']' ? after!.end : piece.end),
              ),
            );
          }
          continue;
        }
        if (piece.text != '[' || piece.end - piece.start != 1) continue;
        final name = _bracketContent(line, piece.start);
        if (name == null) continue;
        // 안에 코드 토큰이 든 `[[G]]` 의 바깥 `[` 는 위에서 다룬다.
        if (name.contains('[')) continue;
        final start = lineStart + piece.start;
        final end = start + name.length + 2;
        final fix = _caseFix(name);
        issues.add(
          fix != null
              ? ChordIssue(
                  ChordIssueKind.fixableCase,
                  p,
                  start,
                  end,
                  suggestion: '[$fix]',
                )
              : ChordIssue(ChordIssueKind.unreadableBracket, p, start, end),
        );
      }
      lineStart += line.length + 1;
    }
  }
  // 끝의 코드만 있는 페이지 — strip 하면 떼어져 짝이 없다.
  for (var p = pages.length - 1; p >= 0; p--) {
    if (_stripPage(pages[p]).isNotEmpty) break;
    if (_hasChordToken(pages[p])) {
      issues.add(
        ChordIssue(ChordIssueKind.trailingChordOnlyPage, p, 0, pages[p].length),
      );
    }
  }
  return issues;
}

/// 코드 개수 (요약 줄).
int countChords(String chordText) {
  var n = 0;
  for (final line in chordText.split('\n')) {
    n += _scanLine(line).where((p) => p.chord != null).length;
  }
  return n;
}

/// 코드 글에 쓰인 코드 이름(나온 순서, 겹치면 한 번). 자동완성·빠른 버튼용.
List<String> chordNamesIn(String chordText) {
  final counts = <String, int>{};
  for (final line in chordText.split('\n')) {
    for (final p in _scanLine(line)) {
      if (p.chord != null) counts[p.chord!] = (counts[p.chord!] ?? 0) + 1;
    }
  }
  final names = counts.keys.toList();
  // 많이 쓴 순서, 같으면 처음 나온 순서.
  final order = {for (var i = 0; i < names.length; i++) names[i]: i};
  names.sort((a, b) {
    final c = counts[b]!.compareTo(counts[a]!);
    return c != 0 ? c : order[a]!.compareTo(order[b]!);
  });
  return names;
}

/// 커서 나누기 위치를 토큰·'\[' 밖으로 당긴다 (§3-7).
/// 토큰 안·`\[` 사이면 그 앞으로, 토큰 바로 뒤면 토큰 앞으로(연달아 붙은 토큰은 모두 함께).
int snapSplitOffset(String chordPage, int offset) {
  if (offset <= 0) return 0;
  if (offset >= chordPage.length) return chordPage.length;
  final lineStart = chordPage.lastIndexOf('\n', offset - 1) + 1;
  var lineEnd = chordPage.indexOf('\n', lineStart);
  if (lineEnd < 0) lineEnd = chordPage.length;
  final line = chordPage.substring(lineStart, lineEnd);
  final pieces = _scanLine(line);
  var local = offset - lineStart;
  // 조각 안이면 조각 앞으로.
  for (final p in pieces) {
    if (p.start < local && local < p.end) {
      local = p.start;
      break;
    }
  }
  // 토큰 바로 뒤면 토큰 앞으로(반복 — `[G][D]주`).
  var moved = true;
  while (moved) {
    moved = false;
    for (final p in pieces) {
      if (p.chord != null && p.end == local) {
        local = p.start;
        moved = true;
        break;
      }
    }
  }
  return lineStart + local;
}

// ── 조 ─────────────────────────────────────────────

const _pitchOf = {
  'C': 0,
  'B#': 0,
  'C#': 1,
  'Db': 1,
  'D': 2,
  'D#': 3,
  'Eb': 3,
  'E': 4,
  'Fb': 4,
  'E#': 5,
  'F': 5,
  'F#': 6,
  'Gb': 6,
  'G': 7,
  'G#': 8,
  'Ab': 8,
  'A': 9,
  'A#': 10,
  'Bb': 10,
  'B': 11,
  'Cb': 11,
};

const _sharpNames = [
  'C',
  'C#',
  'D',
  'D#',
  'E',
  'F',
  'F#',
  'G',
  'G#',
  'A',
  'A#',
  'B',
];
const _flatNames = [
  'C',
  'Db',
  'D',
  'Eb',
  'E',
  'F',
  'Gb',
  'G',
  'Ab',
  'A',
  'Bb',
  'B',
];

/// 자동 표기 조 이름(§3-10): F·Bb·Eb·Ab·Db·Gb 장조와 Dm·Gm·Cm·Fm·Bbm·Ebm 은 ♭.
const _autoMajor = [
  'C',
  'Db',
  'D',
  'Eb',
  'E',
  'F',
  'Gb',
  'G',
  'Ab',
  'A',
  'Bb',
  'B',
];
const _autoMinor = [
  'C',
  'C#',
  'D',
  'Eb',
  'E',
  'F',
  'F#',
  'G',
  'G#',
  'A',
  'Bb',
  'B',
];

String _ascii(String root) => root.replaceAll('♯', '#').replaceAll('♭', 'b');

int? _pitch(String root) => _pitchOf[_ascii(root)];

final _keyPattern = RegExp(r'^([A-G](?:#|b|♯|♭)?)(m?)$');

/// 'G' 'Bb' 'F#m' 처럼 조 이름(장 12 + 단 12)인지. E#·B#·Fb·Cb 는 조로 안 받는다.
bool isKeyName(String key) {
  final m = _keyPattern.firstMatch(key);
  if (m == null) return false;
  return !const {'E#', 'B#', 'Fb', 'Cb'}.contains(_ascii(m.group(1)!));
}

({int pitch, bool minor})? _parseKey(String? key) {
  if (key == null || !isKeyName(key)) return null;
  final m = _keyPattern.firstMatch(key)!;
  return (pitch: _pitch(m.group(1)!)!, minor: m.group(2) == 'm');
}

/// 원래 조 추정 (§3-6): 첫 코드의 뿌리음, 그 코드가 m/min 이면 단조. N.C. 는 건너뛴다.
/// 코드가 없으면 null.
String? estimateKey(String chordText) {
  for (final line in chordText.split('\n')) {
    for (final p in _scanLine(line)) {
      final name = p.chord;
      if (name == null || name == 'N.C.') continue;
      final m = _chordParts.firstMatch(name);
      if (m == null) continue;
      final root = _ascii(m.group(1)!);
      final rest = m.group(2)!;
      final minor =
          rest.startsWith('min') ||
          (rest.startsWith('m') && !rest.startsWith('maj'));
      final key = '$root${minor ? 'm' : ''}';
      return isKeyName(key)
          ? key
          : '${_sharpNames[_pitch(root)!]}${minor ? 'm' : ''}';
    }
  }
  return null;
}

/// 조 이름(ASCII)으로 쓸 이름표. [flatPreferred] null 이면 자동(조 기준).
String _keyName(int pitch, bool minor, ChordAccidental accidental) {
  final names = switch (accidental) {
    ChordAccidental.sharp => _sharpNames,
    ChordAccidental.flat => _flatNames,
    ChordAccidental.auto => minor ? _autoMinor : _autoMajor,
  };
  return '${names[pitch]}${minor ? 'm' : ''}';
}

/// 그 조를 ♭ 으로 쓰는지(자동 표기).
bool _keyPrefersFlat(int pitch, bool minor) =>
    (minor ? const {2, 7, 0, 5, 10, 3} : const {5, 10, 3, 8, 1, 6}).contains(
      pitch,
    );

/// n 반음 옮긴 조 이름 (표기 규칙 §3-10). 조 이름이 아니거나 n == 0 이면 그대로.
String keyAfter(
  String key,
  int semitones, {
  ChordAccidental accidental = ChordAccidental.auto,
}) {
  final k = _parseKey(key);
  if (k == null || semitones % 12 == 0) return key;
  return _keyName((k.pitch + semitones) % 12, k.minor, accidental);
}

/// from → to 반음 차 (−5..+6). 장·단조가 다르거나 이름이 틀리면 null.
int? semitonesBetween(String fromKey, String toKey) {
  final a = _parseKey(fromKey);
  final b = _parseKey(toKey);
  if (a == null || b == null || a.minor != b.minor) return null;
  var d = (b.pitch - a.pitch) % 12;
  if (d > 6) d -= 12;
  return d;
}

/// −11..11 로 돌리기 (12 → 0, −12 → 0, 13 → 1).
int wrapTranspose(int semitones) => semitones.remainder(12);

String _moveRoot(String root, int semitones, bool flat) {
  final p = _pitch(root);
  if (p == null) return root;
  return (flat ? _flatNames : _sharpNames)[(p + semitones) % 12];
}

/// 코드 이름 하나 옮기기. 뿌리음과 `/` 뒤 베이스음만 옮긴다. 문법 밖 이름·N.C. 는 그대로.
/// semitones == 0 이면 입력 그대로.
/// 표기: sharp/flat 이면 그것, auto 면 [targetKey](바꾼 뒤 조) 기준, 그것도 없으면 그 이름의 표기.
String transposeChordName(
  String name,
  int semitones, {
  ChordAccidental accidental = ChordAccidental.auto,
  String? targetKey,
}) {
  if (semitones % 12 == 0 || name == 'N.C.' || !isChordName(name)) {
    return name;
  }
  final m = _chordParts.firstMatch(name);
  if (m == null) return name;
  final bool flat;
  switch (accidental) {
    case ChordAccidental.sharp:
      flat = false;
    case ChordAccidental.flat:
      flat = true;
    case ChordAccidental.auto:
      final k = _parseKey(targetKey);
      flat = k != null
          ? _keyPrefersFlat(k.pitch, k.minor)
          : _ascii(m.group(1)!).contains('b');
  }
  final root = _moveRoot(m.group(1)!, semitones, flat);
  final bass = m.group(3);
  return '$root${m.group(2)}${bass == null ? '' : '/${_moveRoot(bass, semitones, flat)}'}';
}

/// 코드 글 전체 옮기기. 코드 토큰만 바꾸고 나머지 글(이스케이프 포함)은 한 글자도 안 바꾼다.
/// 늘 stripChords(transposeChordText(t, n)) == stripChords(t).
String transposeChordText(
  String chordText,
  int semitones, {
  ChordAccidental accidental = ChordAccidental.auto,
  String? originalKey,
}) {
  if (semitones % 12 == 0 || chordText.isEmpty) return chordText;
  var acc = accidental;
  if (acc == ChordAccidental.auto) {
    final k = _parseKey(originalKey);
    if (k != null) {
      acc = _keyPrefersFlat((k.pitch + semitones) % 12, k.minor)
          ? ChordAccidental.flat
          : ChordAccidental.sharp;
    } else {
      // 조를 모르면 원래 코드 글 표기를 따른다(♭ 가 더 많으면 ♭).
      var flats = 0, sharps = 0;
      for (final name in _allChordNames(chordText)) {
        final m = _chordParts.firstMatch(name);
        if (m == null) continue;
        for (final r in [m.group(1), m.group(3)]) {
          if (r == null) continue;
          final a = _ascii(r);
          if (a.endsWith('b')) flats++;
          if (a.endsWith('#')) sharps++;
        }
      }
      acc = flats > sharps ? ChordAccidental.flat : ChordAccidental.sharp;
    }
  }
  final out = StringBuffer();
  final lines = chordText.split('\n');
  for (var l = 0; l < lines.length; l++) {
    if (l > 0) out.write('\n');
    final line = lines[l];
    var last = 0;
    for (final p in _scanLine(line)) {
      if (p.chord == null) continue;
      out.write(line.substring(last, p.start));
      out.write(
        '[${transposeChordName(p.chord!, semitones, accidental: acc)}]',
      );
      last = p.end;
    }
    out.write(line.substring(last));
  }
  return out.toString();
}

Iterable<String> _allChordNames(String chordText) sync* {
  for (final line in chordText.split('\n')) {
    for (final p in _scanLine(line)) {
      if (p.chord != null) yield p.chord!;
    }
  }
}

/// 싱어·발표 보기 머리줄 표시. 조가 그대로면 ''.
/// 예) 'A (원래 G, +2)', 'A (원래 G (추정), +2)'. 원래 조를 모르면 '+2'.
String keyLabel({
  required String? originalKey,
  required bool estimated,
  required int semitones,
  ChordAccidental accidental = ChordAccidental.auto,
}) {
  final n = wrapTranspose(semitones);
  if (n == 0) return '';
  final sign = n > 0 ? '+$n' : '$n';
  if (originalKey == null || !isKeyName(originalKey)) return sign;
  final now = keyAfter(originalKey, n, accidental: accidental);
  return '$now (원래 $originalKey${estimated ? ' (추정)' : ''}, $sign)';
}

// ── 다시 맞추기 (§3-5) ─────────────────────────────────

class ChordRealign {
  const ChordRealign(
    this.chordText, {
    required this.kept,
    required this.moved,
    required this.dropped,
    required this.confident,
  });

  final String chordText;
  final int kept, moved, dropped;

  /// §3-5 자동 저장 조건.
  final bool confident;

  @override
  String toString() =>
      'ChordRealign(kept $kept, moved $moved, dropped $dropped, confident $confident)\n$chordText';
}

/// 옛 코드 글의 코드 위치(옛 strip 글 기준).
/// inline: [pos] 글자 앞에 붙는 코드(줄 끝이면 pos = 줄 끝 위치, [lineEnd] 참).
/// ownLine: 코드만 있는 줄 [raw]. [pos] = 다음 가사 줄 첫 글자(before), 앞 줄 끝(after),
/// 빈 페이지 자리(emptyPage).
typedef _Anchor = ({
  int pos,
  String chord,
  bool lineEnd,
  String? raw,
  int mode, // 0 inline, 1 before line, 2 after line, 3 empty page
});

/// 옛 코드 글 → (strip 글, 앵커들). strip 글은 [stripChords] 와 같은 글이다.
({String text, List<_Anchor> anchors, List<String> tail}) _anchorsOf(
  String chordText,
) {
  final pages = _rawPages(chordText);
  // 끝 빈 페이지·끝 코드만 있는 페이지는 strip 에서 떼어진다. 코드가 든 것은 [tail] 로 따로
  // 돌려줘 새 글 끝에 그대로 붙인다(보이지 않는 코드라도 지우지 않는다).
  final tail = <String>[];
  while (pages.isNotEmpty && _stripPage(pages.last).isEmpty) {
    final last = pages.removeLast();
    if (_hasChordToken(last)) tail.insert(0, last);
  }
  final out = StringBuffer();
  final anchors = <_Anchor>[];
  for (var pi = 0; pi < pages.length; pi++) {
    if (pi > 0) out.write('\n\n');
    // 페이지 trim 을 그대로 흉내 낸다: 줄 목록을 만든 뒤 앞뒤 빈 줄·공백을 뗀다.
    final kept = <({String text, List<({int offset, String name})> chords})>[];
    final pendingOwn = <String>[]; // 다음 가사 줄 앞에 붙을 코드만 있는 줄
    final ownBefore = <int, List<String>>{}; // kept 줄 번호 → 그 앞 코드 줄
    for (final line in pages[pi].split('\n')) {
      final s = _stripLine(line);
      if (s.chordOnly) {
        pendingOwn.add(line.trim());
        continue;
      }
      if (pendingOwn.isNotEmpty) {
        ownBefore[kept.length] = List.of(pendingOwn);
        pendingOwn.clear();
      }
      kept.add((text: s.text, chords: s.chords));
    }
    final pageStart = out.length;
    // 페이지 글 = kept 줄을 잇고 trim. trim 으로 빠진 앞 글자 수만큼 오프셋을 당긴다.
    final joined = kept.map((k) => k.text).join('\n');
    final lead = joined.length - joined.trimLeft().length;
    final pageText = joined.trim();
    if (pageText.isEmpty) {
      // 코드만 있는(또는 빈) 페이지.
      for (final raw in [...ownBefore.values.expand((e) => e), ...pendingOwn]) {
        anchors.add((
          pos: pageStart,
          chord: '',
          lineEnd: false,
          raw: raw,
          mode: 3,
        ));
      }
      for (final k in kept) {
        for (final c in k.chords) {
          anchors.add((
            pos: pageStart,
            chord: '',
            lineEnd: false,
            raw: '[${c.name}]',
            mode: 3,
          ));
        }
      }
      continue;
    }
    var lineOffset = -lead;
    for (var li = 0; li < kept.length; li++) {
      final k = kept[li];
      int clampPos(int local) {
        final g = lineOffset + local;
        return pageStart +
            (g < 0 ? 0 : (g > pageText.length ? pageText.length : g));
      }

      for (final raw in ownBefore[li] ?? const <String>[]) {
        anchors.add((
          pos: clampPos(0),
          chord: '',
          lineEnd: false,
          raw: raw,
          mode: 1,
        ));
      }
      for (final c in k.chords) {
        final atEnd = c.offset >= k.text.length;
        anchors.add((
          pos: clampPos(c.offset),
          chord: c.name,
          lineEnd: atEnd,
          raw: null,
          mode: 0,
        ));
      }
      lineOffset += k.text.length + 1;
    }
    for (final raw in pendingOwn) {
      anchors.add((
        pos: pageStart + pageText.length,
        chord: '',
        lineEnd: true,
        raw: raw,
        mode: 2,
      ));
    }
    out.write(pageText);
  }
  return (text: out.toString(), anchors: anchors, tail: tail);
}

/// 글자 단위 diff 결과: 옛 글 위치마다 새 글 위치(지워졌으면 -1), 넣은 글자 수, 지운 글자 수.
({List<int> map, int inserted, int deleted}) _diff(String a, String b) {
  final map = List<int>.filled(a.length, -1);
  var pre = 0;
  while (pre < a.length && pre < b.length && a[pre] == b[pre]) {
    map[pre] = pre;
    pre++;
  }
  var suf = 0;
  while (suf < a.length - pre &&
      suf < b.length - pre &&
      a[a.length - 1 - suf] == b[b.length - 1 - suf]) {
    map[a.length - 1 - suf] = b.length - 1 - suf;
    suf++;
  }
  final aa = a.substring(pre, a.length - suf);
  final bb = b.substring(pre, b.length - suf);
  if (aa.isEmpty || bb.isEmpty) {
    return (map: map, inserted: bb.length, deleted: aa.length);
  }
  final pairs = _myers(aa, bb, 1000);
  if (pairs == null) {
    return (map: map, inserted: bb.length, deleted: aa.length);
  }
  for (final (x, y) in pairs) {
    map[pre + x] = pre + y;
  }
  return (
    map: map,
    inserted: bb.length - pairs.length,
    deleted: aa.length - pairs.length,
  );
}

/// Myers diff — 같은 글자 짝 (a 위치, b 위치). 편집 거리가 [maxD] 를 넘으면 null.
/// 단계마다 쓰인 칸만 남겨 두므로 메모리는 편집 거리의 제곱에 비례한다.
List<(int, int)>? _myers(String a, String b, int maxD) {
  final n = a.length, m = b.length;
  final max = n + m;
  final off = max + 1;
  final v = List<int>.filled(2 * max + 3, 0);
  // trace[d][k + d + 1] = d 단계 전의 v[k] (k = -d-1 .. d+1).
  final trace = <List<int>>[];
  for (var d = 0; d <= max && d <= maxD; d++) {
    trace.add(List<int>.generate(2 * d + 3, (i) => v[off - d - 1 + i]));
    for (var k = -d; k <= d; k += 2) {
      var x = (k == -d || (k != d && v[off + k - 1] < v[off + k + 1]))
          ? v[off + k + 1]
          : v[off + k - 1] + 1;
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[off + k] = x;
      if (x < n || y < m) continue;
      // 되짚기.
      final pairs = <(int, int)>[];
      var cx = n, cy = m;
      for (var dd = d; dd > 0; dd--) {
        final pv = trace[dd];
        int at(int kk) => pv[kk + dd + 1];
        final kk = cx - cy;
        final prevK = (kk == -dd || (kk != dd && at(kk - 1) < at(kk + 1)))
            ? kk + 1
            : kk - 1;
        final px = at(prevK);
        final py = px - prevK;
        while (cx > px && cy > py) {
          cx--;
          cy--;
          pairs.add((cx, cy));
        }
        cx = px;
        cy = py;
      }
      while (cx > 0 && cy > 0) {
        cx--;
        cy--;
        pairs.add((cx, cy));
      }
      return pairs.reversed.toList();
    }
  }
  return null;
}

/// 옛 코드 글의 코드를 새 가사에 다시 붙인다 (§3-5).
ChordRealign realignChords(String oldChordText, String newLyrics) {
  final target = normalizeEditableLyrics(newLyrics);
  final old = _anchorsOf(oldChordText);
  if (old.anchors.isEmpty && old.tail.isEmpty) {
    return ChordRealign(
      escapeLyricsForChords(target),
      kept: 0,
      moved: 0,
      dropped: 0,
      confident: true,
    );
  }
  final s = old.text;
  final d = _diff(s, target);
  final map = d.map;

  int lineStartOf(String t, int i) =>
      i <= 0 ? 0 : t.lastIndexOf('\n', i - 1) + 1;
  int lineEndOf(String t, int i) {
    final e = t.indexOf('\n', i);
    return e < 0 ? t.length : e;
  }

  // 새 글 위치 → 그 앞에 넣을 글들(순서 유지).
  final inserts = <int, List<String>>{};
  void put(int pos, String text) => (inserts[pos] ??= []).add(text);
  var kept = 0, moved = 0, dropped = 0;

  for (final a in old.anchors) {
    switch (a.mode) {
      case 0:
        final token = '[${a.chord}]';
        final ls = lineStartOf(s, a.pos);
        final le = lineEndOf(s, a.pos);
        if (!a.lineEnd && a.pos < s.length && map[a.pos] >= 0) {
          put(map[a.pos], token);
          kept++;
          break;
        }
        if (a.lineEnd) {
          // 줄 끝 코드: 앞 글자가 살아 있으면 그 뒤.
          if (a.pos > ls && map[a.pos - 1] >= 0) {
            put(map[a.pos - 1] + 1, token);
            kept++;
            break;
          }
        }
        // 지워진 글자: 같은 줄의 다음 살아 있는 글자 → 없으면 그 줄 끝.
        // 앞 글자도 살아 있으면 그 바로 뒤(바꿔 쓴 글자 '워'→'와' 의 새 글자 위)에 붙인다.
        var next = -1;
        for (var i = a.pos + 1; i < le; i++) {
          if (map[i] >= 0) {
            next = map[i];
            break;
          }
        }
        var prev = -1;
        for (var i = (a.pos < le ? a.pos : le) - 1; i >= ls; i--) {
          if (map[i] >= 0) {
            prev = map[i];
            break;
          }
        }
        if (next >= 0) {
          put(prev >= 0 ? prev + 1 : next, token);
          moved++;
        } else if (prev >= 0) {
          put(lineEndOf(target, prev), token);
          moved++;
        } else {
          dropped++;
        }
      case 1:
        // 다음 가사 줄 첫 글자가 살아 있고 새 글에서도 줄 첫 글자일 때만.
        if (a.pos < s.length && map[a.pos] >= 0) {
          final np = map[a.pos];
          final ns = lineStartOf(target, np);
          put(ns, '${a.raw}\n');
          kept++;
        } else {
          dropped++;
        }
      case 2:
        if (a.pos > 0 && map[a.pos - 1] >= 0) {
          put(lineEndOf(target, map[a.pos - 1]), '\n${a.raw}');
          kept++;
        } else {
          dropped++;
        }
      case 3:
        // 빈 페이지 자리: 그 자리의 페이지 구분 줄바꿈이 살아 있고 새 글에서도 빈 페이지면.
        final p = a.pos;
        int? np;
        if (p == 0) {
          // 맨 앞 빈 페이지: 새 글도 빈 페이지로 시작하면 0.
          if (target.startsWith('\n\n') && s.startsWith('\n\n')) np = 0;
        } else if (p - 1 >= 0 && map[p - 1] >= 0) {
          final q = map[p - 1] + 1;
          final before = q >= 2 && target.substring(q - 2, q) == '\n\n';
          final after =
              q + 2 <= target.length && target.substring(q, q + 2) == '\n\n';
          if (before && after) np = q;
        }
        if (np != null) {
          final list = inserts[np];
          // 같은 빈 페이지에 여럿이면 줄로 잇는다.
          if (list != null &&
              list.isNotEmpty &&
              list.last.startsWith('\u0001')) {
            list[list.length - 1] = '${list.last}\n${a.raw}';
          } else {
            put(np, '\u0001${a.raw}');
          }
          kept++;
        } else {
          dropped++;
        }
    }
  }

  // 새 글을 이스케이프하며 넣을 글을 끼운다.
  final out = StringBuffer();
  final lines = target.split('\n');
  var g = 0;
  void flush(int pos) {
    final list = inserts[pos];
    if (list == null) return;
    for (final t in list) {
      out.write(t.startsWith('\u0001') ? t.substring(1) : t);
    }
  }

  for (var l = 0; l < lines.length; l++) {
    final line = lines[l];
    for (var i = 0; i < line.length; i++) {
      final list = inserts[g];
      if (list != null) {
        // 바로 앞 글자가 `\` 면 `\[G]` 가 이스케이프로 읽힌다 — 그 자리 코드는 버린다.
        if (i > 0 && line[i - 1] == r'\') {
          final tokens = list.where(
            (t) => t.startsWith('[') && !t.contains('\n'),
          );
          dropped += tokens.length;
          kept -= tokens.length;
          list.removeWhere((t) => t.startsWith('[') && !t.contains('\n'));
        }
        flush(g);
      }
      if (_needsEscape(line, i)) out.write(r'\');
      out.write(line[i]);
      g++;
    }
    // 줄 끝 자리.
    final list = inserts[g];
    if (list != null && line.isNotEmpty && line[line.length - 1] == r'\') {
      final n = list
          .where((t) => t.startsWith('[') && !t.contains('\n'))
          .length;
      dropped += n;
      kept -= n;
      list.removeWhere((t) => t.startsWith('[') && !t.contains('\n'));
    }
    flush(g);
    if (l < lines.length - 1) {
      out.write('\n');
      g++;
    }
  }

  var result = out.toString();
  if (old.tail.isNotEmpty) {
    result = [if (result.isNotEmpty) result, ...old.tail].join('\n\n');
    for (final page in old.tail) {
      kept += countChords(page);
    }
  }

  final whitespaceOnly =
      s.replaceAll(RegExp(r'\s'), '') == target.replaceAll(RegExp(r'\s'), '');
  final changed = d.inserted > d.deleted ? d.inserted : d.deleted;
  final confident =
      (whitespaceOnly && dropped == 0) ||
      (changed <= target.length * 0.1 && moved == 0 && dropped == 0);
  return ChordRealign(
    result,
    kept: kept,
    moved: moved,
    dropped: dropped,
    confident: confident,
  );
}

// ── '코드 위 가사' 붙여 넣기 변환 ─────────────────────────

/// 한 줄이 코드만 있는 줄인지(공백으로 나눈 낱말이 모두 코드 이름, '|' 마디선은 넘긴다).
bool _isChordOnlyLine(String line) {
  final words = line.trim().split(RegExp(r'\s+')).where((w) => w != '|');
  if (words.isEmpty || line.trim().isEmpty) return false;
  return words.every(isChordName);
}

/// 표시 폭: 한글·한자·전각은 2칸.
int _width(int codeUnit) {
  if ((codeUnit >= 0x1100 && codeUnit <= 0x115F) ||
      (codeUnit >= 0x2E80 && codeUnit <= 0xA4CF) ||
      (codeUnit >= 0xAC00 && codeUnit <= 0xD7A3) ||
      (codeUnit >= 0xF900 && codeUnit <= 0xFAFF) ||
      (codeUnit >= 0xFE30 && codeUnit <= 0xFE4F) ||
      (codeUnit >= 0xFF00 && codeUnit <= 0xFF60) ||
      (codeUnit >= 0xFFE0 && codeUnit <= 0xFFE6)) {
    return 2;
  }
  return 1;
}

/// 한 줄을 이스케이프하며 [at](글자 위치 → 넣을 토큰들)을 끼운다.
String _emitLine(String line, Map<int, List<String>> at) {
  final out = StringBuffer();
  for (var i = 0; i < line.length; i++) {
    for (final t in at[i] ?? const <String>[]) {
      out.write(t);
    }
    if (_needsEscape(line, i)) out.write(r'\');
    out.write(line[i]);
  }
  for (final t in at[line.length] ?? const <String>[]) {
    out.write(t);
  }
  return out.toString();
}

/// '코드 줄 + 가사 줄' 쌍이 2쌍 이상이면 인라인 코드 글로, 아니면 null (한글 폭 2칸).
/// 짝 없는 코드 줄(전주·간주)은 코드만 있는 줄 `[G] [D]` 로 남긴다.
String? chordOverLyricsToInline(String pasted) {
  final lines = pasted
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final isChord = [for (final l in lines) _isChordOnlyLine(l)];
  var pairs = 0;
  for (var i = 0; i + 1 < lines.length; i++) {
    if (isChord[i] && !isChord[i + 1] && lines[i + 1].trim().isNotEmpty) {
      pairs++;
    }
  }
  if (pairs < 2) return null;
  final out = <String>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (!isChord[i]) {
      out.add(escapeLyricsForChords(line));
      i++;
      continue;
    }
    // 코드 위치(칸).
    final chords = <({int column, String name})>[];
    for (final m in RegExp(r'\S+').allMatches(line)) {
      if (m.group(0) == '|') continue;
      chords.add((column: m.start, name: m.group(0)!));
    }
    final paired =
        i + 1 < lines.length &&
        !isChord[i + 1] &&
        lines[i + 1].trim().isNotEmpty;
    if (!paired) {
      out.add([for (final c in chords) '[${c.name}]'].join(' '));
      i++;
      continue;
    }
    final lyric = lines[i + 1].replaceFirst(RegExp(r'\s+$'), '');
    // 글자마다 시작 칸.
    final starts = <int>[];
    var col = 0;
    for (var k = 0; k < lyric.length; k++) {
      starts.add(col);
      col += lyric[k] == '\t' ? 4 : _width(lyric.codeUnitAt(k));
    }
    final at = <int, List<String>>{};
    var padded = lyric;
    for (final c in chords) {
      var idx = -1;
      for (var k = 0; k < lyric.length; k++) {
        final w = k + 1 < lyric.length ? starts[k + 1] - starts[k] : 1;
        if (c.column < starts[k] + w) {
          idx = k;
          break;
        }
      }
      if (idx < 0) {
        idx = lyric.length;
      }
      (at[idx] ??= []).add('[${c.name}]');
    }
    padded = _emitLine(lyric, at);
    out.add(padded);
    i += 2;
  }
  return out.join('\n');
}
