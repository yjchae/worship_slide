import 'dart:io';

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
      version: 12,
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
    english_lyrics TEXT NOT NULL DEFAULT ''
  )
''');
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
    created_at INTEGER NOT NULL
  )
''');
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
    bible_sub_text  TEXT
  )
''');
  await db.execute(_createSongTranslations);
}

/// 곡의 보조 언어 가사. 곡 id 가 아니라 **제목**을 키로 쓴다 —
/// `replaceAllSongs` 가 전체 삭제 후 재삽입이라 id 는 임포트마다 바뀐다.
/// '영어'는 `praise_songs.english_lyrics` 가 그대로 맡으므로 여기 없다.
const _createSongTranslations = '''
  CREATE TABLE IF NOT EXISTS song_translations (
    song_title TEXT NOT NULL,
    language   TEXT NOT NULL,
    lyrics     TEXT NOT NULL,
    PRIMARY KEY (song_title, language)
  )
''';

/// [oldVersion] 에서 현재 스키마까지 올린다. 각 단계는 앞 단계가 이미 돈 것을 전제한다.
Future<void> upgradePraiseSchema(DatabaseExecutor db, int oldVersion) async {
  if (oldVersion < 2) {
    await db.execute(
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
    await db.execute(
      "ALTER TABLE worship_conti_items ADD COLUMN song_lyrics TEXT",
    );
    await db.execute(
      "ALTER TABLE worship_conti_items ADD COLUMN song_english_lyrics TEXT",
    );
  }
  if (oldVersion < 8) {
    await db.execute(
      "ALTER TABLE worship_conti_items ADD COLUMN blank_text TEXT",
    );
    await db.execute(
      "ALTER TABLE worship_conti_items ADD COLUMN blank_english_text TEXT",
    );
  }
  if (oldVersion < 9) {
    await db.execute(
      "ALTER TABLE worship_conti_items ADD COLUMN image_source TEXT",
    );
    await db.execute(
      "ALTER TABLE worship_conti_items ADD COLUMN image_paths TEXT",
    );
  }
  if (oldVersion < 10) {
    // 발표자 보기의 슬라이드 메모. {"페이지번호": "메모"} JSON.
    await db.execute("ALTER TABLE worship_conti_items ADD COLUMN notes TEXT");
  }
  if (oldVersion < 11) {
    // 항목별 배경 오버라이드. {"color": "#RRGGBB", "image_path": "..."} JSON.
    // 비어 있으면 전역 디자인의 배경을 그대로 쓴다.
    await db.execute(
      "ALTER TABLE worship_conti_items ADD COLUMN background TEXT",
    );
  }
  if (oldVersion < 12) {
    // 다국어: 곡의 보조 언어 가사 + 성경 보조 역본 본문.
    await db.execute(_createSongTranslations);
    await db.execute(
      "ALTER TABLE worship_conti_items ADD COLUMN bible_sub_text TEXT",
    );
  }
}

// \n###\n 구분자를 \n\n 형식으로 변환 (버전 6 마이그레이션용).
String _migratePageFormat(String stored) {
  if (!stored.contains('###')) return stored;
  final pages = stored.split('###').map((p) => p.trim()).toList();
  while (pages.isNotEmpty && pages.last.isEmpty) pages.removeLast();
  return pages.join('\n\n');
}
