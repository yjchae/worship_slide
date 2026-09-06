import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/worship_conti_repository.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/slide_background.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';

/// 항목별 배경이 콘티 저장/불러오기를 실제 SQLite 로 왕복하는지 확인한다.
void main() {
  setUpAll(sqfliteFfiInit);

  Future<Database> openFreshDb() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await createPraiseSchema(db);
    return db;
  }

  test('항목별 배경이 콘티 저장 → 불러오기를 왕복한다', () async {
    final db = await openFreshDb();
    addTearDown(db.close);
    final repository = WorshipContiRepository(
      database: PraiseDatabase.forTesting(db),
    );

    const offering = PraiseSong(
      id: 1,
      fileName: 'offering.pptx',
      title: '헌금송',
      lyrics: '헌금송 1절\n\n헌금송 2절',
      englishLyrics: '',
    );
    const normal = PraiseSong(
      id: 2,
      fileName: 'normal.pptx',
      title: '일반 찬양',
      lyrics: '일반 1절',
      englishLyrics: '',
    );
    const offeringBackground = SlideBackground(
      color: Color(0xFF123456),
      imagePath: '/tmp/offering.png',
    );

    final items = <({int uid, StagingItem item})>[
      (uid: 10, item: SongStagingItem(offering)),
      (uid: 11, item: SongStagingItem(normal)),
      (uid: 12, item: const BlankStagingItem()),
    ];

    final contiId = await repository.saveConti(
      '주일 예배',
      items,
      backgrounds: const {10: offeringBackground},
    );

    final loaded = await repository.loadConti(contiId, 100);

    expect(loaded.items.length, 3);
    // uid 는 startUid(100) 부터 새로 매겨진다. 배경도 새 uid 로 따라와야 한다.
    expect(loaded.backgrounds, {100: offeringBackground});
    expect(loaded.backgrounds.containsKey(101), isFalse);
    expect(loaded.missingCount, 0);
  });

  test('배경을 지정하지 않으면 칸이 비고 불러올 때도 비어 있다', () async {
    final db = await openFreshDb();
    addTearDown(db.close);
    final repository = WorshipContiRepository(
      database: PraiseDatabase.forTesting(db),
    );

    final contiId = await repository.saveConti('배경 없는 콘티', [
      (uid: 1, item: const BlankStagingItem()),
    ]);

    final stored = await db.query(
      'worship_conti_items',
      columns: ['background'],
    );
    expect(stored.single['background'], isNull);
    expect((await repository.loadConti(contiId, 0)).backgrounds, isEmpty);
  });

  test('version 5 DB 를 올리면 background 칸이 생긴다', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);

    // version 5 시절 스키마 (background · notes · 가사 스냅샷 이전)
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
      CREATE TABLE worship_contis (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE worship_conti_items (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        conti_id        INTEGER NOT NULL,
        position        INTEGER NOT NULL,
        item_type       TEXT    NOT NULL,
        song_id         INTEGER,
        bible_reference TEXT,
        bible_text      TEXT
      )
    ''');
    await db.insert('worship_contis', {'name': '옛 콘티', 'created_at': 0});
    await db.insert('worship_conti_items', {
      'conti_id': 1,
      'position': 0,
      'item_type': 'bible',
      'bible_reference': '롬 8:28',
      'bible_text': '모든 것이 합력하여 선을 이루느니라',
    });

    await upgradePraiseSchema(db, 5);

    final columns = await db.rawQuery('PRAGMA table_info(worship_conti_items)');
    expect(columns.map((c) => c['name']), contains('background'));

    // 마이그레이션된 옛 항목은 "오버라이드 없음"으로 읽힌다.
    final repository = WorshipContiRepository(
      database: PraiseDatabase.forTesting(db),
    );
    final loaded = await repository.loadConti(1, 0);
    expect(loaded.items.length, 1);
    expect(loaded.backgrounds, isEmpty);
  });
}
