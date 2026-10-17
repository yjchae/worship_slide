import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/worship_conti.dart';
import 'app_logger.dart';
import 'atomic_file.dart';
import 'conti_cloud_repository.dart';
import 'praise_database.dart';
import 'song_sync_repository.dart';
import 'sync_snapshot.dart';
import 'worship_conti_repository.dart';

/// 동기화 화면·상태 줄에 보여 줄 상태.
@immutable
class SyncStatus {
  const SyncStatus({
    this.folder,
    this.syncing = false,
    this.lastSyncAt,
    this.lastError,
    this.peers = const [],
    this.hasLocalChanges = false,
  });

  /// 사용자가 고른 공유 폴더. null 이면 동기화 꺼짐.
  final String? folder;
  final bool syncing;
  final DateTime? lastSyncAt;
  final String? lastError;

  /// 같은 폴더를 쓰는 다른 PC 이름(마지막으로 맞췄을 때).
  final List<String> peers;

  /// 이 PC 에서 찬양을 고친 뒤 아직 '찬양 동기화'를 안 눌렀다.
  final bool hasLocalChanges;

  bool get enabled => folder != null;

  SyncStatus copyWith({
    bool? syncing,
    DateTime? lastSyncAt,
    String? Function()? lastError,
    List<String>? peers,
    bool? hasLocalChanges,
  }) => SyncStatus(
    folder: folder,
    syncing: syncing ?? this.syncing,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    lastError: lastError != null ? lastError() : this.lastError,
    peers: peers ?? this.peers,
    hasLocalChanges: hasLocalChanges ?? this.hasLocalChanges,
  );
}

/// 프로그램을 켤 때 본 "서버(공유 폴더)에 있는 새 것". DB 는 건드리지 않고 센 값이다.
class SyncCheck {
  const SyncCheck({
    this.songs = const SyncMergeResult(),
    this.newContis = const [],
  });

  /// '찬양 동기화'를 누르면 이 PC 에 생길 변화(새 찬양·바뀐 찬양·지운 찬양).
  final SyncMergeResult songs;

  /// 클라우드에 있는데 이 PC 에 없는 콘티.
  final List<CloudConti> newContis;

  bool get hasAnything => songs.changed || newContis.isNotEmpty;
}

/// 공유 폴더(Google Drive 공유 드라이브 등)로 여러 PC 의 찬양을 맞추고 콘티를 주고받는다.
/// **모두 손으로 한다** — 찬양은 '찬양 동기화' 버튼, 콘티는 '클라우드에 올리기/내려받기'.
/// 자동으로 하는 일은 프로그램을 켤 때 한 번 서버를 보고 새 것이 있으면 알리는 것([checkForUpdates])뿐이다.
///
/// SQLite 파일 자체를 드라이브에 두면 두 PC 가 동시에 쓸 때 파일이 깨지거나 드라이브가 사본을
/// 만든다. 그래서 **PC 마다 자기 찬양 전부를 JSON 파일 하나로만 쓰고**
/// (`<폴더>/worship_slides_sync/<기기 id>.json`), 동기화를 누르면 다른 PC 들의 파일을 읽어 합친다.
/// 앱은 드라이브 API 를 모른다 — Google Drive 데스크톱 앱이 PC 에 보여 주는 폴더면 된다.
class SyncService {
  SyncService({
    SongSyncRepository? songs,
    ContiCloudRepository? contiCloud,
    WorshipContiRepository? contis,
    Future<Directory> Function()? settingsDirectory,
    String? deviceName,
    DateTime Function()? clock,
  }) : _songs = songs ?? SongSyncRepository(),
       _contis = contis ?? WorshipContiRepository(),
       _settingsDirectory = settingsDirectory ?? getApplicationSupportDirectory,
       _deviceName = deviceName ?? Platform.localHostname,
       _clock = clock ?? DateTime.now {
    _cloud = contiCloud ?? ContiCloudRepository(contis: _contis);
  }

  static const _settingsFile = 'song_sync.json';

  final SongSyncRepository _songs;
  final WorshipContiRepository _contis;
  late final ContiCloudRepository _cloud;
  final Future<Directory> Function() _settingsDirectory;
  final String _deviceName;
  final DateTime Function() _clock;

  final status = ValueNotifier(const SyncStatus());

  String? _deviceId;

  /// 이번 실행이 쓰는 내 파일 표시([SyncSnapshot.writer]). 설정에는 남기지 않는다 —
  /// 지난 실행의 파일은 [_lastWrittenAt] 으로 알아본다.
  final String _writer = newSongUid();

  /// 이 PC 가 마지막으로 내 파일을 쓴 시각(ms). 설정에 남기고, **파일보다 먼저** 저장한다.
  /// 그래서 내 파일의 시각이 이보다 늦고 표시도 내 것이 아니면 다른 PC 가 같은 기기 id 로
  /// 쓴 것이다(설정 폴더째 복제·마이그레이션). 폴더를 바꿨다 돌아와도 옛 파일은 이보다 이르다.
  int? _lastWrittenAt;

  /// 내가 마지막으로 쓴 내 파일의 상태. 바뀌었으면 누가 썼는지 확인한다.
  FileStat? _ownStat;

  /// 마지막으로 쓴 내 파일 내용(쓴 시각 뺌). 같으면 다시 쓰지 않는다.
  String? _lastWrittenText;

  Future<void> _queue = Future.value();
  bool _disposed = false;

  String get deviceId => _deviceId ?? '';
  String get deviceName => _deviceName;

  Future<File> get _settings async =>
      File(p.join((await _settingsDirectory()).path, _settingsFile));

  /// 저장해 둔 설정을 읽는다. 동기화는 하지 않는다.
  /// 큐로 돈다 — 다 읽기 전에 [setFolder] 가 기기 id 없는 설정을 저장하지 않게.
  Future<void> load() => _enqueue(() async {
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
        _lastWrittenAt = json['written_at'] is int
            ? json['written_at'] as int
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
    _setStatus(SyncStatus(folder: folder, lastError: settingsError));
  });

  /// 공유 폴더를 바꾼다. null 이면 동기화를 끈다(공유 폴더의 파일은 지우지 않는다).
  Future<void> setFolder(String? folder) => _enqueue(() async {
    await _saveSettings(folder);
    _lastWrittenText = null;
    _ownStat = null;
    _setStatus(
      SyncStatus(folder: folder, hasLocalChanges: status.value.hasLocalChanges),
    );
  });

  /// 이 PC 에서 찬양을 고쳤을 때 — 상태 줄에 '동기화 안 한 변경'으로만 보인다.
  void markLocalChanged() {
    if (_disposed || status.value.hasLocalChanges) return;
    _setStatus(status.value.copyWith(hasLocalChanges: true));
  }

  /// **'찬양 동기화' 버튼.** 다른 PC 들의 새 찬양·바뀐 찬양(지운 찬양 포함)을 이 PC 에 합치고,
  /// 이 PC 의 찬양을 공유 폴더에 쓴다. 폴더가 없거나 실패하면 null(이유는 [status] 의 lastError).
  Future<SyncMergeResult?> syncSongs() => _enqueue(() async {
    final dirs = await _prepare();
    if (dirs == null) return null;
    _setStatus(status.value.copyWith(syncing: true));
    var merged = false;
    try {
      final read = await _readSnapshots(dirs.remoteFiles);
      final result = await _songs.merge(read.snapshots);
      merged = true;
      await _writeOwn(dirs.ownPath);
      _setStatus(
        status.value.copyWith(
          syncing: false,
          lastSyncAt: _clock(),
          hasLocalChanges: false,
          peers: _peerNames(read.snapshots),
          lastError: () => read.unreadable == 0
              ? null
              : '다른 PC 파일 ${read.unreadable}개를 읽지 못했습니다'
                    '(드라이브가 아직 내려받는 중일 수 있습니다). 잠시 뒤에 다시 눌러 주세요.',
        ),
      );
      if (result.changed) {
        await AppLogger.instance.info(
          '[sync] 찬양 추가 ${result.addedCount} · 수정 ${result.updatedCount} · 삭제 ${result.deletedCount}',
        );
      }
      return result;
    } catch (error, stack) {
      await AppLogger.instance.error('찬양 동기화 실패', error, stack);
      _fail(
        error,
        // 합치기는 끝났는데 내 파일을 못 썼으면, 다음에 누를 때 다시 쓰게 표시해 둔다.
        hasLocalChanges: merged || status.value.hasLocalChanges,
      );
      return null;
    }
  });

  /// **프로그램을 켤 때 한 번.** 서버에 새 찬양·바뀐 찬양·새 콘티가 있는지만 본다(DB 는 그대로).
  /// 폴더가 꺼져 있거나 못 읽으면 null.
  Future<SyncCheck?> checkForUpdates() => _enqueue(() async {
    final dirs = await _prepare();
    if (dirs == null) return null;
    try {
      final read = await _readSnapshots(dirs.remoteFiles);
      final songs = await _songs.preview(read.snapshots);
      final local = await _contis.contisByUid();
      final cloud = await _cloud.list(status.value.folder!);
      _setStatus(status.value.copyWith(peers: _peerNames(read.snapshots)));
      return SyncCheck(
        songs: songs,
        newContis: [
          for (final c in cloud)
            if (!local.containsKey(c.uid)) c,
        ],
      );
    } catch (error, stack) {
      await AppLogger.instance.error('동기화 확인 실패', error, stack);
      return null;
    }
  });

  // ── 콘티 클라우드 (손으로 올리기·내려받기) ────────────────────────────

  /// 클라우드 콘티 목록과, 그중 이 PC 에 이미 있는 것(uid → 이 PC 콘티).
  Future<({List<CloudConti> cloud, Map<String, WorshipConti> local})>
  listCloudContis() async {
    final folder = _requireFolder();
    return (
      cloud: await _cloud.list(folder),
      local: await _contis.contisByUid(),
    );
  }

  Future<void> uploadConti(WorshipConti conti) =>
      _cloud.upload(_requireFolder(), conti, deviceName: _deviceName);

  Future<int> downloadConti(CloudConti conti) =>
      _cloud.download(_requireFolder(), conti);

  Future<void> deleteCloudConti(CloudConti conti) =>
      _cloud.delete(_requireFolder(), conti);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
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

  void _fail(Object error, {bool? hasLocalChanges}) => _setStatus(
    status.value.copyWith(
      syncing: false,
      hasLocalChanges: hasLocalChanges,
      lastError: () =>
          error is FileSystemException ? error.message : error.toString(),
    ),
  );

  String _requireFolder() {
    final folder = status.value.folder;
    if (folder == null) {
      throw const FileSystemException('동기화 폴더를 먼저 골라 주세요.');
    }
    return folder;
  }

  static List<String> _peerNames(List<SyncSnapshot> snapshots) => [
    for (final s in snapshots) s.deviceName.isEmpty ? s.deviceId : s.deviceName,
  ];

  /// 공유 폴더를 확인하고 내 파일 경로·다른 PC 파일을 찾는다. 못 쓰면 null(상태에 오류).
  Future<({String ownPath, List<File> remoteFiles})?> _prepare() async {
    final folder = status.value.folder;
    if (_disposed || folder == null) return null;
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
        await _saveSettings(folder);
        await AppLogger.instance.info(
          '[sync] 기기 id 가 겹쳐 새로 만듦 $old → $deviceId',
        );
      }
      final ownPath = p.join(dir.path, '$deviceId.json');
      return (ownPath: ownPath, remoteFiles: await _remoteFiles(dir, ownPath));
    } catch (error, stack) {
      await AppLogger.instance.error('동기화 폴더 확인 실패', error, stack);
      _fail(error);
      return null;
    }
  }

  /// 임시 파일에 쓰고 이름을 바꾼다 — 쓰는 도중 꺼져도 설정이 반쯤 남지 않게. 실패하면 false.
  Future<bool> _saveSettings(String? folder) async {
    try {
      await atomicWriteString(
        await _settings,
        jsonEncode({
          'folder': folder,
          'device_id': _deviceId,
          'written_at': _lastWrittenAt,
        }),
      );
      return true;
    } catch (error, stack) {
      await AppLogger.instance.error('동기화 설정 저장 실패', error, stack);
      return false;
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

  /// 다른 PC 파일을 읽어 푼다. 곡이 수천 곡이면 파일마다 몇 MB 라서 화면 스레드가
  /// 멈추지 않게 별도 isolate 에서 읽고 푼다. 내 기기 id 로 된 파일은 뺀다.
  Future<({List<SyncSnapshot> snapshots, int unreadable})> _readSnapshots(
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
              // 지운 기록 비교에 쓰는 곡 내용 해시를 여기서 미리 계산해 둔다(가사 전체를 훑는다 —
              // 화면 스레드에서 하면 발표 넘기기가 끊긴다). late final 이라 그대로 넘어간다.
              if (snapshot != null && snapshot.deletedContent.isNotEmpty) {
                for (final song in snapshot.songs) {
                  song.contentHash;
                }
              }
              return (snapshot: snapshot, error: null);
            } catch (error) {
              return (snapshot: null, error: '$path: $error');
            }
          }(),
      ],
    );
    final result = <SyncSnapshot>[];
    var unreadable = 0;
    for (final r in read) {
      if (r.snapshot != null) {
        if (r.snapshot!.deviceId != deviceId) result.add(r.snapshot!);
      } else if (r.error != null) {
        // 드라이브가 아직 내려받는 중이거나 다른 PC 가 쓰는 중일 수 있다.
        unreadable += 1;
        await AppLogger.instance.info('[sync] 읽기 건너뜀 ${r.error}');
      }
    }
    return (snapshots: result, unreadable: unreadable);
  }

  /// 내 파일은 내용이 바뀌었거나 사라졌을 때만 쓴다(드라이브가 쓸데없이 올리지 않게).
  /// 임시 파일에 쓰고 이름을 바꿔, 다른 PC 가 반쯤 쓴 파일을 읽지 않게 한다.
  Future<void> _writeOwn(String path) async {
    final snapshot = await _songs.exportSnapshot(
      deviceId: deviceId,
      deviceName: _deviceName,
      writer: _writer,
    );
    // 쓴 시각은 내용 비교에서 뺀다 — 넣으면 바뀐 게 없어도 매번 다시 쓴다.
    final body = await Isolate.run(() => jsonEncode(snapshot.toJson()));
    final file = File(path);
    if (body == _lastWrittenText && await file.exists()) return;
    // 시각은 늘 앞으로만 간다(시계가 같은 ms 를 돌려줘도).
    final now = _clock().millisecondsSinceEpoch;
    final writtenAt = now > (_lastWrittenAt ?? 0) ? now : _lastWrittenAt! + 1;
    final text = '{"written_at":$writtenAt,${body.substring(1)}';
    // 쓴 시각을 설정에 먼저 남긴다. 못 남기면 쓰지 않는다 — 남기지 못한 채 쓰면 다음 실행이
    // 내 파일을 "다른 PC 가 쓴 것"으로 오해한다.
    final previous = _lastWrittenAt;
    _lastWrittenAt = writtenAt;
    if (!await _saveSettings(status.value.folder)) {
      _lastWrittenAt = previous;
      throw const FileSystemException('동기화 설정을 저장하지 못했습니다.');
    }
    try {
      await atomicWriteString(file, text);
    } on FileSystemException {
      // 드라이브가 파일을 잡고 있어 이름 바꾸기가 막히면 바로 덮어쓴다.
      await file.writeAsString(text, flush: true);
    }
    _lastWrittenText = body;
    _ownStat = await file.stat();
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
    final found = await Isolate.run(() {
      try {
        final json = jsonDecode(File(path).readAsStringSync());
        if (json is! Map) return null;
        return (
          writer: json['writer'] is String ? json['writer'] as String : '',
          at: json['written_at'] is int ? json['written_at'] as int : 0,
        );
      } catch (_) {
        return null;
      }
    });
    if (found == null || found.writer.isEmpty) return false;
    if (found.writer == _writer) {
      _ownStat = stat;
      return false;
    }
    // 이번 실행에서 내가 쓴 뒤에 다른 표시로 바뀌었다 = 다른 PC.
    if (mine != null) return true;
    // 이번 실행에서 처음 본다: 지난번에 내가 쓴 뒤에 누가 썼으면 다른 PC.
    final mineAt = _lastWrittenAt;
    return mineAt != null && found.at > mineAt;
  }
}
