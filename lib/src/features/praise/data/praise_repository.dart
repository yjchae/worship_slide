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
    return db.transaction((txn) async {
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
              {'english_lyrics': english},
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
