import '../data/obs_overlay_store.dart';

/// OBS 자막이 알아야 할 지금 페이지의 모양. 발표 화면 쪽 `_SlideInfo` 에서 필요한 칸만 옮긴 것 —
/// 코드·메모·송폼·로컬 경로는 처음부터 들어오지 않는다.
class ObsSlide {
  const ObsSlide({
    this.mainText = '',
    this.subText = '',
    this.extraText = '',
    this.title,
    this.isBible = false,
    this.isSermon = false,
    this.hasImage = false,
    this.hasMedia = false,
  });

  final String mainText;
  final String subText;
  final String extraText;
  final String? title;
  final bool isBible;
  final bool isSermon;

  /// PPT 그림·편집 페이지(구운 PNG). 1단계는 자막을 내지 않는다.
  final bool hasImage;

  /// 동영상·음악·유튜브 페이지.
  final bool hasMedia;
}

/// 자막이 안 보이는 까닭. 미리보기(`&preview=1`)·설정 창 상태 글에만 쓴다.
enum ObsHideReason {
  none,
  beforePresent,
  blackout,
  hidden,
  image,
  media,
  empty,
  sermonOff,
}

String obsHideLabel(ObsHideReason reason) => switch (reason) {
  ObsHideReason.none => '',
  ObsHideReason.beforePresent => '발표 전',
  ObsHideReason.blackout => '블랙아웃',
  ObsHideReason.hidden => 'OBS 자막 숨김',
  ObsHideReason.image => '그림 페이지 — OBS 에는 안 보임',
  ObsHideReason.media => '동영상·음악 페이지',
  ObsHideReason.empty => '빈 페이지',
  ObsHideReason.sermonOff => '설교 제목 페이지(내보내기 꺼짐)',
};

/// OBS 페이지에 보낼 자막 한 장. [show] 가 false 면 페이지는 완전 투명이다.
class ObsCaption {
  const ObsCaption({
    required this.show,
    this.reason = ObsHideReason.none,
    this.kind = '',
    this.heading = '',
    this.main = '',
    this.sub = '',
    this.extra = '',
  });

  const ObsCaption.hidden(this.reason)
    : show = false,
      kind = '',
      heading = '',
      main = '',
      sub = '',
      extra = '';

  final bool show;
  final ObsHideReason reason;

  /// 'song' | 'bible' | 'sermon' | 'text'.
  final String kind;

  /// 성경 참조 또는 곡 제목(켜 둔 경우). '' = 없음.
  final String heading;
  final String main;
  final String sub;
  final String extra;

  Map<String, dynamic> toJson() => {
    'show': show,
    'reason': obsHideLabel(reason),
    'kind': kind,
    'heading': heading,
    'main': main,
    'sub': sub,
    'extra': extra,
  };
}

/// 지금 페이지 → OBS 자막. 관객 화면을 따라간다:
/// 발표 전·블랙아웃·잠시 숨김이면 투명, 그림·미디어·빈 페이지·자동 여백도 투명.
/// 보조·추가 보조·참조·곡 제목은 OBS 설정의 스위치로 따로 켜고 끈다(관객 디자인과 무관).
/// 설교 제목 페이지의 부제는 번역이 아니라 내용이라 '보조' 스위치와 상관없이 싣는다.
ObsCaption obsCaptionFor({
  required ObsSlide? slide,
  required bool presenting,
  required bool blackout,
  required bool hidden,
  required ObsOverlayConfig config,
}) {
  if (!presenting) return const ObsCaption.hidden(ObsHideReason.beforePresent);
  if (hidden) return const ObsCaption.hidden(ObsHideReason.hidden);
  if (blackout) return const ObsCaption.hidden(ObsHideReason.blackout);
  if (slide == null) return const ObsCaption.hidden(ObsHideReason.empty);
  if (slide.hasImage) return const ObsCaption.hidden(ObsHideReason.image);
  if (slide.hasMedia) return const ObsCaption.hidden(ObsHideReason.media);

  final main = _clean(slide.mainText);
  if (slide.isSermon) {
    if (!config.showSermon) {
      return const ObsCaption.hidden(ObsHideReason.sermonOff);
    }
    final sub = _clean(slide.subText);
    if (main.isEmpty && sub.isEmpty) {
      return const ObsCaption.hidden(ObsHideReason.empty);
    }
    return ObsCaption(show: true, kind: 'sermon', main: main, sub: sub);
  }

  final sub = config.showSub ? _clean(slide.subText) : '';
  final extra = config.showExtra ? _clean(slide.extraText) : '';
  if (main.isEmpty && sub.isEmpty && extra.isEmpty) {
    return const ObsCaption.hidden(ObsHideReason.empty);
  }
  final title = (slide.title ?? '').trim();
  final kind = slide.isBible
      ? 'bible'
      : title.isEmpty
      ? 'text'
      : 'song';
  final heading = switch (kind) {
    'bible' when config.showReference => title,
    'song' when config.showSongTitle => title,
    _ => '',
  };
  return ObsCaption(
    show: true,
    kind: kind,
    heading: heading,
    main: main,
    sub: sub,
    extra: extra,
  );
}

// 줄 끝 공백·앞뒤 빈 줄만 걷어 낸다. 줄은 관객 화면 페이지 그대로 둔다.
String _clean(String text) => text
    .replaceAll('\r\n', '\n')
    .split('\n')
    .map((line) => line.trimRight())
    .join('\n')
    .trim();
