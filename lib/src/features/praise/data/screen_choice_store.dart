import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 네이티브 `getScreens` 가 돌려준 모니터 하나. [index] 가 네이티브가 받는 번호다.
class ScreenInfo {
  const ScreenInfo({
    required this.index,
    required this.name,
    required this.width,
    required this.height,
    required this.isMain,
  });

  final int index;
  final String name;
  final int width;
  final int height;
  /// 앱 메인 창이 떠 있는 모니터.
  final bool isMain;

  String get label =>
      '${index + 1}. $name ($width×$height)${isMain ? ' · 메인 창' : ''}';

  static ScreenInfo fromJson(int index, Map<dynamic, dynamic> json) =>
      ScreenInfo(
        index: index,
        name: json['name'] as String? ?? '모니터 ${index + 1}',
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
        isMain: json['main'] as bool? ?? false,
      );
}

/// 사용자가 고른 모니터. 번호는 연결 순서에 따라 바뀔 수 있어 이름을 같이 남긴다.
class ScreenChoice {
  const ScreenChoice(this.index, this.name);
  final int index;
  final String name;

  /// 지금 연결된 모니터 중 고른 것의 번호. 번호와 이름이 둘 다 맞을 때만 쓰고, 아니면 -1(자동).
  /// 이름만으로 다시 찾지 않는 이유 — 같은 모델·"일반 PnP 모니터"처럼 이름이 겹치는 일이 흔해서
  /// 연결 순서가 바뀌면 메인 창 모니터를 잘못 고를 수 있다. 엉뚱한 모니터보다 자동이 안전하다.
  static int resolve(ScreenChoice? choice, List<ScreenInfo> screens) {
    if (choice == null) return -1;
    for (final s in screens) {
      if (s.index == choice.index && s.name == choice.name) return s.index;
    }
    return -1;
  }

  Map<String, dynamic> toJson() => {'index': index, 'name': name};

  static ScreenChoice? fromJson(Object? json) {
    if (json is! Map) return null;
    final index = json['index'];
    final name = json['name'];
    if (index is! int || name is! String) return null;
    return ScreenChoice(index, name);
  }
}

/// 관객·싱어 창 모니터 선택 → Application Support/screen_choice.json. null = 자동.
class ScreenChoiceStore {
  Future<File> _file() async => File(
    p.join((await getApplicationSupportDirectory()).path, 'screen_choice.json'),
  );

  Future<(ScreenChoice?, ScreenChoice?)> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return (null, null);
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (
        ScreenChoice.fromJson(json['audience']),
        ScreenChoice.fromJson(json['singer']),
      );
    } catch (_) {
      return (null, null);
    }
  }

  Future<void> save(ScreenChoice? audience, ScreenChoice? singer) async {
    try {
      await (await _file()).writeAsString(
        jsonEncode({'audience': audience?.toJson(), 'singer': singer?.toJson()}),
      );
    } catch (_) {}
  }
}
