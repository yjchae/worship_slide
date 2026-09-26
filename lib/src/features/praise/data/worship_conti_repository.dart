import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/praise_song.dart';
import '../domain/slide_background.dart';
import '../domain/staging_item.dart';
import '../domain/worship_conti.dart';
import 'praise_database.dart';

class LoadContiResult {
  const LoadContiResult({
    required this.items,
    required this.missingCount,
    this.notes = const {},
    this.backgrounds = const {},
  });
  final List<({int uid, StagingItem item})> items;
  final int missingCount;
  // 발표자 보기 슬라이드 메모. 키는 '<uid>:<항목 안 페이지 번호>'.
  final Map<String, String> notes;
  // 항목별 배경 오버라이드. 키는 항목 uid. 없는 항목은 전역 배경을 쓴다.
  final Map<int, SlideBackground> backgrounds;
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
    Map<int, SlideBackground> backgrounds = const {},
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
            'song_title': item.song.title,
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
            'bible_sub_text': item.subText,
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
        row['background'] = SlideBackground.encode(
          backgrounds[stagingItems[i].uid],
        );
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
      return WorshipConti.fromMap(
        row,
        itemCount: (row['item_count'] as int?) ?? 0,
      );
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
    final backgrounds = <int, SlideBackground>{};

    for (final row in itemRows) {
      final addedBefore = result.length;
      final type = row['item_type'] as String;
      if (type == 'song') {
        final songId = row['song_id'] as int?;
        final storedLyrics = row['song_lyrics'] as String?;
        final storedEnglishLyrics = row['song_english_lyrics'] as String?;
        final storedTitle = row['song_title'] as String? ?? '';
        PraiseSong? baseSong = songId != null ? songMap[songId] : null;
        if (baseSong == null && storedLyrics == null) {
          missingCount++;
          continue;
        }
        final song = baseSong == null
            ? PraiseSong(
                id: songId,
                fileName: '',
                title: storedTitle,
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
        result.add((
          uid: uid++,
          item: BibleStagingItem(
            reference: ref,
            text: text,
            subText: row['bible_sub_text'] as String? ?? '',
          ),
        ));
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
        final background = SlideBackground.decode(row['background']);
        if (background != null) backgrounds[result.last.uid] = background;
      }
    }

    return LoadContiResult(
      items: result,
      missingCount: missingCount,
      notes: notes,
      backgrounds: backgrounds,
    );
  }

  /// 콘티를 다른 PC 로 옮길 파일 하나(JSON)로 내보낸다.
  ///
  /// DB 행을 그대로 담고, 행이 가리키는 이미지(외부 PPT 페이지·항목 배경·헌금송 PNG와
  /// 그 원본)는 base64 로 같이 넣는다. 경로 자리에는 파일 키가 들어가고
  /// [importContiFile] 이 받는 쪽 폴더에 풀면서 경로를 되돌려 쓴다.
  /// song_id 는 받는 쪽 DB 와 안 맞으므로 빼고, 제목·가사 스냅샷만 보낸다.
  Future<void> exportContiFile(int contiId, String outPath) async {
    final db = await _db.database;
    final contiRows = await db.query(
      'worship_contis',
      where: 'id = ?',
      whereArgs: [contiId],
    );
    if (contiRows.isEmpty) throw StateError('콘티를 찾을 수 없습니다.');
    final itemRows = await db.rawQuery(
      '''
      SELECT wci.*, ps.title AS cur_title, ps.lyrics AS cur_lyrics,
             ps.english_lyrics AS cur_english_lyrics
      FROM worship_conti_items wci
      LEFT JOIN praise_songs ps ON ps.id = wci.song_id
      WHERE wci.conti_id = ?
      ORDER BY wci.position ASC
    ''',
      [contiId],
    );

    final files = <String, String>{};
    final keyByPath = <String, String>{};
    // 없는 파일은 경로를 그대로 둔다 — 받는 쪽에서도 로컬과 똑같이 "유실"로 처리된다.
    String? pack(String? path) {
      if (path == null || path.isEmpty) return path;
      final file = File(path);
      if (!file.existsSync()) return path;
      return keyByPath.putIfAbsent(path, () {
        final key = 'file${files.length}${p.extension(path)}';
        files[key] = base64Encode(file.readAsBytesSync());
        return key;
      });
    }

    final items = <Map<String, Object?>>[];
    for (final row in itemRows) {
      final item = Map<String, Object?>.of(row)
        ..remove('id')
        ..remove('conti_id')
        ..remove('song_id')
        ..remove('cur_title')
        ..remove('cur_lyrics')
        ..remove('cur_english_lyrics');
      if (row['item_type'] == 'song') {
        item['song_title'] ??= row['cur_title'];
        item['song_lyrics'] ??= row['cur_lyrics'];
        item['song_english_lyrics'] ??= row['cur_english_lyrics'];
      }
      final imagePaths = row['image_paths'] as String?;
      if (imagePaths != null) {
        item['image_paths'] = imagePaths.split('\n').map(pack).join('\n');
      }
      item['background'] = _mapBackgroundPaths(row['background'], pack);
      items.add(item);
    }

    await File(outPath).writeAsString(
      jsonEncode({
        'format': contiFileFormat,
        'version': 1,
        'name': contiRows.first['name'],
        'items': items,
        'files': files,
      }),
    );
  }

  /// [exportContiFile] 로 만든 파일을 이 PC 의 콘티 목록에 새 콘티로 넣는다.
  /// 담겨 온 이미지는 `Application Support/imported_contis/<시각>/` 에 푼다
  /// (PPT 렌더 캐시처럼 저장한 콘티가 참조하므로 Caches 가 아니다).
  /// 반환값은 새 콘티 id.
  Future<int> importContiFile(String path, {Directory? filesDir}) async {
    final Object? data;
    try {
      data = jsonDecode(await File(path).readAsString());
    } on FormatException {
      throw const FormatException('콘티 파일이 아닙니다.');
    }
    if (data is! Map || data['format'] != contiFileFormat) {
      throw const FormatException('콘티 파일이 아닙니다.');
    }
    final items = (data['items'] as List? ?? const []).whereType<Map>();
    final files = data['files'] as Map? ?? const {};
    final name = data['name'] as String? ?? '가져온 콘티';

    final dir =
        filesDir ??
        Directory(
          p.join(
            (await getApplicationSupportDirectory()).path,
            'imported_contis',
            '${DateTime.now().millisecondsSinceEpoch}',
          ),
        );
    final pathByKey = <String, String>{};
    String? unpack(String? key) {
      final encoded = files[key];
      if (key == null || encoded is! String) return key;
      return pathByKey.putIfAbsent(key, () {
        // 키를 파일 이름으로 그대로 쓰지 않는다 — 남이 만든 파일이라 '../' 가 들어 있을 수 있다.
        final file = File(
          p.join(dir.path, '${pathByKey.length}${p.extension(key)}'),
        );
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(base64Decode(encoded));
        return file.path;
      });
    }

    final db = await _db.database;
    // 더 새 버전 앱이 만든 파일의 모르는 칸은 버린다.
    final columns = {
      for (final c in await db.rawQuery(
        'PRAGMA table_info(worship_conti_items)',
      ))
        c['name'] as String,
    }..removeAll(['id', 'conti_id', 'song_id']);

    return db.transaction((txn) async {
      final contiId = await txn.insert('worship_contis', {
        'name': name,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      var position = 0;
      for (final item in items) {
        final row = <String, Object?>{
          for (final e in item.entries)
            if (columns.contains(e.key)) e.key as String: e.value,
        };
        final imagePaths = row['image_paths'] as String?;
        if (imagePaths != null) {
          row['image_paths'] = imagePaths.split('\n').map(unpack).join('\n');
        }
        row['background'] = _mapBackgroundPaths(row['background'], unpack);
        row['conti_id'] = contiId;
        row['position'] = position++;
        await txn.insert('worship_conti_items', row);
      }
      return contiId;
    });
  }

  static const contiFileFormat = 'worship_slides_conti';
  static const contiFileExtension = 'wsconti';

  // 배경 JSON 안의 두 경로(배경 이미지, 헌금송 디자인의 원본 배경)를 바꿔 쓴다.
  static Object? _mapBackgroundPaths(
    Object? stored,
    String? Function(String?) map,
  ) {
    if (stored is! String || stored.isEmpty) return stored;
    try {
      final json = jsonDecode(stored);
      if (json is! Map) return stored;
      if (json['image_path'] is String) {
        json['image_path'] = map(json['image_path'] as String);
      }
      final offering = json['offering'];
      if (offering is Map && offering['background_image_path'] is String) {
        offering['background_image_path'] = map(
          offering['background_image_path'] as String,
        );
      }
      return jsonEncode(json);
    } catch (_) {
      return stored;
    }
  }

  Future<void> deleteConti(int contiId) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      await txn.delete(
        'worship_conti_items',
        where: 'conti_id = ?',
        whereArgs: [contiId],
      );
      await txn.delete('worship_contis', where: 'id = ?', whereArgs: [contiId]);
    });
  }
}
