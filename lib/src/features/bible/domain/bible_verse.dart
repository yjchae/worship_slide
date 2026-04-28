class BibleVerse {
  const BibleVerse({
    required this.id,
    required this.bookName,
    required this.chapter,
    required this.verse,
    required this.text,
  });

  final int id;
  final String bookName;
  final int chapter;
  final int verse;
  final String text;

  String get reference => '$bookName $chapter:$verse';
}
