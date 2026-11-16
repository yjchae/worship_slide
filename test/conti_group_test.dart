import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/worship_conti_repository.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';

/// 콘티 항목 그룹(item_group): 저장·불러오기·.wsconti 왕복·옛 DB 열기·옛 앱 호환.
void main() {
  setUpAll(sqfliteFfiInit);

  Future<Database> freshDb() async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(db.close);
    await createPraiseSchema(db);
    return db;
  }

  WorshipContiRepository repoOn(Database db) => WorshipContiRepository(
    database: PraiseDatabase.forTesting(db),
    supportDirectory: () async => Directory.systemTemp,
  );

  List<({int uid, StagingItem item})> items() => [
    (uid: 1, item: BibleStagingItem(reference: '요 3:16', text: 'a')),
    (uid: 2, item: BibleStagingItem(reference: '요 3:17', text: 'b')),
    (uid: 3, item: BibleStagingItem(reference: '요 3:18', text: 'c')),
  ];

  test('저장·덮어쓰기·불러오기: 이름 정리(trim·12자·빈 값)', () async {
    final repo = repoOn(await freshDb());
    final id = await repo.saveConti(
      'c',
      items(),
      itemGroups: {1: '  시작곡 ', 2: '가나다라마바사아자차카타파하', 3: '   '},
    );
    var loaded = await repo.loadConti(id, 10);
    expect(loaded.itemGroups.length, 2);
    expect(loaded.itemGroups[loaded.items[0].uid], '시작곡');
    expect(loaded.itemGroups[loaded.items[1].uid], '가나다라마바사아자차카타');

    final uid = (await repo.listContis()).single.uid;
    await repo.saveConti('c', items(), overwriteUid: uid);
    loaded = await repo.loadConti(id, 10);
    expect(loaded.itemGroups, isEmpty);
  });

  test('.wsconti 왕복에서 그룹이 유지되고 키 없는 옛 파일은 그룹 없음', () async {
    final tmp = await Directory.systemTemp.createTemp('conti_group');
    addTearDown(() => tmp.delete(recursive: true));
    final src = repoOn(await freshDb());
    final id = await src.saveConti('c', items(), itemGroups: {2: '말씀'});
    final file = p.join(tmp.path, 'o.wsconti');
    await src.exportContiFile(id, file);

    final dst = repoOn(await freshDb());
    final newId = await dst.importContiFile(
      file,
      filesDir: Directory(p.join(tmp.path, 'imp')),
    );
    final loaded = await dst.loadConti(newId, 10);
    expect(loaded.itemGroups, {loaded.items[1].uid: '말씀'});

    // 그룹 없는 콘티를 내보내면 키는 null → 그룹 없음.
    final id2 = await src.saveConti('d', items());
    final file2 = p.join(tmp.path, 'p.wsconti');
    await src.exportContiFile(id2, file2);
    final id3 = await dst.importContiFile(
      file2,
      filesDir: Directory(p.join(tmp.path, 'imp2')),
    );
    expect((await dst.loadConti(id3, 10)).itemGroups, isEmpty);
  });

  test('컬럼 없는 같은 버전 DB 를 열면 멱등하게 추가되고, 옛 방식 쿼리도 동작', () async {
    final db = await freshDb();
    // 그룹 칸이 생기기 전 모양을 흉내: 칸 지우기(SQLite 3.35+).
    await db.execute('ALTER TABLE worship_conti_items DROP COLUMN item_group');
    Future<bool> has() async => (await db.rawQuery(
      'PRAGMA table_info(worship_conti_items)',
    )).any((c) => c['name'] == 'item_group');
    expect(await has(), isFalse);
    await ensureItemGroupColumn(db);
    await ensureItemGroupColumn(db);
    expect(await has(), isTrue);

    // 옛 앱: 모르는 칸을 이름 없이 건너뛰고 insert/select 한다.
    final cid = await db.insert('worship_contis', {
      'name': 'x',
      'created_at': 1,
    });
    await db.insert('worship_conti_items', {
      'conti_id': cid,
      'position': 0,
      'item_type': 'blank',
      'blank_text': 'hi',
    });
    final rows = await db.rawQuery(
      'SELECT item_type, blank_text FROM worship_conti_items WHERE conti_id = ?',
      [cid],
    );
    expect(rows.single['blank_text'], 'hi');
    // 새 코드가 그룹 없는 옛 행을 읽는다.
    final loaded = await repoOn(db).loadConti(cid, 10);
    expect(loaded.itemGroups, isEmpty);
  });
}
