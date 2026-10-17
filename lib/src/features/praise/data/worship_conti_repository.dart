import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../domain/praise_song.dart';
import '../domain/slide_background.dart';
import '../domain/slide_media.dart';
import '../domain/staging_item.dart';
import '../domain/worship_conti.dart';
import 'praise_database.dart';
import 'sync_snapshot.dart';

class LoadContiResult {
  const LoadContiResult({
    required this.items,
    required this.missingCount,
    this.notes = const {},
    this.backgrounds = const {},
    this.noSpacerUids = const {},
  });
  final List<({int uid, StagingItem item})> items;
  final int missingCount;
  // 발표자 보기 슬라이드 메모. 키는 '<uid>:<항목 안 페이지 번호>'.
  final Map<String, String> notes;
  // 항목별 배경 오버라이드. 키는 항목 uid. 없는 항목은 전역 배경을 쓴다.
  final Map<int, SlideBackground> backgrounds;
  // 뒤 자동 여백을 지운 항목 uid.
  final Set<int> noSpacerUids;
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
  WorshipContiRepository({
    PraiseDatabase? database,
    Future<Directory> Function()? supportDirectory,
  }) : _db = database ?? PraiseDatabase.instance,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final PraiseDatabase _db;

  /// 가져온 콘티의 이미지를 풀 곳의 바탕(Application Support). 테스트가 바꾼다.
  final Future<Directory> Function() _supportDirectory;

  Future<int> saveConti(
    String name,
    List<({int uid, StagingItem item})> stagingItems, {
    Map<String, String> notes = const {},
    Map<int, SlideBackground> backgrounds = const {},
    Set<int> noSpacerUids = const {},
  }) async {
    final db = await _db.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final savedId = await db.transaction((txn) async {
      final songIds = [
        for (final e in stagingItems)
          if (e.item case SongStagingItem(:final song) when song.id != null)
            song.id!,
      ];
      final songUids = <int, String>{
        if (songIds.isNotEmpty)
          for (final r in await txn.query(
            'praise_songs',
            columns: ['id', 'uid'],
            where: 'id IN (${List.filled(songIds.length, '?').join(', ')})',
            whereArgs: songIds,
          ))
            if (r['uid'] != null) r['id'] as int: r['uid'] as String,
      };
      final contiId = await txn.insert('worship_contis', {
        'name': name,
        'created_at': now,
        'uid': newSongUid(),
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
            'song_uid': songUids[item.song.id],
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
            'image_source_path': item.sourcePath,
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
            'media': SlideMedia.encode(item.media),
          };
        } else {
          continue;
        }
        row['notes'] = encodeContiNotes(notes, stagingItems[i].uid);
        row['background'] = SlideBackground.encode(
          backgrounds[stagingItems[i].uid],
        );
        if (noSpacerUids.contains(stagingItems[i].uid)) row['no_spacer'] = 1;
        await txn.insert('worship_conti_items', row);
      }
      return contiId;
    });
    return savedId;
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
    final noSpacerUids = <int>{};

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
            sourcePath: row['image_source_path'] as String?,
          ),
        ));
      } else if (type == 'blank') {
        result.add((
          uid: uid++,
          item: BlankStagingItem(
            mainText: row['blank_text'] as String? ?? '',
            englishText: row['blank_english_text'] as String? ?? '',
            media: SlideMedia.decode(row['media']),
          ),
        ));
      }
      if (result.length > addedBefore) {
        decodeContiNotes(row['notes'], result.last.uid, notes);
        final background = SlideBackground.decode(row['background']);
        if (background != null) backgrounds[result.last.uid] = background;
        if (row['no_spacer'] == 1) noSpacerUids.add(result.last.uid);
      }
    }

    return LoadContiResult(
      items: result,
      missingCount: missingCount,
      notes: notes,
      backgrounds: backgrounds,
      noSpacerUids: noSpacerUids,
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
    await fillMissingSyncUids(db);
    final contiRows = await db.query(
      'worship_contis',
      where: 'id = ?',
      whereArgs: [contiId],
    );
    if (contiRows.isEmpty) throw StateError('콘티를 찾을 수 없습니다.');
    final itemRows = await db.rawQuery(
      '''
      SELECT wci.*, ps.title AS cur_title, ps.lyrics AS cur_lyrics,
             ps.english_lyrics AS cur_english_lyrics, ps.uid AS cur_song_uid
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
      final item = portableItemRow(row);
      final imagePaths = row['image_paths'] as String?;
      if (imagePaths != null) {
        item['image_paths'] = imagePaths.split('\n').map(pack).join('\n');
      }
      item['background'] = mapBackgroundPaths(row['background'], pack);
      items.add(item);
    }

    await File(outPath).writeAsString(
      jsonEncode({
        'format': contiFileFormat,
        'version': 1,
        // 클라우드에 올린 콘티를 다시 받을 때 같은 콘티로 알아보려고(새로 넣지 않고 바꾼다).
        'uid': contiRows.first['uid'],
        'name': contiRows.first['name'],
        'created_at': contiRows.first['created_at'],
        'items': items,
        'files': files,
      }),
    );
  }

  /// [exportContiFile] 로 만든 파일을 이 PC 의 콘티 목록에 새 콘티로 넣는다.
  /// 담겨 온 이미지는 `Application Support/imported_contis/<시각>/` 에 푼다
  /// (PPT 렌더 캐시처럼 저장한 콘티가 참조하므로 Caches 가 아니다).
  /// [keepUid] 면(클라우드에서 받기) 파일의 콘티 uid 를 그대로 쓰고, 같은 uid 의 콘티가 이미
  /// 있으면 그것을 바꾼다 — 같은 콘티를 두 번 받아도 목록에 둘이 되지 않게. 아니면(파일 가져오기)
  /// 늘 새 콘티다. 곡 항목은 곡 uid 로 이 PC 의 곡에 다시 잇는다. 반환값은 콘티 id.
  Future<int> importContiFile(
    String path, {
    Directory? filesDir,
    bool keepUid = false,
  }) async {
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
    final fileUid = data['uid'];
    final uid = keepUid && fileUid is String && isValidContiUid(fileUid)
        ? fileUid
        : newSongUid();

    final dir =
        filesDir ??
        Directory(
          p.join(
            (await _supportDirectory()).path,
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
    final columns = await receivableItemColumns(db);

    final now = DateTime.now().millisecondsSinceEpoch;
    final createdAt = keepUid && data['created_at'] is int
        ? data['created_at'] as int
        : now;
    return db.transaction((txn) async {
      if (keepUid) {
        for (final old in await txn.query(
          'worship_contis',
          columns: ['id'],
          where: 'uid = ?',
          whereArgs: [uid],
        )) {
          await _deleteContiRows(txn, old['id'] as int);
        }
      }
      final contiId = await txn.insert('worship_contis', {
        'name': name,
        'created_at': createdAt,
        'uid': uid,
      });
      final songIdByUid = await _songIdsByUid(txn);
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
        row['background'] = mapBackgroundPaths(row['background'], unpack);
        final songUid = row['song_uid'];
        if (songUid is String) row['song_id'] = songIdByUid(songUid);
        row['conti_id'] = contiId;
        row['position'] = position++;
        await txn.insert('worship_conti_items', row);
      }
      return contiId;
    });
  }

  /// 콘티 uid 모양(32자리 hex). 클라우드 파일 이름으로 쓰므로 남이 쓴 값은 이 모양만 받는다.
  static bool isValidContiUid(String uid) =>
      RegExp(r'^[0-9a-f]{32}$').hasMatch(uid);

  /// 콘티의 uid(클라우드 파일 이름). 예전 콘티라 없으면 지금 만든다.
  Future<String> contiUid(int contiId) async {
    final db = await _db.database;
    await fillMissingSyncUids(db);
    final rows = await db.query(
      'worship_contis',
      columns: ['uid'],
      where: 'id = ?',
      whereArgs: [contiId],
    );
    if (rows.isEmpty) throw StateError('콘티를 찾을 수 없습니다.');
    return rows.first['uid'] as String;
  }

  /// 이 PC 의 콘티 uid → 콘티. 클라우드 목록에서 "이미 받은 콘티"를 가리는 데 쓴다.
  Future<Map<String, WorshipConti>> contisByUid() async {
    final contis = await listContis();
    final db = await _db.database;
    await fillMissingSyncUids(db);
    final uids = {
      for (final r in await db.query('worship_contis', columns: ['id', 'uid']))
        r['id'] as int: r['uid'] as String?,
    };
    return {
      for (final c in contis)
        if (uids[c.id] != null) uids[c.id]!: c,
    };
  }

  /// 곡 uid → 이 PC 의 곡 id. 합쳐진 uid(동기화)도 따라간다. 없으면 null.
  static Future<int? Function(String)> _songIdsByUid(
    DatabaseExecutor txn,
  ) async {
    final ids = {
      for (final r in await txn.query(
        'praise_songs',
        columns: ['id', 'uid'],
        where: 'uid IS NOT NULL',
      ))
        r['uid'] as String: r['id'] as int,
    };
    final aliases = {
      for (final r in await txn.query('song_uid_aliases'))
        r['alias'] as String: r['uid'] as String,
    };
    return (uid) => ids[resolveSongUid(aliases, uid)];
  }

  static const contiFileFormat = 'worship_slides_conti';
  static const contiFileExtension = 'wsconti';

  // 배경 JSON 안의 두 경로(배경 이미지, 헌금송 디자인의 원본 배경)를 바꿔 쓴다.
  static Object? mapBackgroundPaths(
    Object? stored,
    String? Function(String?) map,
  ) {
    final json = _decodeBackground(stored);
    if (json == null) return stored;
    for (final slot in _backgroundPathSlots(json)) {
      slot.set(map(slot.value));
    }
    return jsonEncode(json);
  }

  static Map<dynamic, dynamic>? _decodeBackground(Object? stored) {
    if (stored is! String || stored.isEmpty) return null;
    try {
      final json = jsonDecode(stored);
      return json is Map ? json : null;
    } on FormatException {
      return null;
    }
  }

  /// 배경 JSON 안의 경로 칸: 배경 이미지, 헌금송 디자인의 원본 배경.
  static List<({String value, void Function(String?) set})>
  _backgroundPathSlots(Map<dynamic, dynamic> json) {
    final offering = json['offering'];
    return [
      if (json['image_path'] is String)
        (
          value: json['image_path'] as String,
          set: (v) => json['image_path'] = v,
        ),
      if (offering is Map && offering['background_image_path'] is String)
        (
          value: offering['background_image_path'] as String,
          set: (v) => offering['background_image_path'] = v,
        ),
    ];
  }

  /// 다른 PC 로 보낼 항목 행(.wsconti·동기화 공용). 이 PC 에서만 뜻이 있는 칸(id·conti_id·song_id·
  /// 원본 PPT 경로)과 `cur_` 로 시작하는 곁들인 칸을 빼고, 빈 곡 스냅샷은 지금 곡(`cur_title`·
  /// `cur_lyrics`·`cur_english_lyrics`)으로 채운다 — 예전(DB version 7·13 전) 콘티는 스냅샷이 비어
  /// 있어서, 받는 PC 에 그 곡이 없으면 항목이 통째로 빠진다.
  static Map<String, Object?> portableItemRow(Map<String, Object?> row) {
    final item = Map<String, Object?>.of(row)
      ..remove('id')
      ..remove('conti_id')
      ..remove('song_id')
      // 원본 PPT 경로는 이 PC 에서만 뜻이 있다(받는 쪽은 다시 굽기만 못 한다).
      ..remove('image_source_path')
      ..removeWhere((key, _) => key.startsWith('cur_'));
    if (row['item_type'] == 'song') {
      item['song_title'] ??= row['cur_title'];
      item['song_lyrics'] ??= row['cur_lyrics'];
      item['song_english_lyrics'] ??= row['cur_english_lyrics'];
      // 받는 PC 가 같은 곡(동기화로 uid 가 같은 곡)에 다시 잇는 데 쓴다.
      item['song_uid'] ??= row['cur_song_uid'];
    }
    return item;
  }

  /// 다른 PC 가 보낸 항목에서 받을 칸(.wsconti·동기화 공용). 더 새 버전 앱이 보낸 모르는 칸은
  /// 버리고, song_id 는 이 PC 의 곡으로 다시 잇는다.
  static Future<Set<String>> receivableItemColumns(DatabaseExecutor db) async =>
      {
        for (final c in await db.rawQuery(
          'PRAGMA table_info(worship_conti_items)',
        ))
          c['name'] as String,
      }..removeAll(['id', 'conti_id', 'song_id']);

  Future<void> deleteConti(int contiId) async {
    final db = await _db.database;
    await db.transaction((txn) => _deleteContiRows(txn, contiId));
  }

  static Future<void> _deleteContiRows(
    DatabaseExecutor txn,
    int contiId,
  ) async {
    await txn.delete(
      'worship_conti_items',
      where: 'conti_id = ?',
      whereArgs: [contiId],
    );
    await txn.delete('worship_contis', where: 'id = ?', whereArgs: [contiId]);
  }
}
