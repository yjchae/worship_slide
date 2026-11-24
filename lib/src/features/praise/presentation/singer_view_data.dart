import '../domain/chord_lyrics.dart';

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
    this.chordLines,
    this.keyLabel = '',
    this.formLabels = const [],
  });

  final String mainText;

  /// 보조 언어 가사·보조 역본. 디자인에서 보조 언어를 꺼 두면 빈 문자열로 넘긴다.
  final String englishText;
  final String? title;

  /// 외부 PPT 에서 구운 페이지 이미지. 있으면 글자 대신 이 이미지를 보여 준다.
  final String? imagePath;

  /// 원본 줄마다 코드(조 바꾸기를 적용한 뒤). JSON `chord_lines` — 렌더러는 이것만 읽고 코드 글을 풀지 않는다.
  /// null·빈 목록이면 키를 뺀다. 네이티브 싱어 창은 '싱어 코드'가 꺼져 있으면 아예 안 실린다.
  final List<ChordLine>? chordLines;

  /// 조를 바꿨을 때 머리줄 배지(`A (원래 G, +2)`). 그대로면 ''.
  final String keyLabel;

  /// 송폼 라벨 약어(`['V2', 'PC']`, `SectionLabel.abbr`). 없으면 빈 목록이고 JSON 키 `form` 을 뺀다.
  /// 싱어 화면 전용 — 관객 화면·통역(B)·PPTX 로는 가지 않는다. 스위치 없이 늘 싣는다.
  final List<String> formLabels;

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
    if (chordLines != null && chordLines!.isNotEmpty)
      'chord_lines': [for (final l in chordLines!) l.toJson()],
    if (keyLabel.isNotEmpty) 'key_label': keyLabel,
    if (formLabels.isNotEmpty) 'form': formLabels,
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

/// 휴대폰 발표자 모드 '모든 페이지'에 쓸 한 장의 재료. 앱(`_SlideInfo`)에서 채워 넘긴다.
typedef PhonePageSource = ({
  int stagingUid,
  int pageIndexInItem,
  bool isAutoSpacer,
  String mainText,
  String? title,
  String? imagePath,
});

/// 발표자 모드 페이지 목록(`SingerWebServer.update` 의 `pages`). 원본 가사만 싣는다.
/// `id` = 앱 슬라이드 키(`uid:페이지:자동여백`) — 휴대폰은 이 값으로 `goto` 한다.
/// `image` 는 로컬 경로 그대로다 — 서버가 밖으로 내보내기 전에 주소로 바꾼다.
List<Map<String, Object?>> phonePageList(Iterable<PhonePageSource> slides) => [
  for (final s in slides)
    {
      'id': '${s.stagingUid}:${s.pageIndexInItem}:${s.isAutoSpacer}',
      'title': s.title ?? '',
      'text': s.mainText,
      'image': (s.imagePath?.isEmpty ?? true) ? null : s.imagePath,
      'blank': (s.imagePath?.isEmpty ?? true) && s.mainText.trim().isEmpty,
      'spacer': s.isAutoSpacer,
      'first': s.pageIndexInItem == 0 && !s.isAutoSpacer,
    },
];
