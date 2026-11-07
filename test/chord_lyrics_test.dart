import 'package:flutter_test/flutter_test.dart';
import 'package:worship_slides/src/features/praise/domain/chord_lyrics.dart';
import 'package:worship_slides/src/features/praise/domain/lyrics_text.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';

void main() {
  group('isChordName (§3-1 표)', () {
    for (final name in [
      'G',
      'D/F#',
      'Em7',
      'Bb',
      'F#m7b5',
      'Cmaj7',
      'Dsus4',
      'D7sus4',
      'Cadd9',
      'C7(b9)',
      'Am(maj7)',
      'Am7/G',
      'N.C.',
      'Gsus',
      'C#m7',
      'F♯m',
      'B♭',
      'Gm7',
      'Bdim',
      'Caug',
      'C+',
      'Bø',
      'E°7',
      'CM7',
      'Asus2',
      'G7(b9,#11)',
    ]) {
      test('코드: $name', () => expect(isChordName(name), isTrue));
    }
    for (final name in [
      '후렴',
      'Chorus',
      'Bridge',
      'Ending',
      'Coda',
      'Fine',
      'D.S.',
      'x2',
      'Gsuss',
      'g',
      'am',
      'C6/9',
      'H',
      '',
      'G ',
      ' G',
      'Intro',
      'Am7/g',
    ]) {
      test('글자: "$name"', () => expect(isChordName(name), isFalse));
    }
  });

  group('stripChords (H6 예시)', () {
    test('페이지 안 코드만 있는 줄은 줄째 사라진다', () {
      expect(stripChords('가사\n[G] [D]\n\n가사2'), '가사\n\n가사2');
    });
    test('앞의 코드만 있는 페이지는 빈 페이지로 남는다', () {
      expect(stripChords('[G] [D]\n\n가사'), '\n\n가사');
    });
    test('끝의 코드만 있는 페이지는 떼어진다', () {
      expect(stripChords('가사\n\n[G] [D]'), '가사');
    });
    test('가운데 코드만 있는 페이지는 빈 페이지', () {
      expect(stripChords('가사\n\n[G] [D]\n\n가사2'), '가사\n\n\n\n가사2');
    });
    test('이스케이프는 글자 [', () {
      expect(stripChords(r'[G]주 \[A]'), '주 [A]');
    });
    test('인라인 코드', () {
      expect(stripChords('[G]주 은[D/F#]혜 [Em7]놀라워'), '주 은혜 놀라워');
    });
    test('줄 끝 코드 뒤 공백은 지운다', () {
      expect(stripChords('주님 [G]'), '주님');
    });
    test('문법 밖 대괄호는 글자로 남는다', () {
      expect(stripChords('[후렴]\n[G]주 [Gsuss]'), '[후렴]\n주 [Gsuss]');
    });
    test('짝 없는 대괄호·줄 넘는 대괄호는 글자', () {
      expect(stripChords('주 [G\n]은혜'), '주 [G\n]은혜');
      expect(stripChords('a ] b ['), 'a ] b [');
    });
    test('[[G]] 은 바깥이 글자', () {
      expect(stripChords('[[G]]주'), '[]주');
    });
    test('빈 글', () => expect(stripChords(''), ''));
    test('코드 없는 빈 줄 여럿은 빈 페이지 규칙 그대로', () {
      expect(stripChords('a\n\n\n\nb'), 'a\n\n\n\nb');
    });
  });

  group('escapeLyricsForChords (B0)', () {
    final samples = [
      '',
      '주 은혜',
      '[A]',
      '[후렴]\n주 은혜',
      '[G]주 [D]님',
      r'\[G]',
      r'\\[G]',
      r'a\b',
      r'a \ b',
      r'끝 \',
      '[[G]]',
      '[x2] 다시',
      '[G',
      ']G[',
      '[Gsuss]',
      '[N.C.]',
      '[]',
      '[ G ]',
      '1절\n\n2절',
      '\n\n앞 빈 페이지',
      '가사\n\n\n\n빈 페이지 가운데',
      '끝 빈 페이지\n\n',
      '  앞뒤 공백  \n다음  ',
      'a\r\nb',
      '###\n가사',
      '[Em7]은혜 [D/F#]',
      r'\[[G]]',
      '[C][D]',
      '줄1 [Am]\n[Am]줄2',
      'How [G]great is our God',
      '[A] [B]\n\n[C]',
      r'\\\[G]',
    ];
    for (final x in samples) {
      test('왕복: ${x.replaceAll('\n', r'\n')}', () {
        expect(
          stripChords(escapeLyricsForChords(x)),
          normalizeEditableLyrics(x),
        );
      });
    }
    test('코드로 읽힐 [ 에만 붙인다', () {
      expect(escapeLyricsForChords('[A] [후렴]'), r'\[A] [후렴]');
      expect(countEscapedBrackets('[A] [후렴] [Bb]'), 2);
    });
    test('이스케이프한 글에는 코드가 없다', () {
      expect(countChords(escapeLyricsForChords('[G]주 [D]님')), 0);
    });
  });

  group('chordPagesOf · parseChordPage', () {
    test('페이지 나누기', () {
      expect(chordPagesOf('[G]가\n\n[D]나\n\n'), ['[G]가', '[D]나']);
      expect(chordPagesOf('가\n\n[G] [D]'), ['가', '[G] [D]']);
    });
    test('줄과 UTF-16 오프셋', () {
      final lines = parseChordPage('[G]주 은[D/F#]혜\n[G] [C]\n주님[Em]');
      expect(lines[0].text, '주 은혜');
      expect(lines[0].chords, [
        (offset: 0, name: 'G'),
        (offset: 3, name: 'D/F#'),
      ]);
      expect(lines[1].text, '');
      expect(lines[1].chords, [(offset: 0, name: 'G'), (offset: 0, name: 'C')]);
      expect(lines[2].chords.single, (offset: 2, name: 'Em'));
      expect(lines[0].toJson(), {
        't': '주 은혜',
        'c': [
          [0, 'G'],
          [3, 'D/F#'],
        ],
      });
    });
    test('연달아 쓴 코드는 같은 오프셋', () {
      final l = parseChordPage('[G][D]주').single;
      expect(l.chords.map((c) => c.offset), [0, 0]);
    });
    test('공백 앞 코드는 공백 위', () {
      final l = parseChordPage('주[G] 님').single;
      expect(l.text, '주 님');
      expect(l.chords.single.offset, 1);
    });
    test('이스케이프는 글자로', () {
      final l = parseChordPage(r'\[A] [G]x').single;
      expect(l.text, '[A] x');
      expect(l.chords.single, (offset: 4, name: 'G'));
    });
  });

  group('정합 (§3-5)', () {
    test('chordsMatchLyrics', () {
      expect(chordsMatchLyrics(null, '아무'), isTrue);
      expect(chordsMatchLyrics('[G]주\n\n[D]님', '주\n\n님'), isTrue);
      expect(chordsMatchLyrics('[G]주\n\n[D]님', '주\n\n님!'), isFalse);
    });
    test('페이지마다 같은 것만 보인다', () {
      expect(matchedChordPages('[G]가\n\n[D]나\n\n[E]다', '가\n\n나!\n\n다'), [
        '[G]가',
        null,
        '[E]다',
      ]);
    });
    test('페이지 수가 다르면 모두 숨긴다', () {
      expect(matchedChordPages('[G]가\n\n[D]나', '가\n\n나\n\n다'), [
        null,
        null,
        null,
      ]);
      expect(hiddenChordPageCount('[G]가\n\n[D]나', '가\n\n나\n\n다'), 2);
    });
    test('코드 없는 페이지는 null', () {
      expect(matchedChordPages('[G]가\n\n나', '가\n\n나'), ['[G]가', null]);
      expect(hiddenChordPageCount('[G]가\n\n나', '가\n\n나'), 0);
    });
    test('코드만 있는 가운데 페이지는 빈 페이지와 짝', () {
      expect(matchedChordPages('가\n\n[G] [D]\n\n나', '가\n\n\n\n나'), [
        null,
        '[G] [D]',
        null,
      ]);
    });
    test('끝 코드만 있는 페이지는 안 보이고 숨김으로 센다', () {
      expect(matchedChordPages('[G]가\n\n[D] [A]', '가'), ['[G]가']);
      expect(hiddenChordPageCount('[G]가\n\n[D] [A]', '가'), 1);
    });
  });

  group('validateChordText', () {
    test('못 읽는 대괄호·고칠 수 있는 대소문자', () {
      final issues = validateChordText('[후렴]\n[g]주 [am]님 [Gsuss]');
      expect(issues.map((i) => i.kind), [
        ChordIssueKind.unreadableBracket,
        ChordIssueKind.fixableCase,
        ChordIssueKind.fixableCase,
        ChordIssueKind.unreadableBracket,
      ]);
      expect(issues[1].suggestion, '[G]');
      expect(issues[2].suggestion, '[Am]');
      final page = '[후렴]\n[g]주 [am]님 [Gsuss]';
      expect(page.substring(issues[3].start, issues[3].end), '[Gsuss]');
    });
    test('이스케이프한 대괄호는 경고하지 않는다', () {
      expect(validateChordText(r'\[G] \[후렴]'), isEmpty);
    });
    test('끝 페이지가 코드뿐', () {
      final issues = validateChordText('[G]가\n\n[D] [A]');
      expect(issues.single.kind, ChordIssueKind.trailingChordOnlyPage);
      expect(issues.single.page, 1);
    });
    test('[[G]]', () {
      final issues = validateChordText('[[G]]주');
      expect(issues.single.kind, ChordIssueKind.nestedBracket);
      expect((issues.single.start, issues.single.end), (0, 5));
    });
  });

  test('countChords · chordNamesIn', () {
    expect(countChords('[G]가 [D]나\n\n[G] [C]\n\\[A]'), 4);
    expect(chordNamesIn('[D]a[G]b[G]c[C]'), ['G', 'D', 'C']);
  });

  group('snapSplitOffset', () {
    const page = '[G]주 은[D/F#]혜 \\[x]';
    test('토큰 안이면 토큰 앞', () {
      expect(snapSplitOffset(page, 1), 0);
      expect(snapSplitOffset(page, 7), 6);
    });
    test('토큰 바로 뒤면 토큰 앞(토큰은 뒤 조각으로)', () {
      expect(snapSplitOffset(page, 3), 0);
      expect(snapSplitOffset(page, 12), 6);
    });
    test('\\[ 사이면 앞으로', () {
      final i = page.indexOf(r'\[');
      expect(snapSplitOffset(page, i + 1), i);
    });
    test('연달아 붙은 토큰은 함께', () {
      expect(snapSplitOffset('가[G][D]주', 7), 1);
    });
    test('보통 글자는 그대로', () {
      expect(snapSplitOffset(page, 4), 4);
      expect(snapSplitOffset('a\n[G]b', 2), 2);
      expect(snapSplitOffset('a\n[G]b', 5), 2);
    });
  });

  group('조', () {
    test('isKeyName', () {
      for (final k in ['G', 'Bb', 'F#m', 'Ebm', 'C', 'Am', 'B♭']) {
        expect(isKeyName(k), isTrue, reason: k);
      }
      for (final k in ['H', 'Gmaj', 'G7', '', 'E#', 'Cb', 'gm']) {
        expect(isKeyName(k), isFalse, reason: k);
      }
    });
    test('estimateKey', () {
      expect(estimateKey('[N.C.]주 [G]은혜 [D]'), 'G');
      expect(estimateKey('[Em7]주 [C]'), 'Em');
      expect(estimateKey('[Cmaj7]주'), 'C');
      expect(estimateKey('[Bbm7]주'), 'Bbm');
      expect(estimateKey('[F#min]주'), 'F#m');
      expect(estimateKey('코드 없음'), isNull);
      expect(estimateKey(r'\[G]글자'), isNull);
    });
    test('keyAfter 자동 표기', () {
      expect(keyAfter('G', 2), 'A');
      expect(keyAfter('G', -2), 'F');
      expect(keyAfter('C', 1), 'Db');
      expect(keyAfter('E', 2), 'Gb');
      expect(keyAfter('A', 1), 'Bb');
      expect(keyAfter('Em', 1), 'Fm');
      expect(keyAfter('Em', 2), 'F#m');
      expect(keyAfter('Am', 1), 'Bbm');
      expect(keyAfter('Am', 4), 'C#m');
      expect(keyAfter('G', 0), 'G');
      expect(keyAfter('G', 12), 'G');
      expect(keyAfter('C', 1, accidental: ChordAccidental.sharp), 'C#');
      expect(keyAfter('C', 3, accidental: ChordAccidental.sharp), 'D#');
      expect(keyAfter('C', 6, accidental: ChordAccidental.flat), 'Gb');
      expect(keyAfter('모름', 3), '모름');
    });
    test('semitonesBetween', () {
      expect(semitonesBetween('G', 'F'), -2);
      expect(semitonesBetween('G', 'A'), 2);
      expect(semitonesBetween('C', 'F#'), 6);
      expect(semitonesBetween('C', 'G'), -5);
      expect(semitonesBetween('Bb', 'A#'), 0);
      expect(semitonesBetween('Em', 'F#m'), 2);
      expect(semitonesBetween('G', 'Em'), isNull);
      expect(semitonesBetween('G', 'H'), isNull);
    });
    test('wrapTranspose', () {
      expect(wrapTranspose(12), 0);
      expect(wrapTranspose(-12), 0);
      expect(wrapTranspose(13), 1);
      expect(wrapTranspose(-13), -1);
      expect(wrapTranspose(11), 11);
      expect(wrapTranspose(-11), -11);
    });
    test('keyLabel', () {
      expect(
        keyLabel(originalKey: 'G', estimated: false, semitones: 2),
        'A (원래 G, +2)',
      );
      expect(
        keyLabel(originalKey: 'G', estimated: true, semitones: 2),
        'A (원래 G (추정), +2)',
      );
      expect(
        keyLabel(originalKey: 'G', estimated: false, semitones: -2),
        'F (원래 G, -2)',
      );
      expect(keyLabel(originalKey: 'G', estimated: false, semitones: 0), '');
      expect(keyLabel(originalKey: 'G', estimated: false, semitones: 12), '');
      expect(keyLabel(originalKey: null, estimated: false, semitones: 3), '+3');
    });
  });

  group('조 바꾸기', () {
    test('transposeChordName', () {
      expect(transposeChordName('G', 2), 'A');
      expect(transposeChordName('D/F#', 2), 'E/G#');
      expect(transposeChordName('Bbm7', 2), 'Cm7');
      expect(
        transposeChordName('F#m7b5', 1, accidental: ChordAccidental.sharp),
        'Gm7b5',
      );
      expect(
        transposeChordName('Cmaj7', 1, accidental: ChordAccidental.flat),
        'Dbmaj7',
      );
      expect(
        transposeChordName('Cmaj7', 1, accidental: ChordAccidental.sharp),
        'C#maj7',
      );
      expect(transposeChordName('C7(b9)', 2), 'D7(b9)');
      expect(transposeChordName('N.C.', 3), 'N.C.');
      expect(transposeChordName('Gsuss', 3), 'Gsuss');
      expect(transposeChordName('G', 0), 'G');
      expect(transposeChordName('F♯m', 0), 'F♯m');
      expect(transposeChordName('F♯m', 1), 'Gm');
      expect(transposeChordName('A', 1, targetKey: 'Bb'), 'Bb');
      expect(transposeChordName('A', 1, targetKey: 'B'), 'A#');
      expect(transposeChordName('B', 1), 'C');
      expect(transposeChordName('E', 1), 'F');
    });
    test('E#·B#·Cb·Fb 는 내지 않는다', () {
      for (var n = -11; n <= 11; n++) {
        for (final acc in ChordAccidental.values) {
          for (final name in ['C', 'E', 'F', 'B', 'Bb', 'F#', 'Gb']) {
            final out = transposeChordName(name, n, accidental: acc);
            expect(
              RegExp(r'^(E#|B#|Cb|Fb)').hasMatch(out),
              isFalse,
              reason: '$name $n $acc → $out',
            );
          }
        }
      }
    });
    test('transposeChordText: 원래 조 기준 자동 표기', () {
      const text = '[G]주 은[D/F#]혜 [Em7]놀라워 \\[A]\n[C] [D]';
      expect(
        transposeChordText(text, 2, originalKey: 'G'),
        '[A]주 은[E/G#]혜 [F#m7]놀라워 \\[A]\n[D] [E]',
      );
      expect(
        transposeChordText(text, -2, originalKey: 'G'),
        '[F]주 은[C/E]혜 [Dm7]놀라워 \\[A]\n[Bb] [C]',
      );
    });
    test('조를 모르면 원래 표기를 따른다', () {
      expect(transposeChordText('[Bb] [Eb] [F]', 2), '[C] [F] [G]');
      expect(transposeChordText('[Bb] [Eb] [C]', 1), '[B] [E] [Db]');
      expect(transposeChordText('[A] [E]', 1), '[A#] [F]');
    });
    test('0 이면 그대로', () {
      const t = '[F♯m]가 [Bb]';
      expect(transposeChordText(t, 0), same(t));
      expect(transposeChordText(t, 12), t);
    });
    test('strip 은 늘 같다', () {
      const texts = [
        '[G]주 은[D/F#]혜 [Em7]놀라워',
        r'\[A] [Bb]가 [Gsuss] [후렴]',
        '[G] [D]\n\n가사',
        '[N.C.]아무',
      ];
      for (final t in texts) {
        for (var n = -11; n <= 11; n++) {
          expect(stripChords(transposeChordText(t, n)), stripChords(t));
        }
      }
    });
    test('표기 선호를 지킨다', () {
      expect(
        transposeChordText(
          '[C] [G]',
          1,
          accidental: ChordAccidental.sharp,
          originalKey: 'C',
        ),
        '[C#] [G#]',
      );
      expect(
        transposeChordText(
          '[C] [G]',
          1,
          accidental: ChordAccidental.flat,
          originalKey: 'C',
        ),
        '[Db] [Ab]',
      );
    });
  });

  group('realignChords', () {
    test('코드가 없으면 이스케이프한 새 가사', () {
      final r = realignChords('주 은혜', '주 [A] 은혜');
      expect(r.chordText, r'주 \[A] 은혜');
      expect(r.confident, isTrue);
    });
    test('같은 가사면 그대로', () {
      const t = '[G]주 은[D]혜\n[C] [D]\n주[Em]님\n\n[G] [D]\n\n[A]끝';
      final r = realignChords(t, stripChords(t));
      expect(r.chordText, t);
      expect(r.dropped, 0);
      expect(r.moved, 0);
      expect(r.confident, isTrue);
    });
    test('(a) 페이지 경계만 옮김 — 코드를 하나도 안 잃는다', () {
      const t = '[G]첫 줄\n[D]둘째 줄\n\n[Em]셋째 [C]줄';
      final r = realignChords(t, '첫 줄\n\n둘째 줄\n셋째 줄');
      expect(r.chordText, '[G]첫 줄\n\n[D]둘째 줄\n[Em]셋째 [C]줄');
      expect(r.confident, isTrue);
      expect(r.kept, 4);
      expect(stripChords(r.chordText), '첫 줄\n\n둘째 줄\n셋째 줄');
    });
    test('(a) 합치기', () {
      const t = '[G]가\n\n[D]나';
      final r = realignChords(t, '가\n나');
      expect(r.chordText, '[G]가\n[D]나');
      expect(r.confident, isTrue);
    });
    test('(b) 오타 고치기', () {
      const t = '[G]주 은혜 놀라[D]워 그 소리 [C]듣기 좋아라 나 같은 [G]죄인';
      final r = realignChords(t, '주 은혜 놀라와 그 소리 듣기 좋아라 나 같은 죄인');
      expect(r.chordText, '[G]주 은혜 놀라[D]와 그 소리 [C]듣기 좋아라 나 같은 [G]죄인');
      // 코드가 붙은 글자가 바뀌어 다음 글자로 옮겼다 — 옮김이 있으면 자동 저장 안 함.
      expect(r.moved + r.kept, 4);
    });
    test('(b) 코드 없는 글자 오타는 자동 저장', () {
      const t = '[G]주 은혜 놀라워 그 소리 [C]듣기 좋아라 나 같은 [G]죄인';
      final r = realignChords(t, '주 은혜 놀라와 그 소리 듣기 좋아라 나 같은 죄인');
      expect(r.chordText, '[G]주 은혜 놀라와 그 소리 [C]듣기 좋아라 나 같은 [G]죄인');
      expect(r.confident, isTrue);
    });
    test('크게 바뀌면 자동 저장 안 함', () {
      const t = '[G]주 은혜 [D]놀라워';
      final r = realignChords(t, '전혀 다른 노래 가사입니다');
      expect(r.confident, isFalse);
    });
    test('줄째 지워진 코드는 버린다', () {
      const t = '[G]가나다\n[D]라마바';
      final r = realignChords(t, '가나다');
      expect(r.chordText, '[G]가나다');
      expect(r.dropped, 1);
      expect(r.confident, isFalse);
    });
    test('줄 끝 코드', () {
      const t = '주님[G]\n다음';
      final r = realignChords(t, '주님\n\n다음');
      expect(r.chordText, '주님[G]\n\n다음');
      expect(r.confident, isTrue);
    });
    test('코드만 있는 줄은 다음 가사 줄 앞에', () {
      const t = '[G] [D]\n가사\n둘째';
      final r = realignChords(t, '가사\n\n둘째');
      expect(r.chordText, '[G] [D]\n가사\n\n둘째');
      expect(r.confident, isTrue);
    });
    test('가운데 코드만 있는 페이지', () {
      const t = '가\n\n[G] [D]\n\n나';
      final r = realignChords(t, '가\n\n\n\n나');
      expect(r.chordText, t);
      expect(r.confident, isTrue);
    });
    test('끝 코드만 있는 페이지는 지우지 않고 끝에 둔다', () {
      const t = '[G]가\n\n[D] [A]';
      final r = realignChords(t, '가\n나');
      expect(r.chordText, '[G]가\n나\n\n[D] [A]');
    });
    test('새 가사의 대괄호는 이스케이프', () {
      const t = '[G]가 나';
      final r = realignChords(t, '가 [A] 나');
      expect(r.chordText, r'[G]가 \[A] 나');
      expect(stripChords(r.chordText), '가 [A] 나');
    });
    test('결과 strip 은 늘 새 가사', () {
      const t = '[G]주 은[D/F#]혜\n[C] [D]\n주[Em]님\n\n[G] [D]\n\n[A]끝 [E]';
      for (final lyrics in [
        '주 은혜\n주님\n\n\n\n끝',
        '주 은혜\n\n주님\n\n\n\n끝',
        '주 은혜 놀라워\n주님\n\n끝',
        '완전히 다른\n\n가사',
        '',
        r'주 \[G] 은혜',
      ]) {
        final r = realignChords(t, lyrics);
        expect(
          stripChords(r.chordText),
          normalizeEditableLyrics(lyrics),
          reason: lyrics,
        );
      }
    });
    test('긴 가사도 빠르게 끝난다', () {
      final old = List.generate(200, (i) => '[G]줄 $i 가사 [D]입니다').join('\n');
      final lyrics = List.generate(200, (i) => '다른 $i 가사').join('\n');
      final sw = Stopwatch()..start();
      final r = realignChords(old, lyrics);
      expect(sw.elapsedMilliseconds, lessThan(5000));
      expect(stripChords(r.chordText), normalizeEditableLyrics(lyrics));
    });
  });

  group('chordOverLyricsToInline', () {
    test('코드 위 가사 두 쌍 이상', () {
      const pasted = 'G       D/F#\n주 은혜 놀라워\nEm  C\nabc defgh';
      final out = chordOverLyricsToInline(pasted);
      // 한글 폭 2칸: 'G' 칸 0 → '주', 'D/F#' 칸 8 → '놀'(주=0,공=2,은=3,혜=5,공=7,놀=8).
      expect(out, '[G]주 은혜 [D/F#]놀라워\n[Em]abc [C]defgh');
      expect(stripChords(out!), '주 은혜 놀라워\nabc defgh');
    });
    test('한 쌍뿐이면 null', () {
      expect(chordOverLyricsToInline('G  D\n주 은혜\n그냥 가사'), isNull);
    });
    test('짝 없는 코드 줄은 코드만 있는 줄', () {
      const pasted = 'G  D\n\nG\n주\nC\n님';
      expect(chordOverLyricsToInline(pasted), '[G] [D]\n\n[G]주\n[C]님');
    });
    test('줄보다 오른쪽 코드는 줄 끝', () {
      const pasted = 'G      D\nab\nC\n가';
      expect(chordOverLyricsToInline(pasted), '[G]ab[D]\n[C]가');
    });
    test('가사의 대괄호는 이스케이프', () {
      const pasted = 'G\n[A]가\nC\n나';
      expect(chordOverLyricsToInline(pasted), '[G]\\[A]가\n[C]나');
    });
  });

  group('PraiseSong 코드 칸', () {
    const song = PraiseSong(
      id: 1,
      fileName: 'a.pptx',
      title: '주 은혜',
      lyrics: '주 은혜\n\n놀라워\n\n끝',
      englishLyrics: 'grace\n\namazing',
      chordLyrics: '[G]주 은[D]혜\n\n놀라워\n\n[C]끝',
      chordKey: 'G',
    );

    test('pairedPages 의 chord 는 짝이 맞는 페이지만', () {
      expect(song.pairedPages.map((p) => p.chord), ['[G]주 은[D]혜', '', '[C]끝']);
      final stale = song.copyWith(lyrics: '주 은혜\n\n놀라워\n\n끝!');
      expect(stale.pairedPages.map((p) => p.chord), ['[G]주 은[D]혜', '', '']);
      final noChords = song.copyWith(chordLyrics: null);
      expect(noChords.hasChords, isFalse);
      expect(noChords.pairedPages.every((p) => p.chord.isEmpty), isTrue);
    });

    test('copyWith: 안 넘기면 그대로, null 이면 지움, 빈 글은 null', () {
      final moved = song.copyWith(
        chordTranspose: 2,
        chordAccidental: ChordAccidental.flat,
      );
      expect(moved.chordLyrics, song.chordLyrics);
      expect(moved.chordKey, 'G');
      expect(moved.chordTranspose, 2);
      expect(moved.chordAccidental, ChordAccidental.flat);
      expect(moved.copyWith(title: 'x').chordTranspose, 2);
      expect(song.copyWith(chordKey: null).chordKey, isNull);
      expect(song.copyWith(chordLyrics: '').chordLyrics, isNull);
    });

    test('toMap 에는 코드 칸이 없고 fromMap 은 읽는다 (H2)', () {
      final map = song.toMap();
      expect(map.keys.where((k) => k.contains('chord')), isEmpty);
      final read = PraiseSong.fromMap({
        ...map,
        'chord_lyrics': '[G]주',
        'chord_key': '',
      });
      expect(read.chordLyrics, '[G]주');
      expect(read.chordKey, isNull);
      expect(PraiseSong.fromMap(map).chordLyrics, isNull);
    });

    test('원래 조: 정해 둔 값, 없으면 추정', () {
      expect(song.effectiveChordKey, 'G');
      expect(song.chordKeyEstimated, isFalse);
      final guess = song.copyWith(chordKey: null);
      expect(guess.effectiveChordKey, 'G');
      expect(guess.chordKeyEstimated, isTrue);
      expect(song.copyWith(chordKey: 'H').effectiveChordKey, 'G');
    });

    test('chordLyricsForPages: 코드 없는 페이지는 이스케이프한 원본으로 채운다', () {
      final pages = song.pairedPages;
      expect(chordLyricsForPages([pages[0], pages[2]]), '[G]주 은[D]혜\n\n[C]끝');
      expect(chordLyricsForPages([pages[1]]), isNull);
      final withBracket = [
        (korean: '[A] 글자', english: '', extra: '', chord: ''),
        pages[2],
      ];
      final text = chordLyricsForPages(withBracket)!;
      expect(text, '\\[A] 글자\n\n[C]끝');
      expect(stripChords(text), '[A] 글자\n\n끝');
    });
  });

  group('편집 창 도우미 (chordMarksIn · chordSlotAt · diatonicChords)', () {
    test('코드 토큰과 이스케이프 자리', () {
      final marks = chordMarksIn('[G]주 \\[A]\n은[D]혜');
      expect(
        [for (final m in marks) (m.start, m.end, m.kind)],
        [
          (0, 3, ChordMarkKind.chord),
          (5, 7, ChordMarkKind.escape),
          (11, 14, ChordMarkKind.chord),
        ],
      );
    });

    test('글자 위 자리: 새로 넣을 곳과 이미 있는 코드', () {
      const page = '[G]주 은[D/F#]혜\n놀라워';
      final first = chordSlotAt(page, 0, 0)!;
      expect(first.tokens.single.name, 'G');
      expect((first.tokens.single.start, first.tokens.single.end), (0, 3));
      final hye = chordSlotAt(page, 0, 3)!;
      expect(hye.tokens.single.name, 'D/F#');
      final eun = chordSlotAt(page, 0, 2)!;
      expect(eun.tokens, isEmpty);
      expect(page.substring(eun.insertAt, eun.insertAt + 1), '은');
      final ra = chordSlotAt(page, 1, 1)!;
      expect(page.substring(ra.insertAt, ra.insertAt + 1), '라');
      final end = chordSlotAt(page, 1, 3)!;
      expect(end.insertAt, page.length);
      expect(chordSlotAt(page, 5, 0), isNull);
    });

    test('넣은 결과를 strip 하면 가사가 그대로', () {
      const page = '주 은혜\n놀라워';
      final slot = chordSlotAt(page, 1, 2)!;
      final out = page.replaceRange(slot.insertAt, slot.insertAt, '[Em7]');
      expect(out, '주 은혜\n놀라[Em7]워');
      expect(stripChords(out), page);
    });

    test('코드만 있는 줄은 모든 코드가 한 자리', () {
      final slot = chordSlotAt('[G] [D]\n주님', 0, 0)!;
      expect(slot.tokens.map((t) => t.name), ['G', 'D']);
    });

    test('다이어토닉 7개', () {
      expect(diatonicChords('G'), ['G', 'Am', 'Bm', 'C', 'D', 'Em', 'F#m7b5']);
      expect(diatonicChords('F'), ['F', 'Gm', 'Am', 'Bb', 'C', 'Dm', 'Em7b5']);
      expect(diatonicChords('Em'), ['Em', 'F#m7b5', 'G', 'Am', 'Bm', 'C', 'D']);
      expect(diatonicChords('H'), isEmpty);
    });
  });

  group('copyChordsToPage (같은 코드 쓰는 페이지)', () {
    test('같은 가사면 같은 자리', () {
      const src = '[G]주 은[D/F#]혜\n[Em]놀라워[C]';
      expect(copyChordsToPage(src, '주 은혜\n놀라워'), src);
    });

    test('2절: 공백 뺀 몇 번째 글자로 자리를 잡는다', () {
      expect(
        copyChordsToPage('[G]주 은[D]혜 놀[C]라워', '나 같은 죄인'),
        '[G]나 같[D]은 죄[C]인',
      );
    });

    test('원래 코드는 바뀌고 가사는 그대로', () {
      expect(copyChordsToPage('[A]주 은혜', '[G]나 [D]같은'), '[A]나 같은');
    });

    test('넘치는 코드는 줄 끝, 줄 끝 코드는 줄 끝', () {
      expect(copyChordsToPage('주 은혜 놀[D]라[E]워', '나 같'), '나 같[D][E]');
      expect(copyChordsToPage('[G]주[C]', '나 같은'), '[G]나 같은[C]');
    });

    test('코드만 있는 줄은 다음 가사 줄 앞, 남는 줄은 코드 없이', () {
      expect(
        copyChordsToPage('[G] [D]\n[Em]주 은혜', '나 같은\n죄인\n살리신'),
        '[G] [D]\n[Em]나 같은\n죄인\n살리신',
      );
    });

    test('짝 없는 원본 줄의 코드는 버린다', () {
      expect(copyChordsToPage('[G]주\n[D]은혜', '나 같은'), '[G]나 같은');
    });

    test('가사의 대괄호는 이스케이프, strip 하면 가사 그대로', () {
      final r = copyChordsToPage('[G]주 은혜', r'나 \[G] 같은')!;
      expect(stripChords(r), '나 [G] 같은');
    });

    test('코드가 없으면 null', () {
      expect(copyChordsToPage('주 은혜', '나 같은'), isNull);
    });
  });
}
