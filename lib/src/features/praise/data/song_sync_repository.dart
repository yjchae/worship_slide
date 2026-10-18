import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'praise_database.dart';
import 'praise_repository.dart';
import 'sync_snapshot.dart';

/// 곡 동기화의 DB 쪽. 규칙은 곡(uid)마다 **고친 시각이 늦은 쪽이 이긴다**.
/// - 지운 곡은 `song_tombstones` 에 남는다. 지운 뒤에 다른 PC 에서 고쳤으면 고친 쪽이 이긴다
/// - 두 PC 가 따로 가져온 같은 곡(제목·가사가 똑같음)은 작은 uid 로 합친다(`song_uid_aliases`)
/// - 제목은 같아도 가사가 다르면 합치지 않는다 — 어느 쪽이 맞는지 모르니 둘 다 남긴다
/// - 지운 기록에는 내용 해시도 남긴다. 동기화를 켜기 전에 지운 곡이 다른 PC 의 같은 곡(uid 는 다름)으로
///   되살아나지 않게 — 단, 지운 쪽이 같은 내용의 곡을 아직 갖고 있으면(일부러 하나만 지움) 건드리지 않는다
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
    String writer = '',
  }) async {
    final db = await _databaseProvider.database;
    // uid 없는 행(마이그레이션·모든 저장이 주므로 없어야 정상)은 다음 합치기가 채운 뒤에 싣는다.
    final rows = await db.query(
      'praise_songs',
      where: 'uid IS NOT NULL',
      orderBy: 'uid',
    );
    return SyncSnapshot(
      deviceId: deviceId,
      deviceName: deviceName,
      writer: writer,
      songs: [for (final row in rows) _songFromRow(row)],
      deleted: await _tombstones(db),
      deletedContent: {
        for (final r in await db.query(
          'song_tombstones',
          where: 'content_hash IS NOT NULL',
          orderBy: 'uid',
        ))
          r['uid'] as String: r['content_hash'] as String,
      },
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

  /// 다른 PC 들의 파일을 이 PC 의 DB 에 합친다. 동기화 한 번에 가장 먼저 불린다 —
  /// uid 없는 행 채우기도 여기서 한 번만 한다.
  Future<SyncMergeResult> merge(List<SyncSnapshot> remotes) async {
    final db = await _databaseProvider.database;
    return db.transaction((txn) => _mergeIn(txn, remotes));
  }

  /// 합치면 어떻게 될지만 센다(DB 는 그대로). 프로그램을 켤 때 "서버에 새 찬양이 있다"를
  /// 알리는 데 쓴다 — 실제 합치기를 트랜잭션 안에서 돌리고 되돌리므로 셈이 합치기와 똑같다.
  Future<SyncMergeResult> preview(List<SyncSnapshot> remotes) async {
    final db = await _databaseProvider.database;
    late SyncMergeResult result;
    try {
      await db.transaction((txn) async {
        result = await _mergeIn(txn, remotes);
        throw const _Rollback();
      });
    } on _Rollback {
      // 되돌렸다 — 셈만 남는다.
    }
    return result;
  }

  Future<SyncMergeResult> _mergeIn(
    DatabaseExecutor txn,
    List<SyncSnapshot> remotes,
  ) async {
    // uid 없는 행 채우기도 트랜잭션 안에서 — 미리 세기(preview)면 같이 되돌려진다.
    await fillMissingSyncUids(txn);
    final songs = await _mergeSongs(txn, remotes);
    final translations = await _mergeTranslations(txn, remotes);
    return SyncMergeResult(
      addedCount: songs.addedCount,
      updatedCount: songs.updatedCount + translations,
      deletedCount: songs.deletedCount,
    );
  }

  // ── 곡 ──────────────────────────────────────────────────────────────

  Future<SyncMergeResult> _mergeSongs(
    DatabaseExecutor txn,
    List<SyncSnapshot> remotes,
  ) async {
    final aliases = await _mergeAliases(txn, remotes);
    String canonical(String uid) => resolveSongUid(aliases, uid);

    final local = await _canonicalLocalRows(txn, canonical);
    final byContent = {
      for (final entry in local.entries) entry.value.song.contentKey: entry.key,
    };

    // 지운 곡: 이 PC 기록 + 다른 PC 기록 중 가장 늦은 시각.
    final storedRows = await txn.query('song_tombstones');
    final storedTombstones = {
      for (final r in storedRows) r['uid'] as String: r['deleted_at'] as int,
    };
    final storedContent = {
      for (final r in storedRows)
        if (r['content_hash'] != null)
          r['uid'] as String: r['content_hash'] as String,
    };
    final tombstones = <String, int>{};
    final tombstoneContent = <String, String>{};
    void addTombstone(String uid, int at) =>
        keepLatest(tombstones, canonical(uid), at);

    storedTombstones.forEach(addTombstone);
    storedContent.forEach(
      (uid, hash) => tombstoneContent[canonical(uid)] = hash,
    );
    for (final remote in remotes) {
      remote.deleted.forEach(addTombstone);
      remote.deletedContent.forEach(
        (uid, hash) => tombstoneContent.putIfAbsent(canonical(uid), () => hash),
      );
    }
    final deletedByContent = _ContentTombstones(
      canonical: canonical,
      local: [
        for (final e in storedTombstones.entries)
          if (storedContent[e.key] != null)
            (uid: e.key, hash: storedContent[e.key]!, at: e.value),
      ],
      localSongs: [for (final mine in local.values) mine.song],
      remotes: remotes,
    );

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
    for (final key in uids) {
      // 이 반복 안에서 uid 를 합쳤을 수 있다(_renameUid) — 옛 uid 로 온 판은 지금 uid 로 다룬다.
      final uid = canonical(key);
      final song = uid == key ? newest[key]! : newest[key]!.withUid(uid);
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

      if (mine == null && deletedByContent.hides(song)) continue;
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

    // 다른 PC 가 지운 곡과 내용이 같은 이 PC 의 곡(uid 만 다름)도 지운다.
    for (final mine in local.values.toList()) {
      final at = deletedByContent.remoteDeletedAt(mine.song);
      if (at == null) continue;
      keepLatest(tombstones, mine.song.uid, at);
      tombstoneContent[mine.song.uid] = mine.song.contentHash;
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
      final hash = tombstoneContent[entry.key];
      if (storedTombstones[entry.key] != entry.value ||
          storedContent[entry.key] != hash) {
        await txn.insert('song_tombstones', {
          'uid': entry.key,
          'deleted_at': entry.value,
          'content_hash': hash,
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
      if (other != null && other.song.contentKey != current.song.contentKey) {
        // 합칠 때는 같은 곡이었지만 그 뒤에 한쪽을 고쳤다 — 가사가 다른 곡은 둘 다 남긴다는 규칙대로
        // 지우지 않고 새 uid 를 줘 따로 남긴다.
        final fresh = current.song.withUid(newSongUid());
        await txn.update(
          'praise_songs',
          {'uid': fresh.uid},
          where: 'id = ?',
          whereArgs: [current.id],
        );
        result[fresh.uid] = _LocalSong(current.id, fresh);
        continue;
      }
      if (other != null) {
        // 내용까지 같은 중복 — 하나만 남긴다(콘티 곡 링크는 곡 uid 로 다시 맞춰진다).
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
      remote.translationDeleted.forEach(
        (key, at) => keepLatest(tombstones, key, at),
      );
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

/// 내용 해시가 달린 지운 기록으로 "uid 는 다르지만 같은 곡"을 가린다.
/// 지운 쪽(이 PC 또는 다른 PC 한 대)이 같은 내용의 곡을 아직 갖고 있으면 일부러 하나만
/// 지운 것이므로 다른 곡에 번지지 않는다.
class _ContentTombstones {
  _ContentTombstones({
    required String Function(String) canonical,
    required List<({String uid, String hash, int at})> local,
    required Iterable<SyncSong> localSongs,
    required List<SyncSnapshot> remotes,
  }) : _canonical = canonical {
    // 곡마다 가사 전체를 해시하므로 내용 해시가 달린 지운 기록이 있을 때만 계산한다.
    // 이 PC 기록: 이 PC 에 같은 내용 곡이 남아 있으면 쓰지 않는다.
    if (local.isNotEmpty) {
      final localLive = {for (final s in localSongs) s.contentHash};
      for (final t in local) {
        if (!localLive.contains(t.hash)) _add(_local, t.uid, t.hash, t.at);
      }
    }
    for (final remote in remotes) {
      if (remote.deletedContent.isEmpty) continue;
      final live = {for (final s in remote.songs) s.contentHash};
      remote.deletedContent.forEach((uid, hash) {
        final at = remote.deleted[uid];
        if (at != null && !live.contains(hash)) _add(_remote, uid, hash, at);
      });
    }
  }

  final String Function(String) _canonical;
  final _local = <String, List<({String uid, int at})>>{};
  final _remote = <String, List<({String uid, int at})>>{};

  void _add(
    Map<String, List<({String uid, int at})>> into,
    String uid,
    String hash,
    int at,
  ) => into.putIfAbsent(hash, () => []).add((uid: _canonical(uid), at: at));

  /// 다른 PC 의 곡 [song] 이 이 PC·다른 PC 에서 지운 곡과 같은 내용이라 받지 말아야 하면 true.
  bool hides(SyncSong song) =>
      _deletedAt(_local, song) != null || _deletedAt(_remote, song) != null;

  /// 이 PC 의 곡 [song] 을 다른 PC 가 (다른 uid 로) 지웠으면 그 시각.
  int? remoteDeletedAt(SyncSong song) => _deletedAt(_remote, song);

  static int? _deletedAt(
    Map<String, List<({String uid, int at})>> from,
    SyncSong song,
  ) {
    if (from.isEmpty) return null;
    int? latest;
    for (final t
        in from[song.contentHash] ?? const <({String uid, int at})>[]) {
      if (t.uid == song.uid || t.at < song.updatedAt) continue;
      if (latest == null || t.at > latest) latest = t.at;
    }
    return latest;
  }
}

class _LocalSong {
  _LocalSong(this.id, this.song);

  final int id;
  SyncSong song;
}

/// [SongSyncRepository.preview] 가 트랜잭션을 되돌리려고 던진다.
class _Rollback implements Exception {
  const _Rollback();
}
