import 'praise_song.dart';

sealed class StagingItem {
  const StagingItem();
  String get displayTitle;
  String get previewText;
}

class SongStagingItem extends StagingItem {
  SongStagingItem(this.song);
  final PraiseSong song;

  @override
  String get displayTitle => song.title;

  @override
  String get previewText =>
      song.pages.isEmpty ? '' : song.pages.first.replaceAll('\n', ' ');
}

class BibleStagingItem extends StagingItem {
  BibleStagingItem({required this.reference, required this.text});

  final String reference;
  final String text;

  @override
  String get displayTitle => reference;

  @override
  String get previewText =>
      text.length > 60 ? '${text.substring(0, 60)}…' : text;
}

class BlankStagingItem extends StagingItem {
  const BlankStagingItem({this.mainText = '', this.englishText = ''});

  final String mainText;
  final String englishText;

  @override
  String get displayTitle => '[ 빈 페이지 ]';

  @override
  String get previewText => mainText.replaceAll('\n', ' ');
}
