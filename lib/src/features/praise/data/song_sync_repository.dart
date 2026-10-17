import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'praise_database.dart';
import 'praise_repository.dart';
import 'sync_snapshot.dart';

/// 곡 동기화의 DB 쪽. 규칙은 곡(uid)마다 **고친 시각이 늦은 쪽이 이긴다**.
/// - 지운 곡은 `song_tombstones` 에 남는다. 지운 뒤에 다른 PC 에서 고쳤으면 고친 쪽이 이긴다
/// - 두 PC 가 따로 가져온 같은 곡(제목·가사가 똑같음)은 작은 uid 로 합친다(`song_uid_aliases`)
/// - 제목은 같아도 가사가 다르면 합치지 않는다 — 어느 쪽이 맞는지 모르니 둘 다 남긴다
/// - 보조 언어 가사는 (제목, 언어)마다 따로 맞춘다. 곡을 받는다고 그 제목의 가사를 덮지 않는다
///   (같은 제목의 다른 곡이 같이 쓰고, 받는 쪽에만 있는 언어가 지워지면 안 된다)
class SongSyncRepository {
  SongSyncRepository({PraiseDatabase? database})
    : _databaseProvider = database ?? PraiseDatabase.instance;

  final PraiseDatabase _databaseProvider;

  /// 이 PC 의 곡·보조 가사 전부를 공유 폴더에 쓸 모양으로.
  Future<SyncSnapshot> exportSnapshot({
    required String deviceId,
    required String deviceName,
  }) async {
    final db = await _databaseProvider.database;
    await fillMissingSyncUids(db);
    final rows = await db.query('praise_songs', orderBy: 'uid');
    return SyncSnapshot(
      deviceId: deviceId,
      deviceName: deviceName,
      songs: [for (final row in rows) _songFromRow(row)],
      deleted: await _tombstones(db),
      aliases: {
        for (final r in await db.query('song_uid_aliases', orderBy: 'alias'))
          r['alias'] as String: r['uid'] as String,
      },
      translations: [
        for (final r in await db.query(
          'song_translations',
          orderBy: 'song_title, language',
        ))
          _translationFromRow(r),
      ],
      translationDeleted: await _translationTombstones(db),
    );
  }

  /// 다른 PC 들의 파일을 이 PC 의 DB 에 합친다.
  Future<SyncMergeResult> merge(List<SyncSnapshot> remotes) async {
    final db = await _databaseProvider.database;
    await fillMissingSyncUids(db);
    return db.transaction((txn) async {
      final songs = await _mergeSongs(txn, remotes);
      final translations = await _mergeTranslations(txn, remotes);
      return SyncMergeResult(
        addedCount: songs.addedCount,
        updatedCount: songs.updatedCount + translations,
        deletedCount: songs.deletedCount,
      );
    });
  }

  // ── 곡 ──────────────────────────────────────────────────────────────

  Future<SyncMergeResult> _mergeSongs(
    DatabaseExecutor txn,
    List<SyncSnapshot> remotes,
  ) async {
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

    final local = await _canonicalLocalRows(txn, canonical);
    final byContent = {
      for (final entry in local.entries) entry.value.song.contentKey: entry.key,
    };

    // 지운 곡: 이 PC 기록 + 다른 PC 기록 중 가장 늦은 시각.
    final storedTombstones = await _tombstones(txn);
    final tombstones = <String, int>{};
    void addTombstone(String uid, int at) {
      final key = canonical(uid);
      final before = tombstones[key];
      if (before == null || at > before) tombstones[key] = at;
    }

    storedTombstones.forEach(addTombstone);
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
        local[uid] = _LocalSong(id, song);
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
        await txn.delete('praise_songs', where: 'id = ?', whereArgs: [mine.id]);
        local.remove(entry.key);
        deleted += 1;
      }
      // 이미 같은 기록이 있으면 다시 쓰지 않는다(지운 기록은 계속 쌓인다).
      if (storedTombstones[entry.key] != entry.value) {
        await txn.insert('song_tombstones', {
          'uid': entry.key,
          'deleted_at': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }

    return SyncMergeResult(
      addedCount: added,
      updatedCount: updated,
      deletedCount: deleted,
    );
  }

  Future<Map<String, int>> _tombstones(DatabaseExecutor db) async => {
    for (final r in await db.query('song_tombstones', orderBy: 'uid'))
      r['uid'] as String: r['deleted_at'] as int,
  };

  SyncSong _songFromRow(Map<String, Object?> row) => SyncSong(
    uid: row['uid'] as String,
    updatedAt: (row['updated_at'] as int?) ?? 0,
    title: row['title'] as String,
    fileName: row['file_name'] as String? ?? '',
    lyrics: row['lyrics'] as String,
    englishLyrics: (row['english_lyrics'] as String?) ?? '',
  );

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
    List<SyncSnapshot> remotes,
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
  ) async {
    final result = <String, _LocalSong>{};
    for (final row in await txn.query('praise_songs')) {
      final song = _songFromRow(row);
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
    mine.song = song;
  }

  // ── 보조 언어 가사 ──────────────────────────────────────────────────

  /// 바뀐 보조 가사 수를 돌려준다.
  Future<int> _mergeTranslations(
    DatabaseExecutor txn,
    List<SyncSnapshot> remotes,
  ) async {
    final local = {
      for (final r in await txn.query('song_translations'))
        SyncTranslation.keyOf(
          r['song_title'] as String,
          r['language'] as String,
        ): _translationFromRow(
          r,
        ),
    };
    final storedTombstones = await _translationTombstones(txn);
    final tombstones = Map<String, int>.of(storedTombstones);
    final newest = <String, SyncTranslation>{};
    for (final remote in remotes) {
      remote.translationDeleted.forEach((key, at) {
        final before = tombstones[key];
        if (before == null || at > before) tombstones[key] = at;
      });
      for (final t in remote.translations) {
        if (t.language == PraiseRepository.defaultSubLanguage ||
            t.lyrics.trim().isEmpty) {
          continue;
        }
        final before = newest[t.key];
        if (before == null || t.winsOver(before)) newest[t.key] = t;
      }
    }

    var changed = 0;
    for (final t in newest.values) {
      final deletedAt = tombstones[t.key];
      if (deletedAt != null && deletedAt >= t.updatedAt) continue;
      final mine = local[t.key];
      if (mine != null && !t.winsOver(mine)) continue;
      await txn.insert('song_translations', {
        'song_title': t.title,
        'language': t.language,
        'lyrics': t.lyrics,
        'updated_at': t.updatedAt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      local[t.key] = t;
      changed += 1;
    }

    for (final entry in tombstones.entries) {
      final mine = local[entry.key];
      if (mine != null && mine.updatedAt <= entry.value) {
        await txn.delete(
          'song_translations',
          where: 'song_title = ? AND language = ?',
          whereArgs: [mine.title, mine.language],
        );
        changed += 1;
      }
      if (storedTombstones[entry.key] != entry.value) {
        final parts = entry.key.split('\u0000');
        await txn.insert('translation_tombstones', {
          'song_title': parts.first,
          'language': parts.last,
          'deleted_at': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    return changed;
  }

  SyncTranslation _translationFromRow(Map<String, Object?> row) =>
      SyncTranslation(
        title: row['song_title'] as String,
        language: row['language'] as String,
        lyrics: row['lyrics'] as String,
        updatedAt: (row['updated_at'] as int?) ?? 0,
      );

  Future<Map<String, int>> _translationTombstones(
    DatabaseExecutor db,
  ) async => {
    for (final r in await db.query(
      'translation_tombstones',
      orderBy: 'song_title, language',
    ))
      SyncTranslation.keyOf(r['song_title'] as String, r['language'] as String):
          r['deleted_at'] as int,
  };
}

class _LocalSong {
  _LocalSong(this.id, this.song);

  final int id;
  SyncSong song;
}
