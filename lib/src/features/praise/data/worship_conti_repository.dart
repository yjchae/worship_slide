import 'dart:convert';
import 'dart:io';

import '../domain/praise_song.dart';
import '../domain/staging_item.dart';
import '../domain/worship_conti.dart';
import 'praise_database.dart';

class LoadContiResult {
  const LoadContiResult({
    required this.items,
    required this.missingCount,
    this.notes = const {},
  });
  final List<({int uid, StagingItem item})> items;
  final int missingCount;
  // 발표자 보기 슬라이드 메모. 키는 '<uid>:<항목 안 페이지 번호>'.
  final Map<String, String> notes;
}

// 메모는 항목별로 {"페이지": "메모"} JSON 한 칸에 담는다.
String? encodeContiNotes(Map<String, String> notes, int uid) {
  final prefix = '$uid:';
  final forItem = <String, String>{
    for (final e in notes.entries)
      if (e.key.startsWith(prefix) && e.value.isNotEmpty)
        e.key.substring(prefix.length): e.value,
  };
  return forItem.isEmpty ? null : jsonEncode(forItem);
}

void decodeContiNotes(Object? stored, int uid, Map<String, String> out) {
  if (stored is! String || stored.isEmpty) return;
  try {
    final decoded = jsonDecode(stored);
    if (decoded is! Map) return;
    decoded.forEach((page, note) {
      if (note is String && note.isNotEmpty) out['$uid:$page'] = note;
    });
  } catch (_) {
    // 손상된 메모 때문에 콘티 자체를 못 불러오면 안 된다.
  }
}

class WorshipContiRepository {
  WorshipContiRepository({PraiseDatabase? database})
      : _db = database ?? PraiseDatabase.instance;

  final PraiseDatabase _db;

  Future<int> saveConti(
    String name,
    List<({int uid, StagingItem item})> stagingItems, {
    Map<String, String> notes = const {},
  }) async {
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
            'song_lyrics': item.song.lyrics,
            'song_english_lyrics': item.song.englishLyrics,
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
        } else if (item is ImageStagingItem) {
          row = {
            'conti_id': contiId,
            'position': i,
            'item_type': 'image',
            'song_id': null,
            'bible_reference': null,
            'bible_text': null,
            'image_source': item.sourceName,
            'image_paths': item.imagePaths.join('\n'),
          };
        } else if (item is BlankStagingItem) {
          row = {
            'conti_id': contiId,
            'position': i,
            'item_type': 'blank',
            'song_id': null,
            'bible_reference': null,
            'bible_text': null,
            'blank_text': item.mainText,
            'blank_english_text': item.englishText,
          };
        } else {
          continue;
        }
        row['notes'] = encodeContiNotes(notes, stagingItems[i].uid);
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
    final notes = <String, String>{};

    for (final row in itemRows) {
      final addedBefore = result.length;
      final type = row['item_type'] as String;
      if (type == 'song') {
        final songId = row['song_id'] as int?;
        final storedLyrics = row['song_lyrics'] as String?;
        final storedEnglishLyrics = row['song_english_lyrics'] as String?;
        PraiseSong? baseSong = songId != null ? songMap[songId] : null;
        if (baseSong == null && storedLyrics == null) {
          missingCount++;
          continue;
        }
        final song = baseSong == null
            ? PraiseSong(
                id: songId,
                fileName: '',
                title: '',
                lyrics: storedLyrics!,
                englishLyrics: storedEnglishLyrics ?? '',
              )
            : (storedLyrics != null
                ? PraiseSong(
                    id: baseSong.id,
                    fileName: baseSong.fileName,
                    title: baseSong.title,
                    lyrics: storedLyrics,
                    englishLyrics: storedEnglishLyrics ?? '',
                  )
                : baseSong);
        result.add((uid: uid++, item: SongStagingItem(song)));
      } else if (type == 'bible') {
        final ref = row['bible_reference'] as String?;
        final text = row['bible_text'] as String?;
        if (ref == null || text == null) continue;
        result.add((uid: uid++, item: BibleStagingItem(reference: ref, text: text)));
      } else if (type == 'image') {
        final paths = (row['image_paths'] as String? ?? '')
            .split('\n')
            .where((path) => path.isNotEmpty)
            .toList();
        // 이미지 캐시가 지워졌으면 항목을 통째로 건너뛴다.
        if (paths.isEmpty || paths.any((path) => !File(path).existsSync())) {
          missingCount++;
          continue;
        }
        result.add((
          uid: uid++,
          item: ImageStagingItem(
            sourceName: row['image_source'] as String? ?? 'PPT',
            imagePaths: paths,
          ),
        ));
      } else if (type == 'blank') {
        result.add((
          uid: uid++,
          item: BlankStagingItem(
            mainText: row['blank_text'] as String? ?? '',
            englishText: row['blank_english_text'] as String? ?? '',
          ),
        ));
      }
      if (result.length > addedBefore) {
        decodeContiNotes(row['notes'], result.last.uid, notes);
      }
    }

    return LoadContiResult(
      items: result,
      missingCount: missingCount,
      notes: notes,
    );
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
