import 'dart:async';

import 'package:flutter/foundation.dart';

/// 발표 자동 넘기기 타이머. 정한 시간이 지나면 [onElapsed] 를 부른다(홈 화면이 다음 페이지로 넘긴다).
///
/// - [repeat] 가 켜져 있으면 시간이 찰 때마다 계속 부른다. 끄면 한 번 부르고 멈춘다.
/// - [maxCount] 가 있으면 반복 중에도 그 횟수만큼 넘기고 멈춘다(null = 무제한). 손으로 넘긴 것은 세지 않는다.
/// - 다음 마감은 "지난 마감 + 간격"으로 잡는다. 넘기는 데 걸린 시간이 쌓여 늦어지지 않게 —
///   2번에서 5분 반복으로 시작하면 5분에 3번, 10분에 4번이 된다.
/// - 손으로 페이지를 넘겨도 마감은 그대로다(시작한 시각 기준의 일정한 박자).
///
/// 발표 보기 탭이 트리에서 빠져도 흘러야 하므로 [PresenterViewState] 가 들고 있다.
class AutoAdvanceTimer extends ChangeNotifier {
  AutoAdvanceTimer({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// 가장 짧은 간격. 실수로 0초를 넣어 페이지가 미친 듯이 넘어가지 않게.
  static const minInterval = Duration(seconds: 1);

  /// 시간이 다 됐을 때 부른다. 홈 화면이 붙인다.
  VoidCallback? onElapsed;

  Duration _interval = const Duration(minutes: 5);
  bool _repeat = true;
  int? _maxCount;
  int _fired = 0;
  DateTime? _deadline;
  Timer? _timer;

  Duration get interval => _interval;
  bool get repeat => _repeat;
  bool get isRunning => _deadline != null;
  int? get maxCount => _maxCount;

  /// 횟수 제한이 있고 도는 중일 때 남은 넘김 횟수. 아니면 null.
  int? get remainingCount =>
      _maxCount == null || !isRunning ? null : _maxCount! - _fired;

  /// 다음 넘기기까지 남은 시간. 멈춰 있으면 간격 그대로.
  Duration get remaining {
    final deadline = _deadline;
    if (deadline == null) return _interval;
    final left = deadline.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// 간격을 바꾼다. 도는 중이면 지금부터 새 간격으로 다시 센다.
  void setInterval(Duration value) {
    if (value < minInterval || value == _interval) return;
    _interval = value;
    if (isRunning) _schedule(_now().add(_interval));
    notifyListeners();
  }

  void setRepeat(bool value) {
    if (value == _repeat) return;
    _repeat = value;
    notifyListeners();
  }

  /// 넘길 횟수. 1 미만·null 은 무제한.
  void setMaxCount(int? value) {
    final v = value == null || value < 1 ? null : value;
    if (v == _maxCount) return;
    _maxCount = v;
    notifyListeners();
  }

  void start() {
    _fired = 0;
    _schedule(_now().add(_interval));
    notifyListeners();
  }

  void stop() {
    if (!isRunning) return;
    _timer?.cancel();
    _timer = null;
    _deadline = null;
    notifyListeners();
  }

  void _schedule(DateTime deadline) {
    _timer?.cancel();
    _deadline = deadline;
    final wait = deadline.difference(_now());
    _timer = Timer(wait.isNegative ? Duration.zero : wait, _fire);
  }

  void _fire() {
    final deadline = _deadline;
    if (deadline == null) return;
    _fired++;
    if (_repeat && (_maxCount == null || _fired < _maxCount!)) {
      _schedule(deadline.add(_interval));
    } else {
      _timer = null;
      _deadline = null;
    }
    // 먼저 다음 마감을 잡고 부른다 — 콜백 안에서 stop() 해도(마지막 페이지) 다시 켜지지 않게.
    onElapsed?.call();
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
