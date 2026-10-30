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
/// - `<11.01 (주일) 예배 콘티>` 처럼 꺾쇠로 감싼 줄은 머리말이라 뺀다
/// - 번호 줄(`1.`·`1)`·`1 `)이 하나라도 있으면 번호 줄만 곡으로 본다(설명 줄 섞임 대비)
/// - 번호 줄이 없으면 빈 줄·머리말이 아닌 모든 줄을 곡으로 본다
/// - 제목 앞 `->`·`→`·`=>`·`-`·`•` 는 뗀다(이어 부르기 표시)
List<ContiTextEntry> parseContiText(String text) {
  final lines = text
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !_headerLine.hasMatch(l))
      .toList();
  final numbered = [
    for (final l in lines)
      if (_numberedLine.firstMatch(l) case final m?) (line: l, match: m),
  ];

  final entries = <ContiTextEntry>[];
  if (numbered.isNotEmpty) {
    for (final (:line, :match) in numbered) {
      final entry = _parseBody(line, match.group(2)!, int.parse(match.group(1)!));
      if (entry != null) entries.add(entry);
    }
  } else {
    for (final line in lines) {
      final entry = _parseBody(line, line, null);
      if (entry != null) entries.add(entry);
    }
  }
  return entries;
}

final _headerLine = RegExp(r'^[<〈《\[].*[>〉》\]]$');
final _numberedLine = RegExp(r'^(\d{1,2})\s*(?:[.)．:]\s*|\s+)(.*)$');
final _leadingMarks = RegExp(r'^(?:->|→|=>|⇒|-|•|·|\*)+\s*');

// 조 하나: C, F#, Bb, Ebm, A♭ … / 조 바꿈: F-G, G→A, D/E
const _keyUnit = r'[A-G](?:#|b|♯|♭)?m?';
// 대소문자를 가린다 — 'G' 는 조지만 영어 제목 끝 낱말('a', 'be')은 조가 아니다.
final _trailingKey = RegExp(
  '\\s+\\(?(?:[Kk]ey\\s*)?($_keyUnit(?:\\s*(?:-|~|→|->|/|>)\\s*$_keyUnit)*)\\)?\\s*\$',
);
final _orAlternative = RegExp(r'\(\s*(?:or|또는|혹은)\s+([^()]+)\)', caseSensitive: false);

ContiTextEntry? _parseBody(String line, String body, int? number) {
  var rest = body.replaceFirst(_leadingMarks, '').trim();

  var key = '';
  final keyMatch = _trailingKey.firstMatch(rest);
  // 'Bb' 만 남는 줄(제목 없이 조만)이면 조로 보지 않는다.
  if (keyMatch != null && keyMatch.start > 0) {
    key = keyMatch.group(1)!;
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

/// 제목 비교용: 소문자 + 글자·숫자만 (띄어쓰기·문장부호 무시).
/// '갈 길을 밝히 보이시니!' 와 '갈길을밝히보이시니' 가 같아진다.
String normalizeSongTitle(String title) =>
    title.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

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
          ),
      ];

  final List<({PraiseSong song, String full, String bare})> _songs;

  /// 손으로 찾기용 정규화한 가사. 처음 찾을 때 한 번만 만든다(글자마다 수천 곡을 다시 정규화하지 않게).
  late final List<String> _lyrics = [
    for (final s in _songs) normalizeSongTitle(s.song.lyrics),
  ];

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
      final partial = <PraiseSong>[];
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

  void _collect(String title, List<PraiseSong> exact, List<PraiseSong> partial) {
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
        partial.add(s.song);
      }
    }
  }

  /// 길이가 비슷한(덜 붙은) 제목부터.
  static List<PraiseSong> _byLengthGap(List<PraiseSong> songs, String title) {
    final length = normalizeSongTitle(title).length;
    int gap(PraiseSong s) => (normalizeSongTitle(s.displayTitle).length - length).abs();
    return _unique(songs)..sort((a, b) => gap(a).compareTo(gap(b)));
  }

  /// 손으로 찾기: 제목(띄어쓰기 무시) 또는 가사에 검색어가 든 곡.
  List<PraiseSong> search(String query) {
    final q = normalizeSongTitle(query);
    if (q.isEmpty) return const [];
    return [
      for (var i = 0; i < _songs.length; i++)
        if (_songs[i].full.contains(q) || _lyrics[i].contains(q)) _songs[i].song,
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
