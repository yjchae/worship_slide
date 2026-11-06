import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/chord_lyrics.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/presentation/chord_key_controls.dart';
import 'package:worship_slides/src/features/praise/presentation/chord_sheet_view.dart';
import 'package:worship_slides/src/features/praise/presentation/singer_view_data.dart';

/// 코드 악보 그리기(ChordSheetView 조각)·싱어 JSON 모양·조 표시 (기획 planning/chord-lyrics §3-3·§3-11).
void main() {
  group('chordPieces (세 렌더러 공통 조각 규칙)', () {
    test('코드 자리에서 자르고, 첫 코드 앞 글은 코드 없는 조각', () {
      final line = parseChordPage('주 은[D/F#]혜 [G]놀라워').single;
      final pieces = chordPieces(line);
      expect(pieces.map((p) => p.text).toList(), ['주 은', '혜 ', '놀라워']);
      expect(pieces.map((p) => p.chord).toList(), [null, 'D/F#', 'G']);
      expect(pieces.map((p) => p.offset).toList(), [0, 3, 5]);
    });

    test('같은 자리 코드 둘은 한 조각에 나란히', () {
      final pieces = chordPieces(parseChordPage('[G][D]주님').single);
      expect(pieces.single.chord, 'G D');
      expect(pieces.single.text, '주님');
    });

    test('줄 끝 코드는 글 없는 마지막 조각', () {
      final pieces = chordPieces(parseChordPage('[C]주님[G]').single);
      expect(pieces.last.text, '');
      expect(pieces.last.chord, 'G');
    });

    test('코드 없는 줄은 조각 하나', () {
      final pieces = chordPieces(const ChordLine('주님', []));
      expect(pieces.single.chord, isNull);
      expect(pieces.single.text, '주님');
    });
  });

  group('ChordSheetView', () {
    testWidgets('코드와 가사를 그리고, 글자를 누르면 (줄, 위치)를 알린다', (tester) async {
      final taps = <(int, int)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 600,
            height: 300,
            child: ChordSheetView(
              lines: parseChordPage('[G]주 은혜\n놀라워'),
              fontSize: 20,
              fit: BoxFit.scaleDown,
              onTapChar: (l, o) => taps.add((l, o)),
            ),
          ),
        ),
      );
      expect(find.text('G'), findsOneWidget);
      await tester.tap(find.text('혜'));
      await tester.tap(find.text('놀'));
      expect(taps, [(0, 3), (1, 0)]);
    });

    testWidgets('보조 덩어리는 원본 덩어리 다음에 그린다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 600,
            height: 300,
            child: ChordSheetView(
              lines: parseChordPage('[G]주 은혜'),
              subTexts: const ['Amazing grace', ''],
            ),
          ),
        ),
      );
      final main = tester.getTopLeft(find.text('주 은혜'));
      final sub = tester.getTopLeft(find.text('Amazing grace'));
      expect(sub.dy, greaterThan(main.dy));
    });
  });

  group('싱어 JSON (chord_lines · key_label)', () {
    test('코드 줄은 {t, c:[[오프셋, 이름]]} 모양으로 실린다', () {
      final page = SingerPage(
        mainText: '주 은혜',
        chordLines: parseChordPage('[G]주 은[D/F#]혜\n[A] [E]'),
        keyLabel: 'A (원래 G, +2)',
      );
      final json = page.toJson();
      expect(json['chord_lines'], [
        {
          't': '주 은혜',
          'c': [
            [0, 'G'],
            [3, 'D/F#'],
          ],
        },
        {
          't': '',
          'c': [
            [0, 'A'],
            [0, 'E'],
          ],
        },
      ]);
      expect(json['key_label'], 'A (원래 G, +2)');
    });

    test('코드가 없으면 키를 아예 싣지 않는다(꺼진 네이티브 싱어 창 포함)', () {
      final json = const SingerPage(mainText: '주 은혜').toJson();
      expect(json.containsKey('chord_lines'), isFalse);
      expect(json.containsKey('key_label'), isFalse);
      final empty = const SingerPage(mainText: '주', chordLines: []).toJson();
      expect(empty.containsKey('chord_lines'), isFalse);
    });
  });

  group('조 표시', () {
    const song = PraiseSong(
      id: 1,
      fileName: 'a',
      title: '주 은혜',
      lyrics: '주 은혜',
      englishLyrics: '',
      chordLyrics: '[G]주 은혜',
      chordKey: 'G',
    );

    test('조 배지는 조를 바꿨을 때만', () {
      expect(chordKeyLabelOf(song), '');
      expect(chordKeyLabelOf(song.copyWith(chordTranspose: 2)), 'A (원래 G, +2)');
      expect(chordKeyLabelOf(null), '');
    });

    test('추정 조는 (추정)', () {
      final estimated = song.copyWith(chordKey: null, chordTranspose: -2);
      expect(chordKeyLabelOf(estimated), 'F (원래 G (추정), -2)');
    });

    test('콘티 조 칩: 원래대로면 G, 바꿨으면 G→A', () {
      expect(chordKeyChipLabel(song), 'G');
      expect(chordKeyChipLabel(song.copyWith(chordTranspose: 2)), 'G→A');
      expect(
        chordKeyChipLabel(
          song.copyWith(
            chordTranspose: 1,
            chordAccidental: ChordAccidental.flat,
          ),
        ),
        'G→Ab',
      );
    });
  });
}
