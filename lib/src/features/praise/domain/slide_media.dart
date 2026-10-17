import 'dart:convert';

enum MediaKind { video, audio, youtube }

/// 발표 창 위 미디어 레이어에서 재생할 것 하나. 동영상·음악 페이지(빈 페이지 + 이것)와
/// PPT 안에 든 동영상(페이지 이미지 옆 `.media.json`)이 같은 모델을 쓴다.
class SlideMedia {
  const SlideMedia({
    required this.kind,
    required this.source,
    this.fadeIn = 1.0,
    this.fadeOut = 2.0,
    this.rect,
  });

  final MediaKind kind;

  /// 파일 경로(video·audio) 또는 유튜브 주소.
  final String source;

  /// 페이드 시간(초). 시작할 때 0→1, 페이지를 떠나거나 끝나기 전에 1→0.
  final double fadeIn;
  final double fadeOut;

  /// 슬라이드 안 동영상 자리(0~1, [x, y, w, h]). null = 화면 전체.
  /// PPT 동영상만 쓴다 — 미리 구운 페이지 이미지(포스터) 위 제자리에서 재생한다.
  final List<double>? rect;

  static const double maxFade = 10;

  String get label => switch (kind) {
    MediaKind.video => '[동영상] ${_baseName(source)}',
    MediaKind.audio => '[음악] ${_baseName(source)}',
    MediaKind.youtube => '[유튜브] ${youtubeId(source) ?? source}',
  };

  /// 발표 창이 "같은 미디어"인지 가리는 값. 같으면 페이지가 바뀌어도(애니메이션 단계로
  /// 복제된 PPT 페이지, 디자인 변경으로 다시 보낸 페이지) 끊지 않고 이어서 재생한다.
  String get key => '${kind.name}|$source|${rect?.join(',') ?? ''}';

  SlideMedia copyWith({double? fadeIn, double? fadeOut}) => SlideMedia(
    kind: kind,
    source: source,
    fadeIn: fadeIn ?? this.fadeIn,
    fadeOut: fadeOut ?? this.fadeOut,
    rect: rect,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'source': source,
    'fade_in': fadeIn,
    'fade_out': fadeOut,
    if (rect != null) 'rect': rect,
  };

  /// 저장된 값이 깨졌으면 null — 콘티 불러오기가 미디어 하나 때문에 죽지 않게.
  static SlideMedia? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = MediaKind.values
        .where((k) => k.name == json['kind'])
        .firstOrNull;
    final source = json['source'];
    if (kind == null || source is! String || source.isEmpty) return null;
    final rect = json['rect'];
    return SlideMedia(
      kind: kind,
      source: source,
      fadeIn: _fade(json['fade_in'], 1.0),
      fadeOut: _fade(json['fade_out'], 2.0),
      rect: rect is List && rect.length == 4 && rect.every((v) => v is num)
          ? [for (final v in rect) (v as num).toDouble()]
          : null,
    );
  }

  static String? encode(SlideMedia? media) =>
      media == null ? null : jsonEncode(media.toJson());

  static SlideMedia? decode(Object? stored) {
    if (stored is! String || stored.isEmpty) return null;
    try {
      return fromJson(jsonDecode(stored));
    } on FormatException {
      return null;
    }
  }

  static double _fade(Object? v, double fallback) =>
      v is num ? v.toDouble().clamp(0, maxFade).toDouble() : fallback;

  static String _baseName(String path) =>
      path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).lastOrNull ??
      path;
}

/// 유튜브 주소(watch·youtu.be·shorts·embed·live)에서 영상 id 를 꺼낸다. 아니면 null.
String? youtubeId(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return null;
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^(www\.|m\.)'), '');
  String? id;
  if (host == 'youtu.be') {
    id = uri.pathSegments.firstOrNull;
  } else if (host == 'youtube.com' ||
      host == 'music.youtube.com' ||
      host == 'youtube-nocookie.com') {
    final segs = uri.pathSegments;
    if (segs.firstOrNull == 'watch') {
      id = uri.queryParameters['v'];
    } else if (segs.length >= 2 &&
        const {'embed', 'shorts', 'live', 'v'}.contains(segs.first)) {
      id = segs[1];
    }
  }
  return id != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id) ? id : null;
}

/// 유튜브 주소의 시작 위치(`t=90`, `t=1m30s`, `start=90`)를 초로. 없으면 0.
int youtubeStartSeconds(String url) {
  final q = Uri.tryParse(url.trim())?.queryParameters ?? const {};
  final raw = q['t'] ?? q['start'];
  if (raw == null) return 0;
  final plain = int.tryParse(raw.replaceFirst(RegExp(r's$'), ''));
  if (plain != null) return plain;
  final m = RegExp(r'^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$').firstMatch(raw);
  if (m == null) return 0;
  int part(int i) => int.tryParse(m.group(i) ?? '') ?? 0;
  return part(1) * 3600 + part(2) * 60 + part(3);
}

/// 관객 화면 미디어의 재생 위치(초). 발표 창 미디어 레이어가 보내는 `{"t","d","p"}` JSON 문자열.
class MediaPlayback {
  const MediaPlayback({
    required this.position,
    required this.duration,
    required this.playing,
  });

  final double position;
  final double duration; // 0 = 모름(유튜브 생방송, 불러오는 중)
  final bool playing;

  static MediaPlayback? tryParse(Object? raw) {
    if (raw is! String) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      double num0(Object? v) =>
          v is num && v.isFinite && v >= 0 ? v.toDouble() : 0;
      return MediaPlayback(
        position: num0(json['t']),
        duration: num0(json['d']),
        playing: json['p'] == true,
      );
    } on FormatException {
      return null;
    }
  }
}
