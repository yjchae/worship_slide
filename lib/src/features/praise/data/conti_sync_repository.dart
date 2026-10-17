import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app_logger.dart';
import 'fnv_hash.dart';
import 'praise_database.dart';
import 'sync_snapshot.dart';
import 'worship_conti_repository.dart';

/// 콘티 동기화의 DB·파일 쪽.
///
/// 콘티는 이 PC 에만 있는 이미지(외부 PPT 페이지·항목 배경·헌금송 PNG)를 경로로 가리킨다.
/// 그래서 그 파일을 공유 폴더 `files/` 에 올리고 경로 자리에 [SyncConti.fileRef] 를 넣는다.
/// 받는 PC 는 파일을 `Application Support/synced_files/` 로 내려받아 경로를 되돌려 쓴다.
/// - 파일 이름 = 올린 PC·경로·크기·수정 시각의 해시. 내용을 다 읽지 않아도 되고,
///   PPT 렌더 캐시처럼 한 번 구운 파일은 바뀌지 않으므로 이름이 곧 내용이다
/// - 내려받은 파일은 이름을 그대로 쓴다 → 다시 올릴 때 새 파일이 생기지 않는다
/// - 파일이 아직 다 안 내려온 콘티(드라이브가 올리는 중)는 이번엔 건너뛰고 다음에 받는다
/// - 동영상·음악은 싣지 않는다(`.wsconti` 와 같다). 크기가 커서 — 경로만 그대로 간다
/// - 공유 폴더의 파일은 지우지 않는다 — 다른 PC 의 저장 콘티가 아직 쓰고 있을 수 있다
class ContiSyncRepository {
  ContiSyncRepository({PraiseDatabase? database})
    : _databaseProvider = database ?? PraiseDatabase.instance;

  final PraiseDatabase _databaseProvider;

  /// 이번 실행에서 공유 폴더에 있는 것을 확인한 파일('<공유 폴더>|<이름>'). 이름에 크기·수정 시각이
  /// 들어 있으므로 같은 경로의 파일이 바뀌면 이름도 바뀌어 다시 올라간다. 폴더를 바꾸면 새로 올린다.
  final _uploaded = <String>{};

  /// 이미 만든 콘티 동기화 모양. 콘티는 저장하면 안 바뀌므로 고친 시각이 같으면 다시 만들지 않는다
  /// (콘티마다 이미지 수십 장을 sync 마다 다시 stat 하지 않게).
  final _exported =
      <String, ({int updatedAt, String shared, SyncConti conti})>{};

  /// 이 PC 의 저장 콘티 전부 + 지운 콘티. 쓰는 이미지는 [sharedFiles] 에 올린다.
  Future<({List<SyncConti> contis, Map<String, int> deleted})> export({
    required String deviceId,
    required Directory sharedFiles,
    required Directory localFiles,
  }) async {
    final db = await _databaseProvider.database;
    final contis = await db.query('worship_contis', orderBy: 'uid');
    final items = await db.rawQuery('''
      SELECT wci.*, ps.uid AS song_uid
      FROM worship_conti_items wci
      LEFT JOIN praise_songs ps ON ps.id = wci.song_id
      ORDER BY wci.conti_id, wci.position
    ''');
    final itemsByConti = <int, List<Map<String, Object?>>>{};
    for (final row in items) {
      itemsByConti.putIfAbsent(row['conti_id'] as int, () => []).add(row);
    }

    final result = <SyncConti>[];
    for (final conti in contis) {
      final uid = conti['uid'] as String;
      final updatedAt = (conti['updated_at'] as int?) ?? 0;
      final cached = _exported[uid];
      if (cached != null &&
          cached.updatedAt == updatedAt &&
          cached.shared == sharedFiles.path) {
        result.add(cached.conti);
        continue;
      }
      try {
        final built = await _exportConti(
          conti,
          itemsByConti[conti['id']] ?? const [],
          deviceId: deviceId,
          sharedFiles: sharedFiles,
          localFiles: localFiles,
        );
        _exported[uid] = (
          updatedAt: updatedAt,
          shared: sharedFiles.path,
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

  Future<SyncConti> _exportConti(
    Map<String, Object?> conti,
    List<Map<String, Object?>> rows, {
    required String deviceId,
    required Directory sharedFiles,
    required Directory localFiles,
  }) async {
    Future<String?> pack(String? path) async {
      final name = await _upload(path, deviceId, sharedFiles, localFiles);
      return name == null ? path : SyncConti.fileRef(name);
    }

    final syncItems = <Map<String, Object?>>[];
    for (final row in rows) {
      final item = Map<String, Object?>.of(row)
        ..remove('id')
        ..remove('conti_id')
        ..remove('song_id')
        // 원본 PPT 경로는 이 PC 에서만 뜻이 있다.
        ..remove('image_source_path');
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

    final tombstones = <String, int>{};
    void addTombstone(String uid, int at) {
      final before = tombstones[uid];
      if (before == null || at > before) tombstones[uid] = at;
    }

    final storedTombstones = {
      for (final r in await db.query('conti_tombstones'))
        r['uid'] as String: r['deleted_at'] as int,
    };
    storedTombstones.forEach(addTombstone);
    final newest = <String, SyncConti>{};
    for (final remote in remotes) {
      remote.contiDeleted.forEach(addTombstone);
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
    }..removeAll(['id', 'conti_id', 'song_id']);

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
        for (var i = 0; i < rows.length; i++) {
          final row = Map<String, Object?>.of(rows[i]);
          final imagePaths = row['image_paths'] as String?;
          if (imagePaths != null) {
            row['image_paths'] = imagePaths
                .split('\n')
                .map((v) => _localPath(v, localFiles))
                .join('\n');
          }
          row['background'] = WorshipContiRepository.mapBackgroundPaths(
            row['background'],
            (v) => _localPath(v, localFiles),
          );
          row['song_id'] = await _songIdFor(txn, conti.items[i]['song_uid']);
          row['conti_id'] = contiId;
          row['position'] = position++;
          await txn.insert('worship_conti_items', row);
        }
      }

      var deleted = 0;
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
          deleted += 1;
        }
        if (storedTombstones[entry.key] != entry.value) {
          await txn.insert('conti_tombstones', {
            'uid': entry.key,
            'deleted_at': entry.value,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      return SyncMergeResult(
        addedCount: added,
        updatedCount: updated,
        deletedCount: deleted,
        pendingCount: pending,
      );
    });
  }

  // ── 내부 ────────────────────────────────────────────────────────────

  /// 로컬 파일을 공유 폴더에 올리고 그 이름을 돌려준다. 없는 파일이면 null.
  Future<String?> _upload(
    String? path,
    String deviceId,
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
      final key =
          '$deviceId|$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
      name = '${fnvHex(utf8.encode(key))}${p.extension(path).toLowerCase()}';
    }
    final key = '${sharedFiles.path}|$name';
    if (_uploaded.contains(key)) return name;
    final target = File(p.join(sharedFiles.path, name));
    if (!await target.exists()) {
      await sharedFiles.create(recursive: true);
      final temp = File('${target.path}.$deviceId.tmp');
      try {
        await local.copy(temp.path);
        await temp.rename(target.path);
      } on FileSystemException {
        await temp.delete().catchError((_) => temp);
        // 다른 PC 가 같은 파일을 먼저 올렸으면(이름이 같으면 내용도 같다) 그걸로 된다.
        if (!await target.exists()) rethrow;
      }
    }
    _uploaded.add(key);
    return name;
  }

  /// 콘티 항목이 실제로 가리키는 공유 파일 이름들. 남이 쓴 파일이라 '../' 같은 이름이
  /// 들어 있을 수 있다.
  /// 그런 이름이 하나라도 있으면 null.
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
    return names.every(_isSafeFileName) ? names : null;
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

  static bool _isSafeFileName(String name) =>
      name.isNotEmpty &&
      !name.startsWith('.') &&
      name == p.basename(name) &&
      !name.contains('/') &&
      !name.contains('\\');

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
      await localFiles.create(recursive: true);
      final temp = File('${local.path}.tmp');
      try {
        await shared.copy(temp.path);
        await temp.rename(local.path);
      } on FileSystemException {
        await temp.delete().catchError((_) => temp);
        return false;
      }
      _uploaded.add('${sharedFiles.path}|$name');
    }
    return true;
  }

  static String? _localPath(String? value, Directory localFiles) {
    final name = SyncConti.fileName(value);
    return name == null ? value : p.join(localFiles.path, name);
  }

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

  /// 곡 항목의 곡 uid → 이 PC 의 곡 id. 합쳐진 uid 도 따라간다. 없으면 null
  /// (콘티는 가사 스냅샷을 들고 있어서 곡이 없어도 불러와진다).
  static Future<int?> _songIdFor(DatabaseExecutor txn, Object? songUid) async {
    if (songUid is! String) return null;
    var uid = songUid;
    for (var i = 0; i < 32; i++) {
      final rows = await txn.query(
        'praise_songs',
        columns: ['id'],
        where: 'uid = ?',
        whereArgs: [uid],
        limit: 1,
      );
      if (rows.isNotEmpty) return rows.first['id'] as int;
      final alias = await txn.query(
        'song_uid_aliases',
        columns: ['uid'],
        where: 'alias = ?',
        whereArgs: [uid],
        limit: 1,
      );
      if (alias.isEmpty) return null;
      uid = alias.first['uid'] as String;
    }
    return null;
  }
}
