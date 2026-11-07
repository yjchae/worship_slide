import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/praise_repository.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';

/// 코드 가사 저장 길(§3-4): saveChords 하나로만 쓰고, 가사만 고치는 길·전체 교체·다시 가져오기가
/// 코드를 지우지 않는다.
void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  late PraiseRepository repo;
  late int changes;

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('chord_repo_');
    addTearDown(() => dir.delete(recursive: true));
    db = await databaseFactoryFfi.openDatabase('${dir.path}/test.db');
    addTearDown(db.close);
    await createPraiseSchema(db);
    repo = PraiseRepository(database: PraiseDatabase.forTesting(db));
    changes = 0;
    repo.onSongsChanged = () => changes++;
  });

  PraiseSong song({String lyrics = '주 은혜\n\n놀라워', String title = '주 은혜'}) =>
      PraiseSong(
        id: null,
        fileName: 'grace.pptx',
        title: title,
        lyrics: lyrics,
        englishLyrics: '',
      );

  Future<Map<String, Object?>> row() async =>
      (await db.query('praise_songs')).single;

  Future<PraiseSong> stored() async => (await repo.searchSongs('')).single;

  test('코드만 저장 → DB 반영, 곡 시각은 그대로 (H2)', () async {
    await repo.insertSong(song());
    final before = await row();
    changes = 0;
    final id = before['id'] as int;

    await repo.saveChords(id, chordLyrics: '[G]주 은혜\n\n[D]놀라워', chordKey: 'G');
    final after = await row();
    expect(after['chord_lyrics'], '[G]주 은혜\n\n[D]놀라워');
    expect(after['chord_key'], 'G');
    expect(after['chord_updated_at'] as int, greaterThan(0));
    expect(after['updated_at'], before['updated_at']);
    expect(after['lyrics'], before['lyrics']);
    expect(changes, 1);

    final s = await stored();
    expect(s.chordLyrics, '[G]주 은혜\n\n[D]놀라워');
    expect(s.chordKey, 'G');
    expect((await repo.songsByIds([id]))[id]!.hasChords, isTrue);
  });

  test('바뀐 게 없으면 시각도 안 올리고, 빈 글은 null 로 지운다', () async {
    await repo.insertSong(song());
    final id = (await row())['id'] as int;
    await repo.saveChords(id, chordLyrics: '[G]주 은혜', chordKey: null);
    final t1 = (await row())['chord_updated_at'];
    changes = 0;
    await repo.saveChords(id, chordLyrics: '[G]주 은혜', chordKey: '');
    expect((await row())['chord_updated_at'], t1);
    expect(changes, 0);

    await repo.saveChords(id, chordLyrics: '', chordKey: null);
    final cleared = await row();
    expect(cleared['chord_lyrics'], isNull);
    // NULL 글 + 시각 > 0 = 지움(동기화가 전한다).
    expect(cleared['chord_updated_at'] as int, greaterThan(t1 as int));
  });

  test('코드 시각은 늘 옛 시각보다 늦다(시계가 앞선 PC 대비)', () async {
    await repo.insertSong(song());
    final id = (await row())['id'] as int;
    final future = DateTime.now().millisecondsSinceEpoch + 100000;
    await db.update('praise_songs', {'chord_updated_at': future});
    await repo.saveChords(id, chordLyrics: '[G]주', chordKey: null);
    expect((await row())['chord_updated_at'], future + 1);
  });

  test('가사만 저장 → 코드 그대로', () async {
    await repo.insertSong(song());
    final id = (await row())['id'] as int;
    await repo.saveChords(id, chordLyrics: '[G]주 은혜\n\n놀라워', chordKey: 'G');
    final s = await stored();
    await repo.updateSong(s.copyWith(lyrics: '주 은혜!\n\n놀라워'));
    final after = await row();
    expect(after['lyrics'], '주 은혜!\n\n놀라워');
    expect(after['chord_lyrics'], '[G]주 은혜\n\n놀라워');
    expect(after['chord_key'], 'G');
    // 어긋남은 읽을 때 보인다.
    final read = await stored();
    expect(read.pairedPages.first.chord, '');
  });

  test('전체 교체 뒤에도 같은 곡의 코드는 남는다', () async {
    await repo.insertSong(song());
    await repo.insertSong(song(title: '다른 곡', lyrics: '다른'));
    final rows = await db.query('praise_songs', orderBy: 'id');
    await repo.saveChords(
      rows[0]['id'] as int,
      chordLyrics: '[G]주 은혜\n\n놀라워',
      chordKey: 'G',
    );
    await repo.saveChords(
      rows[1]['id'] as int,
      chordLyrics: '[C]다른',
      chordKey: null,
    );
    final t = (await db.query(
      'praise_songs',
      orderBy: 'id',
    ))[0]['chord_updated_at'];

    await repo.replaceAllSongs([
      song(),
      song(title: '다른 곡', lyrics: '다른 가사로 바뀜'),
    ]);
    final after = {
      for (final r in await db.query('praise_songs')) r['title']: r,
    };
    expect(after['주 은혜']!['chord_lyrics'], '[G]주 은혜\n\n놀라워');
    expect(after['주 은혜']!['chord_key'], 'G');
    expect(after['주 은혜']!['chord_updated_at'], t);
    // 가사가 달라 uid 를 못 이어 쓰는 곡은 새 곡이다(코드 없음).
    expect(after['다른 곡']!['chord_lyrics'], isNull);
  });

  test('다시 가져오기(나누기만 바뀜): 확실하면 코드도 다시 맞춘다', () async {
    PraiseSong imported(String lyrics) => PraiseSong(
      id: null,
      fileName: 'a.pptx',
      title: '위대하신주',
      lyrics: lyrics,
      englishLyrics: 'How great is our God',
    );
    await repo.addNewSongs([imported('위대하신 주\n찬양해')]);
    final id = (await row())['id'] as int;
    await repo.saveChords(
      id,
      chordLyrics: '[G]위대하신 [D]주\n[C]찬양해',
      chordKey: 'G',
    );
    final t = (await row())['chord_updated_at'] as int;

    // 페이지 경계만 바뀜(§3-5 (a)).
    final result = await repo.addNewSongs([imported('위대하신 주\n\n찬양해')]);
    expect(result.updatedCount, 1);
    final after = await row();
    expect(after['lyrics'], '위대하신 주\n\n찬양해');
    expect(after['chord_lyrics'], '[G]위대하신 [D]주\n\n[C]찬양해');
    expect(after['chord_updated_at'] as int, greaterThan(t));
    expect((await stored()).pairedPages.map((p) => p.chord), [
      '[G]위대하신 [D]주',
      '[C]찬양해',
    ]);
  });

  test('다시 가져오기: 확실하지 않으면 코드를 그대로 둔다', () async {
    await repo.addNewSongs([
      const PraiseSong(
        id: null,
        fileName: 'a.pptx',
        title: '곡',
        lyrics: '가나',
        englishLyrics: 'Hello world',
      ),
    ]);
    final id = (await row())['id'] as int;
    await repo.saveChords(id, chordLyrics: '[G]가[D]나', chordKey: null);
    // 원본 줄 일부가 보조로 옮겨 감: 글자 모음은 같지만 코드가 붙은 줄이 없어진다.
    await repo.addNewSongs([
      const PraiseSong(
        id: null,
        fileName: 'a.pptx',
        title: '곡',
        lyrics: 'Hello world',
        englishLyrics: '가나',
      ),
    ]);
    final after = await row();
    expect(after['lyrics'], 'Hello world');
    expect(after['chord_lyrics'], '[G]가[D]나');
  });

  test('곡 모음: 코드가 실리고, 이미 있는 곡의 코드는 덮지 않는다 (M10)', () async {
    await repo.insertSong(song());
    final id = (await row())['id'] as int;
    await repo.saveChords(id, chordLyrics: '[G]주 은혜\n\n놀라워', chordKey: 'G');
    final bundle = await repo.exportSongBundle();
    final exported = (bundle['songs'] as List).single as Map;
    expect(exported['chord_lyrics'], '[G]주 은혜\n\n놀라워');
    expect(exported['chord_key'], 'G');

    // 다른 PC: 같은 곡이 이미 있고 코드가 다르다 → 그대로.
    final dir = await Directory.systemTemp.createTemp('chord_repo_other_');
    addTearDown(() => dir.delete(recursive: true));
    final other = await databaseFactoryFfi.openDatabase('${dir.path}/o.db');
    addTearDown(other.close);
    await createPraiseSchema(other);
    final otherRepo = PraiseRepository(
      database: PraiseDatabase.forTesting(other),
    );
    await otherRepo.insertSong(song());
    await otherRepo.insertSong(song(title: '코드 없던 곡', lyrics: '주 은혜\n\n놀라워'));
    final otherRows = await other.query('praise_songs', orderBy: 'id');
    await otherRepo.saveChords(
      otherRows[0]['id'] as int,
      chordLyrics: '[A]주 은혜\n\n놀라워',
      chordKey: 'A',
    );
    final result = await otherRepo.importSongBundle({
      ...bundle,
      'songs': [
        exported,
        {...exported, 'title': '코드 없던 곡'},
        {...exported, 'title': '새 곡'},
      ],
    });
    expect(result.addedCount, 1);
    expect(result.chordsAddedCount, 2);
    final byTitle = {
      for (final r in await other.query('praise_songs')) r['title']: r,
    };
    expect(byTitle['주 은혜']!['chord_lyrics'], '[A]주 은혜\n\n놀라워');
    expect(byTitle['코드 없던 곡']!['chord_lyrics'], '[G]주 은혜\n\n놀라워');
    expect(byTitle['새 곡']!['chord_lyrics'], '[G]주 은혜\n\n놀라워');
    expect(byTitle['새 곡']!['chord_key'], 'G');
  });
}
