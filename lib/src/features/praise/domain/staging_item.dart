import 'praise_song.dart';
import 'slide_media.dart';

sealed class StagingItem {
  const StagingItem();
  String get displayTitle;
  String get previewText;
}

class SongStagingItem extends StagingItem {
  SongStagingItem(this.song);
  final PraiseSong song;

  @override
  String get displayTitle => song.displayTitle;

  @override
  String get previewText =>
      song.pages.isEmpty ? '' : song.pages.first.replaceAll('\n', ' ');
}

class BibleStagingItem extends StagingItem {
  BibleStagingItem({
    required this.reference,
    required this.text,
    this.subText = '',
  });

  final String reference;
  final String text;

  /// 보조 역본 본문. 담을 때 확정되어 스냅샷처럼 남는다 (곡 가사와 같은 방식).
  final String subText;

  @override
  String get displayTitle => reference;

  @override
  String get previewText =>
      text.length > 60 ? '${text.substring(0, 60)}…' : text;
}

/// 외부 PPT를 페이지별 이미지로 구워 넣은 항목. 디자인 설정을 타지 않고 원본 그대로 표시된다.
class ImageStagingItem extends StagingItem {
  const ImageStagingItem({
    required this.sourceName,
    required this.imagePaths,
    this.sourcePath,
  });

  final String sourceName;
  final List<String> imagePaths;

  /// 구운 원본 PPT/PDF 파일 경로. 원본을 열어 고친 뒤 다시 굽는 데 쓴다.
  /// 원본의 일부 페이지만 담은 항목(나누기·복사)은 다시 구우면 페이지가 어긋나므로 null.
  final String? sourcePath;

  @override
  String get displayTitle => '[PPT] $sourceName';

  @override
  String get previewText => '${imagePaths.length}장';
}

/// 빈 페이지. [media] 가 있으면 동영상·음악·유튜브 페이지다 — 발표 창이 이 페이지
/// 위에 미디어를 띄운다(음악은 소리만이라 문구·배경이 그대로 보인다).
class BlankStagingItem extends StagingItem {
  const BlankStagingItem({
    this.mainText = '',
    this.englishText = '',
    this.media,
  });

  final String mainText;
  final String englishText;
  final SlideMedia? media;

  @override
  String get displayTitle => media?.label ?? '[ 빈 페이지 ]';

  @override
  String get previewText => mainText.replaceAll('\n', ' ');
}
