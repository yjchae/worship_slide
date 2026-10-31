import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';
import 'package:worship_slides/src/features/praise/presentation/praise_home_page.dart';

// 원본 곡을 고친 뒤 콘티 항목도 바꿀지: 대상·건너뜀 계산, 바뀜 여부, 확인창 기본값.
void main() {
  PraiseSong song({int? id = 7, String lyrics = '가\n\n나', String en = ''}) =>
      PraiseSong(
        id: id,
        fileName: 'a.pptx',
        title: '주의 사랑',
        lyrics: lyrics,
        englishLyrics: en,
      );

  test('곡 전체를 담은 항목만 대상, 나눈·고친 항목은 건너뜀으로 센다', () {
    final before = song();
    final items = <({int uid, StagingItem item})>[
      (uid: 1, item: SongStagingItem(song(en: 'A\n\nB'))), // 통째(보조만 다름)
      (uid: 2, item: SongStagingItem(song(lyrics: '나'))), // 나눈 항목
      (uid: 3, item: SongStagingItem(song(lyrics: '가 고침\n\n나'))), // 콘티에서 고침
      (uid: 4, item: SongStagingItem(song(id: 8))), // 다른 곡
      (uid: 5, item: SongStagingItem(song())),
    ];
    final plan = stagedSongUpdatePlan(items, songId: 7, before: before);
    expect(plan.targets, [1, 5]);
    expect(plan.skipped, 2);
    expect(
      stagedSongUpdatePlan(items, songId: 99, before: before).targets,
      isEmpty,
    );
  });

  test('바뀐 게 없으면 묻지 않는다', () {
    final before = song(en: 'A');
    bool changed(PraiseSong edited, Map<String, String> sub) => songEditChanged(
      before: before,
      edited: edited,
      oldTranslations: const {'일본어': 'あ'},
      newSubLyrics: sub,
      defaultSubLanguage: '영어',
    );
    expect(changed(before, const {'영어': 'A', '일본어': 'あ'}), isFalse);
    expect(changed(before, const {}), isFalse);
    expect(changed(song(lyrics: '가\n\n다', en: 'A'), const {}), isTrue);
    expect(changed(song(en: 'B'), const {}), isTrue);
    expect(changed(before, const {'일본어': 'い'}), isTrue);
    expect(changed(before, const {'중국어': '你'}), isTrue); // 새 번역
  });

  Future<ValueNotifier<Object?>> open(
    WidgetTester tester,
    Widget dialog,
  ) async {
    final result = ValueNotifier<Object?>('열림');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result.value = await showDialog<bool>(
                context: context,
                builder: (_) => dialog,
              );
            },
            child: const Text('열기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('확인창 기본(Enter)은 그대로 두기다', (tester) async {
    final result = await open(
      tester,
      const StagedSongUpdateDialog(count: 2, skipped: 1),
    );
    expect(find.textContaining('이 곡 2개 항목도'), findsOneWidget);
    expect(
      find.textContaining('라이브러리 가사와 다른 항목 1개(나누었거나 콘티에서 고친 항목)는 그대로 둡니다.'),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result.value, isFalse);
  });

  testWidgets('콘티도 바꾸기를 누르면 true, 건너뜀이 없으면 안내도 없다', (tester) async {
    final result = await open(tester, const StagedSongUpdateDialog(count: 1));
    expect(find.textContaining('라이브러리 가사와 다른'), findsNothing);
    await tester.tap(find.text('콘티도 바꾸기'));
    await tester.pumpAndSettle();
    expect(result.value, isTrue);
  });
}
