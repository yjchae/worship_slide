import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/worship_conti_repository.dart';
import 'package:worship_slides/src/features/praise/domain/slide_background.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';

/// `_appendConti` 는 `_nextUid += items.length` 로 uid 를 맞춘다.
/// 빠진 항목이 uid 를 쓰지 않아야 같은 콘티를 두 번 붙여도 겹치지 않는다.
void main() {
  setUpAll(sqfliteFfiInit);

  test('빠진 항목은 uid 를 쓰지 않아 두 번 붙여도 겹치지 않는다', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await createPraiseSchema(db);
    final repository = WorshipContiRepository(
      database: PraiseDatabase.forTesting(db),
    );

    const background = SlideBackground(color: Color(0xFF123456));
    final contiId = await repository.saveConti(
      '주일 예배',
      [
        (uid: 1, item: const BlankStagingItem(mainText: '앞')),
        (
          uid: 2,
          item: const ImageStagingItem(
            sourceName: 'PPT',
            imagePaths: ['/없는/경로/1.png'],
          ),
        ),
        (uid: 3, item: const BlankStagingItem(mainText: '뒤')),
      ],
      notes: const {'3:0': '메모'},
      backgrounds: const {3: background},
      noSpacerUids: const {3},
    );

    var nextUid = 100;
    final first = await repository.loadConti(contiId, nextUid);
    nextUid += first.items.length;
    final second = await repository.loadConti(contiId, nextUid);

    expect(first.missingCount, 1);
    expect([for (final e in first.items) e.uid], [100, 101]);
    expect([for (final e in second.items) e.uid], [102, 103]);
    // 메모·배경·여백 없음은 각자의 새 uid 로만 따라온다.
    expect(first.notes.keys, ['101:0']);
    expect(second.notes.keys, ['103:0']);
    expect(first.backgrounds.keys, [101]);
    expect(second.backgrounds.keys, [103]);
    expect(first.noSpacerUids, {101});
    expect(second.noSpacerUids, {103});
  });
}
