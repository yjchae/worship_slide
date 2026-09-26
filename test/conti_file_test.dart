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

  Future<WorshipContiRepository> freshRepository() async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(db.close);
    await createPraiseSchema(db);
    return WorshipContiRepository(database: PraiseDatabase.forTesting(db));
  }

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
}
