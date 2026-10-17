import 'dart:convert';

import 'fnv_hash.dart';

// 남이 쓴 파일이라 값 모양을 믿지 않는다 — 모양이 틀린 값은 없는 것으로 본다(던지지 않는다).
// 파일 하나·레코드 하나가 이상하다고 동기화 전체가 멈추면 안 된다.
String? _str(Object? v) => v is String ? v : null;
int? _int(Object? v) => v is num ? v.toInt() : null;

/// [into] 에 [key] 의 시각을 넣는다. 이미 있으면 더 늦은 쪽을 남긴다(지운 기록 합치기).
void keepLatest(Map<String, int> into, String key, int at) {
  final before = into[key];
  if (before == null || at > before) into[key] = at;
}

/// 합쳐진 uid 를 따라가 지금 uid 를 찾는다(옛 uid → 지금 uid 사슬). 고리가 있어도 멈춘다.
String resolveSongUid(Map<String, String> aliases, String uid) {
  var current = uid;
  for (var i = 0; i < 32; i++) {
    final next = aliases[current];
    if (next == null || next == current) break;
    current = next;
  }
  return current;
}

/// 공유 폴더에 올리는 곡 한 곡. 보조 언어 가사는 곡이 아니라 제목에 묶여 있어서
/// 따로([SyncTranslation]) 싣는다 — 같은 제목의 다른 곡과 같이 쓰기 때문이다.
class SyncSong {
  SyncSong({
    required this.uid,
    required this.updatedAt,
    required this.title,
    required this.fileName,
    required this.lyrics,
    required this.englishLyrics,
  });

  final String uid;
  final int updatedAt;
  final String title;
  final String fileName;
  final String lyrics;
  final String englishLyrics;

  /// 따로 가져온 같은 곡을 알아보는 키(제목·원본·영어 가사가 똑같음).
  late final String contentKey = contentKeyOf(title, lyrics, englishLyrics);

  /// [contentKey] 의 짧은 해시. 지운 곡 기록에 가사 전체 대신 싣는다.
  /// 합치기에서 곡마다 여러 번 쓰므로 한 번만 계산한다.
  late final String contentHash = fnvHex(utf8.encode(contentKey));

  static String contentKeyOf(
    String title,
    String lyrics,
    String englishLyrics,
  ) => '$title\u0000$lyrics\u0000$englishLyrics';

  static String contentHashOf(
    String title,
    String lyrics,
    String englishLyrics,
  ) => fnvHex(utf8.encode(contentKeyOf(title, lyrics, englishLyrics)));

  /// 고친 시각이 같을 때 어느 쪽을 쓸지 정하는 키. PC 마다 같은 답이 나와야 한다.
  String get tieKey => '$contentKey\u0000$fileName';

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
  );

  Map<String, Object?> toJson() => {
    'uid': uid,
    'updated_at': updatedAt,
    'title': title,
    'file_name': fileName,
    'lyrics': lyrics,
    'english_lyrics': englishLyrics,
  };

  static SyncSong? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final uid = _str(raw['uid']);
    final title = _str(raw['title']);
    final lyrics = _str(raw['lyrics']);
    if (uid == null || uid.isEmpty || title == null || lyrics == null) {
      return null;
    }
    return SyncSong(
      uid: uid,
      updatedAt: _int(raw['updated_at']) ?? 0,
      title: title,
      fileName: _str(raw['file_name']) ?? '',
      lyrics: lyrics,
      englishLyrics: _str(raw['english_lyrics']) ?? '',
    );
  }
}

/// 보조 언어 가사 하나 (제목, 언어). 곡과 같이 나중에 고친 쪽이 이긴다.
class SyncTranslation {
  const SyncTranslation({
    required this.title,
    required this.language,
    required this.lyrics,
    required this.updatedAt,
  });

  final String title;
  final String language;
  final String lyrics;
  final int updatedAt;

  String get key => keyOf(title, language);

  static String keyOf(String title, String language) => '$title\u0000$language';

  bool winsOver(SyncTranslation other) => updatedAt != other.updatedAt
      ? updatedAt > other.updatedAt
      : lyrics.compareTo(other.lyrics) > 0;

  Map<String, Object?> toJson() => {
    'title': title,
    'language': language,
    'lyrics': lyrics,
    'updated_at': updatedAt,
  };

  static SyncTranslation? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final title = _str(raw['title']);
    final language = _str(raw['language']);
    final lyrics = _str(raw['lyrics']);
    if (title == null || language == null || lyrics == null) return null;
    return SyncTranslation(
      title: title,
      language: language,
      lyrics: lyrics,
      updatedAt: _int(raw['updated_at']) ?? 0,
    );
  }
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
    this.writer = '',
    this.writtenAt = 0,
    this.deletedContent = const {},
    this.translations = const [],
    this.translationDeleted = const {},
    this.contis = const [],
    this.contiDeleted = const {},
  });

  static const format = 'worship_slides_song_sync';

  final String deviceId;
  final String deviceName;

  /// 이 파일을 쓴 앱 실행마다 새로 만드는 표시. 설정 폴더째 복제된 두 PC 가 같은 기기 id 로
  /// 서로의 파일을 덮어쓰는지 알아보는 데 쓴다([SyncService]).
  final String writer;

  /// 이 파일을 쓴 시각(ms, 그 PC 기준). [writer] 와 같이 복제 PC 를 알아보는 데 쓴다.
  final int writtenAt;

  final List<SyncSong> songs;

  /// 지운 곡 uid → 지운 시각.
  final Map<String, int> deleted;

  /// 합쳐진 옛 uid → 지금 uid.
  final Map<String, String> aliases;

  /// 지운 곡 uid → 그 곡의 [SyncSong.contentHash] (아는 것만).
  final Map<String, String> deletedContent;

  final List<SyncTranslation> translations;

  /// 지운 보조 가사 [SyncTranslation.keyOf] → 지운 시각.
  final Map<String, int> translationDeleted;

  final List<SyncConti> contis;

  /// 지운 콘티 uid → 지운 시각.
  final Map<String, int> contiDeleted;

  SyncSnapshot withContis(List<SyncConti> contis, Map<String, int> deleted) =>
      SyncSnapshot(
        deviceId: deviceId,
        deviceName: deviceName,
        writer: writer,
        writtenAt: writtenAt,
        songs: songs,
        deleted: this.deleted,
        aliases: aliases,
        deletedContent: deletedContent,
        translations: translations,
        translationDeleted: translationDeleted,
        contis: contis,
        contiDeleted: deleted,
      );

  Map<String, Object?> toJson() => {
    'format': format,
    'version': 1,
    'device_id': deviceId,
    'device_name': deviceName,
    'writer': writer,
    // 0 이면 싣지 않는다 — SyncService 가 쓸 때 앞에 붙인다(내용 비교에서 빼려고).
    if (writtenAt != 0) 'written_at': writtenAt,
    'songs': [for (final song in songs) song.toJson()],
    'deleted': deleted,
    'aliases': aliases,
    'deleted_content': deletedContent,
    'translations': [for (final t in translations) t.toJson()],
    'translation_deleted': [
      for (final e in translationDeleted.entries)
        {
          'title': e.key.split('\u0000').first,
          'language': e.key.split('\u0000').last,
          'deleted_at': e.value,
        },
    ],
    'contis': [for (final conti in contis) conti.toJson()],
    'conti_deleted': contiDeleted,
  };

  static SyncSnapshot? fromJson(Object? raw) {
    if (raw is! Map || raw['format'] != format) return null;
    final songs = raw['songs'];
    final deleted = raw['deleted'];
    final aliases = raw['aliases'];
    final contis = raw['contis'];
    final translations = raw['translations'];
    final translationDeleted = raw['translation_deleted'];
    return SyncSnapshot(
      deviceId: _str(raw['device_id']) ?? '',
      deviceName: _str(raw['device_name']) ?? '',
      writer: _str(raw['writer']) ?? '',
      writtenAt: _int(raw['written_at']) ?? 0,
      songs: songs is List
          ? songs.map(SyncSong.fromJson).whereType<SyncSong>().toList()
          : const [],
      deleted: _times(deleted),
      aliases: _strings(aliases),
      deletedContent: _strings(raw['deleted_content']),
      translations: translations is List
          ? translations
                .map(SyncTranslation.fromJson)
                .whereType<SyncTranslation>()
                .toList()
          : const [],
      translationDeleted: {
        if (translationDeleted is List)
          for (final e in translationDeleted)
            if (e is Map &&
                e['title'] is String &&
                e['language'] is String &&
                e['deleted_at'] is num)
              SyncTranslation.keyOf(
                e['title'] as String,
                e['language'] as String,
              ): (e['deleted_at'] as num)
                  .toInt(),
      },
      contis: contis is List
          ? contis.map(SyncConti.fromJson).whereType<SyncConti>().toList()
          : const [],
      contiDeleted: _times(raw['conti_deleted']),
    );
  }

  static Map<String, String> _strings(Object? raw) => raw is Map
      ? {
          for (final e in raw.entries)
            if (e.key is String && e.value is String)
              e.key as String: e.value as String,
        }
      : const {};

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
  });

  final String uid;
  final int updatedAt;
  final String name;
  final int createdAt;

  /// `worship_conti_items` 행(id·conti_id·song_id·원본 PPT 경로 뺌). 곡 항목은 `song_uid` 를 싣는다.
  /// 이미지 경로 자리는 [fileRef] 로 바뀌어 있다.
  final List<Map<String, Object?>> items;

  /// 경로 자리에 넣는 공유 파일 표시. 표시가 없는 경로는 그 PC 에 없던 파일(유실)이다.
  static const _filePrefix = 'sync-file:';

  static String fileRef(String name) => '$_filePrefix$name';

  /// [fileRef] 면 파일 이름, 아니면 null.
  static String? fileName(String? value) =>
      value != null && value.startsWith(_filePrefix)
      ? value.substring(_filePrefix.length)
      : null;

  /// 이 앱이 만드는 공유 파일 이름 모양(16자리 해시 + 확장자). 남이 보낸 이름은 이 모양만 받는다 —
  /// '../', 드라이브 문자·NTFS 스트림(':'), NUL 같은 장치 이름이 끼어들 수 없다.
  static final _safeName = RegExp(r'^[0-9a-f]{16}(\.[a-z0-9]{1,8})?$');

  static bool isSafeFileName(String name) => _safeName.hasMatch(name);

  /// 콘티는 저장하면 안 바뀌므로 고친 시각이 같으면 같은 콘티다. 다른 PC 가 다시 실어 보낸 사본이
  /// 원본을 이기지 않게, 같으면 이미 가진 쪽을 둔다.
  bool winsOver(SyncConti other) => updatedAt > other.updatedAt;

  Map<String, Object?> toJson() => {
    'uid': uid,
    'updated_at': updatedAt,
    'name': name,
    'created_at': createdAt,
    'items': items,
  };

  static SyncConti? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final uid = _str(raw['uid']);
    final name = _str(raw['name']);
    final items = raw['items'];
    if (uid == null || uid.isEmpty || name == null || items is! List) {
      return null;
    }
    return SyncConti(
      uid: uid,
      updatedAt: _int(raw['updated_at']) ?? 0,
      name: name,
      createdAt: _int(raw['created_at']) ?? 0,
      items: [
        for (final item in items)
          if (item is Map)
            {
              for (final e in item.entries)
                if (e.key is String) e.key as String: e.value,
            },
      ],
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
    this.stateChanged = false,
  });

  final int addedCount;
  final int updatedCount;
  final int deletedCount;

  /// 콘티만: 파일이 아직 공유 폴더에 다 안 올라와 이번엔 못 받은 수.
  final int pendingCount;

  /// 곡·콘티 수는 그대로지만 내 파일에 실을 것(지운 기록·합친 uid)이 바뀌었다.
  final bool stateChanged;

  bool get changed => addedCount + updatedCount + deletedCount > 0;
}
