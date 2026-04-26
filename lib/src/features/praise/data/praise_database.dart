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

    final dbPath = p.join(_dbDirectory, 'praise_lyrics.db');
    _database = await openDatabase(
      dbPath,
      version: 2,
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
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE praise_songs ADD COLUMN english_lyrics TEXT NOT NULL DEFAULT ''",
          );
        }
      },
    );
    return _database!;
  }
}
