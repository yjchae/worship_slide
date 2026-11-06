import 'chord_lyrics.dart';

/// 곡 한 페이지의 언어별 가사: 원본 · 보조 · 추가 보조 + 그 페이지 코드 글.
/// [chord] 는 원본 가사와 짝이 맞는 코드 글(§3-5 표시 규칙), '' = 이 페이지 코드 없음.
typedef LyricsPage = ({
  String korean,
  String english,
  String extra,
  String chord,
});

extension LyricsPageX on LyricsPage {
  /// 글이 하나도 없는 페이지(코드는 보지 않는다 — 코드만 있는 페이지도 관객에겐 빈 페이지다).
  bool get isEmptyPage => korean.isEmpty && english.isEmpty && extra.isEmpty;
}

/// copyWith 에서 "그대로 둠"을 null(지움)과 가르는 표시.
const Object _keep = Object();

class PraiseSong {
  const PraiseSong({
    required this.id,
    required this.fileName,
    required this.title,
    required this.lyrics,
    required this.englishLyrics,
    this.extraLyrics = '',
    this.chordLyrics,
    this.chordKey,
    this.chordTranspose = 0,
    this.chordAccidental = ChordAccidental.auto,
  });

  final int? id;
  final String fileName;
  final String title;
  final String lyrics;
  final String englishLyrics;

  /// 추가 보조 언어 가사(관객 화면 세 번째 줄). DB(praise_songs)에는 없고 콘티 스냅샷에만
  /// 담긴다 — 곡을 콘티에 담을 때 고른 언어 가사가 들어온다([englishLyrics] 와 같은 방식).
  final String extraLyrics;

  /// 코드 붙은 원본 가사(ChordPro 인라인, `chord_lyrics.dart`). null = 코드 없음.
  /// DB `praise_songs.chord_lyrics` / 콘티 `song_chord_lyrics`. 관객 화면·PPTX 로는 가지 않는다.
  final String? chordLyrics;

  /// 원래 조('G', 'F#m'). null = 모름(첫 코드로 추정). DB `chord_key` / 콘티 `song_chord_key`.
  final String? chordKey;

  /// 조 바꾸기(반음, −11..11). 콘티 스냅샷 전용(DB praise_songs 엔 없음) / 콘티 `song_transpose`.
  final int chordTranspose;

  /// ♯/♭ 표기 선호. 콘티 스냅샷 전용 / 콘티 `song_chord_accidental`.
  final ChordAccidental chordAccidental;

  bool get hasChords => chordLyrics != null && chordLyrics!.isNotEmpty;

  /// 원래 조(정해 둔 값, 없으면 추정). 코드가 없으면 null.
  String? get effectiveChordKey {
    final key = chordKey;
    if (key != null && isKeyName(key)) return key;
    return hasChords ? estimateKey(chordLyrics!) : null;
  }

  /// [effectiveChordKey] 가 추정값인지.
  bool get chordKeyEstimated => chordKey == null || !isKeyName(chordKey!);

  /// 바꾸지 않은 칸은 그대로 둔다. 칸을 하나씩 다시 적으면 [extraLyrics] 를 빠뜨리기 쉽다.
  /// [chordLyrics]·[chordKey] 는 null 을 넘기면 지운다(안 넘기면 그대로).
  PraiseSong copyWith({
    String? title,
    String? lyrics,
    String? englishLyrics,
    String? extraLyrics,
    Object? chordLyrics = _keep,
    Object? chordKey = _keep,
    int? chordTranspose,
    ChordAccidental? chordAccidental,
  }) {
    return PraiseSong(
      id: id,
      fileName: fileName,
      title: title ?? this.title,
      lyrics: lyrics ?? this.lyrics,
      englishLyrics: englishLyrics ?? this.englishLyrics,
      extraLyrics: extraLyrics ?? this.extraLyrics,
      chordLyrics: identical(chordLyrics, _keep)
          ? this.chordLyrics
          : _nullIfEmpty(chordLyrics as String?),
      chordKey: identical(chordKey, _keep)
          ? this.chordKey
          : _nullIfEmpty(chordKey as String?),
      chordTranspose: chordTranspose ?? this.chordTranspose,
      chordAccidental: chordAccidental ?? this.chordAccidental,
    );
  }

  static String? _nullIfEmpty(String? s) => s == null || s.isEmpty ? null : s;

  /// 페이지별 [원본, 보조, 추가 보조, 코드] 가사. 세 언어 중 가장 긴 쪽에 맞추고 빈 칸은 ''.
  /// 코드는 원본 가사와 짝이 맞는 페이지에만 든다([matchedChordPages]).
  /// 끝에 세 칸이 모두 빈 페이지는 뗀다.
  List<LyricsPage> get pairedPages {
    final ks = _parsePages(lyrics);
    final es = _parsePages(englishLyrics);
    final xs = _parsePages(extraLyrics);
    final cs = hasChords
        ? matchedChordPages(chordLyrics, lyrics)
        : const <String?>[];
    final len = [
      ks.length,
      es.length,
      xs.length,
    ].reduce((a, b) => a > b ? a : b);
    String at(List<String> list, int i) => i < list.length ? list[i] : '';
    final result = <LyricsPage>[
      for (var i = 0; i < len; i++)
        (
          korean: at(ks, i),
          english: at(es, i),
          extra: at(xs, i),
          chord: i < cs.length ? cs[i] ?? '' : '',
        ),
    ];
    while (result.isNotEmpty && result.last.isEmptyPage) {
      result.removeLast();
    }
    return result;
  }

  List<String> get pages => pairedPages.map((p) => p.korean).toList();

  List<String> get englishPages => pairedPages.map((p) => p.english).toList();

  List<String> get extraPages => pairedPages.map((p) => p.extra).toList();

  // 페이지 구분자: \n\n (빈 줄 1개).
  // 앞쪽 \n\n = 빈 페이지. 예) '\n\n\n\n가사' → ['', '', '가사'].
  static List<String> _parsePages(String text) {
    if (text.isEmpty) return [];
    final pages = text
        .split(RegExp(r'\n[ \t]*\n'))
        .map((p) => p.trim())
        .toList();
    return pages;
  }

  /// 코드 칸(chord_*)은 넣지 않는다 — `updateSong`·`insertSong` 처럼 가사만 고치는 길이
  /// 코드를 덮지 않게. 코드는 `PraiseRepository.saveChords` 로만 쓴다.
  Map<String, Object?> toMap() {
    return {
      'id': id,
      'file_name': fileName,
      'title': title,
      'lyrics': lyrics,
      'english_lyrics': englishLyrics,
    };
  }

  /// 발표 화면에 보일 제목. PPT 파일 이름에서 온 '(와이드 스크린)'·'와이드스크린'·
  /// 오타('와일드스크린', '와이드 스크림')·'(와이드)' 표시와 '.ppt' 확장자를 뗀다.
  /// DB 제목은 그대로 둔다 — 보조 언어 가사(song_translations)가 제목을 키로 쓴다.
  String get displayTitle => cleanDisplayTitle(title);

  static final _wideMark = RegExp(r'와\s*[이일]{1,2}\s*드(?:\s*스\s*크\s*[린림])?');

  static String cleanDisplayTitle(String title) {
    var t = title.replaceFirst(RegExp(r'\.pptx?$', caseSensitive: false), '');
    if (_wideMark.hasMatch(t)) {
      t = t
          .replaceAll(_wideMark, '')
          .replaceAll(RegExp(r'\(\s*\)'), ' ')
          .replaceAll(RegExp(r'\(\s+'), '(')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      // '(와일드스크린 그 사랑 감사해)' 처럼 제목 전체가 괄호 안에 있던 경우
      final wrapped = RegExp(r'^\(([^()]*)\)$').firstMatch(t);
      if (wrapped != null) t = wrapped.group(1)!.trim();
    }
    return t.isEmpty ? title.trim() : t.trim();
  }

  static String _cleanTitle(String title) => title
      .replaceAll(RegExp(r'\s*\(\s*와이드 스크린\s*\)\s*', caseSensitive: false), '')
      .trim();

  factory PraiseSong.fromMap(Map<String, Object?> map) {
    return PraiseSong(
      id: map['id'] as int?,
      fileName: map['file_name'] as String,
      title: _cleanTitle(map['title'] as String),
      lyrics: map['lyrics'] as String,
      englishLyrics: (map['english_lyrics'] as String?) ?? '',
      chordLyrics: _nullIfEmpty(map['chord_lyrics'] as String?),
      chordKey: _nullIfEmpty(map['chord_key'] as String?),
    );
  }

  factory PraiseSong.fromJson(Map<String, dynamic> json) {
    return PraiseSong(
      id: null,
      fileName: json['file_name'] as String,
      title: _cleanTitle(json['title'] as String),
      lyrics: json['lyrics'] as String,
      englishLyrics: (json['english_lyrics'] as String?) ?? '',
    );
  }
}

/// 페이지들의 코드 글을 다시 잇는다([PraiseSong.pairedPages] 의 반대). 코드 없는 페이지는
/// 이스케이프한 원본 가사로 채워 페이지 수를 맞춘다. 모든 페이지에 코드가 없으면 null.
/// 곡을 나누거나 일부만 담을 때(`_songWithPages`) 코드가 페이지를 따라가게 한다.
String? chordLyricsForPages(List<LyricsPage> pages) {
  if (pages.every((p) => p.chord.isEmpty)) return null;
  return [
    for (final p in pages)
      p.chord.isEmpty ? escapeLyricsForChords(p.korean) : p.chord,
  ].join('\n\n');
}
