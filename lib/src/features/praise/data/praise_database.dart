import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class PraiseDatabase {
  PraiseDatabase._();

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
      version: 7,
      onCreate: (db, version) async {
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
            bible_text      TEXT
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
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
      },
    );
    return _database!;
  }
}

// \n###\n 구분자를 \n\n 형식으로 변환 (버전 6 마이그레이션용).
String _migratePageFormat(String stored) {
  if (!stored.contains('###')) return stored;
  final pages = stored.split('###').map((p) => p.trim()).toList();
  while (pages.isNotEmpty && pages.last.isEmpty) pages.removeLast();
  return pages.join('\n\n');
}
