import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  }) : _songs = songs ?? SongSyncRepository(),
       _contis = contis ?? ContiSyncRepository(),
       _settingsDirectory = settingsDirectory ?? getApplicationSupportDirectory,
       _deviceName = deviceName ?? Platform.localHostname;

  static const syncDirName = 'worship_slides_sync';
  static const filesDirName = 'files';
  static const _settingsFile = 'song_sync.json';
  static const _localFilesDirName = 'synced_files';
  static const _interval = Duration(minutes: 1);
  static const _debounce = Duration(seconds: 3);

  final SongSyncRepository _songs;
  final ContiSyncRepository _contis;
  final Future<Directory> Function() _settingsDirectory;
  final String _deviceName;

  final status = ValueNotifier(const SyncStatus());

  /// 다른 PC 의 변경이 이 PC DB 에 들어왔을 때. 곡 목록을 다시 읽는 데 쓴다.
  void Function(SyncResult result)? onMerged;

  String? _deviceId;
  Timer? _timer;
  Timer? _debounceTimer;
  Future<void> _queue = Future.value();

  /// 이 PC 에서 곡·콘티가 바뀌어 아직 공유 폴더에 안 쓴 상태.
  /// (받지 못한 콘티가 남아 있을 때도 켜 둔다 — 다른 PC 파일이 그대로여도 다시 받아 보게.)
  bool _localDirty = true;

  /// 지난번에 읽은 다른 PC 파일들(경로·수정 시각·크기). 그대로면 합치기를 건너뛴다.
  String? _lastRemoteSignature;

  String get deviceId => _deviceId ?? '';

  Future<File> get _settings async =>
      File(p.join((await _settingsDirectory()).path, _settingsFile));

  /// 저장해 둔 설정을 읽고, 폴더가 있으면 바로 한 번 맞춘 뒤 1분마다 맞춘다.
  Future<void> load() async {
    String? folder;
    try {
      final file = await _settings;
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json is Map) {
          folder = json['folder'] as String?;
          _deviceId = json['device_id'] as String?;
        }
      }
    } catch (error, stack) {
      await AppLogger.instance.error('동기화 설정 읽기 실패', error, stack);
    }
    if (_deviceId == null || _deviceId!.isEmpty) {
      _deviceId = newSongUid();
      await _saveSettings(folder);
    }
    status.value = SyncStatus(folder: folder);
    _restartTimer();
    if (folder != null) unawaited(syncNow());
  }

  /// 공유 폴더를 바꾼다. null 이면 동기화를 끈다(공유 폴더의 파일은 지우지 않는다).
  Future<void> setFolder(String? folder) async {
    await _saveSettings(folder);
    _lastRemoteSignature = null;
    _localDirty = true;
    status.value = SyncStatus(folder: folder);
    _restartTimer();
    if (folder != null) await syncNow();
  }

  /// 이 PC 에서 곡·콘티를 고쳤을 때. 잇따른 수정은 3초 모아서 한 번에 쓴다.
  void markLocalChanged() {
    _localDirty = true;
    if (!status.value.enabled) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () => unawaited(syncNow()));
  }

  /// 지금 맞춘다. 이미 도는 중이면 그 뒤에 이어서 돈다.
  Future<SyncResult?> syncNow() {
    final run = _queue.then((_) => _sync());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  void dispose() {
    _timer?.cancel();
    _debounceTimer?.cancel();
    status.dispose();
  }

  // ── 내부 ────────────────────────────────────────────────────────────

  void _restartTimer() {
    _timer?.cancel();
    _timer = status.value.enabled
        ? Timer.periodic(_interval, (_) => unawaited(syncNow()))
        : null;
  }

  Future<void> _saveSettings(String? folder) async {
    try {
      final file = await _settings;
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({'folder': folder, 'device_id': _deviceId}),
      );
    } catch (error, stack) {
      await AppLogger.instance.error('동기화 설정 저장 실패', error, stack);
    }
  }

  Future<SyncResult?> _sync() async {
    final folder = status.value.folder;
    if (folder == null) return null;
    status.value = status.value.copyWith(syncing: true);
    try {
      if (!await Directory(folder).exists()) {
        throw const FileSystemException(
          '공유 폴더를 찾을 수 없습니다. Google Drive 가 켜져 있는지 확인해 주세요.',
        );
      }
      final dir = Directory(p.join(folder, syncDirName));
      await dir.create(recursive: true);
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

      var result = const SyncResult();
      var pending = status.value.pendingContis;
      final peers = <String>[];
      if (signature != _lastRemoteSignature ||
          _localDirty ||
          !await File(ownPath).exists()) {
        final snapshots = <SyncSnapshot>[];
        for (final file in remoteFiles) {
          final snapshot = await _readSnapshot(file);
          if (snapshot == null || snapshot.deviceId == deviceId) continue;
          snapshots.add(snapshot);
          peers.add(
            snapshot.deviceName.isEmpty
                ? snapshot.deviceId
                : snapshot.deviceName,
          );
        }
        // 곡을 먼저 합쳐야 콘티의 곡 항목이 이 PC 의 곡에 이어진다.
        final songs = await _songs.merge(snapshots);
        final contis = await _contis.merge(
          snapshots,
          sharedFiles: sharedFiles,
          localFiles: localFiles,
        );
        result = SyncResult(songs: songs, contis: contis);
        pending = contis.pendingCount;
        await _writeOwn(ownPath, sharedFiles, localFiles);
        _lastRemoteSignature = signature;
        _localDirty = pending > 0;
      } else {
        peers.addAll(status.value.peers);
      }

      status.value = status.value.copyWith(
        syncing: false,
        lastSyncAt: DateTime.now(),
        lastError: () => null,
        peers: peers,
        pendingContis: pending,
      );
      if (result.changed) {
        String counts(SyncMergeResult r) =>
            '추가 ${r.addedCount} · 수정 ${r.updatedCount} · 삭제 ${r.deletedCount}';
        await AppLogger.instance.info(
          '[sync] 곡 ${counts(result.songs)} / 콘티 ${counts(result.contis)}',
        );
        onMerged?.call(result);
      }
      return result;
    } catch (error, stack) {
      await AppLogger.instance.error('동기화 실패', error, stack);
      status.value = status.value.copyWith(
        syncing: false,
        lastError: () =>
            error is FileSystemException ? error.message : error.toString(),
      );
      return null;
    }
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

  Future<SyncSnapshot?> _readSnapshot(File file) async {
    try {
      return SyncSnapshot.fromJson(jsonDecode(await file.readAsString()));
    } catch (error) {
      // 드라이브가 아직 내려받는 중이거나 다른 PC 가 쓰는 중이면 다음 차례에 다시 읽는다.
      await AppLogger.instance.info('[sync] 읽기 건너뜀 ${file.path}: $error');
      return null;
    }
  }

  /// 내 파일은 내용이 바뀌었을 때만 쓴다(드라이브가 쓸데없이 올리지 않게).
  /// 임시 파일에 쓰고 이름을 바꿔, 다른 PC 가 반쯤 쓴 파일을 읽지 않게 한다.
  Future<void> _writeOwn(
    String path,
    Directory sharedFiles,
    Directory localFiles,
  ) async {
    final songs = await _songs.exportSnapshot(
      deviceId: deviceId,
      deviceName: _deviceName,
    );
    // 콘티 이미지를 먼저 올린다 — 다른 PC 가 콘티를 보고 파일을 찾을 때 있어야 한다.
    final contis = await _contis.export(
      deviceId: deviceId,
      sharedFiles: sharedFiles,
      localFiles: localFiles,
    );
    final snapshot = songs.withContis(contis.contis, contis.deleted);
    final text = jsonEncode(snapshot.toJson());
    final file = File(path);
    if (await file.exists() && await file.readAsString() == text) return;
    final temp = File('$path.tmp');
    await temp.writeAsString(text, flush: true);
    try {
      await temp.rename(path);
    } on FileSystemException {
      await file.writeAsString(text, flush: true);
      await temp.delete().catchError((_) => temp);
    }
  }
}
