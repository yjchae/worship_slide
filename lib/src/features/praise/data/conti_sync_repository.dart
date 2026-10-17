import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app_logger.dart';
import 'atomic_file.dart';
import 'fnv_hash.dart';
import 'praise_database.dart';
import 'sync_snapshot.dart';
import 'worship_conti_repository.dart';

/// 콘티 동기화의 DB·파일 쪽.
///
/// 콘티는 이 PC 에만 있는 이미지(외부 PPT 페이지·항목 배경·헌금송 PNG)를 경로로 가리킨다.
/// 그래서 그 파일을 공유 폴더 `files/` 에 올리고 경로 자리에 [SyncConti.fileRef] 를 넣는다.
/// 받는 PC 는 파일을 `Application Support/synced_files/` 로 내려받아 경로를 되돌려 쓴다.
/// - 파일 이름 = 경로·크기·수정 시각의 해시. 내용을 다 읽지 않아도 되고,
///   PPT 렌더 캐시처럼 한 번 구운 파일은 바뀌지 않으므로 이름이 곧 내용이다
/// - 내려받은 파일은 이름을 그대로 쓴다 → 다시 올릴 때 새 파일이 생기지 않는다
/// - 파일이 아직 다 안 내려온 콘티(드라이브가 올리는 중)는 이번엔 건너뛰고 다음에 받는다
/// - 동영상·음악은 싣지 않는다(`.wsconti` 와 같다). 크기가 커서 — 경로만 그대로 간다
/// - 공유 폴더의 파일은 지우지 않는다 — 다른 PC 의 저장 콘티가 아직 쓰고 있을 수 있다
class ContiSyncRepository {
  ContiSyncRepository({PraiseDatabase? database})
    : _databaseProvider = database ?? PraiseDatabase.instance;

  final PraiseDatabase _databaseProvider;

  /// 이미 만든 콘티 동기화 모양. 콘티는 저장하면 안 바뀌므로 고친 시각이 같고 쓰는 공유 파일이
  /// 아직 다 있으면 다시 만들지 않는다(콘티마다 이미지 수십 장을 sync 마다 다시 stat 하지 않게).
  final _exported =
      <
        String,
        ({int updatedAt, String shared, Set<String> files, SyncConti conti})
      >{};

  /// 지난번에 올린 파일 중 공유 폴더에서 사라진 것이 있으면 true(누가 files/ 를 정리함 등).
  /// 그러면 다시 올려야 다른 PC 가 그 콘티를 받는다. 폴더 목록 한 번이라 매번 불러도 싸다.
  Future<bool> sharedFilesMissing(Directory sharedFiles) async {
    final expected = {
      for (final e in _exported.values)
        if (e.shared == sharedFiles.path) ...e.files,
    };
    if (expected.isEmpty) return false;
    return !(await _listNames(sharedFiles)).containsAll(expected);
  }

  /// 이 PC 의 저장 콘티 전부 + 지운 콘티. 쓰는 이미지는 [sharedFiles] 에 올린다.
  Future<({List<SyncConti> contis, Map<String, int> deleted})> export({
    required Directory sharedFiles,
    required Directory localFiles,
  }) async {
    final db = await _databaseProvider.database;
    // 공유 폴더에 지금 있는 파일. 누가 files/ 를 정리했으면 다시 올린다 — 폴더 목록 한 번이라 싸다.
    final present = await _listNames(sharedFiles);
    final contis = await db.query('worship_contis', orderBy: 'uid');
    final items = await db.rawQuery('''
      SELECT wci.*, ps.uid AS cur_song_uid, ps.title AS cur_title,
             ps.lyrics AS cur_lyrics, ps.english_lyrics AS cur_english_lyrics
      FROM worship_conti_items wci
      LEFT JOIN praise_songs ps ON ps.id = wci.song_id
      ORDER BY wci.conti_id, wci.position
    ''');
    final itemsByConti = <int, List<Map<String, Object?>>>{};
    for (final row in items) {
      itemsByConti.putIfAbsent(row['conti_id'] as int, () => []).add(row);
    }

    // 지운 콘티의 캐시는 버린다 — 남아 있으면 그 파일이 사라졌다고 매번 다시 맞춘다.
    _exported.removeWhere((uid, _) => !contis.any((c) => c['uid'] == uid));
    final result = <SyncConti>[];
    for (final conti in contis) {
      final uid = conti['uid'] as String;
      final updatedAt = (conti['updated_at'] as int?) ?? 0;
      final cached = _exported[uid];
      if (cached != null &&
          cached.updatedAt == updatedAt &&
          cached.shared == sharedFiles.path &&
          present.containsAll(cached.files)) {
        result.add(cached.conti);
        continue;
      }
      try {
        final files = <String>{};
        final built = await _exportConti(
          conti,
          itemsByConti[conti['id']] ?? const [],
          files: files,
          present: present,
          sharedFiles: sharedFiles,
          localFiles: localFiles,
        );
        _exported[uid] = (
          updatedAt: updatedAt,
          shared: sharedFiles.path,
          files: files,
          conti: built,
        );
        result.add(built);
      } on FileSystemException catch (error) {
        // 이미지 하나를 못 올렸다고 곡·다른 콘티까지 못 올리면 안 된다. 이 콘티만 다음에 다시.
        // (빠진 콘티는 지운 게 아니므로 다른 PC 에서 사라지지 않는다.)
        await AppLogger.instance.info(
          '[sync] 콘티 올리기 건너뜀 "${conti['name']}": $error',
        );
      }
    }
    return (
      contis: result,
      deleted: {
        for (final r in await db.query('conti_tombstones', orderBy: 'uid'))
          r['uid'] as String: r['deleted_at'] as int,
      },
    );
  }

  /// [files] 에 이 콘티가 쓰는 공유 파일 이름을 모은다.
  Future<SyncConti> _exportConti(
    Map<String, Object?> conti,
    List<Map<String, Object?>> rows, {
    required Set<String> files,
    required Set<String> present,
    required Directory sharedFiles,
    required Directory localFiles,
  }) async {
    Future<String?> pack(String? path) async {
      final name = await _upload(path, present, sharedFiles, localFiles);
      if (name == null) return path;
      files.add(name);
      return SyncConti.fileRef(name);
    }

    final syncItems = <Map<String, Object?>>[];
    for (final row in rows) {
      final item = Map<String, Object?>.of(row)
        ..remove('id')
        ..remove('conti_id')
        ..remove('song_id')
        ..remove('cur_song_uid')
        ..remove('cur_title')
        ..remove('cur_lyrics')
        ..remove('cur_english_lyrics')
        // 원본 PPT 경로는 이 PC 에서만 뜻이 있다.
        ..remove('image_source_path');
      if (row['item_type'] == 'song') {
        // 예전(DB version 7·13 전) 콘티는 가사·제목 스냅샷이 비어 있다. 받는 PC 에 그 곡이
        // 없으면 항목이 통째로 빠지므로 지금 곡으로 채운다(.wsconti 내보내기와 같다).
        item['song_title'] ??= row['cur_title'];
        item['song_lyrics'] ??= row['cur_lyrics'];
        item['song_english_lyrics'] ??= row['cur_english_lyrics'];
      }
      // 저장할 때 적어 둔 곡 uid 를 먼저 쓴다 — 받은 콘티의 곡이 이 PC 에 없어도 링크가 남는다.
      item['song_uid'] ??= row['cur_song_uid'];
      if (item['song_uid'] == null) item.remove('song_uid');
      final imagePaths = row['image_paths'] as String?;
      if (imagePaths != null) {
        item['image_paths'] = [
          for (final path in imagePaths.split('\n')) await pack(path),
        ].join('\n');
      }
      item['background'] = await _mapBackgroundAsync(row['background'], pack);
      syncItems.add(item);
    }
    return SyncConti(
      uid: conti['uid'] as String,
      updatedAt: (conti['updated_at'] as int?) ?? 0,
      name: conti['name'] as String,
      createdAt: conti['created_at'] as int,
      items: syncItems,
    );
  }

  /// 다른 PC 들의 콘티를 이 PC 에 합친다. 곡 합치기가 끝난 뒤에 불러야
  /// 곡 항목이 이 PC 의 곡(id)에 이어진다.
  Future<SyncMergeResult> merge(
    List<SyncSnapshot> remotes, {
    required Directory sharedFiles,
    required Directory localFiles,
  }) async {
    final db = await _databaseProvider.database;

    final storedTombstones = {
      for (final r in await db.query('conti_tombstones'))
        r['uid'] as String: r['deleted_at'] as int,
    };
    final tombstones = Map<String, int>.of(storedTombstones);
    final newest = <String, SyncConti>{};
    for (final remote in remotes) {
      remote.contiDeleted.forEach((uid, at) => keepLatest(tombstones, uid, at));
      for (final conti in remote.contis) {
        final before = newest[conti.uid];
        if (before == null || conti.winsOver(before)) {
          newest[conti.uid] = conti;
        }
      }
    }

    final localUpdatedAt = {
      for (final r in await db.query(
        'worship_contis',
        columns: ['uid', 'updated_at'],
      ))
        r['uid'] as String: (r['updated_at'] as int?) ?? 0,
    };

    // 더 새 버전 앱이 보낸 모르는 칸은 버린다. song_id 는 이 PC 의 곡으로 다시 잇는다.
    final columns = {
      for (final c in await db.rawQuery(
        'PRAGMA table_info(worship_conti_items)',
      ))
        c['name'] as String,
    }..removeAll(['id', 'conti_id', 'song_id', 'image_source_path']);

    // 받을 콘티를 고르고 파일부터 내려받는다(DB 트랜잭션을 파일 복사 동안 잡고 있지 않게).
    final incoming = <({SyncConti conti, List<Map<String, Object?>> rows})>[];
    var pending = 0;
    for (final conti in newest.values) {
      final deletedAt = tombstones[conti.uid];
      if (deletedAt != null && deletedAt >= conti.updatedAt) continue;
      final mine = localUpdatedAt[conti.uid];
      if (mine != null && mine >= conti.updatedAt) continue;
      // 남이 쓴 파일이라 값 모양·파일 이름을 먼저 본다. 이상하면 받지 않는다
      // (트랜잭션 안에서 터지면 이번 동기화 전체가 실패한다).
      final rows = _rowsOf(conti, columns);
      final files = rows == null ? null : _referencedFiles(rows);
      if (rows == null || files == null) {
        await AppLogger.instance.info('[sync] 이상한 콘티 건너뜀 "${conti.name}"');
        continue;
      }
      if (await _download(files, sharedFiles, localFiles)) {
        incoming.add((conti: conti, rows: rows));
      } else {
        pending += 1;
      }
    }

    return db.transaction((txn) async {
      final aliases = {
        for (final r in await txn.query('song_uid_aliases'))
          r['alias'] as String: r['uid'] as String,
      };
      final songIdByUid = {
        for (final r in await txn.query(
          'praise_songs',
          columns: ['id', 'uid'],
          where: 'uid IS NOT NULL',
        ))
          r['uid'] as String: r['id'] as int,
      };

      var added = 0;
      var updated = 0;
      for (final (:conti, :rows) in incoming) {
        final existing = await txn.query(
          'worship_contis',
          columns: ['id'],
          where: 'uid = ?',
          whereArgs: [conti.uid],
        );
        final int contiId;
        if (existing.isEmpty) {
          contiId = await txn.insert('worship_contis', {
            'uid': conti.uid,
            'updated_at': conti.updatedAt,
            'name': conti.name,
            'created_at': conti.createdAt,
          });
          added += 1;
        } else {
          contiId = existing.first['id'] as int;
          await txn.update(
            'worship_contis',
            {
              'updated_at': conti.updatedAt,
              'name': conti.name,
              'created_at': conti.createdAt,
            },
            where: 'id = ?',
            whereArgs: [contiId],
          );
          await txn.delete(
            'worship_conti_items',
            where: 'conti_id = ?',
            whereArgs: [contiId],
          );
          updated += 1;
        }
        var position = 0;
        for (final source in rows) {
          final row = Map<String, Object?>.of(source);
          final imagePaths = row['image_paths'] as String?;
          if (imagePaths != null) {
            row['image_paths'] = imagePaths
                .split('\n')
                .map(
                  (v) => _receivedPath(v, localFiles) ?? _missing(localFiles),
                )
                .join('\n');
          }
          row['background'] = WorshipContiRepository.mapBackgroundPaths(
            row['background'],
            (v) => _receivedPath(v, localFiles),
          );
          // 합쳐진 uid 도 따라간다. 이 PC 에 없는 곡이면 null — 콘티는 가사 스냅샷을 들고 있어
          // 곡이 없어도 불러와진다.
          final songUid = row['song_uid'];
          row['song_id'] = songUid is String
              ? songIdByUid[resolveSongUid(aliases, songUid)]
              : null;
          row['conti_id'] = contiId;
          row['position'] = position++;
          await txn.insert('worship_conti_items', row);
        }
      }

      // 곡보다 콘티가 먼저 온 경우(그 곡을 가진 PC 파일을 이번엔 못 읽음 등) 곡이 들어온 뒤에 잇는다.
      for (final r in await txn.query(
        'worship_conti_items',
        columns: ['id', 'song_uid'],
        where: 'song_uid IS NOT NULL AND song_id IS NULL',
      )) {
        final songId =
            songIdByUid[resolveSongUid(aliases, r['song_uid'] as String)];
        if (songId == null) continue;
        await txn.update(
          'worship_conti_items',
          {'song_id': songId},
          where: 'id = ?',
          whereArgs: [r['id']],
        );
      }

      var deleted = 0;
      var stateChanged = false;
      final localNow = {
        for (final r in await txn.query(
          'worship_contis',
          columns: ['id', 'uid', 'updated_at'],
        ))
          r['uid'] as String: (
            id: r['id'] as int,
            updatedAt: (r['updated_at'] as int?) ?? 0,
          ),
      };
      for (final entry in tombstones.entries) {
        final mine = localNow[entry.key];
        if (mine != null && mine.updatedAt <= entry.value) {
          await txn.delete(
            'worship_conti_items',
            where: 'conti_id = ?',
            whereArgs: [mine.id],
          );
          await txn.delete(
            'worship_contis',
            where: 'id = ?',
            whereArgs: [mine.id],
          );
          _exported.remove(entry.key);
          deleted += 1;
        }
        if (storedTombstones[entry.key] != entry.value) {
          await txn.insert('conti_tombstones', {
            'uid': entry.key,
            'deleted_at': entry.value,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          stateChanged = true;
        }
      }
      return SyncMergeResult(
        addedCount: added,
        updatedCount: updated,
        deletedCount: deleted,
        pendingCount: pending,
        stateChanged: stateChanged,
      );
    });
  }

  // ── 내부 ────────────────────────────────────────────────────────────

  /// 로컬 파일을 공유 폴더에 올리고 그 이름을 돌려준다. 없는 파일이면 null.
  /// [present] 는 공유 폴더에 이미 있는 이름(올리면 더한다).
  Future<String?> _upload(
    String? path,
    Set<String> present,
    Directory sharedFiles,
    Directory localFiles,
  ) async {
    if (path == null || path.isEmpty) return null;
    final local = File(path);
    final stat = await local.stat();
    if (stat.type == FileSystemEntityType.notFound) return null;
    final String name;
    if (p.isWithin(localFiles.path, path)) {
      // 다른 PC 에서 받아 온 파일 — 원래 이름 그대로.
      name = p.basename(path);
    } else {
      // 기기 id 는 넣지 않는다 — 기기 id 가 바뀌어도 같은 파일을 다시 올리지 않게.
      final key = '$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
      name = '${fnvHex(utf8.encode(key))}${_safeExtension(path)}';
    }
    if (present.contains(name)) return name;
    final target = File(p.join(sharedFiles.path, name));
    // 다른 PC 가 같은 파일을 먼저 올렸으면(이름이 같으면 내용도 같다) 그걸로 된다.
    if (!await target.exists()) await atomicCopy(local, target);
    present.add(name);
    return name;
  }

  /// [SyncConti.isSafeFileName] 에 맞는 확장자(소문자 영숫자 8자까지). 아니면 확장자 없이.
  static String _safeExtension(String path) {
    final ext = p.extension(path).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(ext) ? ext : '';
  }

  static Future<Set<String>> _listNames(Directory dir) async {
    final names = <String>{};
    if (!await dir.exists()) return names;
    await for (final entity in dir.list()) {
      if (entity is File) names.add(p.basename(entity.path));
    }
    return names;
  }

  /// 콘티 항목이 실제로 가리키는 공유 파일 이름들. 남이 쓴 파일이라 '../' 같은 이름이
  /// 들어 있을 수 있다. 그런 이름이 하나라도 있으면 null.
  static Set<String>? _referencedFiles(List<Map<String, Object?>> rows) {
    final names = <String>{};
    void collect(String? value) {
      final name = SyncConti.fileName(value);
      if (name != null) names.add(name);
    }

    for (final item in rows) {
      final imagePaths = item['image_paths'];
      if (imagePaths is String) imagePaths.split('\n').forEach(collect);
      WorshipContiRepository.mapBackgroundPaths(item['background'], (v) {
        collect(v);
        return v;
      });
    }
    return names.every(SyncConti.isSafeFileName) ? names : null;
  }

  /// 콘티 항목을 이 PC 의 칸만 남긴 행으로. 값이 글자·숫자·null 이 아니면(다른 버전·깨진 파일) null.
  static List<Map<String, Object?>>? _rowsOf(
    SyncConti conti,
    Set<String> columns,
  ) {
    final rows = <Map<String, Object?>>[];
    for (final item in conti.items) {
      final row = <String, Object?>{};
      for (final e in item.entries) {
        if (!columns.contains(e.key)) continue;
        final value = e.value;
        if (value != null && value is! String && value is! num) return null;
        row[e.key] = value;
      }
      if (row['item_type'] is! String) return null;
      rows.add(row);
    }
    return rows;
  }

  /// 콘티가 쓰는 파일을 모두 내려받는다. 하나라도 아직 공유 폴더에 없거나 못 읽으면
  /// (드라이브가 아직 내려받는 중) false — 다음 차례에 다시 본다.
  Future<bool> _download(
    Set<String> names,
    Directory sharedFiles,
    Directory localFiles,
  ) async {
    for (final name in names) {
      final local = File(p.join(localFiles.path, name));
      if (await local.exists()) continue;
      final shared = File(p.join(sharedFiles.path, name));
      if (!await shared.exists()) return false;
      try {
        await atomicCopy(shared, local);
      } on FileSystemException {
        return false;
      }
    }
    return true;
  }

  /// 받은 경로 값 → 이 PC 경로. 공유 파일 표시가 아닌 값(보낸 PC 의 로컬 경로)은 버린다 —
  /// 그대로 두면 이 PC 의 같은 경로에 있는 아무 파일이나 다음 동기화 때 공유 폴더로 올라간다.
  static String? _receivedPath(String? value, Directory localFiles) {
    final name = SyncConti.fileName(value);
    return name == null ? null : p.join(localFiles.path, name);
  }

  /// 이미지 페이지 자리를 지키는 없는 파일 경로. 불러오기가 '유실'로 센다.
  static String _missing(Directory localFiles) =>
      p.join(localFiles.path, '.missing');

  static Future<Object?> _mapBackgroundAsync(
    Object? stored,
    Future<String?> Function(String?) map,
  ) async {
    // mapBackgroundPaths 는 동기 콜백이라, 경로를 먼저 모아 올린 뒤 결과로 바꿔 쓴다.
    final paths = <String?>[];
    WorshipContiRepository.mapBackgroundPaths(stored, (v) {
      paths.add(v);
      return v;
    });
    final mapped = {for (final v in paths) v: await map(v)};
    return WorshipContiRepository.mapBackgroundPaths(stored, (v) => mapped[v]);
  }
}
