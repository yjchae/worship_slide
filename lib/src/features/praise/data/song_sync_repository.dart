import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'praise_database.dart';
import 'praise_repository.dart';

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
class SongSyncSnapshot {
  const SongSyncSnapshot({
    required this.deviceId,
    required this.deviceName,
    required this.songs,
    required this.deleted,
    required this.aliases,
  });

  static const format = 'worship_slides_song_sync';

  final String deviceId;
  final String deviceName;
  final List<SyncSong> songs;

  /// 지운 곡 uid → 지운 시각.
  final Map<String, int> deleted;

  /// 합쳐진 옛 uid → 지금 uid.
  final Map<String, String> aliases;

  Map<String, Object?> toJson() => {
    'format': format,
    'version': 1,
    'device_id': deviceId,
    'device_name': deviceName,
    'songs': [for (final song in songs) song.toJson()],
    'deleted': deleted,
    'aliases': aliases,
  };

  static SongSyncSnapshot? fromJson(Object? raw) {
    if (raw is! Map || raw['format'] != format) return null;
    final songs = raw['songs'];
    final deleted = raw['deleted'];
    final aliases = raw['aliases'];
    return SongSyncSnapshot(
      deviceId: raw['device_id'] as String? ?? '',
      deviceName: raw['device_name'] as String? ?? '',
      songs: songs is List
          ? songs.map(SyncSong.fromJson).whereType<SyncSong>().toList()
          : const [],
      deleted: deleted is Map
          ? {
              for (final e in deleted.entries)
                if (e.key is String && e.value is num)
                  e.key as String: (e.value as num).toInt(),
            }
          : const {},
      aliases: aliases is Map
          ? {
              for (final e in aliases.entries)
                if (e.key is String && e.value is String)
                  e.key as String: e.value as String,
            }
          : const {},
    );
  }
}

class SongSyncMergeResult {
  const SongSyncMergeResult({
    this.addedCount = 0,
    this.updatedCount = 0,
    this.deletedCount = 0,
  });

  final int addedCount;
  final int updatedCount;
  final int deletedCount;

  bool get changed => addedCount + updatedCount + deletedCount > 0;
}

/// 곡 동기화의 DB 쪽. 규칙은 곡(uid)마다 **고친 시각이 늦은 쪽이 이긴다**.
/// - 지운 곡은 `song_tombstones` 에 남는다. 지운 뒤에 다른 PC 에서 고쳤으면 고친 쪽이 이긴다
/// - 두 PC 가 따로 가져온 같은 곡(제목·가사가 똑같음)은 작은 uid 로 합친다(`song_uid_aliases`)
/// - 제목은 같아도 가사가 다르면 합치지 않는다 — 어느 쪽이 맞는지 모르니 둘 다 남긴다
class SongSyncRepository {
  SongSyncRepository({PraiseDatabase? database})
    : _databaseProvider = database ?? PraiseDatabase.instance;

  final PraiseDatabase _databaseProvider;

  /// 이 PC 의 곡 전부를 공유 폴더에 쓸 모양으로.
  Future<SongSyncSnapshot> exportSnapshot({
    required String deviceId,
    required String deviceName,
  }) async {
    final db = await _databaseProvider.database;
    await _fillMissingUids(db);
    final translations = await _translationsByTitle(db);
    final rows = await db.query('praise_songs', orderBy: 'uid');
    return SongSyncSnapshot(
      deviceId: deviceId,
      deviceName: deviceName,
      songs: [for (final row in rows) _songFromRow(row, translations)],
      deleted: {
        for (final r in await db.query('song_tombstones', orderBy: 'uid'))
          r['uid'] as String: r['deleted_at'] as int,
      },
      aliases: {
        for (final r in await db.query('song_uid_aliases', orderBy: 'alias'))
          r['alias'] as String: r['uid'] as String,
      },
    );
  }

  /// 다른 PC 들의 파일을 이 PC 의 DB 에 합친다.
  Future<SongSyncMergeResult> merge(List<SongSyncSnapshot> remotes) async {
    final db = await _databaseProvider.database;
    await _fillMissingUids(db);
    return db.transaction((txn) async {
      final aliases = await _mergeAliases(txn, remotes);
      String canonical(String uid) {
        var current = uid;
        for (var i = 0; i < 32; i++) {
          final next = aliases[current];
          if (next == null || next == current) break;
          current = next;
        }
        return current;
      }

      final translations = await _translationsByTitle(txn);
      final local = await _canonicalLocalRows(txn, canonical, translations);
      final byContent = {
        for (final entry in local.entries)
          entry.value.song.contentKey: entry.key,
      };

      // 지운 곡: 이 PC 기록 + 다른 PC 기록 중 가장 늦은 시각.
      final tombstones = <String, int>{};
      void addTombstone(String uid, int at) {
        final key = canonical(uid);
        final before = tombstones[key];
        if (before == null || at > before) tombstones[key] = at;
      }

      for (final r in await txn.query('song_tombstones')) {
        addTombstone(r['uid'] as String, r['deleted_at'] as int);
      }
      for (final remote in remotes) {
        remote.deleted.forEach(addTombstone);
      }

      // 다른 PC 들에서 곡마다 가장 최신 판 하나.
      final newest = <String, SyncSong>{};
      for (final remote in remotes) {
        for (final raw in remote.songs) {
          final song = raw.withUid(canonical(raw.uid));
          final before = newest[song.uid];
          if (before == null || song.winsOver(before)) newest[song.uid] = song;
        }
      }

      var added = 0;
      var updated = 0;
      final uids = newest.keys.toList()..sort();
      for (final uid in uids) {
        final song = newest[uid]!;
        final deletedAt = tombstones[uid];
        if (deletedAt != null && deletedAt >= song.updatedAt) continue;

        var mine = local[uid];
        if (mine == null) {
          final twinUid = byContent[song.contentKey];
          if (twinUid != null && twinUid != uid) {
            // 따로 가져온 같은 곡. 어느 PC 에서든 같은 답이 나오도록 작은 uid 로 모은다.
            if (uid.compareTo(twinUid) < 0) {
              await _renameUid(txn, local, byContent, aliases, twinUid, uid);
              mine = local[uid];
            } else {
              await _addAlias(txn, aliases, uid, twinUid);
              final twin = local[twinUid]!;
              if (song.withUid(twinUid).winsOver(twin.song)) {
                await _applySong(txn, twin, song.withUid(twinUid));
                updated += 1;
              }
              continue;
            }
          }
        }

        if (mine == null) {
          final id = await txn.insert('praise_songs', _rowOf(song));
          await _replaceTranslations(txn, null, song);
          final row = _LocalSong(id, song);
          local[uid] = row;
          byContent[song.contentKey] = uid;
          added += 1;
        } else if (song.winsOver(mine.song)) {
          byContent.remove(mine.song.contentKey);
          await _applySong(txn, mine, song);
          byContent[song.contentKey] = uid;
          updated += 1;
        }
      }

      var deleted = 0;
      for (final entry in tombstones.entries) {
        final mine = local[entry.key];
        if (mine != null && mine.song.updatedAt <= entry.value) {
          await txn.delete(
            'praise_songs',
            where: 'id = ?',
            whereArgs: [mine.id],
          );
          local.remove(entry.key);
          deleted += 1;
        }
        await txn.insert('song_tombstones', {
          'uid': entry.key,
          'deleted_at': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      return SongSyncMergeResult(
        addedCount: added,
        updatedCount: updated,
        deletedCount: deleted,
      );
    });
  }

  // ── 내부 ────────────────────────────────────────────────────────────

  /// 예전 코드·다른 경로로 들어와 uid 가 없는 곡에 uid 를 준다.
  Future<void> _fillMissingUids(DatabaseExecutor db) async {
    final rows = await db.query(
      'praise_songs',
      columns: ['id'],
      where: 'uid IS NULL',
    );
    for (final row in rows) {
      await db.update(
        'praise_songs',
        {'uid': newSongUid()},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  Future<Map<String, Map<String, String>>> _translationsByTitle(
    DatabaseExecutor db,
  ) async {
    final result = <String, Map<String, String>>{};
    for (final r in await db.query('song_translations')) {
      result.putIfAbsent(
        r['song_title'] as String,
        () => {},
      )[r['language'] as String] = r['lyrics'] as String;
    }
    return result;
  }

  SyncSong _songFromRow(
    Map<String, Object?> row,
    Map<String, Map<String, String>> translations,
  ) {
    final title = row['title'] as String;
    return SyncSong(
      uid: row['uid'] as String,
      updatedAt: (row['updated_at'] as int?) ?? 0,
      title: title,
      fileName: row['file_name'] as String? ?? '',
      lyrics: row['lyrics'] as String,
      englishLyrics: (row['english_lyrics'] as String?) ?? '',
      translations: translations[title] ?? const {},
    );
  }

  Map<String, Object?> _rowOf(SyncSong song) => {
    'uid': song.uid,
    'updated_at': song.updatedAt,
    'title': song.title,
    'file_name': song.fileName,
    'lyrics': song.lyrics,
    'english_lyrics': song.englishLyrics,
  };

  /// 다른 PC 가 알려 준 uid 합치기를 이 PC 기록에 더한다.
  Future<Map<String, String>> _mergeAliases(
    DatabaseExecutor txn,
    List<SongSyncSnapshot> remotes,
  ) async {
    final aliases = {
      for (final r in await txn.query('song_uid_aliases'))
        r['alias'] as String: r['uid'] as String,
    };
    for (final remote in remotes) {
      for (final entry in remote.aliases.entries) {
        if (entry.key == entry.value || aliases.containsKey(entry.key)) {
          continue;
        }
        await _addAlias(txn, aliases, entry.key, entry.value);
      }
    }
    return aliases;
  }

  Future<void> _addAlias(
    DatabaseExecutor txn,
    Map<String, String> aliases,
    String alias,
    String uid,
  ) async {
    aliases[alias] = uid;
    await txn.insert('song_uid_aliases', {
      'alias': alias,
      'uid': uid,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 이 PC 의 곡을 합쳐진 uid 로 고쳐 읽는다. 같은 uid 가 둘이 되면 최신 하나만 남긴다.
  Future<Map<String, _LocalSong>> _canonicalLocalRows(
    DatabaseExecutor txn,
    String Function(String) canonical,
    Map<String, Map<String, String>> translations,
  ) async {
    final result = <String, _LocalSong>{};
    for (final row in await txn.query('praise_songs')) {
      final song = _songFromRow(row, translations);
      final uid = canonical(song.uid);
      var current = _LocalSong(row['id'] as int, song);
      if (uid != song.uid) {
        await txn.update(
          'praise_songs',
          {'uid': uid},
          where: 'id = ?',
          whereArgs: [current.id],
        );
        current = _LocalSong(current.id, song.withUid(uid));
      }
      final other = result[uid];
      if (other != null) {
        final loser = current.song.winsOver(other.song) ? other : current;
        await txn.delete(
          'praise_songs',
          where: 'id = ?',
          whereArgs: [loser.id],
        );
        if (identical(loser, current)) continue;
      }
      result[uid] = current;
    }
    return result;
  }

  Future<void> _renameUid(
    DatabaseExecutor txn,
    Map<String, _LocalSong> local,
    Map<String, String> byContent,
    Map<String, String> aliases,
    String from,
    String to,
  ) async {
    final mine = local.remove(from)!;
    await txn.update(
      'praise_songs',
      {'uid': to},
      where: 'id = ?',
      whereArgs: [mine.id],
    );
    await _addAlias(txn, aliases, from, to);
    local[to] = _LocalSong(mine.id, mine.song.withUid(to));
    byContent[mine.song.contentKey] = to;
  }

  Future<void> _applySong(
    DatabaseExecutor txn,
    _LocalSong mine,
    SyncSong song,
  ) async {
    await txn.update(
      'praise_songs',
      _rowOf(song),
      where: 'id = ?',
      whereArgs: [mine.id],
    );
    await _replaceTranslations(txn, mine.song.title, song);
    mine.song = song;
  }

  /// 보조 가사는 제목에 묶여 있다. 제목이 바뀌었으면 옛 제목의 가사는,
  /// 그 제목을 쓰는 다른 곡이 없을 때만 지운다.
  Future<void> _replaceTranslations(
    DatabaseExecutor txn,
    String? oldTitle,
    SyncSong song,
  ) async {
    if (oldTitle != null && oldTitle != song.title) {
      final others = await txn.query(
        'praise_songs',
        columns: ['id'],
        where: 'title = ?',
        whereArgs: [oldTitle],
        limit: 1,
      );
      if (others.isEmpty) {
        await txn.delete(
          'song_translations',
          where: 'song_title = ?',
          whereArgs: [oldTitle],
        );
      }
    }
    await txn.delete(
      'song_translations',
      where: 'song_title = ?',
      whereArgs: [song.title],
    );
    for (final entry in song.translations.entries) {
      if (entry.key == PraiseRepository.defaultSubLanguage ||
          entry.value.trim().isEmpty) {
        continue;
      }
      await txn.insert('song_translations', {
        'song_title': song.title,
        'language': entry.key,
        'lyrics': entry.value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }
}

class _LocalSong {
  _LocalSong(this.id, this.song);

  final int id;
  SyncSong song;
}
