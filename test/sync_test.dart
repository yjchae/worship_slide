import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/conti_sync_repository.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/praise_repository.dart';
import 'package:worship_slides/src/features/praise/data/song_sync_repository.dart';
import 'package:worship_slides/src/features/praise/data/sync_service.dart';
import 'package:worship_slides/src/features/praise/data/sync_snapshot.dart';
import 'package:worship_slides/src/features/praise/data/worship_conti_repository.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/slide_background.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';

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
  // 받지 못한 콘티를 다시 보는 간격을 시험하려고 시계를 손으로 돌린다.
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
    final sync = SyncService(
      songs: SongSyncRepository(database: database),
      contis: ContiSyncRepository(database: database),
      settingsDirectory: () async => dir,
      deviceName: name,
      clock: () => now,
    );
    addTearDown(sync.dispose);
    await sync.load();
    if (join) await sync.setFolder(shared);
    // 앱과 같이: 곡을 고치면 동기화에 알린다.
    final repo = PraiseRepository(database: database)
      ..onSongsChanged = sync.markLocalChanged;
    final contis = WorshipContiRepository(database: database)
      ..onContisChanged = sync.markLocalChanged;
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

    final dir = Directory(p.join(shared, SyncService.syncDirName));
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
    final conti = (await db.query('worship_contis')).single;
    expect((conti['uid'] as String).length, 32);
    // 예전 콘티는 저장한 시각을 고친 시각으로 쓴다.
    expect(conti['updated_at'], 123);
  });

  group('저장 콘티', () {
    /// A 에 곡 하나 + PPT 페이지 이미지 + 배경 이미지를 쓰는 콘티를 저장한다.
    Future<String> saveSampleConti(_Pc pc) async {
      await pc.repo.insertSong(song('은혜', '은혜 가사'));
      final grace = (await pc.songs()).single;
      final pages = await Directory(p.join(pc.dir.path, 'ppt')).create();
      final page1 = File(p.join(pages.path, '0001.png'))
        ..writeAsBytesSync([1, 2, 3]);
      final page2 = File(p.join(pages.path, '0002.png'))
        ..writeAsBytesSync([4, 5, 6]);
      final bg = File(p.join(pc.dir.path, 'bg.jpg'))..writeAsBytesSync([7, 8]);
      await pc.contis.saveConti(
        '주일 예배',
        [
          (uid: 1, item: SongStagingItem(grace)),
          (
            uid: 2,
            item: ImageStagingItem(
              sourceName: '광고.pptx',
              imagePaths: [page1.path, page2.path],
              sourcePath: p.join(pc.dir.path, '광고.pptx'),
            ),
          ),
        ],
        notes: {'1:0': '천천히'},
        backgrounds: {
          1: SlideBackground(
            color: const Color(0xFF000000),
            imagePath: bg.path,
          ),
        },
      );
      return bg.path;
    }

    test('이미지까지 다른 PC 로 넘어가고, 곡 항목은 그 PC 의 곡에 이어진다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await saveSampleConti(a);
      await syncAll([a, b]);

      final list = await b.contis.listContis();
      expect(list.map((c) => c.name), ['주일 예배']);
      final loaded = await b.contis.loadConti(list.single.id, 100);
      expect(loaded.missingCount, 0);
      expect(loaded.items, hasLength(2));

      final songItem = loaded.items[0].item as SongStagingItem;
      final bGrace = (await b.songs()).single;
      expect(songItem.song.id, bGrace.id);
      expect(songItem.song.lyrics, '은혜 가사');
      expect(loaded.notes, {'100:0': '천천히'});

      final image = loaded.items[1].item as ImageStagingItem;
      final synced = p.join(b.dir.path, 'synced_files');
      expect(
        image.imagePaths.every((path) => p.isWithin(synced, path)),
        isTrue,
      );
      expect(File(image.imagePaths[1]).readAsBytesSync(), [4, 5, 6]);
      // 원본 PPT 경로는 그 PC 에서만 뜻이 있어 넘기지 않는다.
      expect(image.sourcePath, isNull);
      final background = loaded.backgrounds[100]!;
      expect(p.isWithin(synced, background.imagePath!), isTrue);
      expect(File(background.imagePath!).readAsBytesSync(), [7, 8]);

      // B 가 받은 파일을 다시 올려도 공유 폴더에 파일이 늘지 않는다.
      final files = Directory(
        p.join(shared, SyncService.syncDirName, SyncService.filesDirName),
      );
      expect(files.listSync(), hasLength(3));
    });

    test('지운 콘티는 다른 PC 에서도 지워지고, 다른 PC 에서 저장한 콘티는 돌아온다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await saveSampleConti(a);
      await syncAll([a, b]);

      final onB = (await b.contis.listContis()).single;
      await b.contis.deleteConti(onB.id);
      await b.contis.saveConti('B 의 콘티', [
        (uid: 1, item: const BlankStagingItem(mainText: '환영합니다')),
      ]);
      await syncAll([a, b]);
      expect((await a.contis.listContis()).map((c) => c.name), ['B 의 콘티']);
      expect((await b.contis.listContis()).map((c) => c.name), ['B 의 콘티']);
    });

    test('파일이 아직 안 올라왔으면 기다렸다가 올라오면 받는다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await saveSampleConti(a);
      await a.sync.syncNow();

      // 드라이브가 이미지를 아직 못 올린 상태를 흉내 낸다.
      final files = Directory(
        p.join(shared, SyncService.syncDirName, SyncService.filesDirName),
      );
      final hidden = Directory(p.join(root.path, 'hidden'));
      await files.rename(hidden.path);
      await b.sync.syncNow();
      expect(await b.contis.listContis(), isEmpty);
      expect(b.sync.status.value.pendingContis, 1);

      await hidden.rename(files.path);
      // 바로는 다시 보지 않는다(매분 전체를 다시 읽지 않게) — 1분 뒤에 본다.
      await b.sync.syncNow();
      expect(await b.contis.listContis(), isEmpty);
      now = now.add(const Duration(minutes: 1));
      await b.sync.syncNow();
      expect((await b.contis.listContis()).map((c) => c.name), ['주일 예배']);
      expect(b.sync.status.value.pendingContis, 0);
    });

    test('다른 PC 파일이 공유 폴더 밖을 가리키면 받지 않는다', () async {
      final b = await newPc('B');
      final secret = File(p.join(root.path, 'secret.png'))
        ..writeAsBytesSync([9]);
      final dir = p.join(shared, SyncService.syncDirName);
      File(p.join(dir, 'evil.json')).writeAsStringSync(
        jsonEncode(
          SyncSnapshot(
            deviceId: 'evil',
            deviceName: 'evil',
            songs: const [],
            deleted: const {},
            aliases: const {},
            contis: [
              SyncConti(
                uid: 'c1',
                updatedAt: 1,
                name: '나쁜 콘티',
                createdAt: 1,
                items: [
                  {
                    'item_type': 'image',
                    'image_paths': SyncConti.fileRef(
                      '../../${p.basename(secret.path)}',
                    ),
                  },
                ],
              ),
            ],
          ).toJson(),
        ),
      );
      await b.sync.syncNow();
      expect(await b.contis.listContis(), isEmpty);
    });
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
    final running = a.sync.syncNow();
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
    final running = a.sync.syncNow();
    a.sync.dispose();
    await running;
  });

  group('리뷰 2차', () {
    test('공유 폴더를 바꾸면 콘티 이미지를 새 폴더에도 올린다', () async {
      final a = await newPc('A');
      await a.repo.insertSong(song('은혜', '가사'));
      final page = File(p.join(a.dir.path, '0001.png'))..writeAsBytesSync([1]);
      await a.contis.saveConti('콘티', [
        (
          uid: 1,
          item: ImageStagingItem(sourceName: 'x', imagePaths: [page.path]),
        ),
      ]);
      await a.sync.syncNow();
      final other = p.join(root.path, '다른 공유 드라이브');
      await Directory(other).create();
      await a.sync.setFolder(other);
      final files = Directory(
        p.join(other, SyncService.syncDirName, SyncService.filesDirName),
      );
      expect(files.listSync(), hasLength(1));
    });

    test('내 파일이 지워지면 다시 쓴다', () async {
      final a = await newPc('A');
      await a.repo.insertSong(song('은혜', '가사'));
      await a.sync.syncNow();
      final own = File(
        p.join(shared, SyncService.syncDirName, '${a.sync.deviceId}.json'),
      );
      own.deleteSync();
      await a.sync.syncNow();
      expect(own.existsSync(), isTrue);
    });

    test('못 읽은 다른 PC 파일은 다음 차례에 다시 읽는다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await a.repo.insertSong(song('은혜', '가사'));
      await a.sync.syncNow();
      final aFile = File(
        p.join(shared, SyncService.syncDirName, '${a.sync.deviceId}.json'),
      );
      final good = aFile.readAsStringSync();
      final modified = aFile.lastModifiedSync();
      // 드라이브가 아직 다 못 내려받은 상태 — 크기·수정 시각은 같은데 내용이 깨져 있다.
      aFile.writeAsStringSync('x' * good.length);
      aFile.setLastModifiedSync(modified);
      await b.sync.syncNow();
      expect(await b.songs(), isEmpty);
      aFile.writeAsStringSync(good);
      aFile.setLastModifiedSync(modified);
      await b.sync.syncNow();
      expect(await b.titles(), ['은혜:가사']);
    });

    test('모양이 이상한 콘티 항목은 건너뛰고 나머지는 맞춘다', () async {
      final b = await newPc('B');
      File(
        p.join(shared, SyncService.syncDirName, 'odd.json'),
      ).writeAsStringSync(
        jsonEncode(
          SyncSnapshot(
            deviceId: 'odd',
            deviceName: 'odd',
            songs: [
              SyncSong(
                uid: 's1',
                updatedAt: 1,
                title: '은혜',
                fileName: '',
                lyrics: '가사',
                englishLyrics: '',
              ),
            ],
            deleted: const {},
            aliases: const {},
            contis: [
              SyncConti(
                uid: 'c1',
                updatedAt: 1,
                name: '이상한 콘티',
                createdAt: 1,
                items: [
                  {
                    'item_type': 'blank',
                    'background': {'nested': true},
                  },
                ],
              ),
            ],
          ).toJson(),
        ),
      );
      await b.sync.syncNow();
      expect(b.sync.status.value.lastError, isNull);
      expect(await b.titles(), ['은혜:가사']);
      expect(await b.contis.listContis(), isEmpty);
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
      final sync = SyncService(
        songs: SongSyncRepository(database: database),
        contis: ContiSyncRepository(database: database),
        settingsDirectory: () async => dir,
        deviceName: name,
        clock: () => now,
      );
      addTearDown(sync.dispose);
      final repo = PraiseRepository(database: database)
        ..onSongsChanged = sync.markLocalChanged;
      final contis = WorshipContiRepository(database: database)
        ..onContisChanged = sync.markLocalChanged;
      await sync.load();
      return _Pc(repo, contis, sync, dir);
    }

    test('설정이 복제된 PC 는 기기 id 를 새로 만들어 서로 덮어쓰지 않는다', () async {
      final a = await newPc('A');
      await a.repo.insertSong(song('은혜', '가사'));
      await a.sync.syncNow();
      final b = await clonePc(a, 'B');
      expect(b.sync.deviceId, a.sync.deviceId);
      // 복제 뒤 A 가 한 번 더 쓴다(설정의 마지막 표시는 복제 시점 것).
      await a.repo.insertSong(song('축복', '가사'));
      await a.sync.syncNow();
      await b.repo.insertSong(song('사랑', '가사'));
      await b.sync.syncNow();
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
      await a.sync.syncNow();
      final again = await clonePc(a, 'A-다시');
      // 같은 PC 를 다시 켠 것과 같다(설정의 마지막 표시 = 파일의 표시).
      await again.sync.syncNow();
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
        contis: ContiSyncRepository(database: PraiseDatabase.forTesting(db)),
        settingsDirectory: () async => dir,
        deviceName: 'X',
      );
      addTearDown(sync.dispose);
      await sync.load();
      expect(sync.status.value.lastError, contains('설정'));
      expect(settings.readAsStringSync(), '{"folder": "/x", "dev');
    });

    test('계속 못 읽는 다른 PC 파일은 매번이 아니라 간격을 늘려 다시 읽는다', () async {
      final a = await newPc('A');
      final dir = p.join(shared, SyncService.syncDirName);
      File(p.join(dir, 'broken.json')).writeAsStringSync('{깨짐');
      await a.sync.syncNow();
      final ownFile = File(p.join(dir, '${a.sync.deviceId}.json'));
      final written = ownFile.lastModifiedSync();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // 1분이 안 지났으면 다시 읽지 않는다(아무것도 안 함).
      final result = await a.sync.syncNow();
      expect(result!.changed, isFalse);
      expect(ownFile.lastModifiedSync(), written);
    });

    test('누가 공유 files/ 를 지우면 다시 올린다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await a.repo.insertSong(song('은혜', '가사'));
      final page = File(p.join(a.dir.path, '0001.png'))..writeAsBytesSync([1]);
      await a.contis.saveConti('콘티', [
        (
          uid: 1,
          item: ImageStagingItem(sourceName: 'x', imagePaths: [page.path]),
        ),
      ]);
      await a.sync.syncNow();
      Directory(
        p.join(shared, SyncService.syncDirName, SyncService.filesDirName),
      ).deleteSync(recursive: true);
      await a.sync.syncNow();
      await b.sync.syncNow();
      expect((await b.contis.listContis()).map((c) => c.name), ['콘티']);
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

    test('다른 PC 를 거쳐 온 콘티도 곡 링크를 잃지 않는다', () async {
      final a = await newPc('A');
      final b = await newPc('B');
      await a.repo.insertSong(song('은혜', '가사'));
      final grace = (await a.songs()).single;
      await a.contis.saveConti('콘티', [(uid: 1, item: SongStagingItem(grace))]);
      await syncAll([a, b]);
      // B 에서 곡만 지워도(콘티는 남음) B 가 다시 실어 보내는 콘티에는 곡 uid 가 남는다.
      final onB = (await b.songs()).single;
      await b.repo.deleteSongsByIds([onB.id!]);
      await b.sync.syncNow();
      final ownB = File(
        p.join(shared, SyncService.syncDirName, '${b.sync.deviceId}.json'),
      );
      final json = jsonDecode(ownB.readAsStringSync()) as Map;
      final items = ((json['contis'] as List).single as Map)['items'] as List;
      expect((items.single as Map)['song_uid'], isA<String>());
      // 새 PC C 는 A 의 곡(지운 기록보다 나중에 고치지 않았으므로 C 에도 없다)이 없어도 콘티를 받는다.
      final c = await newPc('C');
      await c.sync.syncNow();
      expect((await c.contis.listContis()).map((x) => x.name), ['콘티']);
    });
  });

  group('리뷰 4차', () {
    /// 다른 PC 가 쓴 것처럼 공유 폴더에 동기화 파일을 넣는다.
    void writePeer(String id, SyncSnapshot snapshot) => File(
      p.join(shared, SyncService.syncDirName, '$id.json'),
    ).writeAsStringSync(jsonEncode(snapshot.toJson()));

    test('다른 PC 콘티가 이 PC 의 로컬 경로를 가리켜도 그 파일을 올리지 않는다', () async {
      final b = await newPc('B');
      final secret = File(p.join(root.path, 'secret.png'))
        ..writeAsBytesSync([9]);
      writePeer(
        'evil',
        SyncSnapshot(
          deviceId: 'evil',
          deviceName: 'evil',
          songs: const [],
          deleted: const {},
          aliases: const {},
          contis: [
            SyncConti(
              uid: 'c1',
              updatedAt: 1,
              name: '콘티',
              createdAt: 1,
              items: [
                {
                  'item_type': 'image',
                  'image_paths': secret.path,
                  'image_source_path': secret.path,
                },
              ],
            ),
          ],
        ),
      );
      await b.sync.syncNow();
      b.sync.markLocalChanged();
      await b.sync.syncNow();
      final files = Directory(
        p.join(shared, SyncService.syncDirName, SyncService.filesDirName),
      );
      expect(files.existsSync() ? files.listSync() : const [], isEmpty);
      final list = await b.contis.listContis();
      final loaded = await b.contis.loadConti(list.single.id, 1);
      expect(loaded.items, isEmpty); // 이미지가 없는 항목은 유실로 센다
      expect(loaded.missingCount, 1);
    });

    test('콘티가 곡보다 먼저 와도 곡이 들어오면 잇는다', () async {
      final b = await newPc('B');
      SyncConti conti() => SyncConti(
        uid: 'c1',
        updatedAt: 1,
        name: '콘티',
        createdAt: 1,
        items: [
          {
            'item_type': 'song',
            'song_uid': 's1',
            'song_title': '은혜',
            'song_lyrics': '가사',
          },
        ],
      );
      writePeer(
        'p1',
        SyncSnapshot(
          deviceId: 'p1',
          deviceName: 'p1',
          songs: const [],
          deleted: const {},
          aliases: const {},
          contis: [conti()],
        ),
      );
      await b.sync.syncNow();
      writePeer(
        'p2',
        SyncSnapshot(
          deviceId: 'p2',
          deviceName: 'p2',
          songs: [
            SyncSong(
              uid: 's1',
              updatedAt: 1,
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
      await b.sync.syncNow();
      final list = await b.contis.listContis();
      final loaded = await b.contis.loadConti(list.single.id, 1);
      final item = loaded.items.single.item as SongStagingItem;
      expect(item.song.id, (await b.songs()).single.id);
    });

    test('예전 콘티(가사 스냅샷 없음)는 지금 곡 가사로 채워 보낸다', () async {
      final a = await newPc('A');
      await a.repo.insertSong(song('은혜', '지금 가사'));
      final grace = (await a.songs()).single;
      final id = await a.contis.saveConti('예전 콘티', [
        (uid: 1, item: SongStagingItem(grace)),
      ]);
      final db = await databaseFactoryFfi.openDatabase(
        p.join(a.dir.path, 'a.db'),
      );
      addTearDown(db.close);
      await db.update(
        'worship_conti_items',
        {'song_lyrics': null, 'song_title': null},
        where: 'conti_id = ?',
        whereArgs: [id],
      );
      a.sync.markLocalChanged();
      await a.sync.syncNow();
      final own = File(
        p.join(shared, SyncService.syncDirName, '${a.sync.deviceId}.json'),
      );
      final json = jsonDecode(own.readAsStringSync()) as Map;
      final item =
          (((json['contis'] as List).single as Map)['items'] as List).single
              as Map;
      expect(item['song_lyrics'], '지금 가사');
      expect(item['song_title'], '은혜');
    });

    test('제목에 (와이드 스크린) 이 붙은 곡도 그냥 저장하면 고친 시각이 그대로다', () async {
      final a = await newPc('A');
      await a.repo.insertSong(song('은혜 (와이드 스크린)', '가사'));
      final loaded = (await a.songs()).single;
      expect(loaded.title, '은혜');
      final before = await a.sync.syncNow();
      expect(before, isNotNull);
      final own = File(
        p.join(shared, SyncService.syncDirName, '${a.sync.deviceId}.json'),
      );
      final text = own.readAsStringSync();
      await a.repo.updateSong(loaded);
      a.sync.markLocalChanged();
      await a.sync.syncNow();
      expect(own.readAsStringSync(), text);
    });
  });
}
