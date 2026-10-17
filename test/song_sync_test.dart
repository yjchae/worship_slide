import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/praise_repository.dart';
import 'package:worship_slides/src/features/praise/data/song_sync_repository.dart';
import 'package:worship_slides/src/features/praise/data/song_sync_service.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';

/// PC 한 대: 자기 DB + 자기 설정 폴더. 공유 폴더 하나를 여러 대가 같이 쓴다.
class _Pc {
  _Pc(this.repo, this.sync);

  final PraiseRepository repo;
  final SongSyncService sync;

  Future<List<PraiseSong>> songs() => repo.searchSongs('');

  Future<List<String>> titles() async =>
      (await songs()).map((s) => '${s.title}:${s.lyrics}').toList()..sort();
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory root;
  late String shared;

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
    final sync = SongSyncService(
      repository: SongSyncRepository(database: database),
      settingsDirectory: () async => dir,
      deviceName: name,
    );
    addTearDown(sync.dispose);
    await sync.load();
    if (join) await sync.setFolder(shared);
    // 앱과 같이: 곡을 고치면 동기화에 알린다.
    final repo = PraiseRepository(database: database)
      ..onSongsChanged = sync.markLocalChanged;
    return _Pc(repo, sync);
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
        final result = await pc.sync.syncNow();
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

    final dir = Directory(p.join(shared, SongSyncService.syncDirName));
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
    await a.sync.syncNow();
    expect(own.lastModifiedSync(), modified);
    expect(a.sync.status.value.peers, ['B']);
  });

  test('공유 폴더가 없으면 오류만 남기고 DB 는 그대로다', () async {
    final a = await newPc('A', join: false);
    await a.repo.insertSong(song('은혜', '가사'));
    await a.sync.setFolder(p.join(root.path, '없는 폴더'));
    expect(a.sync.status.value.lastError, contains('찾을 수 없습니다'));
    expect(await a.titles(), ['은혜:가사']);
  });

  test('version 16 DB 를 올리면 기존 곡에 uid 가 생긴다', () async {
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
  });
}
