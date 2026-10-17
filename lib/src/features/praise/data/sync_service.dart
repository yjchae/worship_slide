import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';
import 'conti_sync_repository.dart';
import 'praise_database.dart';
import 'song_sync_repository.dart';
import 'sync_snapshot.dart';

/// 동기화 한 번의 결과. 곡과 콘티를 따로 센다.
class SyncResult {
  const SyncResult({
    this.songs = const SyncMergeResult(),
    this.contis = const SyncMergeResult(),
  });

  final SyncMergeResult songs;
  final SyncMergeResult contis;

  bool get changed => songs.changed || contis.changed;
}

/// 곡·콘티 동기화 화면에 보여 줄 상태.
@immutable
class SyncStatus {
  const SyncStatus({
    this.folder,
    this.syncing = false,
    this.lastSyncAt,
    this.lastError,
    this.peers = const [],
    this.pendingContis = 0,
  });

  /// 사용자가 고른 공유 폴더. null 이면 동기화 꺼짐.
  final String? folder;
  final bool syncing;
  final DateTime? lastSyncAt;
  final String? lastError;

  /// 같은 폴더를 쓰는 다른 PC 이름.
  final List<String> peers;

  /// 파일이 아직 공유 폴더에 다 안 올라와 받지 못한 다른 PC 의 콘티 수.
  final int pendingContis;

  bool get enabled => folder != null;

  SyncStatus copyWith({
    bool? syncing,
    DateTime? lastSyncAt,
    String? Function()? lastError,
    List<String>? peers,
    int? pendingContis,
  }) => SyncStatus(
    folder: folder,
    syncing: syncing ?? this.syncing,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    lastError: lastError != null ? lastError() : this.lastError,
    peers: peers ?? this.peers,
    pendingContis: pendingContis ?? this.pendingContis,
  );
}

/// 공유 폴더(Google Drive 공유 드라이브 등)로 여러 PC 의 곡·저장 콘티를 맞춘다.
///
/// SQLite 파일 자체를 드라이브에 두면 두 PC 가 동시에 쓸 때 파일이 깨지거나
/// 드라이브가 사본을 만든다. 그래서 **PC 마다 자기 곡·콘티 목록을 JSON 파일 하나로만
/// 쓰고**(`<폴더>/worship_slides_sync/<기기 id>.json`), 다른 PC 들의 파일을 읽어 합친다.
/// 콘티가 쓰는 이미지는 `<폴더>/worship_slides_sync/files/` 에 따로 올린다.
/// 앱은 드라이브 API 를 모른다 — Google Drive 데스크톱 앱이 PC 에 보여 주는 폴더면 된다.
class SyncService {
  SyncService({
    SongSyncRepository? songs,
    ContiSyncRepository? contis,
    Future<Directory> Function()? settingsDirectory,
    String? deviceName,
    DateTime Function()? clock,
  }) : _songs = songs ?? SongSyncRepository(),
       _contis = contis ?? ContiSyncRepository(),
       _settingsDirectory = settingsDirectory ?? getApplicationSupportDirectory,
       _deviceName = deviceName ?? Platform.localHostname,
       _clock = clock ?? DateTime.now;

  static const syncDirName = 'worship_slides_sync';
  static const filesDirName = 'files';
  static const _settingsFile = 'song_sync.json';
  static const _localFilesDirName = 'synced_files';
  static const _interval = Duration(minutes: 1);
  static const _debounce = Duration(seconds: 3);
  static const _maxRetry = Duration(minutes: 30);

  final SongSyncRepository _songs;
  final ContiSyncRepository _contis;
  final Future<Directory> Function() _settingsDirectory;
  final String _deviceName;
  final DateTime Function() _clock;

  final status = ValueNotifier(const SyncStatus());

  /// 다른 PC 의 변경이 이 PC DB 에 들어왔을 때. 곡 목록을 다시 읽는 데 쓴다.
  void Function(SyncResult result)? onMerged;

  String? _deviceId;

  /// 이번 실행이 쓰는 내 파일 표시([SyncSnapshot.writer]). 설정에는 마지막으로 쓴 값을 남긴다.
  final String _writer = newSongUid();

  /// 설정에 남은, 이 PC 가 마지막으로 쓴 내 파일 표시. 내 파일의 표시가 이것과 다르면
  /// 다른 PC 가 같은 기기 id 로 쓴 것이다(설정 폴더째 복제·마이그레이션).
  String? _lastWriter;

  /// 내가 마지막으로 쓴 내 파일의 상태. 바뀌었으면 누가 썼는지 확인한다.
  FileStat? _ownStat;

  Timer? _timer;
  Timer? _debounceTimer;
  Future<void> _queue = Future.value();
  bool _disposed = false;

  /// 이 PC 에서 곡·콘티가 바뀌어 아직 공유 폴더에 안 쓴 상태.
  bool _localDirty = true;

  /// 지난번에 읽은 다른 PC 파일들(경로·수정 시각·크기). 그대로면 합치기를 건너뛴다.
  String? _lastRemoteSignature;

  /// 마지막으로 쓴(또는 확인한) 내 파일 내용. 같으면 다시 쓰지 않는다.
  String? _lastWrittenText;

  /// 받지 못한 콘티·못 읽은 다른 PC 파일이 있을 때 다시 볼 시각. 1분부터 두 배씩 30분까지
  /// 늘린다 — 영영 안 고쳐지는 파일 때문에 매분 전체를 다시 읽지 않게.
  DateTime? _nextRetry;
  Duration _retryDelay = _interval;

  String get deviceId => _deviceId ?? '';

  Future<File> get _settings async =>
      File(p.join((await _settingsDirectory()).path, _settingsFile));

  /// 저장해 둔 설정을 읽고, 폴더가 있으면 바로 한 번 맞춘 뒤 1분마다 맞춘다.
  Future<void> load() async {
    String? folder;
    String? settingsError;
    try {
      final file = await _settings;
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json is! Map) throw const FormatException('설정 모양이 아닙니다');
        folder = json['folder'] is String ? json['folder'] as String : null;
        _deviceId = json['device_id'] is String
            ? json['device_id'] as String
            : null;
        _lastWriter = json['writer'] is String
            ? json['writer'] as String
            : null;
      }
    } catch (error, stack) {
      // 깨진 설정을 "꺼짐"으로 덮어쓰지 않는다 — 사용자가 폴더를 다시 고를 때까지 그대로 두고 알린다.
      await AppLogger.instance.error('동기화 설정 읽기 실패', error, stack);
      settingsError = '동기화 설정을 읽지 못해 꺼 두었습니다. 폴더를 다시 골라 주세요.';
    }
    if (_deviceId == null || _deviceId!.isEmpty) {
      _deviceId = newSongUid();
      if (settingsError == null) await _saveSettings(folder);
    }
    if (_disposed) return;
    _setStatus(SyncStatus(folder: folder, lastError: settingsError));
    _restartTimer();
    if (folder != null) unawaited(syncNow());
  }

  /// 공유 폴더를 바꾼다. null 이면 동기화를 끈다(공유 폴더의 파일은 지우지 않는다).
  /// 도는 중인 동기화가 끝난 뒤에 바꾼다 — 옛 폴더의 결과가 새 폴더 상태를 덮지 않게.
  Future<void> setFolder(String? folder) async {
    await _enqueue(() async {
      await _saveSettings(folder);
      _lastRemoteSignature = null;
      _lastWrittenText = null;
      _ownStat = null;
      _localDirty = true;
      _nextRetry = null;
      _retryDelay = _interval;
      _setStatus(SyncStatus(folder: folder));
      _restartTimer();
    });
    if (folder != null) await syncNow();
  }

  /// 이 PC 에서 곡·콘티를 고쳤을 때. 잇따른 수정은 3초 모아서 한 번에 쓴다.
  void markLocalChanged() {
    _localDirty = true;
    if (_disposed || !status.value.enabled) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () => unawaited(syncNow()));
  }

  /// 지금 맞춘다. 이미 도는 중이면 그 뒤에 이어서 돈다.
  Future<SyncResult?> syncNow() => _enqueue(_sync);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _debounceTimer?.cancel();
    status.dispose();
  }

  // ── 내부 ────────────────────────────────────────────────────────────

  Future<T> _enqueue<T>(Future<T> Function() job) {
    final run = _queue.then((_) => job());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// 앱이 닫힌 뒤(dispose) 끝난 동기화가 상태를 건드리지 않게.
  void _setStatus(SyncStatus value) {
    if (!_disposed) status.value = value;
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = status.value.enabled && !_disposed
        ? Timer.periodic(_interval, (_) => unawaited(syncNow()))
        : null;
  }

  /// 임시 파일에 쓰고 이름을 바꾼다 — 쓰는 도중 꺼져도 설정이 반쯤 남지 않게.
  Future<void> _saveSettings(String? folder) async {
    try {
      final file = await _settings;
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        jsonEncode({
          'folder': folder,
          'device_id': _deviceId,
          'writer': _lastWriter,
        }),
        flush: true,
      );
      await temp.rename(file.path);
    } catch (error, stack) {
      await AppLogger.instance.error('동기화 설정 저장 실패', error, stack);
    }
  }

  Future<SyncResult?> _sync() async {
    final folder = status.value.folder;
    if (_disposed || folder == null) return null;
    _setStatus(status.value.copyWith(syncing: true));
    var hadLocalChanges = false;
    try {
      if (!await Directory(folder).exists()) {
        throw const FileSystemException(
          '공유 폴더를 찾을 수 없습니다. Google Drive 가 켜져 있는지 확인해 주세요.',
        );
      }
      final dir = Directory(p.join(folder, syncDirName));
      await dir.create(recursive: true);
      if (await _ownFileTakenByOther(p.join(dir.path, '$deviceId.json'))) {
        // 설정 폴더째 복제된 다른 PC 가 같은 기기 id 를 쓰고 있다. 이 PC 가 새 id 로 비킨다 —
        // 그대로 두면 서로의 파일을 덮어쓰고 서로를 "나"로 보고 건너뛴다.
        final old = deviceId;
        _deviceId = newSongUid();
        _lastWrittenText = null;
        _ownStat = null;
        hadLocalChanges = true;
        await _saveSettings(folder);
        await AppLogger.instance.info(
          '[sync] 기기 id 가 겹쳐 새로 만듦 $old → $deviceId',
        );
      }
      final ownPath = p.join(dir.path, '$deviceId.json');
      final sharedFiles = Directory(p.join(dir.path, filesDirName));
      final localFiles = Directory(
        p.join((await _settingsDirectory()).path, _localFilesDirName),
      );

      final remoteFiles = await _remoteFiles(dir, ownPath);
      // 상태는 비동기로 읽는다 — 드라이브 폴더의 동기 stat 이 발표 넘기기를 멈출 수 있다.
      final stats = await Future.wait(remoteFiles.map((f) => f.stat()));
      final signature = [
        for (var i = 0; i < remoteFiles.length; i++)
          '${remoteFiles[i].path}|${stats[i].modified}|${stats[i].size}',
      ].join('\n');

      final remoteChanged = signature != _lastRemoteSignature;
      // 변경 표시는 읽자마자 끈다(사이에 await 가 없게). 이 뒤에 생긴 수정은
      // markLocalChanged 가 다시 켠다 — 나중에 끄면 그 사이 수정을 놓친다.
      hadLocalChanges = hadLocalChanges || _localDirty;
      _localDirty = false;
      final ownMissing = !await File(ownPath).exists();
      final retryPending =
          _nextRetry != null && !_clock().isBefore(_nextRetry!);
      final filesMissing = await _contis.sharedFilesMissing(sharedFiles);
      if (!remoteChanged &&
          !hadLocalChanges &&
          !ownMissing &&
          !filesMissing &&
          !retryPending) {
        _setStatus(
          status.value.copyWith(
            syncing: false,
            lastSyncAt: _clock(),
            lastError: () => null,
          ),
        );
        return const SyncResult();
      }

      final read = await _readSnapshots(remoteFiles);
      final snapshots = [
        for (final snapshot in read.snapshots)
          if (snapshot.deviceId != deviceId) snapshot,
      ];
      // 곡을 먼저 합쳐야 콘티의 곡 항목이 이 PC 의 곡에 이어진다.
      final songs = await _songs.merge(snapshots);
      final contis = await _contis.merge(
        snapshots,
        sharedFiles: sharedFiles,
        localFiles: localFiles,
      );
      final result = SyncResult(songs: songs, contis: contis);
      // 받지 못한 콘티만 다시 본 차례에 바뀐 게 없으면 내 파일은 그대로다.
      if (remoteChanged ||
          hadLocalChanges ||
          ownMissing ||
          filesMissing ||
          result.changed) {
        await _writeOwn(ownPath, sharedFiles, localFiles, force: ownMissing);
      }
      _lastRemoteSignature = signature;
      // 받지 못한 콘티나 못 읽은 파일(드라이브가 아직 내려받는 중)이 있으면 조금 뒤에 다시 본다.
      _scheduleRetry(contis.pendingCount > 0 || read.failed);

      _setStatus(
        status.value.copyWith(
          syncing: false,
          lastSyncAt: _clock(),
          lastError: () => null,
          peers: [
            for (final s in snapshots)
              s.deviceName.isEmpty ? s.deviceId : s.deviceName,
          ],
          pendingContis: contis.pendingCount,
        ),
      );
      if (result.changed) {
        String counts(SyncMergeResult r) =>
            '추가 ${r.addedCount} · 수정 ${r.updatedCount} · 삭제 ${r.deletedCount}';
        await AppLogger.instance.info(
          '[sync] 곡 ${counts(result.songs)} / 콘티 ${counts(result.contis)}',
        );
        if (!_disposed) onMerged?.call(result);
      }
      return result;
    } catch (error, stack) {
      // 쓰지 못한 이 PC 의 수정은 다음 차례에 다시 쓴다.
      if (hadLocalChanges) _localDirty = true;
      await AppLogger.instance.error('동기화 실패', error, stack);
      _setStatus(
        status.value.copyWith(
          syncing: false,
          lastError: () =>
              error is FileSystemException ? error.message : error.toString(),
        ),
      );
      return null;
    }
  }

  void _scheduleRetry(bool needed) {
    if (!needed) {
      _nextRetry = null;
      _retryDelay = _interval;
      return;
    }
    _nextRetry = _clock().add(_retryDelay);
    final doubled = _retryDelay * 2;
    _retryDelay = doubled > _maxRetry ? _maxRetry : doubled;
  }

  Future<List<File>> _remoteFiles(Directory dir, String ownPath) async {
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.') || p.extension(name).toLowerCase() != '.json') {
        continue;
      }
      if (p.equals(entity.path, ownPath)) continue;
      files.add(entity);
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// 다른 PC 파일을 읽어 푼다. 곡이 수천 곡이면 파일마다 몇 MB 라서 화면 스레드가
  /// 멈추지 않게 별도 isolate 에서 읽고 푼다.
  Future<({List<SyncSnapshot> snapshots, bool failed})> _readSnapshots(
    List<File> files,
  ) async {
    final paths = [for (final f in files) f.path];
    final read = await Isolate.run(
      () => [
        for (final path in paths)
          () {
            try {
              final snapshot = SyncSnapshot.fromJson(
                jsonDecode(File(path).readAsStringSync()),
              );
              return (snapshot: snapshot, error: null);
            } catch (error) {
              return (snapshot: null, error: '$path: $error');
            }
          }(),
      ],
    );
    final result = <SyncSnapshot>[];
    var failed = false;
    for (final r in read) {
      if (r.snapshot != null) {
        result.add(r.snapshot!);
      } else if (r.error != null) {
        // 드라이브가 아직 내려받는 중이거나 다른 PC 가 쓰는 중이면 다음 차례에 다시 읽는다.
        failed = true;
        await AppLogger.instance.info('[sync] 읽기 건너뜀 ${r.error}');
      }
    }
    return (snapshots: result, failed: failed);
  }

  /// 내 파일은 내용이 바뀌었을 때만 쓴다(드라이브가 쓸데없이 올리지 않게).
  /// 임시 파일에 쓰고 이름을 바꿔, 다른 PC 가 반쯤 쓴 파일을 읽지 않게 한다.
  /// [force] 면 내용이 같아도 쓴다(내 파일이 사라졌을 때).
  Future<void> _writeOwn(
    String path,
    Directory sharedFiles,
    Directory localFiles, {
    bool force = false,
  }) async {
    final songs = await _songs.exportSnapshot(
      deviceId: deviceId,
      deviceName: _deviceName,
      writer: _writer,
    );
    // 콘티 이미지를 먼저 올린다 — 다른 PC 가 콘티를 보고 파일을 찾을 때 있어야 한다.
    final contis = await _contis.export(
      sharedFiles: sharedFiles,
      localFiles: localFiles,
    );
    final snapshot = songs.withContis(contis.contis, contis.deleted);
    final text = await Isolate.run(() => jsonEncode(snapshot.toJson()));
    if (!force && text == _lastWrittenText) return;
    final file = File(path);
    final temp = File('$path.tmp');
    await temp.writeAsString(text, flush: true);
    try {
      await temp.rename(path);
    } on FileSystemException {
      await file.writeAsString(text, flush: true);
      await temp.delete().catchError((_) => temp);
    }
    _lastWrittenText = text;
    _ownStat = await file.stat();
    if (_lastWriter != _writer) {
      _lastWriter = _writer;
      await _saveSettings(status.value.folder);
    }
  }

  /// 내 파일(이 기기 id)을 다른 PC 가 쓰고 있으면 true. 내가 쓴 뒤로 파일이 바뀌었을 때만
  /// 파일 안의 표시(writer)를 읽어 본다.
  Future<bool> _ownFileTakenByOther(String path) async {
    final file = File(path);
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) return false;
    final mine = _ownStat;
    if (mine != null &&
        stat.modified == mine.modified &&
        stat.size == mine.size) {
      return false;
    }
    final writer = await Isolate.run(() {
      try {
        final json = jsonDecode(File(path).readAsStringSync());
        return json is Map && json['writer'] is String
            ? json['writer'] as String
            : null;
      } catch (_) {
        return null;
      }
    });
    if (writer == null || writer.isEmpty || writer == _writer) {
      if (writer == _writer) _ownStat = stat;
      return false;
    }
    // 이번 실행에서 아직 안 썼으면, 지난 실행에서 내가 쓴 것인지 본다.
    if (mine == null && (_lastWriter == null || writer == _lastWriter)) {
      return false;
    }
    return true;
  }
}
