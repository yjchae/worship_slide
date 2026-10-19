/// 싱어용 화면(발표 창과 별도인 두 번째 네이티브 창)에 보낼 한 페이지.
///
/// 싱어는 디자인(배경·폰트·위치)이 아니라 **가사만** 크게 보면 되므로 스타일은 싣지 않는다.
/// 네이티브 창은 이 값만 보고 "현재 페이지 + 다음 페이지"를 읽기 쉬운 고정 레이아웃으로 그린다.
class SingerPage {
  const SingerPage({
    required this.mainText,
    this.englishText = '',
    this.title,
    this.imagePath,
  });

  final String mainText;

  /// 보조 언어 가사·보조 역본. 디자인에서 보조 언어를 꺼 두면 빈 문자열로 넘긴다.
  final String englishText;
  final String? title;

  /// 외부 PPT 에서 구운 페이지 이미지. 있으면 글자 대신 이 이미지를 보여 준다.
  final String? imagePath;

  bool get isBlank =>
      (imagePath == null || imagePath!.isEmpty) &&
      mainText.trim().isEmpty &&
      englishText.trim().isEmpty;

  Map<String, dynamic> toJson() => {
    'main_text': mainText,
    'english_text': englishText,
    'title': title ?? '',
    'image_path': imagePath ?? '',
    'is_blank': isBlank,
  };
}

class SingerViewData {
  const SingerViewData({
    required this.current,
    required this.next,
    required this.pageNumber,
    required this.totalPages,
    required this.isBlackout,
    this.clock,
  });

  final SingerPage current;

  /// 마지막 페이지면 null.
  final SingerPage? next;

  /// 1부터 센다.
  final int pageNumber;
  final int totalPages;

  /// 관객 화면이 꺼져 있는지. 싱어 화면은 가사를 계속 보여 주고 표시만 한다.
  final bool isBlackout;

  /// 시계·경과 시간([PresentationTimer.toSingerJson]). 받는 쪽은 받은 순간부터 자기 시계로
  /// 이어서 센다 — 매초 보내지 않는다. null 이면 표시하지 않는다.
  final Map<String, Object>? clock;

  Map<String, dynamic> toJson() => {
    'current': current.toJson(),
    'next': next?.toJson(),
    'page_number': pageNumber,
    'total_pages': totalPages,
    'blackout': isBlackout,
    'clock': clock,
  };
}
