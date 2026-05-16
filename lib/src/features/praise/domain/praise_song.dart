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

  // Korean/English 페이지를 함께 처리해 인덱스 정합성 보장.
  // 둘 다 비어있는 페이지만 제외하고, 한쪽만 비어있는 경우는 유지한다.
  List<({String korean, String english})> get pairedPages {
    final ks = lyrics.split('###').map((p) => p.trim()).toList();
    final es = englishLyrics.split('###').map((p) => p.trim()).toList();
    final len = ks.length > es.length ? ks.length : es.length;
    final result = <({String korean, String english})>[];
    for (var i = 0; i < len; i++) {
      final k = i < ks.length ? ks[i] : '';
      final e = i < es.length ? es[i] : '';
      if (k.isNotEmpty || e.isNotEmpty) {
        result.add((korean: k, english: e));
      }
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

  factory PraiseSong.fromMap(Map<String, Object?> map) {
    return PraiseSong(
      id: map['id'] as int?,
      fileName: map['file_name'] as String,
      title: map['title'] as String,
      lyrics: map['lyrics'] as String,
      englishLyrics: (map['english_lyrics'] as String?) ?? '',
    );
  }

  factory PraiseSong.fromJson(Map<String, dynamic> json) {
    return PraiseSong(
      id: null,
      fileName: json['file_name'] as String,
      title: json['title'] as String,
      lyrics: json['lyrics'] as String,
      englishLyrics: (json['english_lyrics'] as String?) ?? '',
    );
  }
}
