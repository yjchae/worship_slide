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

  List<String> get pages => lyrics
      .split('###')
      .map((page) => page.trim())
      .where((page) => page.isNotEmpty)
      .toList();

  List<String> get englishPages => englishLyrics
      .split('###')
      .map((page) => page.trim())
      .where((page) => page.isNotEmpty)
      .toList();

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
