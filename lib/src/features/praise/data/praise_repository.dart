import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../domain/praise_song.dart';
import 'praise_database.dart';

class ImportSongsResult {
  const ImportSongsResult({
    required this.insertedCount,
    required this.skippedCount,
  });

  final int insertedCount;
  final int skippedCount;
}

class PraiseRepository {
  PraiseRepository({PraiseDatabase? database})
    : _databaseProvider = database ?? PraiseDatabase.instance;

  final PraiseDatabase _databaseProvider;

  Future<void> replaceAllSongs(
    List<PraiseSong> songs, {
    Future<void> Function(int savedCount)? onSongSaved,
  }) async {
    final db = await _databaseProvider.database;
    await db.transaction((txn) async {
      await txn.delete('praise_songs');
      var savedCount = 0;
      for (final song in songs) {
        await txn.insert('praise_songs', song.toMap()..remove('id'));
        savedCount += 1;
        if (onSongSaved != null) {
          await onSongSaved(savedCount);
        }
      }
    });
  }

  Future<ImportSongsResult> addNewSongs(
    List<PraiseSong> songs, {
    Future<void> Function(int savedCount, int skippedCount)? onProgress,
  }) async {
    final db = await _databaseProvider.database;
    return db.transaction((txn) async {
      var insertedCount = 0;
      var skippedCount = 0;
      for (final song in songs) {
        final existing = await txn.query(
          'praise_songs',
          columns: ['id'],
          where: 'title = ? AND lyrics = ?',
          whereArgs: [song.title, song.lyrics],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          skippedCount += 1;
        } else {
          await txn.insert('praise_songs', song.toMap()..remove('id'));
          insertedCount += 1;
        }
        if (onProgress != null) {
          await onProgress(insertedCount, skippedCount);
        }
      }
      return ImportSongsResult(
        insertedCount: insertedCount,
        skippedCount: skippedCount,
      );
    });
  }

  Future<void> clearAllSongs() async {
    final db = await _databaseProvider.database;
    await db.delete('praise_songs');
  }

  Future<void> deleteSongsByIds(List<int> ids) async {
    if (ids.isEmpty) {
      return;
    }

    final db = await _databaseProvider.database;
    final placeholders = List.filled(ids.length, '?').join(', ');
    await db.delete(
      'praise_songs',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
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
    await db.insert('praise_songs', song.toMap()..remove('id'));
  }

  Future<void> updateSong(PraiseSong song) async {
    final db = await _databaseProvider.database;
    await db.update(
      'praise_songs',
      song.toMap()..remove('id'),
      where: 'id = ?',
      whereArgs: [song.id],
    );
  }

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
      ...rows.map((r) => r['language'] as String).where(
        (l) => l != defaultSubLanguage,
      ),
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
    await db.transaction((txn) async {
      for (final entry in lyricsByTitle.entries) {
        if (entry.value.trim().isEmpty) {
          await txn.delete(
            'song_translations',
            where: 'song_title = ? AND language = ?',
            whereArgs: [entry.key, language],
          );
          continue;
        }
        await txn.insert('song_translations', {
          'song_title': entry.key,
          'language': language,
          'lyrics': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
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
    await db.delete(
      'song_translations',
      where: 'language = ?',
      whereArgs: [language],
    );
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
