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
      version: 4,
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
      },
    );
    return _database!;
  }
}
