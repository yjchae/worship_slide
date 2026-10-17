import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class PraiseDatabase {
  PraiseDatabase._();

  /// 이미 열려 있는 DB(테스트의 메모리 DB 등)를 그대로 쓰는 인스턴스.
  PraiseDatabase.forTesting(Database database) : _database = database;

  static final PraiseDatabase instance = PraiseDatabase._();
  Database? _database;

  // 실행 파일 옆 폴더: macOS는 .app/Contents/MacOS/exe 이므로 3단계 위
  static String get _dbDirectory {
    final exe = File(Platform.resolvedExecutable);
    if (Platform.isMacOS) {
      return exe.parent.parent.parent.parent.path;
    }
    return exe.parent.path;
  }

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    final dbPath = p.join(_dbDirectory, 'worship_slides.db');
    _database = await openDatabase(
      dbPath,
      version: 17,
      onCreate: (db, version) => createPraiseSchema(db),
      onUpgrade: (db, oldVersion, newVersion) =>
          upgradePraiseSchema(db, oldVersion),
    );
    return _database!;
  }
}

/// 새 DB에 테이블을 만든다. 마이그레이션과 함께 테스트에서 직접 부를 수 있도록
/// 최상위 함수로 뺐다 (openDatabase 콜백 안에 있으면 검증할 방법이 없다).
Future<void> createPraiseSchema(DatabaseExecutor db) async {
  await db.execute('''
  CREATE TABLE praise_songs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_name TEXT NOT NULL,
    title TEXT NOT NULL,
    lyrics TEXT NOT NULL,
    english_lyrics TEXT NOT NULL DEFAULT '',
    uid TEXT,
    updated_at INTEGER NOT NULL DEFAULT 0
  )
''');
  await db.execute(_createSongUidIndex);
  await db.execute(_createSongTombstones);
  await db.execute(_createSongUidAliases);
  await db.execute('''
  CREATE TABLE bible_verses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bible_version TEXT NOT NULL DEFAULT '기본',
    book_name TEXT NOT NULL,
    chapter INTEGER NOT NULL,
    verse INTEGER NOT NULL,
    text TEXT NOT NULL
  )
''');
  await db.execute(
    'CREATE INDEX idx_bible_version ON bible_verses(bible_version)',
  );
  await db.execute(
    'CREATE INDEX idx_bible_book ON bible_verses(bible_version, book_name)',
  );
  await db.execute(
    'CREATE INDEX idx_bible_ch ON bible_verses(bible_version, book_name, chapter)',
  );
  await db.execute('''
  CREATE TABLE worship_contis (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL,
    created_at INTEGER NOT NULL,
    uid        TEXT,
    updated_at INTEGER NOT NULL DEFAULT 0
  )
''');
  await db.execute(_createContiTombstones);
  await db.execute('''
  CREATE TABLE worship_conti_items (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conti_id        INTEGER NOT NULL REFERENCES worship_contis(id) ON DELETE CASCADE,
    position        INTEGER NOT NULL,
    item_type       TEXT    NOT NULL,
    song_id         INTEGER,
    bible_reference TEXT,
    bible_text      TEXT,
    song_lyrics     TEXT,
    song_english_lyrics TEXT,
    blank_text      TEXT,
    blank_english_text TEXT,
    image_source    TEXT,
    image_paths     TEXT,
    notes           TEXT,
    background      TEXT,
    bible_sub_text  TEXT,
    song_title      TEXT,
    no_spacer       INTEGER,
    image_source_path TEXT,
    media           TEXT,
    song_uid        TEXT
  )
''');
  await db.execute(_createSongTranslations);
  await db.execute(_createTranslationTombstones);
}

/// 곡의 보조 언어 가사. 곡 id 가 아니라 **제목**을 키로 쓴다 —
/// `replaceAllSongs` 가 전체 삭제 후 재삽입이라 id 는 임포트마다 바뀐다.
/// '영어'는 `praise_songs.english_lyrics` 가 그대로 맡으므로 여기 없다.
const _createSongTranslations = '''
  CREATE TABLE IF NOT EXISTS song_translations (
    song_title TEXT NOT NULL,
    language   TEXT NOT NULL,
    lyrics     TEXT NOT NULL,
    updated_at INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (song_title, language)
  )
''';

/// 지운 보조 가사. 보조 가사는 곡이 아니라 (제목, 언어)에 묶여 있으므로 따로 동기화한다.
const _createTranslationTombstones = '''
  CREATE TABLE IF NOT EXISTS translation_tombstones (
    song_title TEXT NOT NULL,
    language   TEXT NOT NULL,
    deleted_at INTEGER NOT NULL,
    PRIMARY KEY (song_title, language)
  )
''';

// ── 곡 동기화 (공유 드라이브) ─────────────────────────────────────────
//
// 곡 id 는 PC 마다 다르고 임포트마다 바뀌므로, PC 사이에서 같은 곡을 가리키는
// 데는 `uid`(무작위 32자 hex)를 쓴다. `updated_at`(ms) 이 큰 쪽이 이긴다.

const _createSongUidIndex =
    'CREATE INDEX IF NOT EXISTS idx_praise_songs_uid ON praise_songs(uid)';

/// 지운 곡. 다른 PC 에 "이 곡은 지웠다"를 알려야 하므로 행을 지워도 uid 는 남긴다.
/// `content_hash`(제목·가사 해시)는 다른 PC 가 따로 가져온 같은 곡을 알아보는 데 쓴다 —
/// 동기화를 켜기 전에 지운 곡이 다른 PC 의 같은 곡으로 되살아나지 않게.
const _createSongTombstones = '''
  CREATE TABLE IF NOT EXISTS song_tombstones (
    uid          TEXT PRIMARY KEY,
    deleted_at   INTEGER NOT NULL,
    content_hash TEXT
  )
''';

/// 두 PC 가 따로 가져온 같은 곡(제목·가사가 똑같음)은 작은 uid 하나로 합친다.
/// 큰 쪽 uid → 작은 쪽 uid. 다른 PC 의 파일에 옛 uid 가 아직 남아 있어도 따라가게.
const _createSongUidAliases = '''
  CREATE TABLE IF NOT EXISTS song_uid_aliases (
    alias TEXT PRIMARY KEY,
    uid   TEXT NOT NULL
  )
''';

/// 지운 콘티. 곡의 [_createSongTombstones] 와 같은 역할.
const _createContiTombstones = '''
  CREATE TABLE IF NOT EXISTS conti_tombstones (
    uid        TEXT PRIMARY KEY,
    deleted_at INTEGER NOT NULL
  )
''';

final _uidRandom = Random.secure();

/// 곡·콘티 동기화용 uid. 무작위 128비트 hex.
String newSongUid() => List.generate(
  16,
  (_) => _uidRandom.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// uid 가 없는 곡·콘티에 uid 를 준다(마이그레이션 + 예전 경로로 들어온 행).
/// 콘티의 고친 시각은 저장한 시각으로 시작한다.
Future<void> fillMissingSyncUids(DatabaseExecutor db) async {
  for (final row in await db.query(
    'praise_songs',
    columns: ['id'],
    where: 'uid IS NULL',
  )) {
    await db.update(
      'praise_songs',
      {'uid': newSongUid()},
      where: 'id = ?',
      whereArgs: [row['id']],
    );
  }
  for (final row in await db.query(
    'worship_contis',
    columns: ['id', 'created_at'],
    where: 'uid IS NULL',
  )) {
    await db.update(
      'worship_contis',
      {'uid': newSongUid(), 'updated_at': row['created_at']},
      where: 'id = ?',
      whereArgs: [row['id']],
    );
  }
}

/// 이미 그 컬럼이 있으면 조용히 건너뛴다. `user_version`이 실제 스키마보다
/// 뒤처진 DB(예: 예전 업그레이드가 중간에 실패해 롤백된 경우)를 다시 열어도
/// "duplicate column name"으로 죽지 않고 스스로 맞춰진다.
Future<void> _addColumnIfMissing(
  DatabaseExecutor db,
  String table,
  String column,
  String ddl,
) async {
  final columns = await db.rawQuery('PRAGMA table_info($table)');
  final exists = columns.any((c) => c['name'] == column);
  if (!exists) {
    await db.execute(ddl);
  }
}

/// [oldVersion] 에서 현재 스키마까지 올린다. 각 단계는 앞 단계가 이미 돈 것을 전제한다.
Future<void> upgradePraiseSchema(DatabaseExecutor db, int oldVersion) async {
  if (oldVersion < 2) {
    await _addColumnIfMissing(
      db,
      'praise_songs',
      'english_lyrics',
      "ALTER TABLE praise_songs ADD COLUMN english_lyrics TEXT NOT NULL DEFAULT ''",
    );
  }
  if (oldVersion < 3) {
    await db.execute('''
    CREATE TABLE IF NOT EXISTS bible_verses (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      bible_version TEXT NOT NULL DEFAULT '기본',
      book_name TEXT NOT NULL,
      chapter INTEGER NOT NULL,
      verse INTEGER NOT NULL,
      text TEXT NOT NULL
    )
  ''');
  }
  if (oldVersion < 4) {
    final columns = await db.rawQuery('PRAGMA table_info(bible_verses)');
    final hasVersion = columns.any(
      (column) => column['name'] == 'bible_version',
    );
    if (!hasVersion) {
      await db.execute(
        "ALTER TABLE bible_verses ADD COLUMN bible_version TEXT NOT NULL DEFAULT '기본'",
      );
    }
    await db.execute('DROP INDEX IF EXISTS idx_bible_book');
    await db.execute('DROP INDEX IF EXISTS idx_bible_ch');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_bible_version ON bible_verses(bible_version)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_bible_book ON bible_verses(bible_version, book_name)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_bible_ch ON bible_verses(bible_version, book_name, chapter)',
    );
  }
  if (oldVersion < 5) {
    await db.execute('''
    CREATE TABLE IF NOT EXISTS worship_contis (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      name       TEXT    NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');
    await db.execute('''
    CREATE TABLE IF NOT EXISTS worship_conti_items (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      conti_id        INTEGER NOT NULL REFERENCES worship_contis(id) ON DELETE CASCADE,
      position        INTEGER NOT NULL,
      item_type       TEXT    NOT NULL,
      song_id         INTEGER,
      bible_reference TEXT,
      bible_text      TEXT
    )
  ''');
  }
  if (oldVersion < 6) {
    // \n###\n 구분자 → \n\n 형식으로 일괄 변환
    final songs = await db.query(
      'praise_songs',
      columns: ['id', 'lyrics', 'english_lyrics'],
    );
    for (final row in songs) {
      final id = row['id'] as int;
      await db.update(
        'praise_songs',
        {
          'lyrics': _migratePageFormat(row['lyrics'] as String? ?? ''),
          'english_lyrics': _migratePageFormat(
            row['english_lyrics'] as String? ?? '',
          ),
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }
  if (oldVersion < 7) {
    await _addColumnIfMissing(
      db,
      'worship_conti_items',
      'song_lyrics',
      "ALTER TABLE worship_conti_items ADD COLUMN song_lyrics TEXT",
    );
    await _addColumnIfMissing(
      db,
      'worship_conti_items',
      'song_english_lyrics',
      "ALTER TABLE worship_conti_items ADD COLUMN song_english_lyrics TEXT",
    );
  }
  if (oldVersion < 8) {
    await _addColumnIfMissing(
      db,
      'worship_conti_items',
      'blank_text',
      "ALTER TABLE worship_conti_items ADD COLUMN blank_text TEXT",
    );
    await _addColumnIfMissing(
      db,
      'worship_conti_items',
      'blank_english_text',
      "ALTER TABLE worship_conti_items ADD COLUMN blank_english_text TEXT",
    );
  }
  if (oldVersion < 9) {
    await _addColumnIfMissing(
      db,
      'worship_conti_items',
      'image_source',
      "ALTER TABLE worship_conti_items ADD COLUMN image_source TEXT",
    );
    await _addColumnIfMissing(
      db,
      'worship_conti_items',
      'image_paths',
      "ALTER TABLE worship_conti_items ADD COLUMN image_paths TEXT",
    );
  }
  if (oldVersion < 10) {
    // 발표자 보기의 슬라이드 메모. {"페이지번호": "메모"} JSON.
    await _addColumnIfMissing(
      db,
      'worship_conti_items',
      'notes',
      "ALTER TABLE worship_conti_items ADD COLUMN notes TEXT",
    );
  }
  if (oldVersion < 11) {
    // 항목별 배경 오버라이드. {"color": "#RRGGBB", "image_path": "..."} JSON.
    // 비어 있으면 전역 디자인의 배경을 그대로 쓴다.
    await _addColumnIfMissing(
      db,
      'worship_conti_items',
      'background',
      "ALTER TABLE worship_conti_items ADD COLUMN background TEXT",
    );
  }
  if (oldVersion < 12) {
    // 다국어: 곡의 보조 언어 가사 + 성경 보조 역본 본문.
    await db.execute(_createSongTranslations);
    await _addColumnIfMissing(
      db,
      'worship_conti_items',
      'bible_sub_text',
      "ALTER TABLE worship_conti_items ADD COLUMN bible_sub_text TEXT",
    );
  }
  if (oldVersion < 13) {
    // 곡 제목 스냅샷. 다른 PC 로 옮긴 콘티는 song_id 가 그쪽 DB 와 안 맞아 제목을 여기서 읽는다.
    await _addColumnIfMissing(
      db,
      'worship_conti_items',
      'song_title',
      "ALTER TABLE worship_conti_items ADD COLUMN song_title TEXT",
    );
  }
  if (oldVersion < 14) {
    // 1 이면 이 항목 뒤 자동 여백을 넣지 않는다(곡 중간에 붙여 넣은 페이지 등).
    await _addColumnIfMissing(
      db,
      'worship_conti_items',
      'no_spacer',
      "ALTER TABLE worship_conti_items ADD COLUMN no_spacer INTEGER",
    );
  }
  if (oldVersion < 15) {
    // 외부 PPT 항목의 원본 파일 경로. 'PowerPoint 에서 수정' 후 다시 굽는 데 쓴다.
    await _addColumnIfMissing(
      db,
      'worship_conti_items',
      'image_source_path',
      "ALTER TABLE worship_conti_items ADD COLUMN image_source_path TEXT",
    );
  }
  if (oldVersion < 16) {
    // 동영상·음악·유튜브 페이지(빈 페이지 + 미디어). SlideMedia JSON.
    await _addColumnIfMissing(
      db,
      'worship_conti_items',
      'media',
      "ALTER TABLE worship_conti_items ADD COLUMN media TEXT",
    );
  }
  if (oldVersion < 17) {
    // 곡·콘티 동기화: PC 사이 식별자 + 고친 시각 + 지운 기록.
    await _addColumnIfMissing(
      db,
      'praise_songs',
      'uid',
      'ALTER TABLE praise_songs ADD COLUMN uid TEXT',
    );
    await _addColumnIfMissing(
      db,
      'praise_songs',
      'updated_at',
      'ALTER TABLE praise_songs ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(_createSongUidIndex);
    await db.execute(_createSongTombstones);
    await _addColumnIfMissing(
      db,
      'song_tombstones',
      'content_hash',
      'ALTER TABLE song_tombstones ADD COLUMN content_hash TEXT',
    );
    await db.execute(_createSongUidAliases);
    await _addColumnIfMissing(
      db,
      'worship_contis',
      'uid',
      'ALTER TABLE worship_contis ADD COLUMN uid TEXT',
    );
    await _addColumnIfMissing(
      db,
      'worship_contis',
      'updated_at',
      'ALTER TABLE worship_contis ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(_createContiTombstones);
    await _addColumnIfMissing(
      db,
      'song_translations',
      'updated_at',
      'ALTER TABLE song_translations ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(_createTranslationTombstones);
    // 콘티 곡 항목의 곡 uid. 다른 PC 로 넘길 때, 그 곡이 이 PC 에서 지워졌어도 링크를 잃지 않게.
    await _addColumnIfMissing(
      db,
      'worship_conti_items',
      'song_uid',
      'ALTER TABLE worship_conti_items ADD COLUMN song_uid TEXT',
    );
    await fillMissingSyncUids(db);
  }
}

// \n###\n 구분자를 \n\n 형식으로 변환 (버전 6 마이그레이션용).
String _migratePageFormat(String stored) {
  if (!stored.contains('###')) return stored;
  final pages = stored.split('###').map((p) => p.trim()).toList();
  while (pages.isNotEmpty && pages.last.isEmpty) pages.removeLast();
  return pages.join('\n\n');
}
