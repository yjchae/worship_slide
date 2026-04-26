import '../domain/praise_song.dart';
import 'praise_database.dart';

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

  Future<List<PraiseSong>> searchSongs(String query) async {
    final db = await _databaseProvider.database;
    final normalized = query.trim();
    final List<Map<String, Object?>> rows;
    if (normalized.isEmpty) {
      rows = await db.query('praise_songs', orderBy: 'title COLLATE NOCASE');
    } else {
      rows = await db.query(
        'praise_songs',
        where: 'title LIKE ? OR lyrics LIKE ?',
        whereArgs: ['%$normalized%', '%$normalized%'],
        orderBy: 'title COLLATE NOCASE',
      );
    }

    return rows.map(PraiseSong.fromMap).toList();
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
