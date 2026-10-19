import 'package:flutter/foundation.dart';

/// 발표 경과 시간. 발표 보기 시계와 싱어 화면(네이티브·휴대폰)이 같은 값을 본다.
///
/// 1초마다 더하는 대신 "쌓인 시간 + 다시 흐르기 시작한 시각"으로 들고 있는다.
/// 그래야 싱어 화면이 페이지가 바뀔 때만 값을 받아도 자기 시계로 이어서 셀 수 있고,
/// 발표 보기 탭이 트리에서 빠져 있어도 시간이 계속 흐른다.
class PresentationTimer extends ChangeNotifier {
  PresentationTimer({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  Duration _accumulated = Duration.zero;
  // 흐르는 중이면 마지막으로 흐르기 시작한 시각. 멈춰 있으면 null.
  DateTime? _runningSince;

  /// 사용자가 일시정지했는지. 발표가 끝나 멈춘 것과 구별한다(버튼 모양).
  bool isPaused = false;

  int targetMinutes = 20;

  /// 싱어 화면에 시계·경과 시간을 띄울지.
  bool showOnSinger = true;

  /// 값이 바뀔 때마다(시작·멈춤·리셋·목표·표시) 올리고 알린다. 싱어 화면에 다시 보낼지 가리는 데 쓴다 —
  /// 흐르는 동안의 경과 시간은 매번 달라서 비교에 못 쓴다.
  int revision = 0;

  bool get isRunning => _runningSince != null;

  Duration get elapsed => _runningSince == null
      ? _accumulated
      : _accumulated + _now().difference(_runningSince!);

  Duration get target => Duration(minutes: targetMinutes);

  /// 발표를 시작했다: 0부터 다시 센다.
  void start() {
    _accumulated = Duration.zero;
    _runningSince = _now();
    isPaused = false;
    _changed();
  }

  /// 발표가 끝났다: 그 자리에서 멈춘다(다음 발표 전까지 마지막 값이 보인다).
  void stop() {
    _freeze();
    _changed();
  }

  void togglePause({required bool presenting}) {
    if (isPaused) {
      isPaused = false;
      if (presenting) _runningSince = _now();
    } else {
      isPaused = true;
      _freeze();
    }
    _changed();
  }

  void reset() {
    _accumulated = Duration.zero;
    if (_runningSince != null) _runningSince = _now();
    _changed();
  }

  void setTargetMinutes(int minutes) {
    if (minutes <= 0 || minutes == targetMinutes) return;
    targetMinutes = minutes;
    _changed();
  }

  void setShowOnSinger(bool value) {
    if (value == showOnSinger) return;
    showOnSinger = value;
    _changed();
  }

  void _changed() {
    revision++;
    notifyListeners();
  }

  void _freeze() {
    _accumulated = elapsed;
    _runningSince = null;
  }

  /// 싱어 화면용. 받는 쪽은 받은 순간부터 [elapsed_ms] 에 자기 시계로 더해 센다(running 일 때).
  Map<String, Object> toSingerJson() => {
    'show': showOnSinger,
    'elapsed_ms': elapsed.inMilliseconds,
    'running': isRunning,
    'target_ms': target.inMilliseconds,
    'rev': revision,
  };
}
