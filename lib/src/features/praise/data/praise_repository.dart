import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../domain/praise_song.dart';
import 'praise_database.dart';
import 'sync_snapshot.dart';

class ImportSongsResult {
  const ImportSongsResult({
    required this.insertedCount,
    required this.skippedCount,
    this.updatedCount = 0,
  });

  final int insertedCount;
  final int skippedCount;

  /// 같은 곡인데 원본/보조 가사 나누기만 달라져서 기존 곡을 고친 수.
  final int updatedCount;
}

/// 원본 + 보조 가사의 줄 모음(순서·빈 줄 무시). 나누기만 다른 같은 곡이면 같다.
// 공백·줄바꿈을 뺀 글자 모음(순서 무시). 줄을 나누는 규칙이 바뀌어도
// (원본/보조 나누기, 문단 안 줄바꿈 살리기) 같은 가사면 같게 나온다.
String _allLyricLines(String lyrics, String englishLyrics) =>
    ('$lyrics$englishLyrics'.replaceAll(RegExp(r'\s'), '').split('')..sort())
        .join();

class PraiseRepository {
  PraiseRepository({PraiseDatabase? database})
    : _databaseProvider = database ?? PraiseDatabase.instance;

  final PraiseDatabase _databaseProvider;

  /// 곡·보조 가사가 바뀔 때마다 부른다. 곡 동기화가 공유 폴더에 다시 쓰는 신호.
  void Function()? onSongsChanged;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  /// 새로 넣는 곡의 행. 동기화용 uid 와 고친 시각을 붙인다.
  static Map<String, Object?> _newSongRow(PraiseSong song, int now) =>
      song.toMap()
        ..remove('id')
        ..['uid'] = newSongUid()
        ..['updated_at'] = now;

  static const _tombstoneColumns = ['uid', 'title', 'lyrics', 'english_lyrics'];

  /// 지운 곡을 다른 PC 에 알리려고 uid 와 내용 해시를 남긴다.
  /// [rows] 에는 [_tombstoneColumns] 가 있어야 한다.
  static Future<void> _addTombstones(
    DatabaseExecutor txn,
    Iterable<Map<String, Object?>> rows,
    int now,
  ) async {
    for (final row in rows) {
      final uid = row['uid'] as String?;
      if (uid == null) continue;
      await txn.insert('song_tombstones', {
        'uid': uid,
        'deleted_at': now,
        'content_hash': SyncSong.contentHashOf(
          row['title'] as String,
          row['lyrics'] as String,
          (row['english_lyrics'] as String?) ?? '',
        ),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// 같은 제목·가사의 곡은 uid 를 그대로 쓴다 — 전체 교체가 다른 PC 에서
  /// "모든 곡 삭제 + 새로 추가"로 번지지 않게.
  Future<void> replaceAllSongs(
    List<PraiseSong> songs, {
    Future<void> Function(int savedCount)? onSongSaved,
  }) async {
    final db = await _databaseProvider.database;
    final now = _now();
    await db.transaction((txn) async {
      final old = await txn.query(
        'praise_songs',
        columns: ['uid', 'updated_at', 'title', 'lyrics', 'english_lyrics'],
      );
      String keyOf(Object? title, Object? lyrics, Object? english) =>
          SyncSong.contentKeyOf(
            title as String,
            lyrics as String,
            (english as String?) ?? '',
          );
      final reusable = <String, List<Map<String, Object?>>>{};
      for (final row in old) {
        reusable
            .putIfAbsent(
              keyOf(row['title'], row['lyrics'], row['english_lyrics']),
              () => [],
            )
            .add(row);
      }
      await txn.delete('praise_songs');
      var savedCount = 0;
      for (final song in songs) {
        final row = _newSongRow(song, now);
        final same =
            reusable[keyOf(song.title, song.lyrics, song.englishLyrics)];
        if (same != null && same.isNotEmpty) {
          final kept = same.removeLast();
          row['uid'] = kept['uid'] ?? row['uid'];
          row['updated_at'] = kept['updated_at'] ?? now;
        }
        await txn.insert('praise_songs', row);
        savedCount += 1;
        if (onSongSaved != null) {
          await onSongSaved(savedCount);
        }
      }
      await _addTombstones(txn, reusable.values.expand((rows) => rows), now);
    });
    onSongsChanged?.call();
  }

  Future<ImportSongsResult> addNewSongs(
    List<PraiseSong> songs, {
    Future<void> Function(int savedCount, int skippedCount)? onProgress,
  }) async {
    final db = await _databaseProvider.database;
    final now = _now();
    final result = await db.transaction((txn) async {
      var insertedCount = 0;
      var skippedCount = 0;
      var updatedCount = 0;
      for (final song in songs) {
        final existing = await txn.query(
          'praise_songs',
          columns: ['id', 'lyrics', 'english_lyrics'],
          where: 'title = ?',
          whereArgs: [song.title],
        );
        final newLines = _allLyricLines(song.lyrics, song.englishLyrics);
        // 가사 줄은 그대로인데 원본/보조로 나눈 결과만 다르면(가져오기 규칙이 바뀜)
        // 새 곡을 만들지 않고 기존 곡을 고친다.
        final resplit = existing.where(
          (row) =>
              _allLyricLines(
                row['lyrics'] as String,
                (row['english_lyrics'] as String?) ?? '',
              ) ==
              newLines,
        );
        if (existing.any(
          (row) =>
              row['lyrics'] == song.lyrics &&
              (row['english_lyrics'] ?? '') == song.englishLyrics,
        )) {
          skippedCount += 1;
        } else if (resplit.isNotEmpty) {
          await txn.update(
            'praise_songs',
            {
              'lyrics': song.lyrics,
              'english_lyrics': song.englishLyrics,
              'updated_at': now,
            },
            where: 'id = ?',
            whereArgs: [resplit.first['id']],
          );
          updatedCount += 1;
        } else if (existing.any((row) => row['lyrics'] == song.lyrics)) {
          skippedCount += 1;
        } else {
          await txn.insert('praise_songs', _newSongRow(song, now));
          insertedCount += 1;
        }
        if (onProgress != null) {
          await onProgress(insertedCount, skippedCount);
        }
      }
      return ImportSongsResult(
        insertedCount: insertedCount,
        skippedCount: skippedCount,
        updatedCount: updatedCount,
      );
    });
    if (result.insertedCount > 0 || result.updatedCount > 0) {
      onSongsChanged?.call();
    }
    return result;
  }

  Future<void> clearAllSongs() async {
    final db = await _databaseProvider.database;
    await db.transaction((txn) async {
      await _addTombstones(
        txn,
        await txn.query('praise_songs', columns: _tombstoneColumns),
        _now(),
      );
      await txn.delete('praise_songs');
    });
    onSongsChanged?.call();
  }

  Future<void> deleteSongsByIds(List<int> ids) async {
    if (ids.isEmpty) {
      return;
    }

    final db = await _databaseProvider.database;
    final placeholders = List.filled(ids.length, '?').join(', ');
    await db.transaction((txn) async {
      await _addTombstones(
        txn,
        await txn.query(
          'praise_songs',
          columns: _tombstoneColumns,
          where: 'id IN ($placeholders)',
          whereArgs: ids,
        ),
        _now(),
      );
      await txn.delete(
        'praise_songs',
        where: 'id IN ($placeholders)',
        whereArgs: ids,
      );
    });
    onSongsChanged?.call();
  }

  Future<List<PraiseSong>> searchSongs(
    String query, {
    bool searchInTitle = true,
    bool searchInLyrics = true,
  }) async {
    final db = await _databaseProvider.database;
    final normalized = query.trim();
    final List<Map<String, Object?>> rows;
    if (normalized.isEmpty) {
      rows = await db.query('praise_songs', orderBy: 'title COLLATE NOCASE');
    } else if (!searchInTitle && !searchInLyrics) {
      return [];
    } else {
      final conditions = [
        if (searchInTitle) 'title LIKE ?',
        if (searchInLyrics) 'lyrics LIKE ?',
      ];
      final args = [
        if (searchInTitle) '%$normalized%',
        if (searchInLyrics) '%$normalized%',
      ];
      rows = await db.query(
        'praise_songs',
        where: conditions.join(' OR '),
        whereArgs: args,
        orderBy: 'title COLLATE NOCASE',
      );
    }

    return rows.map(PraiseSong.fromMap).toList();
  }

  Future<void> insertSong(PraiseSong song) async {
    final db = await _databaseProvider.database;
    await db.insert('praise_songs', _newSongRow(song, _now()));
    onSongsChanged?.call();
  }

  Future<void> updateSong(PraiseSong song) async {
    final db = await _databaseProvider.database;
    // 바뀐 게 없으면 고친 시각을 올리지 않는다 — 열었다 그냥 저장한 옛 가사가
    // 다른 PC 에서 방금 고친 가사를 "더 최신"으로 덮지 않게.
    final current = await db.query(
      'praise_songs',
      where: 'id = ?',
      whereArgs: [song.id],
      limit: 1,
    );
    final unchanged =
        current.isNotEmpty &&
        current.first['file_name'] == song.fileName &&
        current.first['title'] == song.title &&
        current.first['lyrics'] == song.lyrics &&
        (current.first['english_lyrics'] ?? '') == song.englishLyrics;
    if (unchanged) return;
    await db.update(
      'praise_songs',
      song.toMap()
        ..remove('id')
        ..['updated_at'] = _now(),
      where: 'id = ?',
      whereArgs: [song.id],
    );
    onSongsChanged?.call();
  }

  /// 지운 보조 가사를 다른 PC 에 알리려고 (제목, 언어)를 남긴다.
  static Future<void> _addTranslationTombstone(
    DatabaseExecutor txn,
    String title,
    String language,
    int now,
  ) => txn.insert('translation_tombstones', {
    'song_title': title,
    'language': language,
    'deleted_at': now,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  // ── 보조 언어 가사 ──────────────────────────────────────────────────
  //
  // '영어'는 praise_songs.english_lyrics 가 그대로 맡는다 (기본 보조 언어).
  // 그 외 언어만 song_translations 에 제목으로 묶어 둔다.

  static const defaultSubLanguage = '영어';

  Future<List<String>> getSubLanguages() async {
    final db = await _databaseProvider.database;
    final rows = await db.rawQuery(
      'SELECT DISTINCT language FROM song_translations ORDER BY language',
    );
    return [
      defaultSubLanguage,
      ...rows
          .map((r) => r['language'] as String)
          .where((l) => l != defaultSubLanguage),
    ];
  }

  /// [language] 로 본 [song] 의 보조 가사. 없으면 빈 문자열.
  Future<String> subLyricsFor(PraiseSong song, String language) async {
    if (language == defaultSubLanguage) return song.englishLyrics;
    final db = await _databaseProvider.database;
    final rows = await db.query(
      'song_translations',
      columns: ['lyrics'],
      where: 'song_title = ? AND language = ?',
      whereArgs: [song.title, language],
      limit: 1,
    );
    return rows.isEmpty ? '' : rows.first['lyrics'] as String;
  }

  /// 곡 하나의 모든 보조 가사 (편집 화면용). 키는 언어 이름.
  Future<Map<String, String>> translationsForTitle(String title) async {
    final db = await _databaseProvider.database;
    final rows = await db.query(
      'song_translations',
      columns: ['language', 'lyrics'],
      where: 'song_title = ?',
      whereArgs: [title],
    );
    return {
      for (final r in rows) r['language'] as String: r['lyrics'] as String,
    };
  }

  /// 제목 → 가사 맵을 한 언어로 통째로 저장한다. 빈 가사는 삭제.
  Future<void> saveTranslations(
    String language,
    Map<String, String> lyricsByTitle,
  ) async {
    if (language == defaultSubLanguage) {
      throw ArgumentError('영어 가사는 praise_songs.english_lyrics 에 저장한다');
    }
    final db = await _databaseProvider.database;
    final now = _now();
    await db.transaction((txn) async {
      // 바뀐 것만 고친 시각을 올린다 — 그대로 둔 가사가 다른 PC 의 수정을 덮지 않게.
      final before = {
        for (final r in await txn.query(
          'song_translations',
          where: 'language = ?',
          whereArgs: [language],
        ))
          r['song_title'] as String: r['lyrics'] as String,
      };
      for (final entry in lyricsByTitle.entries) {
        final old = before[entry.key];
        if (entry.value.trim().isEmpty) {
          if (old == null) continue;
          await txn.delete(
            'song_translations',
            where: 'song_title = ? AND language = ?',
            whereArgs: [entry.key, language],
          );
          await _addTranslationTombstone(txn, entry.key, language, now);
          continue;
        }
        if (old == entry.value) continue;
        await txn.insert('song_translations', {
          'song_title': entry.key,
          'language': language,
          'lyrics': entry.value,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    onSongsChanged?.call();
  }

  Future<int> countTranslations(String language) async {
    final db = await _databaseProvider.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM song_translations WHERE language = ?',
      [language],
    );
    final v = rows.first['c'];
    return v is int ? v : (v as num).toInt();
  }

  Future<void> deleteLanguage(String language) async {
    final db = await _databaseProvider.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'song_translations',
        columns: ['song_title'],
        where: 'language = ?',
        whereArgs: [language],
      );
      final now = _now();
      for (final row in rows) {
        await _addTranslationTombstone(
          txn,
          row['song_title'] as String,
          language,
          now,
        );
      }
      await txn.delete(
        'song_translations',
        where: 'language = ?',
        whereArgs: [language],
      );
    });
    onSongsChanged?.call();
  }

  // ── 곡 모음 파일 (다른 PC 와 합치기) ────────────────────────────────

  static const songBundleFormat = 'worship_slides_songs';

  /// 제목 비교용. 띄어쓰기·대소문자만 다른 제목은 같은 곡으로 본다.
  static String normalizeTitle(String title) =>
      title.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  /// 모든 곡 + 보조 언어 가사를 JSON 으로 옮길 수 있는 맵으로.
  Future<Map<String, Object?>> exportSongBundle() async {
    final db = await _databaseProvider.database;
    final songs = await db.query(
      'praise_songs',
      orderBy: 'title COLLATE NOCASE',
    );
    final translations = await db.query('song_translations');
    final byTitle = <String, Map<String, String>>{};
    for (final row in translations) {
      byTitle.putIfAbsent(
        row['song_title'] as String,
        () => {},
      )[row['language'] as String] = row['lyrics'] as String;
    }
    return {
      'format': songBundleFormat,
      'version': 1,
      'songs': [
        for (final row in songs)
          {
            'title': row['title'],
            'file_name': row['file_name'],
            'lyrics': row['lyrics'],
            'english_lyrics': row['english_lyrics'] ?? '',
            'translations': byTitle[row['title']] ?? const {},
          },
      ],
    };
  }

  /// 곡 모음 파일을 합친다. **같은 제목(띄어쓰기·대소문자 무시)의 곡은 새로 넣지 않는다.**
  /// 대신 기존 곡에 없는 보조 가사(비어 있던 영어, 없던 언어)만 채운다.
  /// 이미 있는 가사는 덮어쓰지 않는다.
  Future<SongBundleImportResult> importSongBundle(
    Map<String, Object?> bundle,
  ) async {
    final songs = bundle['songs'];
    if (bundle['format'] != songBundleFormat || songs is! List) {
      throw const FormatException('곡 모음 파일이 아닙니다.');
    }
    final db = await _databaseProvider.database;
    final now = _now();
    final result = await db.transaction((txn) async {
      // 정규화한 제목 → (DB 에 있는 실제 제목, 영어 가사가 비었는지)
      final existing = <String, ({int id, String title, bool noEnglish})>{};
      for (final row in await txn.query('praise_songs')) {
        final title = row['title'] as String;
        existing.putIfAbsent(
          normalizeTitle(title),
          () => (
            id: row['id'] as int,
            title: title,
            noEnglish: ((row['english_lyrics'] as String?) ?? '')
                .trim()
                .isEmpty,
          ),
        );
      }

      var added = 0;
      var skipped = 0;
      var subLyricsAdded = 0;
      for (final raw in songs) {
        if (raw is! Map) continue;
        final title = (raw['title'] as String? ?? '').trim();
        final lyrics = raw['lyrics'] as String? ?? '';
        if (title.isEmpty) continue;
        final english = raw['english_lyrics'] as String? ?? '';
        final key = normalizeTitle(title);
        final found = existing[key];

        final String dbTitle;
        if (found == null) {
          final id = await txn.insert('praise_songs', {
            'file_name': raw['file_name'] as String? ?? '',
            'title': title,
            'lyrics': lyrics,
            'english_lyrics': english,
            'uid': newSongUid(),
            'updated_at': now,
          });
          existing[key] = (
            id: id,
            title: title,
            noEnglish: english.trim().isEmpty,
          );
          dbTitle = title;
          added += 1;
        } else {
          dbTitle = found.title;
          skipped += 1;
          if (found.noEnglish && english.trim().isNotEmpty) {
            await txn.update(
              'praise_songs',
              {'english_lyrics': english, 'updated_at': now},
              where: 'id = ?',
              whereArgs: [found.id],
            );
            existing[key] = (
              id: found.id,
              title: found.title,
              noEnglish: false,
            );
            subLyricsAdded += 1;
          }
        }

        final translations = raw['translations'];
        if (translations is! Map) continue;
        for (final entry in translations.entries) {
          final language = entry.key as String;
          final text = entry.value as String? ?? '';
          if (language == defaultSubLanguage || text.trim().isEmpty) continue;
          final id = await txn.insert('song_translations', {
            'song_title': dbTitle,
            'language': language,
            'lyrics': text,
            'updated_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          if (id != 0) subLyricsAdded += 1;
        }
      }
      return SongBundleImportResult(
        addedCount: added,
        skippedCount: skipped,
        subLyricsAddedCount: subLyricsAdded,
      );
    });
    if (result.addedCount > 0 || result.subLyricsAddedCount > 0) {
      onSongsChanged?.call();
    }
    return result;
  }

  Future<int> countSongs() async {
    final db = await _databaseProvider.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM praise_songs',
    );
    final value = result.first['count'];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return 0;
  }
}

class SongBundleImportResult {
  const SongBundleImportResult({
    required this.addedCount,
    required this.skippedCount,
    required this.subLyricsAddedCount,
  });

  /// 새로 넣은 곡.
  final int addedCount;

  /// 같은 제목이 이미 있어 넣지 않은 곡.
  final int skippedCount;

  /// 기존 곡에 새로 채운 보조 가사(영어·다른 언어) 수.
  final int subLyricsAddedCount;
}
