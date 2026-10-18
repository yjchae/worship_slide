import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/praise_repository.dart';
import 'package:worship_slides/src/features/praise/data/song_sync_repository.dart';
import 'package:worship_slides/src/features/praise/data/sync_service.dart';
import 'package:worship_slides/src/features/praise/data/sync_snapshot.dart';
import 'package:worship_slides/src/features/praise/data/worship_conti_repository.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';
import 'package:worship_slides/src/features/praise/domain/worship_conti.dart';

/// PC 한 대: 자기 DB + 자기 설정 폴더. 공유 폴더 하나를 여러 대가 같이 쓴다.
class _Pc {
  _Pc(this.repo, this.contis, this.sync, this.dir);

  final PraiseRepository repo;
  final WorshipContiRepository contis;
  final SyncService sync;
  final Directory dir;

  Future<List<PraiseSong>> songs() => repo.searchSongs('');

  Future<List<String>> titles() async =>
      (await songs()).map((s) => '${s.title}:${s.lyrics}').toList()..sort();
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory root;
  late String shared;
  // 기기 id 겹침(쓴 시각 비교)을 시험하려고 시계를 고정한다.
  var now = DateTime(2026, 1, 1);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('song_sync_');
    shared = p.join(root.path, '공유 드라이브');
    await Directory(shared).create();
  });
  tearDown(() => root.delete(recursive: true));

  Future<_Pc> newPc(String name, {bool join = true}) async {
    final dir = await Directory(p.join(root.path, name)).create();
    final db = await databaseFactoryFfi.openDatabase(p.join(dir.path, 'a.db'));
    addTearDown(db.close);
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
      clock: () => now,
    );
    addTearDown(sync.dispose);
    await sync.load();
    if (join) await sync.setFolder(shared);
    // 앱과 같이: 곡을 고치면 동기화에 알린다(상태 표시만, 자동으로 맞추지 않는다).
    final repo = PraiseRepository(database: database)
      ..onSongsChanged = sync.markLocalChanged;
    return _Pc(repo, contis, sync, dir);
  }

  PraiseSong song(String title, String lyrics, [String english = '']) =>
      PraiseSong(
        id: null,
        fileName: '$title.pptx',
        title: title,
        lyrics: lyrics,
        englishLyrics: english,
      );

  Future<void> syncAll(List<_Pc> pcs) async {
    // 두 바퀴: 첫 바퀴에 앞 PC 는 뒤 PC 의 변경을 아직 못 본다.
    for (var round = 0; round < 2; round++) {
      for (final pc in pcs) {
        final result = await pc.sync.syncSongs();
        expect(pc.sync.status.value.lastError, isNull);
        expect(result, isNotNull);
      }
    }
  }

  test('추가·수정·삭제가 다른 PC 로 넘어간다', () async {
    final a = await newPc('A');
    final b = await newPc('B');

    await a.repo.insertSong(song('은혜', '은혜 가사'));
    await a.repo.insertSong(song('축복', '축복 가사', 'Blessing'));
    await a.repo.saveTranslations('일본어', {'은혜': '恵み'});
    await syncAll([a, b]);
    expect(await b.titles(), ['은혜:은혜 가사', '축복:축복 가사']);
    expect(await b.repo.translationsForTitle('은혜'), {'일본어': '恵み'});

    // B 에서 가사를 고치면 A 에 반영된다.
    final grace = (await b.songs()).firstWhere((s) => s.title == '은혜');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.repo.updateSong(
      PraiseSong(
        id: grace.id,
        fileName: grace.fileName,
        title: grace.title,
        lyrics: '고친 은혜 가사',
        englishLyrics: 'Grace',
      ),
    );
    await syncAll([a, b]);
    final aGrace = (await a.songs()).firstWhere((s) => s.title == '은혜');
    expect(aGrace.lyrics, '고친 은혜 가사');
    expect(aGrace.englishLyrics, 'Grace');

    // A 에서 지우면 B 에서도 지워진다.
    final bless = (await a.songs()).firstWhere((s) => s.title == '축복');
    await a.repo.deleteSongsByIds([bless.id!]);
    await syncAll([a, b]);
    expect(await b.titles(), ['은혜:고친 은혜 가사']);
  });

  test('같은 곡을 고치면 나중에 고친 쪽이 이긴다', () async {
    final a = await newPc('A');
    final b = await newPc('B');
    await a.repo.insertSong(song('사랑', '처음'));
    await syncAll([a, b]);

    Future<void> edit(_Pc pc, String lyrics) async {
      final s = (await pc.songs()).single;
      await pc.repo.updateSong(
        PraiseSong(
          id: s.id,
          fileName: s.fileName,
          title: s.title,
          lyrics: lyrics,
          englishLyrics: '',
        ),
      );
    }

    await edit(a, 'A 가 고침');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await edit(b, 'B 가 나중에 고침');
    await syncAll([a, b]);
    expect(await a.titles(), ['사랑:B 가 나중에 고침']);
    expect(await b.titles(), ['사랑:B 가 나중에 고침']);
  });

  test('지운 뒤 다른 PC 에서 고친 곡은 살아난다', () async {
    final a = await newPc('A');
    final b = await newPc('B');
    await a.repo.insertSong(song('평안', '가사'));
    await syncAll([a, b]);

    final onA = (await a.songs()).single;
    await a.repo.deleteSongsByIds([onA.id!]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final onB = (await b.songs()).single;
    await b.repo.updateSong(
      PraiseSong(
        id: onB.id,
        fileName: onB.fileName,
        title: onB.title,
        lyrics: '나중에 고친 가사',
        englishLyrics: '',
      ),
    );
    await syncAll([a, b]);
    expect(await a.titles(), ['평안:나중에 고친 가사']);
    expect(await b.titles(), ['평안:나중에 고친 가사']);
  });

  test('각자 가져온 같은 곡은 하나로 합쳐지고, 가사가 다르면 둘 다 남는다', () async {
    final a = await newPc('A', join: false);
    final b = await newPc('B', join: false);
    final c = await newPc('C', join: false);
    for (final pc in [a, b, c]) {
      await pc.repo.addNewSongs([
        song('은혜', '같은 가사'),
        song('축복', '${pc.sync.deviceId} 가사'),
      ]);
    }
    for (final pc in [a, b, c]) {
      await pc.sync.setFolder(shared);
    }
    await syncAll([a, b, c]);

    for (final pc in [a, b, c]) {
      final songs = await pc.songs();
      expect(songs.where((s) => s.title == '은혜'), hasLength(1));
      expect(songs.where((s) => s.title == '축복'), hasLength(3));
    }

    // 합쳐진 곡을 C 에서 고치면 나머지 PC 도 한 곡만 바뀐다(중복이 다시 생기지 않는다).
    final grace = (await c.songs()).firstWhere((s) => s.title == '은혜');
    await c.repo.updateSong(
      PraiseSong(
        id: grace.id,
        fileName: grace.fileName,
        title: '은혜',
        lyrics: 'C 가 고친 가사',
        englishLyrics: '',
      ),
    );
    await syncAll([a, b, c]);
    for (final pc in [a, b, c]) {
      final graces = (await pc.songs()).where((s) => s.title == '은혜');
      expect(graces.map((s) => s.lyrics), ['C 가 고친 가사']);
    }
  });

  test('PC 마다 자기 파일 하나만 쓰고, 바뀐 게 없으면 다시 쓰지 않는다', () async {
    final a = await newPc('A');
    final b = await newPc('B');
    await a.repo.insertSong(song('은혜', '가사'));
    await syncAll([a, b]);

    final dir = Directory(p.join(shared, syncDirName));
    final files = dir.listSync().whereType<File>().toList();
    expect(files.map((f) => p.basename(f.path)).toSet(), {
      '${a.sync.deviceId}.json',
      '${b.sync.deviceId}.json',
    });
    final own = File(p.join(dir.path, '${a.sync.deviceId}.json'));
    final json = jsonDecode(own.readAsStringSync()) as Map;
    expect(json['device_name'], 'A');
    final modified = own.lastModifiedSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    a.sync.markLocalChanged();
    await a.sync.syncSongs();
    expect(own.lastModifiedSync(), modified);
    expect(a.sync.status.value.peers, ['B']);
  });

  test('공유 폴더가 없으면 오류만 남기고 DB 는 그대로다', () async {
    final a = await newPc('A', join: false);
    await a.repo.insertSong(song('은혜', '가사'));
    await a.sync.setFolder(p.join(root.path, '없는 폴더'));
    expect(await a.sync.syncSongs(), isNull);
    expect(a.sync.status.value.lastError, contains('찾을 수 없습니다'));
    expect(await a.titles(), ['은혜:가사']);
  });

  test('version 16 DB 를 올리면 기존 곡·콘티에 uid 가 생긴다', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute('''
      CREATE TABLE praise_songs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_name TEXT NOT NULL,
        title TEXT NOT NULL,
        lyrics TEXT NOT NULL,
        english_lyrics TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE worship_conti_items (id INTEGER PRIMARY KEY, media TEXT)
    ''');
    await db.execute('''
      CREATE TABLE worship_contis (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.insert('worship_contis', {'name': '예전 콘티', 'created_at': 123});
    await db.execute('''
      CREATE TABLE song_translations (
        song_title TEXT NOT NULL,
        language TEXT NOT NULL,
        lyrics TEXT NOT NULL,
        PRIMARY KEY (song_title, language)
      )
    ''');
    await db.insert('praise_songs', {
      'file_name': 'a.pptx',
      'title': '은혜',
      'lyrics': '가사',
    });
    await upgradePraiseSchema(db, 16);
    final row = (await db.query('praise_songs')).single;
    expect(row['uid'], isA<String>());
    expect((row['uid'] as String).length, 32);
    expect(row['updated_at'], 0);
    // 예전 콘티도 uid(클라우드 파일 이름)를 받는다.
    final conti = (await db.query('worship_contis')).single;
    expect((conti['uid'] as String).length, 32);
  });

  group('보조 언어 가사', () {
    test('같은 곡을 합칠 때 한쪽에만 있는 번역이 지워지지 않는다', () async {
      final a = await newPc('A', join: false);
      final b = await newPc('B', join: false);
      await a.repo.addNewSongs([song('은혜', '가사')]);
      await a.repo.saveTranslations('일본어', {'은혜': '恵み'});
      await b.repo.addNewSongs([song('은혜', '가사')]);
      await b.repo.saveTranslations('중국어', {'은혜': '恩典'});
      await a.sync.setFolder(shared);
      await b.sync.setFolder(shared);
      await syncAll([a, b]);
      for (final pc in [a, b]) {
        expect(await pc.repo.translationsForTitle('은혜'), {
          '일본어': '恵み',
          '중국어': '恩典',
        });
      }
    });

    test('제목이 같은 다른 곡을 받아도 이 PC 의 번역이 남는다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await a.repo.insertSong(song('주 은혜임을', '편곡 1'));
      await a.repo.saveTranslations('일본어', {'주 은혜임을': '恵み'});
      await b.repo.insertSong(song('주 은혜임을', '편곡 2'));
      await syncAll([a, b]);
      expect((await a.songs()).map((s) => s.lyrics).toSet(), {'편곡 1', '편곡 2'});
      expect(await a.repo.translationsForTitle('주 은혜임을'), {'일본어': '恵み'});
      expect(await b.repo.translationsForTitle('주 은혜임을'), {'일본어': '恵み'});
    });

    test('번역을 지우면 다른 PC 에서도 지워진다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await a.repo.insertSong(song('은혜', '가사'));
      await a.repo.saveTranslations('일본어', {'은혜': '恵み'});
      await syncAll([a, b]);
      expect(await b.repo.translationsForTitle('은혜'), {'일본어': '恵み'});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await b.repo.deleteLanguage('일본어');
      await syncAll([a, b]);
      expect(await a.repo.translationsForTitle('은혜'), isEmpty);
    });
  });

  test('동기화 도중에 고친 곡도 놓치지 않고 올라간다', () async {
    final a = await newPc('A');
    final b = await newPc('B');
    await a.repo.insertSong(song('은혜', '처음'));
    await syncAll([a, b]);
    final grace = (await a.songs()).single;
    final running = a.sync.syncSongs();
    await a.repo.updateSong(
      PraiseSong(
        id: grace.id,
        fileName: grace.fileName,
        title: grace.title,
        lyrics: '동기화 중에 고침',
        englishLyrics: '',
      ),
    );
    await running;
    await syncAll([a, b]);
    expect(await b.titles(), ['은혜:동기화 중에 고침']);
  });

  test('동기화 도중에 닫아도 오류가 나지 않는다', () async {
    final a = await newPc('A');
    await a.repo.insertSong(song('은혜', '가사'));
    final running = a.sync.syncSongs();
    a.sync.dispose();
    await running;
  });

  group('리뷰 2차', () {
    test('내 파일이 지워지면 다시 쓴다', () async {
      final a = await newPc('A');
      await a.repo.insertSong(song('은혜', '가사'));
      await a.sync.syncSongs();
      final own = File(p.join(shared, syncDirName, '${a.sync.deviceId}.json'));
      own.deleteSync();
      await a.sync.syncSongs();
      expect(own.existsSync(), isTrue);
    });

    test('못 읽은 다른 PC 파일은 다음 차례에 다시 읽는다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await a.repo.insertSong(song('은혜', '가사'));
      await a.sync.syncSongs();
      final aFile = File(
        p.join(shared, syncDirName, '${a.sync.deviceId}.json'),
      );
      final good = aFile.readAsStringSync();
      final modified = aFile.lastModifiedSync();
      // 드라이브가 아직 다 못 내려받은 상태 — 크기·수정 시각은 같은데 내용이 깨져 있다.
      aFile.writeAsStringSync('x' * good.length);
      aFile.setLastModifiedSync(modified);
      await b.sync.syncSongs();
      expect(await b.songs(), isEmpty);
      aFile.writeAsStringSync(good);
      aFile.setLastModifiedSync(modified);
      await b.sync.syncSongs();
      expect(await b.titles(), ['은혜:가사']);
    });

    test('동기화를 켜기 전에 지운 곡은 다른 PC 의 같은 곡으로 살아나지 않는다', () async {
      final a = await newPc('A', join: false);
      final b = await newPc('B', join: false);
      for (final pc in [a, b]) {
        await pc.repo.addNewSongs([song('은혜', '가사'), song('축복', '가사')]);
      }
      final grace = (await a.songs()).firstWhere((s) => s.title == '은혜');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await a.repo.deleteSongsByIds([grace.id!]);
      await a.sync.setFolder(shared);
      await b.sync.setFolder(shared);
      await syncAll([a, b]);
      expect(await a.titles(), ['축복:가사']);
      expect(await b.titles(), ['축복:가사']);
    });

    test('같은 내용 곡 둘 중 하나만 지우면 나머지는 다른 PC 로도 간다', () async {
      // 같은 내용의 곡은 동기화하면 하나로 합쳐지지만, 합치기 전에 한쪽에서 하나만 지운 경우.
      final a = await newPc('A', join: false);
      final b = await newPc('B');
      await a.repo.insertSong(song('은혜', '가사'));
      await a.repo.insertSong(song('은혜', '가사'));
      final first = (await a.songs()).first;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await a.repo.deleteSongsByIds([first.id!]);
      await a.sync.setFolder(shared);
      await syncAll([a, b]);
      expect(await a.titles(), ['은혜:가사']);
      expect(await b.titles(), ['은혜:가사']);
    });
  });

  group('리뷰 3차', () {
    /// [from] PC 의 설정 폴더를 통째로 복사한 PC (마이그레이션·복제).
    Future<_Pc> clonePc(_Pc from, String name) async {
      final dir = await Directory(p.join(root.path, name)).create();
      File(
        p.join(from.dir.path, 'song_sync.json'),
      ).copySync(p.join(dir.path, 'song_sync.json'));
      final db = await databaseFactoryFfi.openDatabase(
        p.join(dir.path, 'a.db'),
      );
      addTearDown(db.close);
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
        clock: () => now,
      );
      addTearDown(sync.dispose);
      final repo = PraiseRepository(database: database)
        ..onSongsChanged = sync.markLocalChanged;
      await sync.load();
      return _Pc(repo, contis, sync, dir);
    }

    test('설정이 복제된 PC 는 기기 id 를 새로 만들어 서로 덮어쓰지 않는다', () async {
      final a = await newPc('A');
      await a.repo.insertSong(song('은혜', '가사'));
      await a.sync.syncSongs();
      final b = await clonePc(a, 'B');
      expect(b.sync.deviceId, a.sync.deviceId);
      // 복제 뒤 A 가 한 번 더 쓴다(설정의 마지막 표시는 복제 시점 것).
      await a.repo.insertSong(song('축복', '가사'));
      await a.sync.syncSongs();
      await b.repo.insertSong(song('사랑', '가사'));
      await b.sync.syncSongs();
      // 먼저 쓴 쪽의 파일을 다른 쪽이 덮으면, 덮인 쪽이 다음 차례에 알아채 새 id 로 비킨다
      // (어느 쪽이 비키든 된다).
      await syncAll([a, b]);
      expect(b.sync.deviceId, isNot(a.sync.deviceId));
      await syncAll([a, b]);
      expect(await a.titles(), ['사랑:가사', '은혜:가사', '축복:가사']);
      expect(await b.titles(), ['사랑:가사', '은혜:가사', '축복:가사']);
    });

    test('같은 PC 를 다시 켜면 기기 id 가 그대로다', () async {
      final a = await newPc('A');
      await a.repo.insertSong(song('은혜', '가사'));
      await a.sync.syncSongs();
      final again = await clonePc(a, 'A-다시');
      // 같은 PC 를 다시 켠 것과 같다(설정의 마지막 표시 = 파일의 표시).
      await again.sync.syncSongs();
      expect(again.sync.deviceId, a.sync.deviceId);
    });

    test('설정 파일이 깨졌으면 꺼진 것으로 덮어쓰지 않고 알린다', () async {
      final dir = await Directory(p.join(root.path, 'broken')).create();
      final settings = File(p.join(dir.path, 'song_sync.json'))
        ..writeAsStringSync('{"folder": "/x", "dev');
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await createPraiseSchema(db);
      final sync = SyncService(
        songs: SongSyncRepository(database: PraiseDatabase.forTesting(db)),
        contis: WorshipContiRepository(database: PraiseDatabase.forTesting(db)),
        settingsDirectory: () async => dir,
        deviceName: 'X',
      );
      addTearDown(sync.dispose);
      await sync.load();
      expect(sync.status.value.lastError, contains('설정'));
      expect(settings.readAsStringSync(), '{"folder": "/x", "dev');
    });

    test('바꾼 게 없이 저장하면 다른 PC 의 수정을 덮지 않는다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await a.repo.insertSong(song('은혜', '처음'));
      await syncAll([a, b]);
      final onA = (await a.songs()).single;
      await a.repo.updateSong(
        PraiseSong(
          id: onA.id,
          fileName: onA.fileName,
          title: onA.title,
          lyrics: 'A 가 고침',
          englishLyrics: '',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final onB = (await b.songs()).single;
      await b.repo.updateSong(onB); // 열었다가 그냥 저장
      await syncAll([a, b]);
      expect(await b.titles(), ['은혜:A 가 고침']);
    });
  });

  group('리뷰 4차', () {
    test('제목에 (와이드 스크린) 이 붙은 곡도 그냥 저장하면 고친 시각이 그대로다', () async {
      final a = await newPc('A');
      await a.repo.insertSong(song('은혜 (와이드 스크린)', '가사'));
      final loaded = (await a.songs()).single;
      expect(loaded.title, '은혜');
      final before = await a.sync.syncSongs();
      expect(before, isNotNull);
      final own = File(p.join(shared, syncDirName, '${a.sync.deviceId}.json'));
      final text = own.readAsStringSync();
      await a.repo.updateSong(loaded);
      a.sync.markLocalChanged();
      await a.sync.syncSongs();
      expect(own.readAsStringSync(), text);
    });
  });

  group('리뷰 5차', () {
    void writePeer(String id, SyncSnapshot snapshot) =>
        (File(p.join(shared, syncDirName, '$id.json'))
              ..parent.createSync(recursive: true))
            .writeAsStringSync(jsonEncode(snapshot.toJson()));

    SyncSong remoteSong(String uid, String lyrics, int at) => SyncSong(
      uid: uid,
      updatedAt: at,
      title: '은혜',
      fileName: '',
      lyrics: lyrics,
      englishLyrics: '',
    );

    test('한 번의 합치기에서 uid 가 합쳐져도 옛 uid 로 온 수정이 중복 곡이 되지 않는다', () async {
      final b = await newPc('B', join: false);
      await b.repo.insertSong(song('은혜', '처음'));
      final db = await databaseFactoryFfi.openDatabase(
        p.join(b.dir.path, 'a.db'),
      );
      addTearDown(db.close);
      await db.update('praise_songs', {'uid': 'b', 'updated_at': 1});
      // p1 은 같은 곡을 작은 uid 'a' 로, p2 는 옛 uid 'b' 로 고친 판을 갖고 있다.
      writePeer(
        'p1',
        SyncSnapshot(
          deviceId: 'p1',
          deviceName: 'p1',
          songs: [remoteSong('a', '처음', 1)],
          deleted: const {},
          aliases: const {},
        ),
      );
      writePeer(
        'p2',
        SyncSnapshot(
          deviceId: 'p2',
          deviceName: 'p2',
          songs: [remoteSong('b', '고친 가사', 5)],
          deleted: const {},
          aliases: const {},
        ),
      );
      await b.sync.setFolder(shared);
      await b.sync.syncSongs();
      expect(await b.titles(), ['은혜:고친 가사']);
    });

    test('다시 가져오기에서 파일 이름만 바뀐 곡도 다른 PC 로 넘어간다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await a.repo.replaceAllSongs([song('은혜', '가사')]);
      await syncAll([a, b]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await a.repo.replaceAllSongs([
        PraiseSong(
          id: null,
          fileName: '새 파일.pptx',
          title: '은혜',
          lyrics: '가사',
          englishLyrics: '',
        ),
      ]);
      await syncAll([a, b]);
      expect((await b.songs()).single.fileName, '새 파일.pptx');
    });
  });

  group('리뷰 6차', () {
    void writePeer(String id, SyncSnapshot snapshot) =>
        (File(p.join(shared, syncDirName, '$id.json'))
              ..parent.createSync(recursive: true))
            .writeAsStringSync(jsonEncode(snapshot.toJson()));

    // 시계가 크게 앞선 PC 에서 온 곡·콘티.
    final future = DateTime.now().millisecondsSinceEpoch + 3600 * 1000;

    test('시계가 앞선 PC 에서 온 곡도 이 PC 에서 지우면 지워진 채로 남는다', () async {
      final b = await newPc('B');
      writePeer(
        'fast',
        SyncSnapshot(
          deviceId: 'fast',
          deviceName: 'fast',
          songs: [
            SyncSong(
              uid: 's1',
              updatedAt: future,
              title: '은혜',
              fileName: '',
              lyrics: '가사',
              englishLyrics: '',
            ),
          ],
          deleted: const {},
          aliases: const {},
        ),
      );
      await b.sync.syncSongs();
      final got = (await b.songs()).single;
      await b.repo.deleteSongsByIds([got.id!]);
      await b.sync.syncSongs();
      expect(await b.songs(), isEmpty);
    });

    test('합친 뒤 따로 고친 두 곡이 같은 uid 로 모여도 둘 다 남는다', () async {
      final b = await newPc('B', join: false);
      await b.repo.insertSong(song('은혜', '편곡 1'));
      await b.repo.insertSong(song('은혜', '편곡 2'));
      final db = await databaseFactoryFfi.openDatabase(
        p.join(b.dir.path, 'a.db'),
      );
      addTearDown(db.close);
      final rows = await db.query('praise_songs', orderBy: 'id');
      await db.update(
        'praise_songs',
        {'uid': 'a'},
        where: 'id = ?',
        whereArgs: [rows[0]['id']],
      );
      await db.update(
        'praise_songs',
        {'uid': 'b'},
        where: 'id = ?',
        whereArgs: [rows[1]['id']],
      );
      // 다른 PC 가 예전에 b → a 로 합쳤다(그때는 내용이 같았다).
      writePeer(
        'p1',
        SyncSnapshot(
          deviceId: 'p1',
          deviceName: 'p1',
          songs: const [],
          deleted: const {},
          aliases: const {'b': 'a'},
        ),
      );
      await b.sync.setFolder(shared);
      await b.sync.syncSongs();
      expect(await b.titles(), ['은혜:편곡 1', '은혜:편곡 2']);
    });
  });

  group('손으로 동기화', () {
    test('찬양을 고쳐도 저절로 올라가지 않고, 동기화를 눌러야 넘어간다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await a.repo.insertSong(song('은혜', '가사'));
      expect(a.sync.status.value.hasLocalChanges, isTrue);
      await b.sync.syncSongs();
      expect(await b.songs(), isEmpty);

      await a.sync.syncSongs();
      expect(a.sync.status.value.hasLocalChanges, isFalse);
      final result = await b.sync.syncSongs();
      expect(result!.addedCount, 1);
      expect(await b.titles(), ['은혜:가사']);
    });

    test('켤 때 확인은 DB 를 바꾸지 않고 새 찬양·바뀐 찬양만 센다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await a.repo.insertSong(song('은혜', '가사'));
      await a.repo.insertSong(song('축복', '가사'));
      await syncAll([a, b]);
      final grace = (await a.songs()).firstWhere((s) => s.title == '은혜');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await a.repo.updateSong(
        PraiseSong(
          id: grace.id,
          fileName: grace.fileName,
          title: grace.title,
          lyrics: '고친 가사',
          englishLyrics: '',
        ),
      );
      await a.repo.insertSong(song('사랑', '가사'));
      await a.sync.syncSongs();

      final check = await b.sync.checkForUpdates();
      expect(check!.songs.addedCount, 1);
      expect(check.songs.updatedCount, 1);
      expect(check.hasAnything, isTrue);
      // 세기만 했다 — B 는 그대로다.
      expect(await b.titles(), ['은혜:가사', '축복:가사']);

      await b.sync.syncSongs();
      expect(await b.titles(), ['사랑:가사', '은혜:고친 가사', '축복:가사']);
      expect((await b.sync.checkForUpdates())!.hasAnything, isFalse);
    });

    test('동기화 폴더가 꺼져 있으면 켤 때 확인을 안 한다', () async {
      final a = await newPc('A', join: false);
      expect(await a.sync.checkForUpdates(), isNull);
    });
  });

  group('클라우드 콘티', () {
    Future<WorshipConti> saveSample(_Pc pc) async {
      await pc.repo.insertSong(song('은혜', '은혜 가사'));
      final grace = (await pc.songs()).single;
      final page = File(p.join(pc.dir.path, '0001.png'))
        ..writeAsBytesSync([1, 2, 3]);
      await pc.contis.saveConti('주일 예배', [
        (uid: 1, item: SongStagingItem(grace)),
        (
          uid: 2,
          item: ImageStagingItem(
            sourceName: '광고.pptx',
            imagePaths: [page.path],
          ),
        ),
      ]);
      return (await pc.contis.listContis()).single;
    }

    test('올린 콘티를 다른 PC 가 이미지까지 받고, 곡은 그 PC 의 곡에 이어진다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      final conti = await saveSample(a);
      await a.sync.syncSongs();
      await a.sync.uploadConti(conti);

      final check = await b.sync.checkForUpdates();
      expect(check!.newContis.map((c) => c.name), ['주일 예배']);
      expect(check.newContis.single.uploadedBy, 'A');

      await b.sync.syncSongs();
      await b.sync.downloadConti(check.newContis.single);
      final list = await b.contis.listContis();
      expect(list.map((c) => c.name), ['주일 예배']);
      final loaded = await b.contis.loadConti(list.single.id, 1);
      expect(loaded.missingCount, 0);
      final songItem = loaded.items[0].item as SongStagingItem;
      expect(songItem.song.id, (await b.songs()).single.id);
      final image = loaded.items[1].item as ImageStagingItem;
      expect(File(image.imagePaths.single).readAsBytesSync(), [1, 2, 3]);
      // 받은 콘티는 더 이상 "새 콘티"가 아니다.
      expect((await b.sync.checkForUpdates())!.newContis, isEmpty);
    });

    test('같은 콘티를 다시 올리면 덮어쓰고, 다시 받으면 바꾼다(둘이 되지 않는다)', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      final conti = await saveSample(a);
      await a.sync.uploadConti(conti);
      await a.sync.uploadConti(conti);
      final cloud = (await b.sync.listCloudContis()).cloud;
      expect(cloud, hasLength(1));
      await b.sync.downloadConti(cloud.single);
      await b.sync.downloadConti(cloud.single);
      expect(await b.contis.listContis(), hasLength(1));
      expect((await b.sync.listCloudContis()).local.keys, [cloud.single.uid]);
    });

    test('클라우드에서 지워도 이미 받은 PC 의 콘티는 남는다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await a.sync.uploadConti(await saveSample(a));
      final cloud = (await b.sync.listCloudContis()).cloud.single;
      await b.sync.downloadConti(cloud);
      await a.sync.deleteCloudConti(cloud);
      expect((await b.sync.listCloudContis()).cloud, isEmpty);
      expect(await b.contis.listContis(), hasLength(1));
    });

    test('콘티 파일이 아직 안 내려왔으면 받지 않고 알린다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await a.sync.uploadConti(await saveSample(a));
      final cloud = (await b.sync.listCloudContis()).cloud.single;
      File(
        p.join(shared, syncDirName, 'contis', '${cloud.uid}.wsconti'),
      ).deleteSync();
      await expectLater(
        b.sync.downloadConti(cloud),
        throwsA(isA<FileSystemException>()),
      );
      expect(await b.contis.listContis(), isEmpty);
    });

    test('정보 파일의 uid 가 이상하면 목록에 보이지 않는다', () async {
      final b = await newPc('B');
      final dir = Directory(p.join(shared, syncDirName, 'contis'))
        ..createSync(recursive: true);
      File(p.join(dir.path, '../../evil.json')).writeAsStringSync('{}');
      File(
        p.join(dir.path, 'x.json'),
      ).writeAsStringSync(jsonEncode({'uid': '../../x', 'name': '나쁜 콘티'}));
      expect((await b.sync.listCloudContis()).cloud, isEmpty);
    });

    test('파일에서 가져오기는 늘 새 콘티다(클라우드 받기와 다르다)', () async {
      final a = await newPc('A');
      final conti = await saveSample(a);
      final out = p.join(root.path, 'x.wsconti');
      await a.contis.exportContiFile(conti.id, out);
      await a.contis.importContiFile(out);
      expect(await a.contis.listContis(), hasLength(2));
    });
  });

  group('수동 동기화 리뷰', () {
    test('다른 PC 콘티 파일에 담기지 않은 로컬 경로는 버린다(이 PC 파일이 새어 나가지 않게)', () async {
      final b = await newPc('B');
      final secret = File(p.join(root.path, 'secret.png'))
        ..writeAsBytesSync([9]);
      final file = File(p.join(root.path, 'evil.wsconti'))
        ..writeAsStringSync(
          jsonEncode({
            'format': WorshipContiRepository.contiFileFormat,
            'version': 1,
            'name': '나쁜 콘티',
            'items': [
              {
                'item_type': 'image',
                'image_paths': secret.path,
                'image_source_path': secret.path,
                'background': jsonEncode({
                  'color': '#000000',
                  'image_path': secret.path,
                }),
              },
              {
                'item_type': 'blank',
                'media': jsonEncode({'kind': 'video', 'source': secret.path}),
              },
            ],
            'files': const {},
          }),
        );
      final id = await b.contis.importContiFile(file.path);
      final loaded = await b.contis.loadConti(id, 1);
      // 이미지 항목은 유실로 빠지고, 빈 페이지의 동영상 경로도 버려진다.
      expect(loaded.missingCount, 1);
      final blank = loaded.items.single.item as BlankStagingItem;
      expect(blank.media, isNull);
      // 다시 내보내도 이 PC 의 파일이 실려 나가지 않는다.
      final out = p.join(root.path, 'out.wsconti');
      await b.contis.exportContiFile(id, out);
      final files = (jsonDecode(File(out).readAsStringSync()) as Map)['files'];
      expect(files, isEmpty);
    });

    test('켤 때 확인은 지난번에 안 올린 이 PC 의 수정도 알린다', () async {
      final a = await newPc('A');
      await a.repo.insertSong(song('은혜', '가사'));
      await a.sync.syncSongs();
      expect((await a.sync.checkForUpdates())!.localChanges, isFalse);
      await a.repo.insertSong(song('축복', '가사'));
      // 프로그램을 다시 켠 것처럼 상태를 모르는 새 서비스로 본다.
      final again = SyncService(
        songs: SongSyncRepository(
          database: PraiseDatabase.forTesting(
            await databaseFactoryFfi.openDatabase(p.join(a.dir.path, 'a.db')),
          ),
        ),
        contis: a.contis,
        settingsDirectory: () async => a.dir,
        deviceName: 'A',
        clock: () => now,
      );
      addTearDown(again.dispose);
      await again.load();
      final check = await again.checkForUpdates();
      expect(check!.localChanges, isTrue);
      expect(check.hasAnything, isTrue);
    });

    test('켤 때 한 번 알린 콘티는 다음에 다시 알리지 않는다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await a.contis.saveConti('콘티', [
        (uid: 1, item: const BlankStagingItem(mainText: '환영')),
      ]);
      await a.sync.uploadConti((await a.contis.listContis()).single);
      final first = await b.sync.checkForUpdates();
      expect(first!.newContis, hasLength(1));
      await b.sync.markContisSeen(first.newContis.map((c) => c.uid));
      expect((await b.sync.checkForUpdates())!.newContis, isEmpty);
      // 클라우드 콘티 창에는 그대로 보인다.
      expect((await b.sync.listCloudContis()).cloud, hasLength(1));
    });

    test('공유 폴더가 없으면 콘티를 올렸다고 하지 않는다', () async {
      final a = await newPc('A', join: false);
      await a.sync.setFolder(p.join(root.path, '없는 드라이브'));
      await a.contis.saveConti('콘티', [
        (uid: 1, item: const BlankStagingItem(mainText: '환영')),
      ]);
      await expectLater(
        a.sync.uploadConti((await a.contis.listContis()).single),
        throwsA(isA<FileSystemException>()),
      );
      expect(Directory(p.join(root.path, '없는 드라이브')).existsSync(), isFalse);
    });

    test('다른 PC 파일을 못 읽어도 동기화는 성공이고 경고만 남긴다', () async {
      final a = await newPc('A');
      File(p.join(shared, syncDirName, 'broken.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{깨짐');
      expect(await a.sync.syncSongs(), isNotNull);
      expect(a.sync.status.value.lastError, isNull);
      expect(a.sync.status.value.warning, contains('1개'));
    });
  });

  group('마지막 리뷰', () {
    test('동기화 도중에 고친 찬양은 "안 올림" 표시가 남는다', () async {
      final a = await newPc('A');
      await a.repo.insertSong(song('은혜', '가사'));
      final running = a.sync.syncSongs();
      await a.repo.insertSong(song('축복', '가사'));
      await running;
      expect(a.sync.status.value.hasLocalChanges, isTrue);
      await a.sync.syncSongs();
      expect(a.sync.status.value.hasLocalChanges, isFalse);
    });

    test('예전 판이 쓴 내 파일(콘티 칸이 있음)을 "안 올린 수정"으로 보지 않는다', () async {
      final a = await newPc('A');
      await a.repo.insertSong(song('은혜', '가사'));
      await a.sync.syncSongs();
      final own = File(p.join(shared, syncDirName, '${a.sync.deviceId}.json'));
      final json = jsonDecode(own.readAsStringSync()) as Map
        ..['contis'] = []
        ..['conti_deleted'] = {};
      own.writeAsStringSync(jsonEncode(json));
      expect((await a.sync.checkForUpdates())!.localChanges, isFalse);
    });

    test('켤 때 확인은 uid 없는 행도 건드리지 않는다', () async {
      final a = await newPc('A');
      await a.repo.insertSong(song('은혜', '가사'));
      final db = await databaseFactoryFfi.openDatabase(
        p.join(a.dir.path, 'a.db'),
      );
      addTearDown(db.close);
      await db.update('praise_songs', {'uid': null});
      await a.sync.checkForUpdates();
      expect((await db.query('praise_songs')).single['uid'], isNull);
      // 실제 동기화는 채운다.
      await a.sync.syncSongs();
      expect((await db.query('praise_songs')).single['uid'], isA<String>());
    });

    test('깨진 콘티 파일을 받다 실패하면 푼 이미지 폴더를 남기지 않는다', () async {
      final a = await newPc('A');
      final file = File(p.join(root.path, 'broken.wsconti'))
        ..writeAsStringSync(
          jsonEncode({
            'format': WorshipContiRepository.contiFileFormat,
            'name': '깨진 콘티',
            'items': const [],
            'files': {
              'file0.png': base64Encode([1, 2]),
              'file1.png': '###',
            },
          }),
        );
      await expectLater(a.contis.importContiFile(file.path), throwsA(anything));
      expect(
        Directory(p.join(a.dir.path, 'imported_contis')).existsSync()
            ? Directory(p.join(a.dir.path, 'imported_contis')).listSync()
            : const [],
        isEmpty,
      );
      expect(await a.contis.listContis(), isEmpty);
    });
  });
}
