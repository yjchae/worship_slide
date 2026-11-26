import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';
import 'atomic_file.dart';

/// OBS 자막 뒤 띠: 없음 / 글 폭에 맞춤 / 화면 폭 전체.
enum ObsBand { none, text, full }

/// 자막 덩어리 가로 정렬.
enum ObsAlign { left, center, right }

/// 자막 덩어리가 붙는 쪽(아래 = 아래 기준선에서 위로 자란다).
enum ObsAnchor { bottom, top }

const defaultObsPort = 8766;
const minObsPort = 1024;
const maxObsPort = 65535;

/// 키 글자판 — 싱어 서버와 같다(헷갈리는 0·o·1·l·i 뺌).
const _keyAlphabet = 'abcdefghjkmnpqrstuvwxyz23456789';

String newObsKey([Random? random]) {
  final rnd = random ?? Random.secure();
  return List.generate(
    16,
    (_) => _keyAlphabet[rnd.nextInt(_keyAlphabet.length)],
  ).join();
}

/// `#RRGGBB` 만 받는다. 틀리면 [fallback].
String _color(Object? value, String fallback) {
  if (value is! String) return fallback;
  final v = value.trim().toUpperCase();
  return RegExp(r'^#[0-9A-F]{6}$').hasMatch(v) ? v : fallback;
}

double _num(Object? value, double fallback, double min, double max) {
  final v = value is num ? value.toDouble() : fallback;
  return (v.isFinite ? v : fallback).clamp(min, max).toDouble();
}

bool _bool(Object? value, bool fallback) => value is bool ? value : fallback;

/// OBS 자막 설정 → Application Support/obs_overlay.json.
///
/// 크기·거리는 OBS 페이지 높이 1080 기준 px 이다(페이지가 `vh` 로 바꿔 그리므로 OBS 소스를
/// 다른 크기로 넣어도 비율대로 따라간다). 관객 화면 디자인(`ExportStyle`)과는 따로다 —
/// 관객 디자인을 바꿀 때 방송 자막이 같이 움직이면 방송 사고라서.
class ObsOverlayConfig {
  const ObsOverlayConfig({
    this.enabled = false,
    this.port = defaultObsPort,
    this.key = '',
    this.allowLan = true,
    this.fontFamily = '',
    this.fontSize = 56,
    this.bold = true,
    this.subRatio = 0.8,
    this.extraRatio = 0.7,
    this.showSub = true,
    this.showExtra = false,
    this.showReference = true,
    this.showSongTitle = false,
    this.showSermon = true,
    this.mainColor = '#FFFFFF',
    this.subColor = '#FFE082',
    this.extraColor = '#B3E5FC',
    this.referenceColor = '#FFD54F',
    this.outlineWidth = 3,
    this.outlineColor = '#000000',
    this.shadow = true,
    this.band = ObsBand.none,
    this.bandColor = '#000000',
    this.bandOpacity = 0.55,
    this.align = ObsAlign.center,
    this.anchor = ObsAnchor.bottom,
    this.offset = 60,
    this.sideMargin = 120,
    this.maxHeight = 0.4,
    this.fade = true,
  });

  // ── 연결 ──
  /// 켜 두면 앱이 켜질 때 서버도 켠다(OBS 는 보통 예배 전부터 켜 둔다).
  final bool enabled;
  final int port;

  /// 주소의 `?k=`. 처음 켤 때 만들어 계속 쓴다(바뀌면 OBS 주소가 깨진다).
  final String key;

  /// true = 같은 망의 다른 PC(방송 PC)의 OBS 도 받는다(0.0.0.0). false = 이 PC(127.0.0.1)만.
  final bool allowLan;

  // ── 글자 ──
  /// '' = 관객 화면 글꼴 따라가기.
  final String fontFamily;
  final double fontSize;
  final bool bold;
  final double subRatio;
  final double extraRatio;

  // ── 보일 줄 ──
  final bool showSub;
  final bool showExtra;
  final bool showReference;
  final bool showSongTitle;
  final bool showSermon;

  // ── 색 ──
  final String mainColor;
  final String subColor;
  final String extraColor;
  final String referenceColor;

  // ── 꾸밈 ──
  /// 0 = 외곽선 없음.
  final double outlineWidth;
  final String outlineColor;
  final bool shadow;
  final ObsBand band;
  final String bandColor;
  final double bandOpacity;

  // ── 위치 ──
  final ObsAlign align;
  final ObsAnchor anchor;

  /// 기준(아래·위)에서 떨어진 거리.
  final double offset;

  /// 좌우 여백.
  final double sideMargin;

  /// 덩어리 최대 높이(화면 높이 대비). 넘으면 글자를 줄인다.
  final double maxHeight;
  final bool fade;

  /// 키가 없으면 새로 만든 것.
  ObsOverlayConfig withKey() =>
      key.isNotEmpty ? this : copyWith(key: newObsKey());

  ObsOverlayConfig copyWith({
    bool? enabled,
    int? port,
    String? key,
    bool? allowLan,
    String? fontFamily,
    double? fontSize,
    bool? bold,
    double? subRatio,
    double? extraRatio,
    bool? showSub,
    bool? showExtra,
    bool? showReference,
    bool? showSongTitle,
    bool? showSermon,
    String? mainColor,
    String? subColor,
    String? extraColor,
    String? referenceColor,
    double? outlineWidth,
    String? outlineColor,
    bool? shadow,
    ObsBand? band,
    String? bandColor,
    double? bandOpacity,
    ObsAlign? align,
    ObsAnchor? anchor,
    double? offset,
    double? sideMargin,
    double? maxHeight,
    bool? fade,
  }) => ObsOverlayConfig.fromJson({
    ...toJson(),
    'enabled': ?enabled,
    'port': ?port,
    'key': ?key,
    'allow_lan': ?allowLan,
    'font_family': ?fontFamily,
    'font_size': ?fontSize,
    'bold': ?bold,
    'sub_ratio': ?subRatio,
    'extra_ratio': ?extraRatio,
    'show_sub': ?showSub,
    'show_extra': ?showExtra,
    'show_reference': ?showReference,
    'show_song_title': ?showSongTitle,
    'show_sermon': ?showSermon,
    'main_color': ?mainColor,
    'sub_color': ?subColor,
    'extra_color': ?extraColor,
    'reference_color': ?referenceColor,
    'outline_width': ?outlineWidth,
    'outline_color': ?outlineColor,
    'shadow': ?shadow,
    'band': ?band?.name,
    'band_color': ?bandColor,
    'band_opacity': ?bandOpacity,
    'align': ?align?.name,
    'anchor': ?anchor?.name,
    'offset': ?offset,
    'side_margin': ?sideMargin,
    'max_height': ?maxHeight,
    'fade': ?fade,
  });

  /// 디자인 칸만 기본값으로(연결 칸은 그대로).
  ObsOverlayConfig resetDesign() => ObsOverlayConfig(
    enabled: enabled,
    port: port,
    key: key,
    allowLan: allowLan,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'enabled': enabled,
    'port': port,
    'key': key,
    'allow_lan': allowLan,
    ...designJson(),
  };

  /// OBS 페이지로 보내는 디자인(연결 칸·키는 빼고).
  Map<String, dynamic> designJson() => {
    'font_family': fontFamily,
    'font_size': fontSize,
    'bold': bold,
    'sub_ratio': subRatio,
    'extra_ratio': extraRatio,
    'show_sub': showSub,
    'show_extra': showExtra,
    'show_reference': showReference,
    'show_song_title': showSongTitle,
    'show_sermon': showSermon,
    'main_color': mainColor,
    'sub_color': subColor,
    'extra_color': extraColor,
    'reference_color': referenceColor,
    'outline_width': outlineWidth,
    'outline_color': outlineColor,
    'shadow': shadow,
    'band': band.name,
    'band_color': bandColor,
    'band_opacity': bandOpacity,
    'align': align.name,
    'anchor': anchor.name,
    'offset': offset,
    'side_margin': sideMargin,
    'max_height': maxHeight,
    'fade': fade,
  };

  /// 키는 여기 한 곳에서만 읽는다(스토어에 따로 읽는 곳을 두지 않는다). 틀린 값은 범위 안으로.
  factory ObsOverlayConfig.fromJson(Map<String, dynamic> json) {
    const d = ObsOverlayConfig();
    final port = json['port'];
    final key = json['key'];
    return ObsOverlayConfig(
      enabled: _bool(json['enabled'], d.enabled),
      port: port is int && port >= minObsPort && port <= maxObsPort
          ? port
          : d.port,
      key: key is String && RegExp(r'^[a-z0-9]{8,64}$').hasMatch(key)
          ? key
          : '',
      allowLan: _bool(json['allow_lan'], d.allowLan),
      fontFamily: json['font_family'] is String
          ? (json['font_family'] as String).trim()
          : d.fontFamily,
      fontSize: _num(json['font_size'], d.fontSize, 16, 200),
      bold: _bool(json['bold'], d.bold),
      subRatio: _num(json['sub_ratio'], d.subRatio, 0.3, 1.5),
      extraRatio: _num(json['extra_ratio'], d.extraRatio, 0.3, 1.5),
      showSub: _bool(json['show_sub'], d.showSub),
      showExtra: _bool(json['show_extra'], d.showExtra),
      showReference: _bool(json['show_reference'], d.showReference),
      showSongTitle: _bool(json['show_song_title'], d.showSongTitle),
      showSermon: _bool(json['show_sermon'], d.showSermon),
      mainColor: _color(json['main_color'], d.mainColor),
      subColor: _color(json['sub_color'], d.subColor),
      extraColor: _color(json['extra_color'], d.extraColor),
      referenceColor: _color(json['reference_color'], d.referenceColor),
      outlineWidth: _num(json['outline_width'], d.outlineWidth, 0, 12),
      outlineColor: _color(json['outline_color'], d.outlineColor),
      shadow: _bool(json['shadow'], d.shadow),
      band: ObsBand.values.asNameMap()[json['band']] ?? d.band,
      bandColor: _color(json['band_color'], d.bandColor),
      bandOpacity: _num(json['band_opacity'], d.bandOpacity, 0, 1),
      align: ObsAlign.values.asNameMap()[json['align']] ?? d.align,
      anchor: ObsAnchor.values.asNameMap()[json['anchor']] ?? d.anchor,
      offset: _num(json['offset'], d.offset, 0, 600),
      sideMargin: _num(json['side_margin'], d.sideMargin, 0, 700),
      maxHeight: _num(json['max_height'], d.maxHeight, 0.1, 1),
      fade: _bool(json['fade'], d.fade),
    );
  }
}

class ObsOverlayStore {
  ObsOverlayStore({this.directory});

  /// 테스트용. null 이면 Application Support.
  final Directory? directory;

  Future<File> _file() async => File(
    p.join(
      (directory ?? await getApplicationSupportDirectory()).path,
      'obs_overlay.json',
    ),
  );

  /// 없거나 깨졌으면 기본값. 키가 없으면 만들어 바로 저장한다(OBS 주소가 처음부터 정해지게).
  Future<ObsOverlayConfig> load() async {
    var config = const ObsOverlayConfig();
    try {
      final file = await _file();
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, dynamic>) {
          config = ObsOverlayConfig.fromJson(json);
        } else {
          await _keepBroken(file);
        }
      }
    } catch (error) {
      await AppLogger.instance.info(
        '[obs] obs_overlay.json 읽기 실패 — 기본값: $error',
      );
      try {
        await _keepBroken(await _file());
      } catch (_) {}
    }
    if (config.key.isEmpty) {
      config = config.withKey();
      await save(config);
    }
    return config;
  }

  // 깨진 파일은 지우지 않고 옆에 남긴다(손으로 되살릴 수 있게).
  Future<void> _keepBroken(File file) async {
    if (!await file.exists()) return;
    await file.copy('${file.path}.broken.bak');
  }

  Future<void> save(ObsOverlayConfig config) async {
    try {
      await atomicWriteString(await _file(), jsonEncode(config.toJson()));
    } catch (error, stack) {
      await AppLogger.instance.error('obs_overlay.json 저장 실패', error, stack);
    }
  }
}
