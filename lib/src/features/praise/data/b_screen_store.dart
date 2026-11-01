import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';
import 'atomic_file.dart';
import 'screen_choice_store.dart';

/// 통역 화면(내부 이름 B)에서 슬라이드 칸이 놓이는 쪽.
enum BSide { top, bottom, left, right }

const defaultBSubtitleUrl = 'http://127.0.0.1:8000/display.html?net';
const defaultBShare = 0.65;
const minBShare = 0.4;
const maxBShare = 0.8;

/// 자막 주소가 저장해도 되는 꼴인지. 빈 값은 '자막 없이 슬라이드만'이라 맞다.
bool isValidBSubtitleUrl(String url) {
  final text = url.trim();
  if (text.isEmpty) return true;
  if (text.contains(RegExp(r'\s'))) return false;
  final uri = Uri.tryParse(text);
  return uri != null &&
      (uri.isScheme('http') || uri.isScheme('https')) &&
      uri.host.isNotEmpty;
}

/// A 렌더 폴더 하나에 이어 둔 외국어 PPT.
class BPptPair {
  const BPptPair({
    required this.bDir,
    required this.bName,
    required this.aCount,
    required this.bCount,
  });

  final String bDir;
  final String bName;

  /// 폴더 전체 장수(항목 장수가 아니다 — 나눈 항목도 원본 기준으로 비교한다).
  final int aCount;
  final int bCount;

  Map<String, dynamic> toJson() => {
    'b_dir': bDir,
    'b_name': bName,
    'a_count': aCount,
    'b_count': bCount,
  };

  static BPptPair? fromJson(Object? json) {
    if (json is! Map) return null;
    final bDir = json['b_dir'];
    if (bDir is! String) return null;
    return BPptPair(
      bDir: bDir,
      bName: json['b_name'] as String? ?? '',
      aCount: (json['a_count'] as num?)?.toInt() ?? 0,
      bCount: (json['b_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 통역 화면 설정 + 폴더 대응표 → Application Support/b_screen.json.
/// 대응표의 경로는 이 PC 에서만 뜻이 있다(`.wsconti`·클라우드로 옮기지 않는다).
class BScreenConfig {
  const BScreenConfig({
    this.screen,
    this.side = BSide.top,
    this.share = defaultBShare,
    this.subtitleUrl = defaultBSubtitleUrl,
    this.pairs = const {},
  });

  /// 자동이 없다. null = 아직 안 고름. 찾기는 [ScreenChoice.resolve].
  final ScreenChoice? screen;
  final BSide side;

  /// 슬라이드 몫(0.4~0.8). 위·아래면 높이, 왼쪽·오른쪽이면 폭의 비율.
  final double share;

  /// 빈 값이면 자막 없이 슬라이드만.
  final String subtitleUrl;

  /// A 렌더 폴더 → 외국어 PPT.
  final Map<String, BPptPair> pairs;

  /// 저장한 설정의 필드를 바꾼 사본. 모니터 선택 해제는 [clearScreen].
  BScreenConfig copyWith({
    ScreenChoice? screen,
    bool clearScreen = false,
    BSide? side,
    double? share,
    String? subtitleUrl,
    Map<String, BPptPair>? pairs,
  }) => BScreenConfig(
    screen: clearScreen ? null : screen ?? this.screen,
    side: side ?? this.side,
    share: share ?? this.share,
    subtitleUrl: subtitleUrl ?? this.subtitleUrl,
    pairs: pairs ?? this.pairs,
  );

  /// A 원본을 다시 구워 폴더가 바뀌었을 때. 빠뜨리면 B 가 조용히 A 로 돌아간다.
  BScreenConfig movePair(String oldDir, String newDir, int aCount) {
    final pair = pairs[oldDir];
    if (pair == null) return this;
    final moved = {...pairs}..remove(oldDir);
    moved[newDir] = BPptPair(
      bDir: pair.bDir,
      bName: pair.bName,
      aCount: aCount,
      bCount: pair.bCount,
    );
    return copyWith(pairs: moved);
  }

  /// [aDir] 의 연결을 끊는다. 다시 구울 때 남긴 옛 폴더 키(같은 `bDir`)도 같이 끊어서
  /// 나눈 항목·저장한 콘티가 끊은 PPT 를 내보내지 않게 한다.
  BScreenConfig unlinkPair(String aDir) {
    final bDir = pairs[aDir]?.bDir;
    return copyWith(
      pairs: {...pairs}..removeWhere((_, pair) => pair.bDir == bDir),
    );
  }

  /// [aDir] 에 [pair] 를 잇는다. 이미 이어져 있었으면 옛 폴더 키도 새 PPT 로 바꾼다.
  /// 옛 키의 `aCount` 는 그 폴더 기준이라 그대로 둔다.
  BScreenConfig linkPair(String aDir, BPptPair pair) {
    final oldBDir = pairs[aDir]?.bDir;
    return copyWith(
      pairs: {
        for (final MapEntry(:key, :value) in pairs.entries)
          key: value.bDir != oldBDir
              ? value
              : BPptPair(
                  bDir: pair.bDir,
                  bName: pair.bName,
                  aCount: value.aCount,
                  bCount: pair.bCount,
                ),
        aDir: pair,
      },
    );
  }

  /// `openB` 에 페이지 JSON·`screen` 과 함께 싣는 칸 정보. [width]·[height] 는 모니터 크기.
  Map<String, dynamic> layoutJson(int width, int height) {
    final url = subtitleUrl.trim();
    final rects = bSplitRects(width, height, side, share, url.isNotEmpty);
    return {
      'slide_rect': _rectJson(rects.slide),
      'sub_rect': rects.sub == null ? null : _rectJson(rects.sub!),
      'sub_url': url,
    };
  }

  static List<double> _rectJson(Rect r) => [r.left, r.top, r.width, r.height];

  Map<String, dynamic> toJson() => {
    'screen': screen?.toJson(),
    'side': side.name,
    'share': share,
    'subtitle_url': subtitleUrl,
    'pairs': pairs.map((key, value) => MapEntry(key, value.toJson())),
  };

  factory BScreenConfig.fromJson(Map<String, dynamic> json) {
    final pairs = <String, BPptPair>{};
    final raw = json['pairs'];
    if (raw is Map) {
      raw.forEach((key, value) {
        final pair = BPptPair.fromJson(value);
        if (key is String && pair != null) pairs[key] = pair;
      });
    }
    return BScreenConfig(
      screen: ScreenChoice.fromJson(json['screen']),
      side: BSide.values.asNameMap()[json['side']] ?? BSide.top,
      share: ((json['share'] as num?)?.toDouble() ?? defaultBShare).clamp(
        minBShare,
        maxBShare,
      ),
      subtitleUrl: json['subtitle_url'] as String? ?? defaultBSubtitleUrl,
      pairs: pairs,
    );
  }
}

class BScreenStore {
  Future<File> _file() async => File(
    p.join((await getApplicationSupportDirectory()).path, 'b_screen.json'),
  );

  Future<BScreenConfig> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const BScreenConfig();
      return BScreenConfig.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } catch (_) {
      return const BScreenConfig();
    }
  }

  Future<void> save(BScreenConfig config) async {
    try {
      await atomicWriteString(await _file(), jsonEncode(config.toJson()));
    } catch (error, stack) {
      await AppLogger.instance.error('b_screen.json 저장 실패', error, stack);
    }
  }
}

/// 모니터 [width]×[height] 를 나눈 칸. 값은 0~1 비율이고 위가 0 이다.
/// 슬라이드 칸은 늘 16:9 — 글자 크기·폭이 창 기준이라 비율이 다르면 가사 배치가 깨진다.
/// 자막 칸은 슬라이드가 안 쓰는 쪽 띠 전체. [hasSubtitle] 이 false 면 sub 는 null.
({Rect slide, Rect? sub}) bSplitRects(
  int width,
  int height,
  BSide side,
  double share,
  bool hasSubtitle,
) {
  final w = width.toDouble(), h = height.toDouble();
  final vertical = side == BSide.top || side == BSide.bottom;
  // 위·아래는 높이, 왼쪽·오른쪽은 폭에서 몫을 잡고 모니터를 넘지 않게 줄인다.
  final useShare = hasSubtitle ? share : 1.0;
  var slideW = vertical ? h * useShare * 16 / 9 : w * useShare;
  if (slideW > w) slideW = w;
  var slideH = slideW * 9 / 16;
  if (slideH > h) {
    slideH = h;
    slideW = h * 16 / 9;
  }
  final centerX = (w - slideW) / 2, centerY = (h - slideH) / 2;
  final (slideX, slideY) = !hasSubtitle
      ? (centerX, centerY)
      : switch (side) {
          BSide.top => (centerX, 0.0),
          BSide.bottom => (centerX, h - slideH),
          BSide.left => (0.0, centerY),
          BSide.right => (w - slideW, centerY),
        };
  final slide = Rect.fromLTWH(slideX / w, slideY / h, slideW / w, slideH / h);
  if (!hasSubtitle) return (slide: slide, sub: null);
  return (
    slide: slide,
    sub: switch (side) {
      BSide.top => Rect.fromLTRB(0, slide.bottom, 1, 1),
      BSide.bottom => Rect.fromLTRB(0, 0, 1, slide.top),
      BSide.left => Rect.fromLTRB(slide.right, 0, 1, 1),
      BSide.right => Rect.fromLTRB(0, 0, slide.left, 1),
    },
  );
}

/// 렌더가 만든 페이지 이미지 이름(`0007.png`).
final _renderedPageName = RegExp(r'^\d{4}\.png$');

/// 외국어 PPT 를 이을 수 있는 이미지인가. `.wsconti` 로 받은 이미지는 `0.png` 꼴이라
/// 쪽 번호가 파일 이름이 아니므로 잇지 못한다.
bool isRenderedPage(String path) =>
    _renderedPageName.hasMatch(p.basename(path));

/// A 페이지 이미지 → 통역 화면 이미지. 슬라이드 번호가 아니라 파일 이름으로 짝을 지어서
/// 지운 페이지·나누기·옮기기가 저절로 맞는다. 연결이 없거나 B 에 그 쪽이 없으면 A 그대로.
String? bImagePath(String? aPath, Map<String, BPptPair> pairs) {
  if (aPath == null) return null;
  final pair = pairs[p.dirname(aPath)];
  if (pair == null) return aPath;
  final path = p.join(pair.bDir, p.basename(aPath));
  return File(path).existsSync() ? path : aPath;
}

/// 렌더 폴더 전체 장수(대조 창·대응표용).
Future<int> countRenderedPages(String dir) async {
  var count = 0;
  await for (final entry in Directory(dir).list()) {
    if (entry is File && isRenderedPage(entry.path)) count++;
  }
  return count;
}
