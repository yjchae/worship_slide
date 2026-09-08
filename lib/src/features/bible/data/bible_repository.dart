import 'dart:convert';

import '../../praise/data/praise_database.dart';
import '../domain/bible_verse.dart';

class BibleRepository {
  BibleRepository({PraiseDatabase? database})
    : _db = database ?? PraiseDatabase.instance;

  final PraiseDatabase _db;

  Future<bool> hasData() async {
    final db = await _db.database;
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM bible_verses');
    final v = result.first['c'];
    return (v is int ? v : (v as num).toInt()) > 0;
  }

  Future<int> countVerses() async {
    final db = await _db.database;
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM bible_verses');
    final v = result.first['c'];
    return v is int ? v : (v as num).toInt();
  }

  Future<List<String>> getBookNames() async {
    final versions = await getVersions();
    if (versions.isEmpty) return const [];
    return getBookNamesForVersion(versions.first);
  }

  Future<List<String>> getVersions() async {
    final db = await _db.database;
    final rows = await db.rawQuery(
      'SELECT bible_version FROM bible_verses GROUP BY bible_version ORDER BY MIN(id)',
    );
    return rows.map((r) => r['bible_version'] as String).toList();
  }

  Future<List<String>> getBookNamesForVersion(String version) async {
    final db = await _db.database;
    final rows = await db.rawQuery(
      'SELECT book_name FROM bible_verses WHERE bible_version = ? GROUP BY book_name ORDER BY MIN(id)',
      [version],
    );
    return rows.map((r) => r['book_name'] as String).toList();
  }

  Future<int> getMaxChapter(String bookName) async {
    final db = await _db.database;
    final result = await db.rawQuery(
      'SELECT MAX(chapter) AS m FROM bible_verses WHERE book_name = ?',
      [bookName],
    );
    final v = result.first['m'];
    if (v == null) return 0;
    return v is int ? v : (v as num).toInt();
  }

  Future<List<BibleVerse>> getChapterVerses(
    String bookName,
    int chapter,
  ) async {
    final versions = await getVersions();
    if (versions.isEmpty) return const [];
    return getVerses(
      version: versions.first,
      bookName: bookName,
      chapter: chapter,
    );
  }

  Future<List<BibleVerse>> getVerses({
    required String version,
    required String bookName,
    required int chapter,
    int? verse,
  }) async {
    final db = await _db.database;
    final where = StringBuffer(
      'bible_version = ? AND book_name = ? AND chapter = ?',
    );
    final whereArgs = <Object>[version, bookName, chapter];
    if (verse != null) {
      where.write(' AND verse = ?');
      whereArgs.add(verse);
    }

    final rows = await db.query(
      'bible_verses',
      where: where.toString(),
      whereArgs: whereArgs,
      orderBy: 'verse',
    );
    return rows
        .map(
          (r) => BibleVerse(
            id: r['id'] as int,
            bookName: r['book_name'] as String,
            chapter: r['chapter'] as int,
            verse: r['verse'] as int,
            text: r['text'] as String,
          ),
        )
        .toList();
  }

  /// [version] 의 [bookName] 과 같은 책을 [inVersion] 에서 찾아 준다.
  ///
  /// 역본마다 책 이름이 다르다 (창세기 vs Genesis). 이름이 같으면 그대로 쓰고,
  /// 아니면 삽입 순서(= 정경 순서) 상 같은 자리의 책을 쓴다.
  ///
  /// ponytail: 두 역본이 같은 순서로 전권을 담고 있다고 가정한다.
  /// 권 수가 다르면 포기하고 null. 실제로 어긋나면 책 이름 별칭표가 필요하다.
  Future<String?> mapBookName({
    required String bookName,
    required String fromVersion,
    required String inVersion,
  }) async {
    if (fromVersion == inVersion) return bookName;
    final target = await getBookNamesForVersion(inVersion);
    if (target.contains(bookName)) return bookName;
    final source = await getBookNamesForVersion(fromVersion);
    if (source.length != target.length) return null;
    final index = source.indexOf(bookName);
    if (index < 0) return null;
    return target[index];
  }

  // JSON 임포트 — 기존 데이터 삭제 후 재삽입
  Future<int> importFromJson(
    String jsonString, {
    required String version,
  }) async {
    final normalizedVersion = version.trim();
    if (normalizedVersion.isEmpty) {
      throw Exception('성경 버전 이름을 입력해 주세요.');
    }
    final verses = _parseJson(jsonString);
    if (verses.isEmpty) {
      throw Exception('파싱된 절이 없습니다. JSON 형식을 확인해주세요.');
    }

    final db = await _db.database;
    await db.transaction((txn) async {
      await txn.delete(
        'bible_verses',
        where: 'bible_version = ?',
        whereArgs: [normalizedVersion],
      );
      for (final v in verses) {
        await txn.insert('bible_verses', {
          'bible_version': normalizedVersion,
          'book_name': v.bookName,
          'chapter': v.chapter,
          'verse': v.verse,
          'text': v.text,
        });
      }
    });
    return verses.length;
  }

  // ── JSON 파싱 (3가지 형식 지원) ──────────────────────────────────────

  List<BibleVerse> _parseJson(String src) {
    final dynamic data = jsonDecode(src);
    if (data is List) return _parseList(data);
    if (data is Map) return _parseMap(data as Map<String, dynamic>);
    throw Exception('지원하지 않는 JSON 형식입니다.');
  }

  // 형식 A: [{"book":"창세기","chapter":1,"verse":1,"text":"..."}]
  // 형식 B: [{"book":"창세기","chapters":[{"chapter":1,"verses":[{"verse":1,"text":"..."}]}]}]
  List<BibleVerse> _parseList(List<dynamic> list) {
    final out = <BibleVerse>[];
    for (final raw in list) {
      final item = raw as Map<String, dynamic>;
      if (item.containsKey('chapters')) {
        // 형식 B
        final book = item['book'] as String;
        for (final chRaw in item['chapters'] as List<dynamic>) {
          final ch = chRaw as Map<String, dynamic>;
          final chNum = (ch['chapter'] as num).toInt();
          for (final vRaw in ch['verses'] as List<dynamic>) {
            final v = vRaw as Map<String, dynamic>;
            out.add(
              BibleVerse(
                id: 0,
                bookName: book,
                chapter: chNum,
                verse: (v['verse'] as num).toInt(),
                text: v['text'] as String,
              ),
            );
          }
        }
      } else if (item.containsKey('verse') && item.containsKey('text')) {
        // 형식 A
        out.add(
          BibleVerse(
            id: 0,
            bookName: item['book'] as String,
            chapter: (item['chapter'] as num).toInt(),
            verse: (item['verse'] as num).toInt(),
            text: item['text'] as String,
          ),
        );
      }
    }
    return out;
  }

  // 형식 C: {"창세기":{"1":{"1":"태초에..."}}}
  List<BibleVerse> _parseMap(Map<String, dynamic> map) {
    final out = <BibleVerse>[];
    for (final bookEntry in map.entries) {
      final book = bookEntry.key;
      final chMap = bookEntry.value as Map<String, dynamic>;
      for (final chEntry in chMap.entries) {
        final ch = int.tryParse(chEntry.key) ?? 0;
        final vMap = chEntry.value as Map<String, dynamic>;
        for (final vEntry in vMap.entries) {
          final v = int.tryParse(vEntry.key) ?? 0;
          out.add(
            BibleVerse(
              id: 0,
              bookName: book,
              chapter: ch,
              verse: v,
              text: vEntry.value as String,
            ),
          );
        }
      }
    }
    return out;
  }
}
