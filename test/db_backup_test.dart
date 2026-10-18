import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';

/// 업데이트로 DB 스키마를 올리기 전 자동 백업(`backupBeforeUpgrade`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory dir;
  late String dbPath;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('db_backup_test');
    dbPath = p.join(dir.path, 'worship_slides.db');
  });

  tearDown(() => dir.delete(recursive: true));

  Future<void> makeDb(int version) async {
    final db = await databaseFactoryFfi.openDatabase(dbPath);
    await db.execute('CREATE TABLE t (v TEXT)');
    await db.insert('t', {'v': 'hello'});
    await db.setVersion(version);
    await db.close();
  }

  test('헤더에서 버전을 읽는다', () async {
    await makeDb(16);
    expect(await readSqliteUserVersion(dbPath), 16);
    expect(await readSqliteUserVersion(p.join(dir.path, 'none.db')), isNull);
    await File(p.join(dir.path, 'x.db')).writeAsString('not sqlite');
    expect(await readSqliteUserVersion(p.join(dir.path, 'x.db')), isNull);
  });

  test('옛 버전 DB 는 올리기 전에 똑같이 복사해 둔다', () async {
    await makeDb(16);
    final original = await File(dbPath).readAsBytes();

    final backup = await backupBeforeUpgrade(dbPath, toVersion: 17);

    expect(backup, '$dbPath.v16.bak');
    expect(await File(backup!).readAsBytes(), original);
    final leftovers = dir.listSync().where((e) => e.path.endsWith('.tmp'));
    expect(leftovers, isEmpty);
  });

  test('이미 최신이거나 새 DB 면 복사하지 않는다', () async {
    expect(await backupBeforeUpgrade(dbPath, toVersion: 17), isNull);
    await makeDb(17);
    expect(await backupBeforeUpgrade(dbPath, toVersion: 17), isNull);
    expect(dir.listSync().where((e) => e.path.endsWith('.bak')), isEmpty);
  });

  test('같은 버전 사본이 있으면 덮어쓰지 않는다', () async {
    await makeDb(16);
    await File('$dbPath.v16.bak').writeAsString('earlier');

    expect(await backupBeforeUpgrade(dbPath, toVersion: 17), isNull);
    expect(await File('$dbPath.v16.bak').readAsString(), 'earlier');
  });

  test('남아 있는 저널도 같이 복사한다', () async {
    await makeDb(16);
    await File('$dbPath-journal').writeAsString('hot journal');

    final backup = await backupBeforeUpgrade(dbPath, toVersion: 17);

    expect(await File('$backup-journal').readAsString(), 'hot journal');
  });
}
