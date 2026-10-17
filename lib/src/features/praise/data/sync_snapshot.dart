import 'dart:convert';

/// 공유 폴더에 올리는 곡 한 곡. 보조 언어 가사(제목에 묶여 있다)도 같이 싣는다.
class SyncSong {
  const SyncSong({
    required this.uid,
    required this.updatedAt,
    required this.title,
    required this.fileName,
    required this.lyrics,
    required this.englishLyrics,
    required this.translations,
  });

  final String uid;
  final int updatedAt;
  final String title;
  final String fileName;
  final String lyrics;
  final String englishLyrics;

  /// 언어 → 가사. '영어'는 [englishLyrics] 가 맡으므로 여기 없다.
  final Map<String, String> translations;

  /// 따로 가져온 같은 곡을 알아보는 키(제목·원본·영어 가사가 똑같음).
  String get contentKey => '$title\u0000$lyrics\u0000$englishLyrics';

  /// 고친 시각이 같을 때 어느 쪽을 쓸지 정하는 키. PC 마다 같은 답이 나와야 한다.
  String get tieKey =>
      '$contentKey\u0000$fileName\u0000${jsonEncode(_sorted(translations))}';

  /// [other] 보다 이 곡이 더 최신이면 true.
  bool winsOver(SyncSong other) => updatedAt != other.updatedAt
      ? updatedAt > other.updatedAt
      : tieKey.compareTo(other.tieKey) > 0;

  SyncSong withUid(String newUid) => SyncSong(
    uid: newUid,
    updatedAt: updatedAt,
    title: title,
    fileName: fileName,
    lyrics: lyrics,
    englishLyrics: englishLyrics,
    translations: translations,
  );

  Map<String, Object?> toJson() => {
    'uid': uid,
    'updated_at': updatedAt,
    'title': title,
    'file_name': fileName,
    'lyrics': lyrics,
    'english_lyrics': englishLyrics,
    if (translations.isNotEmpty) 'translations': _sorted(translations),
  };

  static SyncSong? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final uid = raw['uid'];
    final title = raw['title'];
    final lyrics = raw['lyrics'];
    if (uid is! String ||
        uid.isEmpty ||
        title is! String ||
        lyrics is! String) {
      return null;
    }
    final translations = raw['translations'];
    return SyncSong(
      uid: uid,
      updatedAt: (raw['updated_at'] as num?)?.toInt() ?? 0,
      title: title,
      fileName: raw['file_name'] as String? ?? '',
      lyrics: lyrics,
      englishLyrics: raw['english_lyrics'] as String? ?? '',
      translations: translations is Map
          ? {
              for (final e in translations.entries)
                if (e.key is String && e.value is String)
                  e.key as String: e.value as String,
            }
          : const {},
    );
  }

  static Map<String, String> _sorted(Map<String, String> map) => {
    for (final key in map.keys.toList()..sort()) key: map[key]!,
  };
}

/// PC 한 대가 공유 폴더에 쓰는 내용 전부. PC 마다 자기 파일 하나만 쓰므로
/// 두 PC 가 같은 파일을 동시에 고쳐 생기는 충돌(드라이브의 "사본" 파일)이 없다.
class SyncSnapshot {
  const SyncSnapshot({
    required this.deviceId,
    required this.deviceName,
    required this.songs,
    required this.deleted,
    required this.aliases,
    this.contis = const [],
    this.contiDeleted = const {},
  });

  static const format = 'worship_slides_song_sync';

  final String deviceId;
  final String deviceName;
  final List<SyncSong> songs;

  /// 지운 곡 uid → 지운 시각.
  final Map<String, int> deleted;

  /// 합쳐진 옛 uid → 지금 uid.
  final Map<String, String> aliases;

  final List<SyncConti> contis;

  /// 지운 콘티 uid → 지운 시각.
  final Map<String, int> contiDeleted;

  SyncSnapshot withContis(List<SyncConti> contis, Map<String, int> deleted) =>
      SyncSnapshot(
        deviceId: deviceId,
        deviceName: deviceName,
        songs: songs,
        deleted: this.deleted,
        aliases: aliases,
        contis: contis,
        contiDeleted: deleted,
      );

  Map<String, Object?> toJson() => {
    'format': format,
    'version': 1,
    'device_id': deviceId,
    'device_name': deviceName,
    'songs': [for (final song in songs) song.toJson()],
    'deleted': deleted,
    'aliases': aliases,
    'contis': [for (final conti in contis) conti.toJson()],
    'conti_deleted': contiDeleted,
  };

  static SyncSnapshot? fromJson(Object? raw) {
    if (raw is! Map || raw['format'] != format) return null;
    final songs = raw['songs'];
    final deleted = raw['deleted'];
    final aliases = raw['aliases'];
    final contis = raw['contis'];
    return SyncSnapshot(
      deviceId: raw['device_id'] as String? ?? '',
      deviceName: raw['device_name'] as String? ?? '',
      songs: songs is List
          ? songs.map(SyncSong.fromJson).whereType<SyncSong>().toList()
          : const [],
      deleted: _times(deleted),
      aliases: aliases is Map
          ? {
              for (final e in aliases.entries)
                if (e.key is String && e.value is String)
                  e.key as String: e.value as String,
            }
          : const {},
      contis: contis is List
          ? contis.map(SyncConti.fromJson).whereType<SyncConti>().toList()
          : const [],
      contiDeleted: _times(raw['conti_deleted']),
    );
  }

  static Map<String, int> _times(Object? raw) => raw is Map
      ? {
          for (final e in raw.entries)
            if (e.key is String && e.value is num)
              e.key as String: (e.value as num).toInt(),
        }
      : const {};
}

/// 공유 폴더에 올리는 저장 콘티 하나. 콘티는 저장하면 고치지 않으므로(다시 저장 = 새 콘티)
/// 실제로는 추가·삭제만 넘어간다. 그래도 곡처럼 "나중 것이 이긴다"로 맞춘다.
class SyncConti {
  const SyncConti({
    required this.uid,
    required this.updatedAt,
    required this.name,
    required this.createdAt,
    required this.items,
    required this.files,
  });

  final String uid;
  final int updatedAt;
  final String name;
  final int createdAt;

  /// `worship_conti_items` 행(id·conti_id·song_id·원본 PPT 경로 뺌). 곡 항목은 `song_uid` 를 싣는다.
  /// 이미지 경로 자리는 [fileRef] 로 바뀌어 있다.
  final List<Map<String, Object?>> items;

  /// 이 콘티가 쓰는 공유 폴더 `files/` 안 파일 이름. 다 내려와 있어야 받는다.
  final List<String> files;

  /// 경로 자리에 넣는 공유 파일 표시. 표시가 없는 경로는 그 PC 에 없던 파일(유실)이다.
  static const _filePrefix = 'sync-file:';

  static String fileRef(String name) => '$_filePrefix$name';

  /// [fileRef] 면 파일 이름, 아니면 null.
  static String? fileName(String? value) =>
      value != null && value.startsWith(_filePrefix)
      ? value.substring(_filePrefix.length)
      : null;

  bool winsOver(SyncConti other) => updatedAt != other.updatedAt
      ? updatedAt > other.updatedAt
      : jsonEncode(toJson()).compareTo(jsonEncode(other.toJson())) > 0;

  Map<String, Object?> toJson() => {
    'uid': uid,
    'updated_at': updatedAt,
    'name': name,
    'created_at': createdAt,
    'items': items,
    'files': files,
  };

  static SyncConti? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final uid = raw['uid'];
    final name = raw['name'];
    final items = raw['items'];
    final files = raw['files'];
    if (uid is! String || uid.isEmpty || name is! String || items is! List) {
      return null;
    }
    return SyncConti(
      uid: uid,
      updatedAt: (raw['updated_at'] as num?)?.toInt() ?? 0,
      name: name,
      createdAt: (raw['created_at'] as num?)?.toInt() ?? 0,
      items: [
        for (final item in items)
          if (item is Map)
            {
              for (final e in item.entries)
                if (e.key is String) e.key as String: e.value,
            },
      ],
      files: files is List ? files.whereType<String>().toList() : const [],
    );
  }
}

/// 합치기 한 번에 바뀐 수.
class SyncMergeResult {
  const SyncMergeResult({
    this.addedCount = 0,
    this.updatedCount = 0,
    this.deletedCount = 0,
    this.pendingCount = 0,
  });

  final int addedCount;
  final int updatedCount;
  final int deletedCount;

  /// 콘티만: 파일이 아직 공유 폴더에 다 안 올라와 이번엔 못 받은 수.
  final int pendingCount;

  bool get changed => addedCount + updatedCount + deletedCount > 0;
}
