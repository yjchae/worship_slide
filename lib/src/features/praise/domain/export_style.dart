import 'package:flutter/material.dart';

final RegExp _hexColorPattern = RegExp(r'^[0-9A-F]{6}$');

String colorToHex(Color color) =>
    '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}';

Color? tryParseHexColor(String? value) {
  if (value == null) return null;
  final normalized = value.trim().replaceFirst('#', '').toUpperCase();
  if (!_hexColorPattern.hasMatch(normalized)) return null;
  return Color(int.parse('FF$normalized', radix: 16));
}

Color parseHexColor(String? value, Color fallback) {
  return tryParseHexColor(value) ?? fallback;
}

enum VerticalTextPosition {
  top('상단'),
  middle('중단'),
  bottom('하단');

  const VerticalTextPosition(this.label);
  final String label;
}

/// 상단/중단/하단 기준선에서 위아래로 더 밀어 주는 미세 조정 값(인치).
/// 양수면 아래로, 음수면 위로 올라간다. 0이면 기준선 그대로.
/// 예전 "본문 상단 여백"(`text_box_top`)을 대체한다 — 상단 여백은 상자 높이까지
/// 같이 바꿔서 기준마다 효과가 달랐고(하단 기준에서는 아예 효과가 없었다),
/// 낼 수 있는 위치는 모두 이 값의 범위 안에 들어온다.
const double kMinTextOffsetY = -2.0;
const double kMaxTextOffsetY = 2.0;

/// 미세 조정 슬라이더 한 칸(인치). UI 눈금과 +/- 버튼이 같은 값을 쓴다.
const double kTextOffsetYStep = 0.05;

double clampTextOffsetY(double value) {
  if (value.isNaN) return 0;
  return value.clamp(kMinTextOffsetY, kMaxTextOffsetY).toDouble();
}

/// 예전 "본문 상단 여백"의 기본값. 이 값이면 위치를 건드린 적 없다는 뜻이다.
const double kLegacyDefaultTopMargin = 0.6;

/// 없어진 "본문 상단 여백"(`text_box_top`)을 세로 미세 조정 값으로 옮긴다.
///
/// 상단 여백은 상자의 위쪽만 끌어내려 높이까지 같이 줄이던 값이라 기준선마다
/// 효과가 달랐다. 상자 아래쪽은 항상 6.0인치에 붙어 있었기 때문에
/// - 상단 기준: 여백만큼 그대로 내려갔고
/// - 중단 기준: 가운데가 여백의 **절반**만 내려갔고
/// - 하단 기준: 아무 효과가 없었다.
///
/// 예전 설정 파일을 열었을 때 글자가 튀지 않도록 기준선별로 같은 위치가 나오는
/// 미세 조정 값으로 환산해 [savedOffset] 에 더한다. 여백 키가 없으면 그대로 둔다.
double migrateLegacyTopMargin({
  required num? savedTopMargin,
  required double savedOffset,
  required VerticalTextPosition position,
}) {
  if (savedTopMargin == null) return clampTextOffsetY(savedOffset);
  final shift = savedTopMargin.toDouble() - kLegacyDefaultTopMargin;
  final converted = switch (position) {
    VerticalTextPosition.top => shift,
    VerticalTextPosition.middle => shift / 2,
    VerticalTextPosition.bottom => 0.0,
  };
  return clampTextOffsetY(savedOffset + converted);
}

enum HorizontalPosition {
  left('좌측'),
  center('중앙'),
  right('우측');

  const HorizontalPosition(this.label);
  final String label;
}

/// 보조·추가 보조 글자 크기 비율(본문 대비). 0.8 은 렌더러 네 곳의 예전 규칙(본문 × 0.8)과 같다.
const kDefaultSubFontRatio = 0.8;
const kDefaultExtraFontRatio = 0.7;
const kMinFontRatio = 0.3;
const kMaxFontRatio = 1.5;

double clampFontRatio(double value) =>
    value.clamp(kMinFontRatio, kMaxFontRatio).toDouble();

/// 저장된 비율을 읽는다. 없거나 숫자가 아니면 [fallback].
double parseFontRatio(Object? value, double fallback) =>
    value is num ? clampFontRatio(value.toDouble()) : fallback;

class ExportStyle {
  const ExportStyle({
    required this.fontSize,
    required this.bibleFontSize,
    required this.backgroundColor,
    required this.textColor,
    required this.bibleTextColor,
    required this.textPosition,
    required this.bibleTextPosition,
    this.textOffsetY = 0,
    this.bibleTextOffsetY = 0,
    this.titleOffsetY = 0,
    this.bibleTitleOffsetY = 0,
    required this.lyricsTextAlign,
    required this.bibleTextAlign,
    required this.includeEnglishLyrics,
    required this.englishTextColor,
    required this.showSongTitle,
    required this.showBibleTitle,
    required this.titleFontSize,
    required this.bibleTitleFontSize,
    required this.titleTextColor,
    required this.bibleTitleTextColor,
    required this.titleHorizontalPosition,
    required this.titleVerticalPosition,
    required this.bibleTitleHorizontalPosition,
    required this.bibleTitleVerticalPosition,
    this.fontFamily = 'Pretendard',
    this.backgroundImagePath,
    this.subLanguage = '영어',
    this.bibleSubVersion = '',
    this.englishFontSize,
    this.mediaFadeIn = 1.0,
    this.mediaFadeOut = 2.0,
    this.extraLanguage = '',
    this.bibleExtraVersion = '',
    this.includeExtraLyrics = true,
    this.extraTextColor = const Color(0xFF80DEEA),
    this.subFontRatio = kDefaultSubFontRatio,
    this.extraFontRatio = kDefaultExtraFontRatio,
    this.bibleSubFontRatio = kDefaultSubFontRatio,
    this.bibleExtraFontRatio = kDefaultExtraFontRatio,
  });

  final double fontSize;
  final double bibleFontSize;
  final Color backgroundColor;
  final Color textColor;
  final Color bibleTextColor;
  final VerticalTextPosition textPosition;
  final VerticalTextPosition bibleTextPosition;

  /// 가사/성경 본문 세로 미세 조정 (인치, + = 아래로)
  final double textOffsetY;
  final double bibleTextOffsetY;

  /// 본문 아래 보조 줄(영어 가사·성경 보조 역본·설교 부제) 글자 크기.
  /// null 이면 본문의 0.8 배(렌더러 네 곳의 원래 규칙). 설교 제목 페이지만 따로 정한다.
  final double? englishFontSize;
  double get effectiveEnglishFontSize => englishFontSize ?? fontSize * 0.8;

  /// 곡/성경 제목 세로 미세 조정 (인치, + = 아래로)
  final double titleOffsetY;
  final double bibleTitleOffsetY;
  final HorizontalPosition lyricsTextAlign;
  final HorizontalPosition bibleTextAlign;
  final bool includeEnglishLyrics;
  final Color englishTextColor;
  final bool showSongTitle;
  final bool showBibleTitle;
  final double titleFontSize;
  final double bibleTitleFontSize;
  final Color titleTextColor;
  final Color bibleTitleTextColor;
  final HorizontalPosition titleHorizontalPosition;
  final VerticalTextPosition titleVerticalPosition;
  final HorizontalPosition bibleTitleHorizontalPosition;
  final VerticalTextPosition bibleTitleVerticalPosition;
  final String fontFamily;
  final String? backgroundImagePath;

  /// 찬양 보조 가사로 쓸 언어. '영어'가 기본(= praise_songs.english_lyrics).
  /// 렌더러는 이 값을 보지 않는다 — 콘티에 담을 때 이미 해당 언어 가사가
  /// english_text 슬롯에 들어가 있다.
  final String subLanguage;

  /// 성경 본문 아래 함께 띄울 역본. 빈 문자열이면 표시하지 않는다.
  final String bibleSubVersion;

  /// PPT 안 동영상의 페이드 시간(초), 새 동영상·음악 페이지의 시작값.
  /// 렌더러는 읽지 않는다 — 페이지마다 `media` 에 담겨 간다.
  final double mediaFadeIn;
  final double mediaFadeOut;

  // ── 추가 보조 언어(관객 화면 세 번째 줄) ──────────────────────────────

  /// 찬양 추가 보조 가사로 쓸 언어. 빈 문자열이면 없음. [subLanguage] 와 같은 방식으로
  /// 담을 때 이미 extra 칸에 들어가 있으므로 렌더러는 이 값을 보지 않는다.
  final String extraLanguage;

  /// 성경 본문 아래 세 번째로 띄울 역본. 빈 문자열이면 없음.
  final String bibleExtraVersion;

  /// 추가 보조 줄 표시. 찬양·성경이 같이 쓴다([includeEnglishLyrics] 와 같은 방식).
  final bool includeExtraLyrics;
  final Color extraTextColor;

  /// 보조·추가 보조 글자 크기 = 본문 크기 × 비율. 찬양과 성경이 따로다.
  /// 렌더러는 비율이 아니라 [subFontSizeFor]·[extraFontSizeFor] 로 계산한 pt 를 받는다.
  final double subFontRatio;
  final double extraFontRatio;
  final double bibleSubFontRatio;
  final double bibleExtraFontRatio;

  /// 보조 줄 글자 크기(pt). 설교 부제처럼 [englishFontSize] 를 정했으면 그 값이 이긴다.
  double subFontSizeFor({required bool isBible}) =>
      englishFontSize ??
      (isBible ? bibleFontSize * bibleSubFontRatio : fontSize * subFontRatio);

  /// 추가 보조 줄 글자 크기(pt).
  double extraFontSizeFor({required bool isBible}) =>
      isBible ? bibleFontSize * bibleExtraFontRatio : fontSize * extraFontRatio;

  Map<String, dynamic> toJson() {
    return {
      'font_size': fontSize,
      'bible_font_size': bibleFontSize,
      'background_color': colorToHex(backgroundColor),
      'text_color': colorToHex(textColor),
      'bible_text_color': colorToHex(bibleTextColor),
      'text_position': textPosition.name,
      'bible_text_position': bibleTextPosition.name,
      'text_offset_y': textOffsetY,
      'bible_text_offset_y': bibleTextOffsetY,
      'title_offset_y': titleOffsetY,
      'bible_title_offset_y': bibleTitleOffsetY,
      'lyrics_text_align': lyricsTextAlign.name,
      'bible_text_align': bibleTextAlign.name,
      'include_english_lyrics': includeEnglishLyrics,
      'english_text_color': colorToHex(englishTextColor),
      'show_song_title': showSongTitle,
      'show_bible_title': showBibleTitle,
      'title_font_size': titleFontSize,
      'bible_title_font_size': bibleTitleFontSize,
      'title_text_color': colorToHex(titleTextColor),
      'bible_title_text_color': colorToHex(bibleTitleTextColor),
      'title_horizontal_position': titleHorizontalPosition.name,
      'title_vertical_position': titleVerticalPosition.name,
      'bible_title_horizontal_position': bibleTitleHorizontalPosition.name,
      'bible_title_vertical_position': bibleTitleVerticalPosition.name,
      'font_family': fontFamily,
      'background_image_path': backgroundImagePath,
      'sub_language': subLanguage,
      'bible_sub_version': bibleSubVersion,
      if (englishFontSize != null) 'english_font_size': englishFontSize,
      'media_fade_in': mediaFadeIn,
      'media_fade_out': mediaFadeOut,
      'extra_language': extraLanguage,
      'bible_extra_version': bibleExtraVersion,
      'include_extra_lyrics': includeExtraLyrics,
      'extra_text_color': colorToHex(extraTextColor),
      'sub_font_ratio': subFontRatio,
      'extra_font_ratio': extraFontRatio,
      'bible_sub_font_ratio': bibleSubFontRatio,
      'bible_extra_font_ratio': bibleExtraFontRatio,
    };
  }

  factory ExportStyle.fromJson(Map<String, dynamic> json) {
    VerticalTextPosition parseVertical(String? name) =>
        VerticalTextPosition.values.firstWhere(
          (e) => e.name == name,
          orElse: () => VerticalTextPosition.middle,
        );
    HorizontalPosition parseHorizontal(String? name) =>
        HorizontalPosition.values.firstWhere(
          (e) => e.name == name,
          orElse: () => HorizontalPosition.center,
        );
    return ExportStyle(
      fontSize: (json['font_size'] as num).toDouble(),
      bibleFontSize: (json['bible_font_size'] as num).toDouble(),
      backgroundColor: parseHexColor(
        json['background_color'] as String?,
        const Color(0xFF1B1B1B),
      ),
      textColor: parseHexColor(json['text_color'] as String?, Colors.white),
      bibleTextColor: parseHexColor(
        json['bible_text_color'] as String?,
        Colors.white,
      ),
      textPosition: parseVertical(json['text_position'] as String?),
      bibleTextPosition: parseVertical(json['bible_text_position'] as String?),
      textOffsetY: clampTextOffsetY(
        (json['text_offset_y'] as num?)?.toDouble() ?? 0,
      ),
      bibleTextOffsetY: clampTextOffsetY(
        (json['bible_text_offset_y'] as num?)?.toDouble() ?? 0,
      ),
      titleOffsetY: clampTextOffsetY(
        (json['title_offset_y'] as num?)?.toDouble() ?? 0,
      ),
      bibleTitleOffsetY: clampTextOffsetY(
        (json['bible_title_offset_y'] as num?)?.toDouble() ?? 0,
      ),
      lyricsTextAlign: parseHorizontal(json['lyrics_text_align'] as String?),
      bibleTextAlign: parseHorizontal(json['bible_text_align'] as String?),
      includeEnglishLyrics: (json['include_english_lyrics'] as bool?) ?? true,
      englishTextColor: parseHexColor(
        json['english_text_color'] as String?,
        const Color(0xFFFFF176),
      ),
      showSongTitle: (json['show_song_title'] as bool?) ?? false,
      showBibleTitle: (json['show_bible_title'] as bool?) ?? false,
      titleFontSize: (json['title_font_size'] as num?)?.toDouble() ?? 14.0,
      bibleTitleFontSize:
          (json['bible_title_font_size'] as num?)?.toDouble() ?? 14.0,
      titleTextColor: parseHexColor(
        json['title_text_color'] as String?,
        const Color(0xB3FFFFFF),
      ),
      bibleTitleTextColor: parseHexColor(
        json['bible_title_text_color'] as String?,
        const Color(0xB3FFFFFF),
      ),
      titleHorizontalPosition: parseHorizontal(
        json['title_horizontal_position'] as String?,
      ),
      titleVerticalPosition: parseVertical(
        json['title_vertical_position'] as String?,
      ),
      bibleTitleHorizontalPosition: parseHorizontal(
        json['bible_title_horizontal_position'] as String?,
      ),
      bibleTitleVerticalPosition: parseVertical(
        json['bible_title_vertical_position'] as String?,
      ),
      fontFamily: (json['font_family'] as String?) ?? 'Pretendard',
      backgroundImagePath: json['background_image_path'] as String?,
      subLanguage: (json['sub_language'] as String?) ?? '영어',
      bibleSubVersion: (json['bible_sub_version'] as String?) ?? '',
      englishFontSize: (json['english_font_size'] as num?)?.toDouble(),
      mediaFadeIn: (json['media_fade_in'] as num?)?.toDouble() ?? 1.0,
      mediaFadeOut: (json['media_fade_out'] as num?)?.toDouble() ?? 2.0,
      extraLanguage: (json['extra_language'] as String?) ?? '',
      bibleExtraVersion: (json['bible_extra_version'] as String?) ?? '',
      includeExtraLyrics: (json['include_extra_lyrics'] as bool?) ?? true,
      extraTextColor: parseHexColor(
        json['extra_text_color'] as String?,
        const Color(0xFF80DEEA),
      ),
      subFontRatio: parseFontRatio(
        json['sub_font_ratio'],
        kDefaultSubFontRatio,
      ),
      extraFontRatio: parseFontRatio(
        json['extra_font_ratio'],
        kDefaultExtraFontRatio,
      ),
      bibleSubFontRatio: parseFontRatio(
        json['bible_sub_font_ratio'],
        kDefaultSubFontRatio,
      ),
      bibleExtraFontRatio: parseFontRatio(
        json['bible_extra_font_ratio'],
        kDefaultExtraFontRatio,
      ),
    );
  }

  ExportStyle copyWith({
    double? fontSize,
    double? bibleFontSize,
    Color? backgroundColor,
    Color? textColor,
    Color? bibleTextColor,
    VerticalTextPosition? textPosition,
    VerticalTextPosition? bibleTextPosition,
    double? textOffsetY,
    double? bibleTextOffsetY,
    double? titleOffsetY,
    double? bibleTitleOffsetY,
    HorizontalPosition? lyricsTextAlign,
    HorizontalPosition? bibleTextAlign,
    bool? includeEnglishLyrics,
    Color? englishTextColor,
    bool? showSongTitle,
    bool? showBibleTitle,
    double? titleFontSize,
    double? bibleTitleFontSize,
    Color? titleTextColor,
    Color? bibleTitleTextColor,
    HorizontalPosition? titleHorizontalPosition,
    VerticalTextPosition? titleVerticalPosition,
    HorizontalPosition? bibleTitleHorizontalPosition,
    VerticalTextPosition? bibleTitleVerticalPosition,
    String? fontFamily,
    Object? backgroundImagePath = _sentinel,
    String? subLanguage,
    String? bibleSubVersion,
    Object? englishFontSize = _sentinel,
    double? mediaFadeIn,
    double? mediaFadeOut,
    String? extraLanguage,
    String? bibleExtraVersion,
    bool? includeExtraLyrics,
    Color? extraTextColor,
    double? subFontRatio,
    double? extraFontRatio,
    double? bibleSubFontRatio,
    double? bibleExtraFontRatio,
  }) {
    return ExportStyle(
      fontSize: fontSize ?? this.fontSize,
      bibleFontSize: bibleFontSize ?? this.bibleFontSize,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      textColor: textColor ?? this.textColor,
      bibleTextColor: bibleTextColor ?? this.bibleTextColor,
      textPosition: textPosition ?? this.textPosition,
      bibleTextPosition: bibleTextPosition ?? this.bibleTextPosition,
      textOffsetY: clampTextOffsetY(textOffsetY ?? this.textOffsetY),
      bibleTextOffsetY: clampTextOffsetY(
        bibleTextOffsetY ?? this.bibleTextOffsetY,
      ),
      titleOffsetY: clampTextOffsetY(titleOffsetY ?? this.titleOffsetY),
      bibleTitleOffsetY: clampTextOffsetY(
        bibleTitleOffsetY ?? this.bibleTitleOffsetY,
      ),
      lyricsTextAlign: lyricsTextAlign ?? this.lyricsTextAlign,
      bibleTextAlign: bibleTextAlign ?? this.bibleTextAlign,
      includeEnglishLyrics: includeEnglishLyrics ?? this.includeEnglishLyrics,
      englishTextColor: englishTextColor ?? this.englishTextColor,
      showSongTitle: showSongTitle ?? this.showSongTitle,
      showBibleTitle: showBibleTitle ?? this.showBibleTitle,
      titleFontSize: titleFontSize ?? this.titleFontSize,
      bibleTitleFontSize: bibleTitleFontSize ?? this.bibleTitleFontSize,
      titleTextColor: titleTextColor ?? this.titleTextColor,
      bibleTitleTextColor: bibleTitleTextColor ?? this.bibleTitleTextColor,
      titleHorizontalPosition:
          titleHorizontalPosition ?? this.titleHorizontalPosition,
      titleVerticalPosition:
          titleVerticalPosition ?? this.titleVerticalPosition,
      bibleTitleHorizontalPosition:
          bibleTitleHorizontalPosition ?? this.bibleTitleHorizontalPosition,
      bibleTitleVerticalPosition:
          bibleTitleVerticalPosition ?? this.bibleTitleVerticalPosition,
      fontFamily: fontFamily ?? this.fontFamily,
      backgroundImagePath: identical(backgroundImagePath, _sentinel)
          ? this.backgroundImagePath
          : backgroundImagePath as String?,
      subLanguage: subLanguage ?? this.subLanguage,
      bibleSubVersion: bibleSubVersion ?? this.bibleSubVersion,
      englishFontSize: identical(englishFontSize, _sentinel)
          ? this.englishFontSize
          : (englishFontSize as num?)?.toDouble(),
      mediaFadeIn: mediaFadeIn ?? this.mediaFadeIn,
      mediaFadeOut: mediaFadeOut ?? this.mediaFadeOut,
      extraLanguage: extraLanguage ?? this.extraLanguage,
      bibleExtraVersion: bibleExtraVersion ?? this.bibleExtraVersion,
      includeExtraLyrics: includeExtraLyrics ?? this.includeExtraLyrics,
      extraTextColor: extraTextColor ?? this.extraTextColor,
      subFontRatio: clampFontRatio(subFontRatio ?? this.subFontRatio),
      extraFontRatio: clampFontRatio(extraFontRatio ?? this.extraFontRatio),
      bibleSubFontRatio: clampFontRatio(
        bibleSubFontRatio ?? this.bibleSubFontRatio,
      ),
      bibleExtraFontRatio: clampFontRatio(
        bibleExtraFontRatio ?? this.bibleExtraFontRatio,
      ),
    );
  }

  static const Object _sentinel = Object();
}
