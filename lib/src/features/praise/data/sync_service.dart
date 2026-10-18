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
import 'drive_sync_store.dart';
import 'praise_database.dart';
import 'song_sync_repository.dart';
import 'sync_snapshot.dart';
import 'sync_store.dart';
import 'worship_conti_repository.dart';

/// 동기화 화면·상태 줄에 보여 줄 상태.
@immutable
class SyncStatus {
  const SyncStatus({
    this.folder,
    this.syncing = false,
    this.lastSyncAt,
    this.lastError,
    this.warning,
    this.peers = const [],
    this.hasLocalChanges = false,
  });

  /// 연결된 저장소 이름(구글 드라이브 · 폴더). null 이면 동기화 꺼짐(접속 키 없음).
  final String? folder;
  final bool syncing;
  final DateTime? lastSyncAt;
  final String? lastError;

  /// 맞추긴 했지만 알릴 것(다른 PC 파일 몇 개를 못 읽음 등). 실패가 아니다.
  final String? warning;

  /// 같은 폴더를 쓰는 다른 PC 이름(마지막으로 맞췄을 때).
  final List<String> peers;

  /// 이 PC 에서 찬양을 고친 뒤 아직 '찬양 동기화'를 안 눌렀다.
  final bool hasLocalChanges;

  bool get enabled => folder != null;

  SyncStatus copyWith({
    bool? syncing,
    DateTime? lastSyncAt,
    String? Function()? lastError,
    String? Function()? warning,
    List<String>? peers,
    bool? hasLocalChanges,
  }) => SyncStatus(
    folder: folder,
    syncing: syncing ?? this.syncing,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    lastError: lastError != null ? lastError() : this.lastError,
    warning: warning != null ? warning() : this.warning,
    peers: peers ?? this.peers,
    hasLocalChanges: hasLocalChanges ?? this.hasLocalChanges,
  );
}

/// 프로그램을 켤 때 본 "서버(구글 드라이브)에 있는 새 것". DB 는 건드리지 않고 센 값이다.
class SyncCheck {
  const SyncCheck({
    this.songs = const SyncMergeResult(),
    this.newContis = const [],
    this.localChanges = false,
  });

  /// '찬양 동기화'를 누르면 이 PC 에 생길 변화(새 찬양·바뀐 찬양·지운 찬양).
  final SyncMergeResult songs;

  /// 클라우드에 있는데 이 PC 에 없고, 전에 알린 적도 없는 콘티.
  final List<CloudConti> newContis;

  /// 이 PC 에서 고친 찬양을 아직 올리지 않았다(지난번에 동기화 없이 껐다 등).
  final bool localChanges;

  bool get hasAnything => songs.changed || newContis.isNotEmpty || localChanges;
}

/// 구글 드라이브 폴더 하나로 여러 PC 의 찬양을 맞추고 콘티를 주고받는다.
/// **모두 손으로 한다** — 찬양은 '찬양 동기화' 버튼, 콘티는 '클라우드에 올리기/내려받기'.
/// 자동으로 하는 일은 프로그램을 켤 때 한 번 서버를 보고 새 것이 있으면 알리는 것([checkForUpdates])뿐이다.
///
/// SQLite 파일 자체를 드라이브에 두면 두 PC 가 동시에 쓸 때 파일이 깨지거나 드라이브가 사본을
/// 만든다. 그래서 **PC 마다 자기 찬양 전부를 JSON 파일 하나로만 쓰고**
/// (`<기기 id>.json`), 동기화를 누르면 다른 PC 들의 파일을 읽어 합친다.
/// 드라이브에는 Drive API 로 직접 붙는다([DriveSyncStore]) — PC 에 드라이브 앱도, 로그인도 필요 없고
/// 관리자가 건넨 접속 키를 한 번 넣으면 된다([connect]).
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
  static const _keyFile = 'sync_key.txt';

  final SongSyncRepository _songs;
  final WorshipContiRepository _contis;
  late final ContiCloudRepository _cloud;
  final Future<Directory> Function() _settingsDirectory;
  final String _deviceName;
  final DateTime Function() _clock;

  final status = ValueNotifier(const SyncStatus());

  String? _deviceId;

  SyncStore? _store;

  /// 이번 실행이 쓰는 내 파일 표시([SyncSnapshot.writer]). 설정에는 남기지 않는다 —
  /// 지난 실행의 파일은 [_lastWrittenAt] 으로 알아본다.
  final String _writer = newSongUid();

  /// 이 PC 가 마지막으로 내 파일을 쓴 시각(ms). 설정에 남기고, **파일보다 먼저** 저장한다.
  /// 그래서 내 파일의 시각이 이보다 늦고 표시도 내 것이 아니면 다른 PC 가 같은 기기 id 로
  /// 쓴 것이다(설정 폴더째 복제·마이그레이션). 폴더를 바꿨다 돌아와도 옛 파일은 이보다 이르다.
  int? _lastWrittenAt;

  /// 내가 마지막으로 쓴 내 파일의 상태. 바뀌었으면 누가 썼는지 확인한다.
  SyncEntry? _ownEntry;

  /// 마지막으로 쓴 내 파일 내용(쓴 시각 뺌). 같으면 다시 쓰지 않는다.
  String? _lastWrittenText;

  /// 찬양을 고칠 때마다 1 씩 는다. 동기화 도중에 고친 것을 "다 올렸다"로 지우지 않으려고
  /// 시작할 때 값과 끝날 때 값을 비교한다.
  int _localChangeCount = 0;

  /// 켤 때 이미 알린(또는 받은) 클라우드 콘티 uid — 받지 않기로 한 콘티를 켤 때마다 다시 알리지 않게.
  final _seenContis = <String>{};

  Future<void> _queue = Future.value();
  bool _disposed = false;

  String get deviceId => _deviceId ?? '';
  String get deviceName => _deviceName;

  Future<File> get _settings async =>
      File(p.join((await _settingsDirectory()).path, _settingsFile));

  Future<File> get _key async =>
      File(p.join((await _settingsDirectory()).path, _keyFile));

  /// 저장해 둔 설정·접속 키를 읽는다. 동기화는 하지 않는다.
  /// 큐로 돈다 — 다 읽기 전에 [connect] 가 기기 id 없는 설정을 저장하지 않게.
  Future<void> load() => _enqueue(() async {
    String? settingsError;
    try {
      final file = await _settings;
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json is! Map) throw const FormatException('설정 모양이 아닙니다');
        _deviceId = json['device_id'] is String
            ? json['device_id'] as String
            : null;
        _lastWrittenAt = json['written_at'] is int
            ? json['written_at'] as int
            : null;
        final seen = json['seen_contis'];
        if (seen is List) _seenContis.addAll(seen.whereType<String>());
      }
    } catch (error, stack) {
      // 깨진 설정을 덮어쓰지 않는다 — 기기 id 가 바뀌면 내 파일을 남의 것으로 본다.
      await AppLogger.instance.error('동기화 설정 읽기 실패', error, stack);
      settingsError = '동기화 설정을 읽지 못해 꺼 두었습니다. 접속 키를 다시 넣어 주세요.';
    }
    if (_deviceId == null || _deviceId!.isEmpty) {
      _deviceId = newSongUid();
      if (settingsError == null) await _saveSettings();
    }
    if (settingsError == null) {
      try {
        final key = await _key;
        if (await key.exists()) {
          _store = DriveSyncStore(DriveKey.parse(await key.readAsString()));
        }
      } catch (error, stack) {
        await AppLogger.instance.error('접속 키 읽기 실패', error, stack);
        settingsError = '저장된 접속 키를 읽지 못했습니다. 다시 넣어 주세요.';
      }
    }
    _setStatus(SyncStatus(folder: _store?.label, lastError: settingsError));
  });

  /// 관리자가 건넨 접속 키를 확인하고(드라이브 폴더까지 열어 본다) 이 PC 에 저장한다.
  /// 키가 틀리거나 못 열면 [FormatException]·[FileSystemException](메시지를 그대로 보인다).
  Future<void> connect(String keyText) => _enqueue(() async {
    final store = DriveSyncStore(DriveKey.parse(keyText));
    await store.check();
    await atomicWriteString(await _key, keyText.trim());
    _useStore(store);
  });

  /// 접속 키를 이 PC 에서 지운다(드라이브의 파일은 그대로).
  Future<void> disconnect() => _enqueue(() async {
    final key = await _key;
    if (await key.exists()) await key.delete();
    _useStore(null);
  });

  /// 테스트: 드라이브 대신 [store] 를 쓴다.
  @visibleForTesting
  Future<void> useStore(SyncStore? store) => _enqueue(() async {
    _useStore(store);
  });

  void _useStore(SyncStore? store) {
    _store = store;
    _lastWrittenText = null;
    _ownEntry = null;
    _setStatus(
      SyncStatus(
        folder: store?.label,
        hasLocalChanges: status.value.hasLocalChanges,
      ),
    );
  }

  /// 이 PC 에서 찬양을 고쳤을 때 — 상태 줄에 '동기화 안 한 변경'으로만 보인다.
  void markLocalChanged() {
    _localChangeCount += 1;
    if (_disposed || status.value.hasLocalChanges) return;
    _setStatus(status.value.copyWith(hasLocalChanges: true));
  }

  /// **'찬양 동기화' 버튼.** 다른 PC 들의 새 찬양·바뀐 찬양(지운 찬양 포함)을 이 PC 에 합치고,
  /// 이 PC 의 찬양을 드라이브에 쓴다. 키가 없거나 실패하면 null(이유는 [status] 의 lastError).
  Future<SyncMergeResult?> syncSongs() {
    // 누른 순간의 값 — 그 뒤에 고친 것은(이번에 같이 올라갔더라도) "안 올림"으로 남긴다. 숨기는 것보다 낫다.
    final changesAtStart = _localChangeCount;
    return _enqueue(() async {
      final dirs = await _prepare();
      if (dirs == null) return null;
      _setStatus(status.value.copyWith(syncing: true));
      var merged = false;
      try {
        final read = await _readSnapshots(dirs.store, dirs.remote);
        final result = await _songs.merge(read.snapshots);
        merged = true;
        await _writeOwn(dirs.store, dirs.own);
        _setStatus(
          status.value.copyWith(
            syncing: false,
            lastSyncAt: _clock(),
            // 동기화하는 동안 또 고쳤으면 그건 아직 안 올라갔다.
            hasLocalChanges: _localChangeCount != changesAtStart,
            peers: _peerNames(read.snapshots),
            lastError: () => null,
            warning: () => read.unreadable == 0
                ? null
                : '다른 PC 파일 ${read.unreadable}개를 읽지 못했습니다. 잠시 뒤에 다시 눌러 주세요.',
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
  }

  /// **프로그램을 켤 때 한 번.** 서버에 새 찬양·바뀐 찬양·새 콘티가 있는지만 본다(DB 는 그대로).
  /// 키가 없거나 못 읽으면 null.
  Future<SyncCheck?> checkForUpdates() => _enqueue(() async {
    final dirs = await _prepare();
    if (dirs == null) return null;
    try {
      final read = await _readSnapshots(dirs.store, dirs.remote);
      final songs = await _songs.preview(read.snapshots);
      final localChanges = !await _ownFileUpToDate(dirs.store, dirs.own);
      final local = await _contis.contisByUid();
      final cloud = await _cloud.list(dirs.store);
      _setStatus(
        status.value.copyWith(
          peers: _peerNames(read.snapshots),
          hasLocalChanges: localChanges || status.value.hasLocalChanges,
        ),
      );
      return SyncCheck(
        songs: songs,
        localChanges: localChanges,
        newContis: [
          for (final c in cloud)
            if (!local.containsKey(c.uid) && !_seenContis.contains(c.uid)) c,
        ],
      );
    } catch (error, stack) {
      await AppLogger.instance.error('동기화 확인 실패', error, stack);
      return null;
    }
  });

  /// 켤 때 알린 클라우드 콘티를 기억한다 — 다음에 켤 때 다시 "새 콘티"로 알리지 않는다
  /// (클라우드 콘티 창에는 그대로 보인다).
  Future<void> markContisSeen(Iterable<String> uids) => _enqueue(() async {
    final before = _seenContis.length;
    _seenContis.addAll(uids);
    if (_seenContis.length != before) await _saveSettings();
  });

  // ── 콘티 클라우드 (손으로 올리기·내려받기) ────────────────────────────

  /// 클라우드 콘티 목록과, 그중 이 PC 에 이미 있는 것(uid → 이 PC 콘티).
  Future<({List<CloudConti> cloud, Map<String, WorshipConti> local})>
  listCloudContis() async {
    final store = await _requireStore();
    return (
      cloud: await _cloud.list(store),
      local: await _contis.contisByUid(),
    );
  }

  Future<void> uploadConti(WorshipConti conti) async =>
      _cloud.upload(await _requireStore(), conti, deviceName: _deviceName);

  Future<int> downloadConti(CloudConti conti) async {
    final id = await _cloud.download(await _requireStore(), conti);
    await markContisSeen([conti.uid]);
    return id;
  }

  Future<void> deleteCloudConti(CloudConti conti) async =>
      _cloud.delete(await _requireStore(), conti);

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

  /// 연결된 저장소. 키가 없거나 못 열면 던진다.
  Future<SyncStore> _requireStore() async {
    final store = _store;
    if (store == null) {
      throw const FileSystemException('동기화 접속 키를 먼저 넣어 주세요.');
    }
    await store.check();
    return store;
  }

  static List<String> _peerNames(List<SyncSnapshot> snapshots) => [
    for (final s in snapshots) s.deviceName.isEmpty ? s.deviceId : s.deviceName,
  ];

  /// 저장소를 확인하고 내 파일·다른 PC 파일을 찾는다. 못 쓰면 null(상태에 오류).
  Future<({SyncStore store, SyncEntry? own, List<SyncEntry> remote})?>
  _prepare() async {
    final store = _store;
    if (_disposed || store == null) return null;
    try {
      await store.check();
      var entries = await store.list();
      SyncEntry? own() =>
          entries.where((e) => e.name == '$deviceId.json').firstOrNull;
      if (await _ownFileTakenByOther(store, own())) {
        // 설정 폴더째 복제된 다른 PC 가 같은 기기 id 를 쓰고 있다. 이 PC 가 새 id 로 비킨다 —
        // 그대로 두면 서로의 파일을 덮어쓰고 서로를 "나"로 보고 건너뛴다.
        final old = deviceId;
        _deviceId = newSongUid();
        _lastWrittenText = null;
        _ownEntry = null;
        await _saveSettings();
        await AppLogger.instance.info(
          '[sync] 기기 id 가 겹쳐 새로 만듦 $old → $deviceId',
        );
      }
      final mine = own();
      return (
        store: store,
        own: mine,
        remote: [
          for (final e in entries)
            if (e != mine &&
                !e.name.startsWith('.') &&
                !e.name.startsWith(ContiCloudRepository.prefix) &&
                p.extension(e.name).toLowerCase() == '.json')
              e,
        ]..sort((a, b) => a.name.compareTo(b.name)),
      );
    } catch (error, stack) {
      await AppLogger.instance.error('동기화 저장소 확인 실패', error, stack);
      _fail(error);
      return null;
    }
  }

  /// 임시 파일에 쓰고 이름을 바꾼다 — 쓰는 도중 꺼져도 설정이 반쯤 남지 않게. 실패하면 false.
  Future<bool> _saveSettings() async {
    try {
      await atomicWriteString(
        await _settings,
        jsonEncode({
          'device_id': _deviceId,
          'written_at': _lastWrittenAt,
          'seen_contis': _seenContis.toList()..sort(),
        }),
      );
      return true;
    } catch (error, stack) {
      await AppLogger.instance.error('동기화 설정 저장 실패', error, stack);
      return false;
    }
  }

  /// 다른 PC 파일을 받아 푼다. 곡이 수천 곡이면 파일마다 몇 MB 라서 화면 스레드가
  /// 멈추지 않게 별도 isolate 에서 푼다. 내 기기 id 로 된 파일은 뺀다.
  Future<({List<SyncSnapshot> snapshots, int unreadable})> _readSnapshots(
    SyncStore store,
    List<SyncEntry> entries,
  ) async {
    final texts = await Future.wait([
      for (final e in entries)
        () async {
          try {
            return (name: e.name, text: await store.read(e), error: null);
          } on FileSystemException catch (error) {
            return (name: e.name, text: null, error: error.message);
          }
        }(),
    ]);
    final read = await _parseSnapshots(texts);
    final result = <SyncSnapshot>[];
    var unreadable = 0;
    for (final r in read) {
      if (r.snapshot != null) {
        if (r.snapshot!.deviceId != deviceId) result.add(r.snapshot!);
      } else if (r.error != null) {
        // 받다가 끊겼거나 파일이 깨졌다.
        unreadable += 1;
        await AppLogger.instance.info('[sync] 읽기 건너뜀 ${r.error}');
      }
    }
    return (snapshots: result, unreadable: unreadable);
  }

  /// [_readSnapshots] 의 isolate 부분. 따로 뺀 이유 — 같은 함수 안에 두면 클로저가 그 함수의
  /// 변수 묶음을 통째로 붙잡아 `store`(드라이브면 http 클라이언트)까지 isolate 로 보내려다 실패한다.
  static Future<List<({SyncSnapshot? snapshot, String? error})>>
  _parseSnapshots(List<({String name, String? text, String? error})> texts) {
    return Isolate.run(
      () => [
        for (final t in texts)
          () {
            if (t.text == null) {
              return (snapshot: null, error: '${t.name}: ${t.error}');
            }
            try {
              final snapshot = SyncSnapshot.fromJson(jsonDecode(t.text!));
              // 지운 기록 비교에 쓰는 곡 내용 해시를 여기서 미리 계산해 둔다(가사 전체를 훑는다 —
              // 화면 스레드에서 하면 발표 넘기기가 끊긴다). late final 이라 그대로 넘어간다.
              if (snapshot != null && snapshot.deletedContent.isNotEmpty) {
                for (final song in snapshot.songs) {
                  song.contentHash;
                }
              }
              return (snapshot: snapshot, error: null);
            } catch (error) {
              return (snapshot: null, error: '${t.name}: $error');
            }
          }(),
      ],
    );
  }

  Future<String> _ownBody() async {
    final snapshot = await _songs.exportSnapshot(
      deviceId: deviceId,
      deviceName: _deviceName,
      writer: _writer,
    );
    return Isolate.run(() => jsonEncode(snapshot.toJson()));
  }

  /// 내 파일에서 찬양 내용을 담은 칸. 이것만 비교한다 — 쓴 시각·표시·PC 이름이나, 예전 판이
  /// 쓴 콘티 칸(`contis` 등)이 달라도 "안 올린 수정"으로 보지 않게.
  static const _songKeys = [
    'songs',
    'deleted',
    'aliases',
    'deleted_content',
    'translations',
    'translation_deleted',
  ];

  /// 드라이브의 내 파일이 지금 이 PC 의 찬양과 같은지. 다르면 이 PC 에서 고친 찬양을 아직 안
  /// 올린 것이다. 곡이 수천 곡이면 몇 MB 라 비교는 별도 isolate 에서 한다.
  Future<bool> _ownFileUpToDate(SyncStore store, SyncEntry? own) async {
    final snapshot = await _songs.exportSnapshot(
      deviceId: deviceId,
      deviceName: _deviceName,
      writer: _writer,
    );
    String? text;
    if (own != null) {
      try {
        text = await store.read(own);
      } on FileSystemException {
        return false;
      }
    }
    return Isolate.run(() {
      final mine = snapshot.toJson();
      if (text == null) {
        // 아직 올린 적이 없다 — 찬양도 지운 기록도 없으면 올릴 것도 없다.
        return snapshot.songs.isEmpty &&
            snapshot.translations.isEmpty &&
            snapshot.deleted.isEmpty;
      }
      final Object? stored;
      try {
        stored = jsonDecode(text);
      } catch (_) {
        return false;
      }
      if (stored is! Map) return false;
      final theirs = stored;
      return _songKeys.every(
        (key) => jsonEncode(theirs[key]) == jsonEncode(mine[key]),
      );
    });
  }

  /// 내 파일은 내용이 바뀌었거나 사라졌을 때만 쓴다(쓸데없이 올리지 않게).
  Future<void> _writeOwn(SyncStore store, SyncEntry? own) async {
    // 쓴 시각은 내용 비교에서 뺀다 — 넣으면 바뀐 게 없어도 매번 다시 쓴다.
    final body = await _ownBody();
    if (body == _lastWrittenText && own != null) return;
    // 시각은 늘 앞으로만 간다(시계가 같은 ms 를 돌려줘도).
    final now = _clock().millisecondsSinceEpoch;
    final writtenAt = now > (_lastWrittenAt ?? 0) ? now : _lastWrittenAt! + 1;
    final text = '{"written_at":$writtenAt,${body.substring(1)}';
    // 쓴 시각을 설정에 먼저 남긴다. 못 남기면 쓰지 않는다 — 남기지 못한 채 쓰면 다음 실행이
    // 내 파일을 "다른 PC 가 쓴 것"으로 오해한다.
    final previous = _lastWrittenAt;
    _lastWrittenAt = writtenAt;
    if (!await _saveSettings()) {
      _lastWrittenAt = previous;
      throw const FileSystemException('동기화 설정을 저장하지 못했습니다.');
    }
    _ownEntry = await store.write('$deviceId.json', text);
    _lastWrittenText = body;
  }

  /// 내 파일(이 기기 id)을 다른 PC 가 쓰고 있으면 true. 내가 쓴 뒤로 파일이 바뀌었을 때만
  /// 파일 안의 표시(writer)를 읽어 본다.
  Future<bool> _ownFileTakenByOther(SyncStore store, SyncEntry? own) async {
    if (own == null) return false;
    final mine = _ownEntry;
    if (mine != null && own.sameVersion(mine)) return false;
    final String text;
    try {
      text = await store.read(own);
    } on FileSystemException {
      return false;
    }
    final found = await Isolate.run(() {
      try {
        final json = jsonDecode(text);
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
      _ownEntry = own;
      return false;
    }
    // 이번 실행에서 내가 쓴 뒤에 다른 표시로 바뀌었다 = 다른 PC.
    if (mine != null) return true;
    // 이번 실행에서 처음 본다: 지난번에 내가 쓴 뒤에 누가 썼으면 다른 PC.
    final mineAt = _lastWrittenAt;
    return mineAt != null && found.at > mineAt;
  }
}
