import 'dart:isolate';

import '../../bible/domain/bible_voice_parse.dart' show composeHangul;
import 'praise_song.dart';

/// 붙여 넣은 콘티 글의 한 줄 = 곡 하나.
///
/// 예) `2. 갈길을 밝히 보이시니(or 죄에서 자유를 얻게 함은) G`
///   → number 2, titles ['갈길을 밝히 보이시니', '죄에서 자유를 얻게 함은'], key 'G'
class ContiTextEntry {
  const ContiTextEntry({
    required this.line,
    required this.titles,
    this.number,
    this.key = '',
  });

  /// 원래 줄(앞뒤 공백만 뗀 것). 화면에 그대로 보여 준다.
  final String line;

  /// 찾을 제목. 첫 번째가 본 제목, 나머지는 `(or …)`·`(또는 …)` 로 적은 대신 부를 곡.
  final List<String> titles;

  final int? number;

  /// 줄 끝의 조성(F, G, Bb, F#m, `F-G` 처럼 조 바꿈 포함). 없으면 ''.
  final String key;
}

/// 콘티 글 전체를 곡 줄로 나눈다.
///
/// - `<11.01 (주일) 예배 콘티>` 처럼 꺾쇠로 시작하는 머리말 줄은 뺀다(꺾쇠 뒤에 글이 더 붙어도)
/// - 번호 줄(`1.`·`1)`, 또는 `1 제목` 이 두 줄 이상)이 있으면 번호 줄과 `->` 로 시작하는
///   이어 부르기 줄만 곡으로 본다(설명 줄 섞임 대비)
/// - 번호 줄이 없으면 빈 줄·머리말이 아닌 모든 줄을 곡으로 본다
/// - 제목 앞 `->`·`→`·`=>`·`-`·`•` 는 뗀다(이어 부르기 표시)
List<ContiTextEntry> parseContiText(String text) {
  final lines = composeHangul(text)
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !_headerLine.hasMatch(l))
      .toList();

  // '1 제목' 꼴은 '7 Days' 같은 숫자 제목과 헷갈리므로 두 줄 이상일 때만 번호로 본다.
  final punctNumbered = lines.where(_punctNumberedLine.hasMatch).length;
  final spaceNumbered = lines.where(_spaceNumberedLine.hasMatch).length;
  final numberedMode = punctNumbered > 0 || spaceNumbered >= 2;

  final entries = <ContiTextEntry>[];
  for (final line in lines) {
    final ContiTextEntry? entry;
    if (!numberedMode) {
      entry = _parseBody(line, line, null);
    } else if ((_punctNumberedLine.firstMatch(line) ??
            _spaceNumberedLine.firstMatch(line))
        case final m?) {
      entry = _parseBody(line, m.group(2)!, int.parse(m.group(1)!));
    } else if (_continuationLine.hasMatch(line)) {
      // 번호 없이 '-> 곡' 으로 적은 이어 부르기 곡
      entry = _parseBody(line, line, null);
    } else {
      entry = null;
    }
    if (entry != null) entries.add(entry);
  }
  return entries;
}

final _headerLine = RegExp(r'^[<〈《\[][^>〉》\]]*[>〉》\]]');
// '1.'·'1)' 뒤에 숫자가 오면 번호가 아니다('11.01' 날짜). ':' 는 시각('7:30')이라 받지 않는다.
final _punctNumberedLine = RegExp(r'^(\d{1,2})\s*[.)．]\s*(?!\d)(.+)$');
final _spaceNumberedLine = RegExp(r'^(\d{1,2})\s+(?!\d)(.+)$');
final _continuationLine = RegExp(r'^(?:->|→|=>|⇒)');
final _leadingMarks = RegExp(r'^(?:->|→|=>|⇒|-|•|·|\*)+\s*');

// 조 하나: C, F#, Bb, Ebm, A♭ … / 조 바꿈: F-G, G→A, D/E
const _keyUnit = r'[A-G](?:#|b|♯|♭)?m?';
const _keyChain = '$_keyUnit(?:\\s*(?:-|~|→|->|/|>)\\s*$_keyUnit)*';
// 대소문자를 가린다 — 'G' 는 조지만 영어 제목 끝 낱말('a', 'be')은 조가 아니다.
// 괄호는 짝이 맞을 때만 — '(or Here I Am)' 의 ')' 를 조와 같이 떼면 대신 부를 곡이 깨진다.
final _trailingKey = RegExp(
  '\\s+(?:\\(\\s*(?:[Kk]ey\\s*)?($_keyChain)\\s*\\)|(?:[Kk]ey\\s*)?($_keyChain))\\s*\$',
);
final _orAlternative = RegExp(r'\(\s*(?:or|또는|혹은)\s+([^()]+)\)', caseSensitive: false);

ContiTextEntry? _parseBody(String line, String body, int? number) {
  var rest = body.replaceFirst(_leadingMarks, '').trim();

  var key = '';
  final keyMatch = _trailingKey.firstMatch(rest);
  // 'Bb' 만 남는 줄(제목 없이 조만)이면 조로 보지 않는다.
  if (keyMatch != null && keyMatch.start > 0) {
    key = keyMatch.group(1) ?? keyMatch.group(2)!;
    rest = rest.substring(0, keyMatch.start).trim();
  }

  final alternatives = [
    for (final m in _orAlternative.allMatches(rest)) m.group(1)!.trim(),
  ];
  final main = rest.replaceAll(_orAlternative, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final titles = [
    if (main.isNotEmpty) main,
    ...alternatives.where((t) => t.isNotEmpty),
  ];
  if (titles.isEmpty) return null;
  return ContiTextEntry(line: line, titles: titles, number: number, key: key);
}

// ── 곡 찾기 ─────────────────────────────────────────────────────────────

/// 제목 비교용: 한글 자모 합치기(NFD → NFC) + 소문자 + 글자·숫자만 (띄어쓰기·문장부호 무시).
/// '갈 길을 밝히 보이시니!' 와 '갈길을밝히보이시니' 가 같아진다.
String normalizeSongTitle(String title) => composeHangul(
  title,
).toLowerCase().replaceAll(_nonWord, '');

final _nonWord = RegExp(r'[^\p{L}\p{N}]', unicode: true);

/// 괄호 안을 뺀 제목. '신부의 노래 (주님 다시 오실 때까지)' → '신부의 노래'
String _withoutParens(String title) =>
    title.replaceAll(RegExp(r'\([^()]*\)|\[[^\[\]]*\]'), ' ').trim();

enum ContiMatchKind {
  /// 제목이 (띄어쓰기·문장부호를 빼면) 똑같다
  exact,

  /// 한쪽 제목이 다른 쪽을 품는다 — 맞을 가능성이 높지만 확인이 필요하다
  partial,
}

class ContiSongMatch {
  const ContiSongMatch({required this.candidates, required this.kind});

  /// 고를 수 있는 곡. 같은 제목 곡이 여럿이면 여럿이다.
  final List<PraiseSong> candidates;

  /// 후보가 없으면 null.
  final ContiMatchKind? kind;
}

/// 곡 목록을 한 번만 정규화해 두고 줄마다 찾는다.
class ContiSongMatcher {
  ContiSongMatcher(List<PraiseSong> songs)
    : _songs = [
        for (final s in songs)
          (
            song: s,
            full: normalizeSongTitle(s.displayTitle),
            bare: normalizeSongTitle(_withoutParens(s.displayTitle)),
            lyrics: normalizeSongTitle(s.lyrics),
          ),
      ];

  /// 곡이 수천 곡이면 가사 정규화가 화면을 멈출 만큼 걸려서 다른 isolate 에서 만든다.
  static Future<ContiSongMatcher> build(List<PraiseSong> songs) =>
      Isolate.run(() => ContiSongMatcher(songs));

  /// 정규화한 제목(full)·괄호 뺀 제목(bare)·가사(손으로 찾기용)를 미리 만들어 둔다.
  final List<_SongKey> _songs;

  /// 부분 일치로 보려면 짧은 쪽이 이만큼은 돼야 한다('주' 하나로 수백 곡이 걸리지 않게).
  static const _minPartialLength = 3;

  /// 비슷한 제목은 제목 하나에 이만큼만 후보로 보인다(나머지는 '직접 찾기').
  static const _maxPartial = 8;

  ContiSongMatch match(ContiTextEntry entry) {
    // 본 제목·대신 부를 곡마다 가장 잘 맞는 쪽(똑같은 제목 > 비슷한 제목)을 모은다.
    // 본 제목이 똑같이 맞아도 대신 부를 곡 후보가 빠지지 않게.
    final candidates = <PraiseSong>[];
    var allExact = true;
    for (var i = 0; i < entry.titles.length; i++) {
      // 'Here I Am' 처럼 제목 끝 낱말이 조로 떼어졌을 수 있어 본 제목은 조를 붙여서도 맞춰 본다.
      final variants = [
        entry.titles[i],
        if (i == 0 && entry.key.isNotEmpty) '${entry.titles[i]} ${entry.key}',
      ];
      final exact = <PraiseSong>[];
      final partial = <_SongKey>[];
      for (final title in variants) {
        _collect(title, exact, partial);
      }
      if (exact.isNotEmpty) {
        candidates.addAll(exact);
      } else if (partial.isNotEmpty) {
        allExact = false;
        candidates.addAll(_byLengthGap(partial, entry.titles[i]).take(_maxPartial));
      }
    }
    if (candidates.isEmpty) {
      return const ContiSongMatch(candidates: [], kind: null);
    }
    return ContiSongMatch(
      candidates: _unique(candidates),
      kind: allExact ? ContiMatchKind.exact : ContiMatchKind.partial,
    );
  }

  void _collect(String title, List<PraiseSong> exact, List<_SongKey> partial) {
    final full = normalizeSongTitle(title);
    final bare = normalizeSongTitle(_withoutParens(title));
    if (bare.isEmpty && full.isEmpty) return;
    for (final s in _songs) {
      final isExact =
          (full.isNotEmpty && (s.full == full || s.bare == full)) ||
          (bare.isNotEmpty && (s.full == bare || s.bare == bare));
      if (isExact) {
        exact.add(s.song);
      } else if (_partial(s.bare, bare) || _partial(s.full, full)) {
        partial.add(s);
      }
    }
  }

  /// 길이가 비슷한(덜 붙은) 제목부터. 정규화한 제목은 미리 만들어 둔 것을 쓴다.
  static List<PraiseSong> _byLengthGap(List<_SongKey> songs, String title) {
    final length = normalizeSongTitle(title).length;
    int gap(_SongKey s) => (s.full.length - length).abs();
    final sorted = [...songs]..sort((a, b) => gap(a).compareTo(gap(b)));
    return _unique([for (final s in sorted) s.song]);
  }

  /// 손으로 찾기: 제목(띄어쓰기 무시) 또는 가사에 검색어가 든 곡.
  List<PraiseSong> search(String query) {
    final q = normalizeSongTitle(query);
    if (q.isEmpty) return const [];
    return [
      for (final s in _songs)
        if (s.full.contains(q) || s.lyrics.contains(q)) s.song,
    ];
  }

  static bool _partial(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    final shorter = a.length < b.length ? a : b;
    if (shorter.length < _minPartialLength) return false;
    return a.contains(b) || b.contains(a);
  }

  /// 같은 곡이 본 제목·대신 부를 곡 양쪽에 걸려도 한 번만. id 가 없으면(테스트) 객체로 가린다.
  static List<PraiseSong> _unique(List<PraiseSong> songs) {
    final seen = <Object>{};
    return [
      for (final s in songs)
        if (seen.add(s.id ?? s)) s,
    ];
  }
}

typedef _SongKey = ({PraiseSong song, String full, String bare, String lyrics});
