import 'dart:async';
import 'dart:io';

/// 바깥 프로그램(PowerPoint 등)에서 연 원본 파일이 저장되는지 지켜본다.
///
/// 파일 시스템 이벤트(`File.watch`) 대신 수정 시각·크기를 주기적으로 본다 —
/// PowerPoint 는 임시 파일에 쓴 뒤 이름을 바꿔 저장해서 파일 하나에 건 감시가 끊기고,
/// 저장 도중에는 파일이 반쯤 써진 상태라 이벤트 한 번으로 바로 읽으면 안 된다.
/// 그래서 바뀐 뒤 **한 번 더 같은 값**이 나와야(저장이 끝나야) [onChanged] 를 부른다.
class SourceFileWatcher {
  SourceFileWatcher({
    required this.onChanged,
    this.interval = const Duration(seconds: 2),
  });

  final void Function(String path) onChanged;
  final Duration interval;

  final Map<String, _Snapshot?> _seen = {};
  final Map<String, _Snapshot> _pending = {};
  Timer? _timer;
  // 확인 한 번이 간격보다 오래 걸려도(느린 네트워크 드라이브) 겹쳐 돌지 않게.
  bool _checking = false;

  bool isWatching(String path) => _seen.containsKey(path);

  Iterable<String> get watchedPaths => _seen.keys;

  /// 지금 상태를 기준으로 [path] 를 지켜보기 시작한다. 이미 보고 있으면 기준만 새로 잡는다.
  Future<void> watch(String path) async {
    final snapshot = await _Snapshot.of(path);
    _seen[path] = snapshot;
    _pending.remove(path);
    _timer ??= Timer.periodic(interval, (_) => check());
  }

  void unwatch(String path) {
    _seen.remove(path);
    _pending.remove(path);
    if (_seen.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void unwatchAll() {
    for (final path in _seen.keys.toList()) {
      unwatch(path);
    }
  }

  /// 타이머가 부른다. 테스트에서는 직접 부른다.
  ///
  /// 파일 상태는 비동기로 읽는다 — 원본이 NAS·USB 에 있으면 한 번에 몇 초씩 걸릴 수 있는데,
  /// 동기로 읽으면 그동안 화면과 발표 넘기기 키가 멈춘다.
  Future<void> check() async {
    if (_checking) return;
    _checking = true;
    try {
      await _checkAll();
    } finally {
      _checking = false;
    }
  }

  Future<void> _checkAll() async {
    for (final path in _seen.keys.toList()) {
      final now = await _Snapshot.of(path);
      // 읽는 사이에 unwatch 됐으면 넘어간다.
      if (!_seen.containsKey(path)) continue;
      // 저장 중 잠깐 파일이 없을 수 있다(이름 바꾸기). 다음 차례에 다시 본다.
      if (now == null || now == _seen[path]) {
        _pending.remove(path);
        continue;
      }
      if (_pending[path] == now) {
        _pending.remove(path);
        _seen[path] = now;
        onChanged(path);
      } else {
        _pending[path] = now;
      }
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _seen.clear();
    _pending.clear();
  }
}

class _Snapshot {
  const _Snapshot(this.modified, this.size);

  final DateTime modified;
  final int size;

  static Future<_Snapshot?> of(String path) async {
    final FileStat stat;
    try {
      stat = await FileStat.stat(path);
    } on FileSystemException {
      return null;
    }
    if (stat.type == FileSystemEntityType.notFound) return null;
    return _Snapshot(stat.modified, stat.size);
  }

  @override
  bool operator ==(Object other) =>
      other is _Snapshot && other.modified == modified && other.size == size;

  @override
  int get hashCode => Object.hash(modified, size);
}
