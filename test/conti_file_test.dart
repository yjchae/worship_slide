import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/worship_conti_repository.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/slide_background.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';

/// 콘티 파일 내보내기 → 다른 PC(빈 DB) 에서 가져오기 왕복.
void main() {
  setUpAll(sqfliteFfiInit);

  Future<Database> freshDatabase() async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(db.close);
    await createPraiseSchema(db);
    return db;
  }

  WorshipContiRepository repositoryOn(Database db) => WorshipContiRepository(
    database: PraiseDatabase.forTesting(db),
    // 단위 테스트엔 Application Support 가 없다.
    supportDirectory: () async => Directory.systemTemp,
  );

  Future<WorshipContiRepository> freshRepository() async =>
      repositoryOn(await freshDatabase());

  test('이미지·배경·곡 제목까지 다른 DB 로 옮겨진다', () async {
    final tmp = await Directory.systemTemp.createTemp('conti_file_test');
    addTearDown(() => tmp.delete(recursive: true));
    final page = File(p.join(tmp.path, 'page1.png'))
      ..writeAsBytesSync([1, 2, 3]);
    final bg = File(p.join(tmp.path, 'bg.jpg'))..writeAsBytesSync([4, 5]);

    final source = await freshRepository();
    final contiId = await source.saveConti(
      '주일 예배',
      [
        (
          uid: 1,
          item: SongStagingItem(
            const PraiseSong(
              id: 42,
              fileName: 'a.pptx',
              title: '주님의 은혜',
              lyrics: '1절\n\n2절',
              englishLyrics: 'verse',
            ),
          ),
        ),
        (
          uid: 2,
          item: ImageStagingItem(sourceName: '광고', imagePaths: [page.path]),
        ),
        (uid: 3, item: BibleStagingItem(reference: '요 3:16', text: '하나님이')),
      ],
      notes: const {'1:0': '천천히'},
      backgrounds: {
        1: SlideBackground(color: const Color(0xFF112233), imagePath: bg.path),
      },
    );
    final file = p.join(tmp.path, 'out.wsconti');
    await source.exportContiFile(contiId, file);

    // 원본 파일이 사라져도 (= 다른 PC) 가져온 쪽은 자기 사본을 쓴다.
    page.deleteSync();
    bg.deleteSync();

    final target = await freshRepository();
    final importedId = await target.importContiFile(
      file,
      filesDir: Directory(p.join(tmp.path, 'imported')),
    );
    expect((await target.listContis()).single.name, '주일 예배');

    final loaded = await target.loadConti(importedId, 100);
    expect(loaded.missingCount, 0);
    expect(loaded.items.length, 3);

    final song = (loaded.items[0].item as SongStagingItem).song;
    expect(song.title, '주님의 은혜');
    expect(song.lyrics, '1절\n\n2절');
    expect(song.id, isNull); // 받는 쪽 DB 의 엉뚱한 곡을 가리키면 안 된다.

    final image = loaded.items[1].item as ImageStagingItem;
    expect(File(image.imagePaths.single).readAsBytesSync(), [1, 2, 3]);

    final background = loaded.backgrounds[100]!;
    expect(background.color, const Color(0xFF112233));
    expect(File(background.imagePath!).readAsBytesSync(), [4, 5]);
    expect(loaded.notes, {'100:0': '천천히'});
    expect((loaded.items[2].item as BibleStagingItem).reference, '요 3:16');
  });

  test('콘티 파일이 아니면 거절한다', () async {
    final tmp = await Directory.systemTemp.createTemp('conti_file_test');
    addTearDown(() => tmp.delete(recursive: true));
    final file = File(p.join(tmp.path, 'x.wsconti'))
      ..writeAsStringSync('{"a":1}');
    final repo = await freshRepository();
    expect(repo.importContiFile(file.path), throwsFormatException);
  });

  group('덮어쓰기 저장', () {
    ({int uid, StagingItem item}) bible(int uid, String text) =>
        (uid: uid, item: BibleStagingItem(reference: '요 3:16', text: text));

    Future<List<String>> texts(WorshipContiRepository repo, int id) async => [
      for (final e in (await repo.loadConti(id, 1)).items)
        (e.item as BibleStagingItem).text,
    ];

    test('id·uid 는 그대로이고 이름·항목만 바뀐다', () async {
      final repo = await freshRepository();
      final id = await repo.saveConti('옛 이름', [bible(1, '옛'), bible(2, '옛2')]);
      final uid = (await repo.listContis()).single.uid!;

      final saved = await repo.saveConti('새 이름', [
        bible(1, '새'),
      ], overwriteUid: uid);

      expect(saved, id);
      final conti = (await repo.listContis()).single;
      expect(conti.id, id);
      expect(conti.uid, uid);
      expect(conti.name, '새 이름');
      expect(conti.itemCount, 1);
      expect(await texts(repo, id), ['새']);
    });

    test('시각이 늘 커져 목록 맨 앞에 온다(옛값이 미래여도)', () async {
      final db = await freshDatabase();
      final repo = repositoryOn(db);
      final first = await repo.saveConti('먼저', [bible(1, '가')]);
      final second = await repo.saveConti('나중', [bible(1, '나')]);
      final future = DateTime.now().millisecondsSinceEpoch + 86400000;
      await db.update(
        'worship_contis',
        {'created_at': future},
        where: 'id = ?',
        whereArgs: [first],
      );
      await db.update(
        'worship_contis',
        {'created_at': future + 5},
        where: 'id = ?',
        whereArgs: [second],
      );
      final uid = await repo.contiUid(first);

      await repo.saveConti('먼저', [bible(1, '다')], overwriteUid: uid);
      expect(
        (await repo.contisByUid())[uid]!.createdAt.millisecondsSinceEpoch,
        future + 1,
      );

      await repo.saveConti('나중', [
        bible(1, '라'),
      ], overwriteUid: await repo.contiUid(second));
      final list = await repo.listContis();
      expect(list.first.id, second);
      expect(list.first.createdAt.millisecondsSinceEpoch, future + 6);
    });

    test('항목을 넣다 실패하면 옛 이름·시각·항목이 그대로다', () async {
      final db = await freshDatabase();
      final repo = repositoryOn(db);
      final id = await repo.saveConti('옛 이름', [bible(1, '옛')]);
      final before = (await repo.listContis()).single;
      await db.execute('''
        CREATE TRIGGER fail_insert BEFORE INSERT ON worship_conti_items
        WHEN NEW.bible_text = '실패'
        BEGIN SELECT RAISE(ABORT, 'test'); END
      ''');

      await expectLater(
        repo.saveConti('새 이름', [
          bible(1, '새'),
          bible(2, '실패'),
        ], overwriteUid: before.uid),
        throwsA(anything),
      );

      final after = (await repo.listContis()).single;
      expect(after.name, '옛 이름');
      expect(after.createdAt, before.createdAt);
      expect(await texts(repo, id), ['옛']);
    });

    test('없는 uid 면 실패하고 새 콘티를 만들지 않는다', () async {
      final repo = await freshRepository();
      await expectLater(
        repo.saveConti('새', [bible(1, '가')], overwriteUid: 'a' * 32),
        throwsStateError,
      );
      expect(await repo.listContis(), isEmpty);
    });
  });
}
