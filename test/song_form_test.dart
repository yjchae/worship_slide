import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:worship_slides/src/features/praise/data/praise_database.dart';
import 'package:worship_slides/src/features/praise/data/praise_repository.dart';
import 'package:worship_slides/src/features/praise/data/worship_conti_repository.dart';
import 'package:worship_slides/src/features/praise/domain/page_format.dart';
import 'package:worship_slides/src/features/praise/domain/praise_song.dart';
import 'package:worship_slides/src/features/praise/domain/song_form.dart';
import 'package:worship_slides/src/features/praise/domain/staging_item.dart';
import 'package:worship_slides/src/features/praise/presentation/singer_view_data.dart';

/// 곡 송폼: 이름 표·짝짓기(숨김, 지우지 않음)·순서 줄·저장·콘티 스냅샷·.wsconti·칸 추가.
void main() {
  setUpAll(sqfliteFfiInit);

  String songFormKey(String t) => pageKey(t) ?? '';
  SectionLabel l(String code) => SectionLabel.parse(code)!;
  List<SectionLabel> ls(String text) => labelsFromText(text);

  group('라벨', () {
    test('약어·한글·저장 글 왕복', () {
      expect(l('V2').abbr, 'V2');
      expect(l('V2').korean, '벌스 2');
      expect(l('PC').korean, '프리코러스');
      expect(l('Intro').code, 'Intro');
      expect(SectionLabel.custom('  후렴, 반복  ')!.code, '=후렴 반복');
      expect(l('=후렴 반복').abbr, '후렴 반복');
      expect(SectionLabel.custom('가나다라마바사아자차카타파하')!.customText.length, 12);
    });

    test('모르는 글·번호가 안 되는 종류·범위 밖 번호는 버린다', () {
      for (final bad in ['', 'X', 'Intro1', 'V0', 'V100', 'c-1', '=']) {
        expect(SectionLabel.parse(bad), isNull, reason: bad);
      }
      expect(SectionLabel.custom('  '), isNull);
      expect(ls('V1,V1,zzz,C'), [l('V1'), l('C')]);
    });

    test('번호 자동: 벌스·브릿지는 최대+1, 코러스는 번호 없음', () {
      final pages = [ls('V1'), ls('C'), ls('V2,PC')];
      expect(autoLabel(SectionKind.verse, pages), l('V3'));
      expect(autoLabel(SectionKind.bridge, pages), l('B1'));
      expect(autoLabel(SectionKind.chorus, pages), l('C'));
      expect(autoLabel(SectionKind.intro, pages), l('Intro'));
    });

    test('mergeLabels: 이어 붙이고 중복은 뺀다', () {
      expect(mergeLabels(ls('V1,PC'), ls('PC,C')), ls('V1,PC,C'));
    });
  });

  group('짝짓기', () {
    const pages = ['1절', '후렴', '2절', '후렴'];
    SongForm form(List<(String, String)> e) => SongForm([
      for (final (k, v) in e) (key: songFormKey(k), labels: ls(v)),
    ]);

    test('같은 번호의 글이 같으면 보이고, 후렴 반복도 번호로 갈린다', () {
      final f = form([('1절', 'V1'), ('후렴', 'C'), ('2절', 'V2'), ('후렴', 'C,PC')]);
      final m = matchedForm(f, pages);
      expect(
        [for (final x in m.labels) labelsToText(x)],
        ['V1', 'C', 'V2', 'C,PC'],
      );
      expect(m.hidden, isEmpty);
    });

    test('한 페이지 글만 고치면 그 페이지만 숨고, 되돌리면 다시 보인다', () {
      final f = form([('1절', 'V1'), ('후렴', 'C'), ('2절', 'V2')]);
      final edited = ['1절', '후렴', '2절 고침'];
      final m = matchedForm(f, edited);
      expect([for (final x in m.labels) labelsToText(x)], ['V1', 'C', '']);
      expect(m.hidden.keys, [2]);
      expect(labelsToText(m.hidden[2]!), 'V2');
      expect(
        [
          for (final x in matchedForm(f, ['1절', '후렴', '2절']).labels)
            labelsToText(x),
        ],
        ['V1', 'C', 'V2'],
      );
    });

    test('페이지가 밀려도 같은 글을 따라간다(앞에 빈 페이지 끼움)', () {
      final f = form([('1절', 'V1'), ('후렴', 'C')]);
      final m = matchedForm(f, ['새 페이지', '1절', '후렴']);
      expect([for (final x in m.labels) labelsToText(x)], ['', 'V1', 'C']);
    });

    test('songFormForPages: 숨은 항목은 이어 두고 라벨 없으면 null', () {
      final f = form([('1절', 'V1'), ('2절', 'V2')]);
      // 2절을 고친 상태로 저장해도 V2 는 지워지지 않는다.
      final cur = [
        for (final (i, t) in ['1절', '2절 고침'].indexed)
          (
            korean: t,
            english: '',
            extra: '',
            chord: '',
            form: i == 0 ? 'V1' : '',
          ),
      ];
      final saved = songFormForPages(cur, previous: f)!;
      expect(saved.entries[1].labels, ls('V2'));
      expect(saved.entries[1].key, songFormKey('2절'));
      expect(
        [
          for (final x in matchedForm(saved, ['1절', '2절']).labels)
            labelsToText(x),
        ],
        ['V1', 'V2'],
      );
      expect(
        songFormForPages([
          (korean: 'a', english: '', extra: '', chord: '', form: ''),
        ]),
        isNull,
      );
    });
  });

  group('순서 줄', () {
    test('연속 중복은 ×n 으로 묶고 한 페이지 여러 라벨은 펼친다', () {
      final pages = [
        ls('Intro'),
        ls('V1,PC'),
        ls('C'),
        ls('C'),
        ls('V2,PC'),
        ls('C'),
        <SectionLabel>[],
        ls('Tag'),
      ];
      expect(formOrderText(pages), 'Intro·V1·PC·C ×2·V2·PC·C·Tag');
      expect(formOrderText(pages, separator: ' · '), contains('C ×2 · V2'));
      final steps = formOrder(pages);
      expect(steps[3].count, 2);
      expect(steps[3].firstPage, 2);
      expect(formOrderText(const []), '');
    });
  });

  group('JSON', () {
    test('왕복·깨진 항목은 빈 항목으로(번호 유지)·라벨 없으면 null', () {
      final f = SongForm([
        (key: 'a', labels: ls('V1,PC')),
        (key: 'b', labels: ls('C')),
      ]);
      expect(SongForm.parse(SongForm.encode(f)), f);
      expect(
        SongForm.encode(const SongForm([(key: 'a', labels: <SectionLabel>[])])),
        isNull,
      );
      final odd = SongForm.parse(
        '{"v":1,"pages":[{"k":"a","l":["V1"]},42,{"k":"c","l":["C","???"]}]}',
      )!;
      expect(odd.entries.length, 3);
      expect(odd.entries[1].labels, isEmpty);
      expect(odd.entries[2].labels, ls('C'));
      expect(SongForm.parse('{oops'), isNull);
      expect(SongForm.isBroken('{oops'), isTrue);
      expect(SongForm.isBroken(null), isFalse);
      expect(SongForm.isBroken(SongForm.encode(f)), isFalse);
    });
  });

  group('PraiseSong', () {
    test('pairedPages 에 라벨이 실리고, 글을 고친 페이지만 숨는다', () {
      final f = SongForm([
        (key: songFormKey('1절'), labels: ls('V1')),
        (key: songFormKey('2절'), labels: ls('V2,PC')),
      ]);
      final song = PraiseSong(
        id: 1,
        fileName: '',
        title: '곡',
        lyrics: '1절\n\n2절',
        englishLyrics: 'one',
        songForm: f,
      );
      expect([for (final x in song.pairedPages) x.form], ['V1', 'V2,PC']);
      expect(song.pairedPages.last.labels, ls('V2,PC'));
      final edited = song.copyWith(lyrics: '1절\n\n2절 고침');
      expect([for (final x in edited.pairedPages) x.form], ['V1', '']);
      expect(edited.songForm, f); // 지우지 않는다.
      expect(song.copyWith(songForm: null).songForm, isNull);
    });
  });

  group('저장·스냅샷', () {
    Future<Database> freshDatabase() async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(db.close);
      await createPraiseSchema(db);
      return db;
    }

    PraiseSong song({String lyrics = '1절\n\n2절', SongForm? form}) => PraiseSong(
      id: null,
      fileName: 'a.pptx',
      title: '곡',
      lyrics: lyrics,
      englishLyrics: '',
      songForm: form,
    );
    final form = SongForm([
      (key: songFormKey('1절'), labels: ls('V1')),
      (key: songFormKey('2절'), labels: ls('V2,PC')),
    ]);

    test('saveSongForm: 송폼 시각만 올리고 곡·가사 저장 길은 송폼을 안 덮는다', () async {
      final db = await freshDatabase();
      final repo = PraiseRepository(database: PraiseDatabase.forTesting(db));
      var changes = 0;
      repo.onSongsChanged = () => changes++;
      final id = await repo.insertSong(song());
      changes = 0;
      final before = (await db.query('praise_songs')).single;
      expect(before['song_form'], isNull);

      await repo.saveSongForm(id, form);
      var row = (await db.query('praise_songs')).single;
      expect(row['song_form'], SongForm.encode(form));
      expect(row['song_form_updated_at'] as int, greaterThan(0));
      expect(row['updated_at'], before['updated_at']);
      expect(changes, 1);
      expect((await repo.songsByIds([id]))[id]!.songForm, form);

      // 같은 값이면 시각·알림 그대로.
      final t = row['song_form_updated_at'];
      await repo.saveSongForm(id, form);
      expect(
        (await db.query('praise_songs')).single['song_form_updated_at'],
        t,
      );
      expect(changes, 1);

      // 가사만 고치는 길은 송폼을 건드리지 않는다.
      final stored = (await repo.songsByIds([id]))[id]!;
      await repo.updateSong(stored.copyWith(lyrics: '1절\n\n2절 고침'));
      row = (await db.query('praise_songs')).single;
      expect(row['song_form'], SongForm.encode(form));

      await repo.saveSongForm(id, null);
      row = (await db.query('praise_songs')).single;
      expect(row['song_form'], isNull);
      expect(row['song_form_updated_at'] as int, greaterThan(t as int));
    });

    test('replaceAllSongs: 같은 곡이면 송폼을 옮겨 준다', () async {
      final db = await freshDatabase();
      final repo = PraiseRepository(database: PraiseDatabase.forTesting(db));
      final id = await repo.insertSong(song());
      await repo.saveSongForm(id, form);
      await repo.replaceAllSongs([song()]);
      final got = (await repo.searchSongs('')).single;
      expect(got.songForm, form);
    });

    test('콘티: 저장·불러오기에 라벨이 남고 라이브러리 곡을 고쳐도 영향 없다', () async {
      final db = await freshDatabase();
      final repo = PraiseRepository(database: PraiseDatabase.forTesting(db));
      final contis = WorshipContiRepository(
        database: PraiseDatabase.forTesting(db),
        supportDirectory: () async => Directory.systemTemp,
      );
      final id = await repo.insertSong(song());
      await repo.saveSongForm(id, form);
      final lib = (await repo.songsByIds([id]))[id]!;
      final cid = await contis.saveConti('주일', [
        (uid: 1, item: SongStagingItem(lib)),
        // 나눈(일부 담은) 곡: 두 번째 페이지만.
        (
          uid: 2,
          item: SongStagingItem(
            lib.copyWith(
              lyrics: '2절',
              songForm: songFormForPages([lib.pairedPages[1]]),
            ),
          ),
        ),
      ]);
      await repo.saveSongForm(id, null); // 라이브러리에서 지워도
      final loaded = await contis.loadConti(cid, 1);
      final a = (loaded.items[0].item as SongStagingItem).song;
      final b = (loaded.items[1].item as SongStagingItem).song;
      expect([for (final x in a.pairedPages) x.form], ['V1', 'V2,PC']);
      expect([for (final x in b.pairedPages) x.form], ['V2,PC']);
    });

    test('.wsconti 왕복: 라벨이 옮겨지고 이상한 값은 버리며 옛 파일은 라벨 없이 열린다', () async {
      final tmp = await Directory.systemTemp.createTemp('form_conti_');
      addTearDown(() => tmp.delete(recursive: true));
      WorshipContiRepository on(Database db) => WorshipContiRepository(
        database: PraiseDatabase.forTesting(db),
        supportDirectory: () async => Directory.systemTemp,
      );
      final source = on(await freshDatabase());
      final cid = await source.saveConti('주일', [
        (uid: 1, item: SongStagingItem(song(form: form))),
      ]);
      final file = p.join(tmp.path, 'a.wsconti');
      await source.exportContiFile(cid, file);
      final json = jsonDecode(File(file).readAsStringSync()) as Map;
      final item = (json['items'] as List).single as Map;
      expect(item['song_form'], SongForm.encode(form));

      final target = on(await freshDatabase());
      final got = await target.importContiFile(
        file,
        filesDir: Directory(p.join(tmp.path, 'i1')),
      );
      expect(
        ((await target.loadConti(got, 1)).items.single.item as SongStagingItem)
            .song
            .songForm,
        form,
      );

      item['song_form'] = '{"v":1,"pages":[{"k":"x","l":["V1","ZZ"]}]}';
      File(p.join(tmp.path, 'bad.wsconti')).writeAsStringSync(jsonEncode(json));
      final bad = await target.importContiFile(
        p.join(tmp.path, 'bad.wsconti'),
        filesDir: Directory(p.join(tmp.path, 'i2')),
      );
      final badSong =
          ((await target.loadConti(bad, 1)).items.single.item
                  as SongStagingItem)
              .song;
      expect(badSong.songForm!.entries.single.labels, ls('V1'));

      item.remove('song_form');
      File(p.join(tmp.path, 'old.wsconti')).writeAsStringSync(jsonEncode(json));
      final old = await target.importContiFile(
        p.join(tmp.path, 'old.wsconti'),
        filesDir: Directory(p.join(tmp.path, 'i3')),
      );
      expect(
        ((await target.loadConti(old, 1)).items.single.item as SongStagingItem)
            .song
            .songForm,
        isNull,
      );
    });
  });

  test('ensureSongFormColumns: 칸이 없는 옛 DB 에 더하고 두 번 불러도 안전하다', () async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(db.close);
    await db.execute(
      'CREATE TABLE praise_songs (id INTEGER PRIMARY KEY, title TEXT)',
    );
    await db.execute(
      'CREATE TABLE worship_conti_items (id INTEGER PRIMARY KEY)',
    );
    await ensureSongFormColumns(db);
    await ensureSongFormColumns(db);
    final songCols = {
      for (final c in await db.rawQuery('PRAGMA table_info(praise_songs)'))
        c['name'],
    };
    final itemCols = {
      for (final c in await db.rawQuery(
        'PRAGMA table_info(worship_conti_items)',
      ))
        c['name'],
    };
    expect(songCols, containsAll(['song_form', 'song_form_updated_at']));
    expect(itemCols, contains('song_form'));
    expect(PraiseDatabase.schemaVersion, 20);
  });

  test('SingerPage JSON: form 키는 라벨이 있을 때만', () {
    const empty = SingerPage(mainText: 'a');
    expect(empty.toJson().containsKey('form'), isFalse);
    const page = SingerPage(mainText: 'a', formLabels: ['V2', 'PC']);
    expect(page.toJson()['form'], ['V2', 'PC']);
  });
}
