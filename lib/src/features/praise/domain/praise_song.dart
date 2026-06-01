class PraiseSong {
  const PraiseSong({
    required this.id,
    required this.fileName,
    required this.title,
    required this.lyrics,
    required this.englishLyrics,
  });

  final int? id;
  final String fileName;
  final String title;
  final String lyrics;
  final String englishLyrics;

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

  List<({String korean, String english})> get pairedPages {
    final ks = _parsePages(lyrics);
    final es = _parsePages(englishLyrics);
    final len = ks.length > es.length ? ks.length : es.length;
    final result = <({String korean, String english})>[];
    for (var i = 0; i < len; i++) {
      final k = i < ks.length ? ks[i] : '';
      final e = i < es.length ? es[i] : '';
      result.add((korean: k, english: e));
    }
    while (result.isNotEmpty) {
      final last = result.last;
      if (last.korean.isNotEmpty || last.english.isNotEmpty) break;
      result.removeLast();
    }
    return result;
  }

  List<String> get pages => pairedPages.map((p) => p.korean).toList();

  List<String> get englishPages => pairedPages.map((p) => p.english).toList();

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'file_name': fileName,
      'title': title,
      'lyrics': lyrics,
      'english_lyrics': englishLyrics,
    };
  }

  static String _cleanTitle(String title) =>
      title.replaceAll(RegExp(r'\s*\(\s*와이드 스크린\s*\)\s*', caseSensitive: false), '').trim();

  factory PraiseSong.fromMap(Map<String, Object?> map) {
    return PraiseSong(
      id: map['id'] as int?,
      fileName: map['file_name'] as String,
      title: _cleanTitle(map['title'] as String),
      lyrics: map['lyrics'] as String,
      englishLyrics: (map['english_lyrics'] as String?) ?? '',
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
