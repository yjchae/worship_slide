import '../domain/praise_song.dart';
import '../domain/staging_item.dart';
import '../domain/worship_conti.dart';
import 'praise_database.dart';

class LoadContiResult {
  const LoadContiResult({required this.items, required this.missingCount});
  final List<({int uid, StagingItem item})> items;
  final int missingCount;
}

class WorshipContiRepository {
  WorshipContiRepository({PraiseDatabase? database})
      : _db = database ?? PraiseDatabase.instance;

  final PraiseDatabase _db;

  Future<int> saveConti(
    String name,
    List<({int uid, StagingItem item})> stagingItems,
  ) async {
    final db = await _db.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction((txn) async {
      final contiId = await txn.insert('worship_contis', {
        'name': name,
        'created_at': now,
      });
      for (var i = 0; i < stagingItems.length; i++) {
        final item = stagingItems[i].item;
        final Map<String, Object?> row;
        if (item is SongStagingItem) {
          row = {
            'conti_id': contiId,
            'position': i,
            'item_type': 'song',
            'song_id': item.song.id,
            'bible_reference': null,
            'bible_text': null,
          };
        } else if (item is BibleStagingItem) {
          row = {
            'conti_id': contiId,
            'position': i,
            'item_type': 'bible',
            'song_id': null,
            'bible_reference': item.reference,
            'bible_text': item.text,
          };
        } else {
          continue;
        }
        await txn.insert('worship_conti_items', row);
      }
      return contiId;
    });
  }

  Future<List<WorshipConti>> listContis() async {
    final db = await _db.database;
    final rows = await db.rawQuery('''
      SELECT wc.id, wc.name, wc.created_at,
             COUNT(wci.id) AS item_count
      FROM worship_contis wc
      LEFT JOIN worship_conti_items wci ON wci.conti_id = wc.id
      GROUP BY wc.id
      ORDER BY wc.created_at DESC
    ''');
    return rows.map((row) {
      return WorshipConti.fromMap(row, itemCount: (row['item_count'] as int?) ?? 0);
    }).toList();
  }

  Future<LoadContiResult> loadConti(int contiId, int startUid) async {
    final db = await _db.database;

    final itemRows = await db.query(
      'worship_conti_items',
      where: 'conti_id = ?',
      whereArgs: [contiId],
      orderBy: 'position ASC',
    );

    final songIds = itemRows
        .where((r) => r['item_type'] == 'song' && r['song_id'] != null)
        .map((r) => r['song_id'] as int)
        .toSet()
        .toList();

    final Map<int, PraiseSong> songMap = {};
    if (songIds.isNotEmpty) {
      final placeholders = List.filled(songIds.length, '?').join(', ');
      final songRows = await db.rawQuery(
        'SELECT * FROM praise_songs WHERE id IN ($placeholders)',
        songIds,
      );
      for (final row in songRows) {
        final song = PraiseSong.fromMap(row);
        if (song.id != null) songMap[song.id!] = song;
      }
    }

    var uid = startUid;
    var missingCount = 0;
    final result = <({int uid, StagingItem item})>[];

    for (final row in itemRows) {
      final type = row['item_type'] as String;
      if (type == 'song') {
        final songId = row['song_id'] as int?;
        if (songId == null || !songMap.containsKey(songId)) {
          missingCount++;
          continue;
        }
        result.add((uid: uid++, item: SongStagingItem(songMap[songId]!)));
      } else if (type == 'bible') {
        final ref = row['bible_reference'] as String?;
        final text = row['bible_text'] as String?;
        if (ref == null || text == null) continue;
        result.add((uid: uid++, item: BibleStagingItem(reference: ref, text: text)));
      }
    }

    return LoadContiResult(items: result, missingCount: missingCount);
  }

  Future<void> deleteConti(int contiId) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      await txn.delete(
        'worship_conti_items',
        where: 'conti_id = ?',
        whereArgs: [contiId],
      );
      await txn.delete(
        'worship_contis',
        where: 'id = ?',
        whereArgs: [contiId],
      );
    });
  }
}
