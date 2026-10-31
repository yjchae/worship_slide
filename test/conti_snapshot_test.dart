import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/praise_repository.dart';
import 'package:worship_slides/src/features/praise/data/song_sync_repository.dart';
import 'package:worship_slides/src/features/praise/data/sync_service.dart';
import 'package:worship_slides/src/features/praise/data/sync_snapshot.dart';
import 'package:worship_slides/src/features/praise/data/sync_store.dart';
import 'package:worship_slides/src/features/praise/data/worship_conti_repository.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';

/// 저장한 콘티는 라이브러리 곡이 바뀌어도(직접 수정·동기화) 저장 당시 그대로 불러온다.
void main() {
  setUpAll(sqfliteFfiInit);

  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('snap_'));
  tearDown(() => root.delete(recursive: true));

  Future<Database> openDb(String name) async {
    final db = await databaseFactoryFfi.openDatabase(p.join(root.path, name));
    addTearDown(db.close);
    return db;
  }

  PraiseSong song(String title, String lyrics, [String english = '']) =>
      PraiseSong(
        id: null,
        fileName: '$title.pptx',
        title: title,
        lyrics: lyrics,
        englishLyrics: english,
      );

  Future<PraiseSong> onlySong(PraiseRepository repo) async =>
      (await repo.searchSongs('')).single;

  Future<PraiseSong> loadedSong(WorshipContiRepository contis, int id) async {
    final loaded = await contis.loadConti(id, 1);
    expect(loaded.missingCount, 0);
    return (loaded.items.single.item as SongStagingItem).song;
  }

  Future<void> expectSnapshot(
    WorshipContiRepository contis,
    int contiId,
    int songId,
  ) async {
    final s = await loadedSong(contis, contiId);
    expect(s.id, songId);
    expect(s.title, '은혜');
    expect(s.lyrics, '은혜 가사');
    expect(s.englishLyrics, 'Grace');
  }

  test('곡을 고쳐도 저장한 콘티는 저장 당시 제목·가사·보조 그대로다', () async {
    final db = await openDb('a.db');
    await createPraiseSchema(db);
    final database = PraiseDatabase.forTesting(db);
    final repo = PraiseRepository(database: database);
    final contis = WorshipContiRepository(
      database: database,
      supportDirectory: () async => root,
    );
    await repo.insertSong(song('은혜', '은혜 가사', 'Grace'));
    final saved = await onlySong(repo);
    final contiId = await contis.saveConti('주일', [
      (uid: 1, item: SongStagingItem(saved)),
    ]);

    await repo.updateSong(
      PraiseSong(
        id: saved.id,
        fileName: saved.fileName,
        title: '은혜 (새 제목)',
        lyrics: '고친 가사',
        englishLyrics: 'New grace',
      ),
    );
    expect((await onlySong(repo)).title, '은혜 (새 제목)');
    await expectSnapshot(contis, contiId, saved.id!);
  });

  test('다른 PC 에서 동기화로 곡이 바뀌어도 저장한 콘티는 그대로다', () async {
    final shared = p.join(root.path, 'shared');
    await Directory(shared).create();

    Future<(PraiseRepository, WorshipContiRepository, SyncService)> pc(
      String name,
    ) async {
      final dir = await Directory(p.join(root.path, name)).create();
      final db = await openDb('$name.db');
      await createPraiseSchema(db);
      final database = PraiseDatabase.forTesting(db);
      final contis = WorshipContiRepository(
        database: database,
        supportDirectory: () async => dir,
      );
      final sync = SyncService(
        songs: SongSyncRepository(database: database),
        contis: contis,
        settingsDirectory: () async => dir,
        deviceName: name,
      );
      addTearDown(sync.dispose);
      await sync.load();
      await sync.useStore(FolderSyncStore(p.join(shared, syncDirName)));
      return (PraiseRepository(database: database), contis, sync);
    }

    final (aRepo, aContis, aSync) = await pc('A');
    final (bRepo, _, bSync) = await pc('B');
    Future<void> syncAll() async {
      for (var round = 0; round < 2; round++) {
        for (final s in [aSync, bSync]) {
          await s.syncSongs();
          expect(s.status.value.lastError, isNull);
        }
      }
    }

    await aRepo.insertSong(song('은혜', '은혜 가사', 'Grace'));
    await syncAll();
    final saved = await onlySong(aRepo);
    final contiId = await aContis.saveConti('주일', [
      (uid: 1, item: SongStagingItem(saved)),
    ]);

    // B 에서 제목·가사를 고쳐 동기화하면 A 의 라이브러리 곡이 바뀐다.
    final bSong = await onlySong(bRepo);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await bRepo.updateSong(
      PraiseSong(
        id: bSong.id,
        fileName: bSong.fileName,
        title: '은혜 (B 에서 고침)',
        lyrics: 'B 가사',
        englishLyrics: 'B grace',
      ),
    );
    await syncAll();
    final aNow = await onlySong(aRepo);
    expect(aNow.title, '은혜 (B 에서 고침)');
    expect(aNow.lyrics, 'B 가사');

    await expectSnapshot(aContis, contiId, saved.id!);
  });

  test('version 18 의 스냅샷 빈 곡 항목은 19 로 올리면 그때 곡으로 굳는다', () async {
    final db = await openDb('old.db');
    await createPraiseSchema(db);
    final database = PraiseDatabase.forTesting(db);
    final repo = PraiseRepository(database: database);
    final contis = WorshipContiRepository(
      database: database,
      supportDirectory: () async => root,
    );
    await repo.insertSong(song('은혜', '은혜 가사', 'Grace'));
    final saved = await onlySong(repo);
    final uid = (await db.query('praise_songs')).single['uid'] as String?;

    // 옛 행: 곡 id 만 있고 스냅샷 칸은 비었다. 지운 곡을 가리키는 행도 하나.
    final contiId = await db.insert('worship_contis', {
      'name': '옛 콘티',
      'created_at': 0,
    });
    await db.insert('worship_conti_items', {
      'conti_id': contiId,
      'position': 0,
      'item_type': 'song',
      'song_id': saved.id,
    });
    await db.insert('worship_conti_items', {
      'conti_id': contiId,
      'position': 1,
      'item_type': 'song',
      'song_id': 9999,
    });
    await db.setVersion(18);

    await upgradePraiseSchema(db, 18);

    final rows = await db.query('worship_conti_items', orderBy: 'position ASC');
    expect(rows[0]['song_title'], '은혜');
    expect(rows[0]['song_lyrics'], '은혜 가사');
    expect(rows[0]['song_english_lyrics'], 'Grace');
    expect(rows[0]['song_uid'], uid);
    expect(rows[1]['song_title'], isNull);
    expect(rows[1]['song_lyrics'], isNull);

    await repo.updateSong(
      PraiseSong(
        id: saved.id,
        fileName: saved.fileName,
        title: '은혜 (새 제목)',
        lyrics: '고친 가사',
        englishLyrics: 'New grace',
      ),
    );
    final loaded = await contis.loadConti(contiId, 1);
    // 지운 곡 행은 스냅샷이 없어 빠진다.
    expect(loaded.missingCount, 1);
    final s = (loaded.items.single.item as SongStagingItem).song;
    expect(s.id, saved.id);
    expect(s.title, '은혜');
    expect(s.lyrics, '은혜 가사');
    expect(s.englishLyrics, 'Grace');
  });

  test('가사 스냅샷만 있고 영어 칸이 빈 옛 행은 지금 영어 가사로 안 채운다', () async {
    final db = await openDb('mixed.db');
    await createPraiseSchema(db);
    final repo = PraiseRepository(database: PraiseDatabase.forTesting(db));
    await repo.insertSong(song('은혜', '새 가사', 'New grace'));
    final saved = await onlySong(repo);
    final contiId = await db.insert('worship_contis', {
      'name': '옛 콘티',
      'created_at': 0,
    });
    await db.insert('worship_conti_items', {
      'conti_id': contiId,
      'position': 0,
      'item_type': 'song',
      'song_id': saved.id,
      'song_lyrics': '옛 가사',
    });
    await db.setVersion(18);

    await upgradePraiseSchema(db, 18);

    final row = (await db.query('worship_conti_items')).single;
    expect(row['song_lyrics'], '옛 가사');
    expect(row['song_english_lyrics'], '');
    expect(row['song_title'], '은혜');
  });

  test('version 18 DB 파일을 앱처럼 열면 스냅샷이 굳는다', () async {
    final path = p.join(root.path, 'worship_slides.db');
    final old = await databaseFactoryFfi.openDatabase(path);
    await createPraiseSchema(old);
    await PraiseRepository(
      database: PraiseDatabase.forTesting(old),
    ).insertSong(song('은혜', '은혜 가사', 'Grace'));
    final songId = (await old.query('praise_songs')).single['id'] as int;
    final contiId = await old.insert('worship_contis', {
      'name': '옛 콘티',
      'created_at': 0,
    });
    await old.insert('worship_conti_items', {
      'conti_id': contiId,
      'position': 0,
      'item_type': 'song',
      'song_id': songId,
    });
    await old.setVersion(18);
    await old.close();

    expect(await readSqliteUserVersion(path), 18);
    final backup = await backupBeforeUpgrade(
      path,
      toVersion: PraiseDatabase.schemaVersion,
    );
    expect(backup, isNotNull);
    // PraiseDatabase.database 와 같은 열기(버전·onCreate·onUpgrade).
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: PraiseDatabase.schemaVersion,
        onCreate: (db, version) => createPraiseSchema(db),
        onUpgrade: (db, oldVersion, newVersion) =>
            upgradePraiseSchema(db, oldVersion),
      ),
    );
    addTearDown(db.close);
    expect(await db.getVersion(), PraiseDatabase.schemaVersion);

    final database = PraiseDatabase.forTesting(db);
    final repo = PraiseRepository(database: database);
    final saved = await onlySong(repo);
    await repo.updateSong(
      PraiseSong(
        id: saved.id,
        fileName: saved.fileName,
        title: '은혜 (새 제목)',
        lyrics: '고친 가사',
        englishLyrics: 'New grace',
      ),
    );
    final contis = WorshipContiRepository(
      database: database,
      supportDirectory: () async => root,
    );
    await expectSnapshot(contis, contiId, songId);
  });
}
