# 코드(기타 코드) 붙은 가사 — 백엔드 기술 검토

작성: 백엔드 · 2026-11-06 · 대상 코드: DB version 19 기준
범위: DB·저장 정합성·찬양 동기화·`.wsconti`/클라우드 콘티·Python ppt_tool·테스트. 화면(편집기·싱어 렌더링)은 다루지 않는다.
앱 코드는 이 문서에서 고치지 않았다. "미확인"은 이 리눅스 환경에서 실행·확인하지 못한 것이다.

---

## 0. 결론 요약

| 항목 | 제안 |
|---|---|
| 곡 저장 | `praise_songs` 에 칸 둘: `chord_lyrics TEXT`(ChordPro 인라인, NULL = 코드 없음) + `chord_updated_at INTEGER NOT NULL DEFAULT 0` |
| 정합성 기준 | `stripChords(chord_lyrics) == lyrics` 일 때만 "맞는 코드". 틀리면 지우지 않고 **어긋남(stale)** 으로 두고 화면에서 다시 맞추게 한다 |
| 동기화 | `SyncSong` 에 싣지 않고 스냅샷에 **별도 구역 `chords`**(곡 uid 별, 자기 시각)로 싣는다. 곡 `updated_at` 을 올리지 않는다 → 옛 앱 PC 가 코드를 지울 길이 없다 |
| 내용 해시·같은 곡 합치기 | 코드는 **넣지 않는다**(`contentKey`·`content_hash`·`tieKey` 그대로) |
| 콘티 스냅샷 | `worship_conti_items.song_chord_lyrics TEXT`, `song_transpose INTEGER`(반음, NULL/0 = 그대로) |
| 마이그레이션 | v20 = 위 4칸 `_addColumnIfMissing`. 데이터 변환 없음 |
| PPTX | Dart `exportPresentation` 이 `song.lyrics` 만 보내므로 지금 구조 그대로면 코드가 안 섞인다. 새 필드를 payload 에 **넣지 않는 것**이 규칙 |
| 악보 OCR | 1차 범위 밖. 글자 박힌 PDF 는 코드 위치 복원이 중간 난이도, 그림 악보 OCR 은 어려움 |

---

## 1. DB (`lib/src/features/praise/data/praise_database.dart`)

### 1.1 새 칸

```sql
-- praise_songs
chord_lyrics      TEXT                       -- NULL = 코드 없음. '' 는 쓰지 않는다(지움 = NULL)
chord_updated_at  INTEGER NOT NULL DEFAULT 0 -- 코드만의 고친 시각(ms). 동기화용

-- worship_conti_items (곡 항목 스냅샷)
song_chord_lyrics TEXT     -- 담을 때의 코드 가사 스냅샷 (song_lyrics 와 짝)
song_transpose    INTEGER  -- 반음 이동(-11~+11). NULL/0 = 원래 조
```

- `createPraiseSchema` 의 `CREATE TABLE` 두 곳에 칸 추가.
- `PraiseDatabase.schemaVersion = 20`, `upgradePraiseSchema` 에
  ```dart
  if (oldVersion < 20) {
    await _addColumnIfMissing(db, 'praise_songs', 'chord_lyrics', 'ALTER TABLE praise_songs ADD COLUMN chord_lyrics TEXT');
    await _addColumnIfMissing(db, 'praise_songs', 'chord_updated_at', 'ALTER TABLE praise_songs ADD COLUMN chord_updated_at INTEGER NOT NULL DEFAULT 0');
    for (final c in ['song_chord_lyrics']) ... 'ALTER TABLE worship_conti_items ADD COLUMN $c TEXT'
    await _addColumnIfMissing(db, 'worship_conti_items', 'song_transpose', '... INTEGER');
  }
  ```
  모두 ADD COLUMN 뿐이라 기존 행·인덱스에 손대지 않는다. 데이터 굳히기(v19 `freezeContiSongSnapshots` 같은 것)는 필요 없다 — 옛 콘티 행은 코드 칸이 NULL = "코드 없음"이고, 불러올 때 라이브러리 곡의 코드를 따라가지 않는다(v19 의 '스냅샷 우선' 원칙과 같게).

### 1.2 자동 백업(`backupBeforeUpgrade`) 영향

- v19 DB 를 처음 여는 순간 `worship_slides.db.v19.bak` 가 생긴다. 기존 로직 그대로라 추가 작업 없음. `test/db_backup_test.dart` 는 `schemaVersion` 상수를 쓰는지 숫자를 박았는지만 확인하면 된다(미확인 — 숫자를 박았으면 고친다).
- **내려가기(옛 앱으로 되돌림)**: 옛 앱(version 19)이 v20 DB 를 열면 sqflite 가 `onDowngrade` 가 없을 때 어떻게 하는지 **미확인**(로컬 pub 캐시 없음). 우리가 아는 sqflite_common 동작은 "콜백 없이 user_version 만 19 로 내린다"(추정). 그렇다면
  - 칸은 남고 옛 앱은 모른다 → 옛 앱에서 가사를 고치면 `chord_lyrics` 는 그대로라 **어긋남** 상태가 된다(2장의 검사가 잡는다).
  - 옛 앱에서 '전체 교체'(`replaceAllSongs`)를 하면 행을 지우고 다시 넣어 코드가 **사라진다**.
  - 다시 새 앱으로 올리면 `oldVersion < 20` 단계가 또 돌지만 `_addColumnIfMissing` 이라 안전하다. 이때 `v19.bak` 는 이미 있어서 새로 안 만든다(첫 사본 우선 규칙) — 의도대로다.

### 1.3 대안: 별도 테이블 `song_chords(song_uid PK, chord_lyrics, updated_at)`

| | 칸 추가(제안) | 별도 테이블 |
|---|---|---|
| 곡 삭제와 함께 사라짐 | 저절로 | 지울 때마다 같이 지워야 함(`deleteSongsByIds`·`clearAllSongs`·동기화 삭제 3곳) |
| `replaceAllSongs`(전체 삭제 후 재삽입) | 재사용 uid 에 칸을 옮겨 줘야 함 | uid 를 재사용하면 저절로 남음(장점) |
| uid 합치기(`_renameUid`, `_canonicalLocalRows` 중복 정리) | 행이 움직이니 저절로 따라감. 단 중복 정리에서 진 쪽의 코드는 살려야 함 | uid 를 바꿀 때마다 테이블도 고쳐야 함(놓치기 쉬움) |
| 옛 앱 내려가기 | 칸이 남음(어긋남 위험) | 테이블이 남음(옛 앱이 전혀 안 건드림 — 조금 더 안전) |
| 조회 | `PraiseSong.fromMap` 한 번 | JOIN 또는 두 번 읽기 |

키가 **제목**인 `song_translations` 와 달리 코드는 "그 곡의 그 가사"에 붙은 정보라 곡 행에 붙이는 편이 맞다. 별도 테이블의 장점(전체 교체에서 살아남음)은 `replaceAllSongs` 에 몇 줄 더해 얻을 수 있다(2.3). **칸 추가를 권한다.**

### 1.4 도메인(`domain/praise_song.dart`)

- `PraiseSong.chordLyrics`(String?, 기본 null) + `copyWith`. `toMap()` 에는 **넣지 않는다** — `updateSong`·`_newSongRow` 가 `toMap()` 을 통째로 쓰므로, 넣으면 코드를 모르는 경로(가사만 고침)가 칸을 NULL 로 덮는다. 코드는 전용 메서드 `PraiseRepository.saveChords(id, chordLyrics)` 로만 쓴다.
- `fromMap` 은 `chord_lyrics` 를 읽는다.
- 순수 함수(새 파일 `domain/chord_lyrics.dart` 권장):
  - `stripChords(String) → String` : `\[[^\]\n]*\]` 제거. 줄·빈 줄 구조는 그대로.
  - `chordsMatch(chord, lyrics) → bool` : `stripChords(chord) == lyrics` (공백 정규화는 하지 않는다 — 페이지 구분이 `\n\n` 이라 공백이 뜻을 가진다. 다만 줄 끝 공백 차이 정도는 허용할지 화면 담당과 정할 것).
  - `chordPages(chord) → List<String>` : `_parsePages` 와 같은 규칙으로 나눈다. `stripChords` 후 페이지 수가 `pages` 와 같아야 페이지별로 짝지을 수 있다.
  - `transposeChords(chord, semitones, {preferFlat})` : 뿌리음과 `/` 뒤 베이스음만 옮긴다(`m7`·`sus4`·`add9` 는 그대로).
  - **규칙: 코드만 있는 줄 금지**. `[G] [D]` 만 있는 줄은 strip 하면 빈 줄 → 페이지 구분자(`\n\n`)로 읽혀 페이지가 어긋난다. 전주·간주 코드는 그 페이지 첫 줄 앞에 붙이거나(`[G][D]주 은혜`) 저장할 때 막는다.

---

## 2. 저장 정합성 — 원본 가사가 바뀌는 경로

원본 `lyrics` 를 바꾸는 곳은 아래가 전부다(코드로 확인):

| 경로 | 위치 | 지금 동작 | 코드 처리 제안 |
|---|---|---|---|
| 곡 수정 | `PraiseRepository.updateSong` | `toMap()` 으로 덮음, 바뀐 게 없으면 시각 안 올림 | 코드 칸은 안 건드림(1.4). 저장 뒤 `chordsMatch` 가 거짓이면 **자동 재정렬 시도**(2.2) → 성공하면 같이 저장, 실패하면 그대로 두고 어긋남 표시 |
| 전체 교체 | `replaceAllSongs` | 모두 지우고 다시 넣음, `contentKey` 가 같으면 uid·시각 재사용 | `old` 쿼리에 `chord_lyrics, chord_updated_at` 추가, 재사용(`kept`)할 때 두 칸도 옮긴다. 가사가 달라져 uid 를 못 쓰는 곡의 코드는 **사라진다** — 실행 전 "코드가 있는 곡 N개의 코드가 지워진다" 수를 세어 알리길 권함 |
| 폴더 다시 가져오기 | `addNewSongs` | ① 똑같으면 건너뜀 ② 줄 모음이 같으면(나누기 규칙만 바뀜) 기존 곡 `lyrics`·`english_lyrics` 갱신 ③ 새 곡 | ②에서 원본 줄이 보조 칸으로 옮겨 가는 경우가 있다 → 재정렬 시도, 실패면 어긋남 |
| 동기화 합치기 | `SongSyncRepository._applySong` | `_rowOf(song)` 로 덮음 | `_rowOf` 에 코드 칸을 넣지 않으므로 코드는 남는다. 다른 PC 에서 가사가 바뀌어 오면 이 PC 코드가 어긋남 → 3장 |
| 곡 모음 가져오기 | `importSongBundle` | 같은 제목은 새로 안 넣고 빈 보조만 채움 | 새로 넣는 곡에만 `chord_lyrics` 를 받는다(내보내기 `exportSongBundle` 에도 싣는다). 이미 있는 곡의 코드는 덮지 않음(기존 규칙과 같음) |
| 수정 후 콘티 반영 | `_offerStagedSongUpdate` (praise_home_page.dart) | 곡 전체를 담은 항목이 있으면 '콘티도 바꿀까요' | 바꿀 때 `chordLyrics` 도 새 값으로. 조 바꾸기 값(`transpose`)은 항목 것이라 유지 |

### 2.1 어긋남(stale) 원칙

- **지우지 않는다.** 어긋난 코드는 DB 에 남기고, 싱어·발표자 화면은 코드 없이 원본 가사만 그린다(틀린 자리에 코드가 보이는 게 더 나쁘다). 편집 화면은 "가사가 바뀌어 코드를 다시 맞춰야 한다" + 재정렬 미리보기.
- 판정은 읽을 때마다 `chordsMatch` 로 한다(칸에 상태를 따로 저장하지 않는다 — 저장해 두면 동기화·옛 앱이 바꾼 가사와 또 어긋난다).

### 2.2 자동 재정렬 가능성

`stripChords(old chord)` = 옛 가사 A, 새 가사 B. 코드는 A 의 글자 위치(오프셋)에 붙어 있다.

1. 페이지·줄 단위로 A↔B 를 맞춘다(줄 LCS). 똑같은 줄은 코드 그대로.
2. 바뀐 줄은 글자 단위 diff(Myers)로 A 오프셋 → B 오프셋을 옮긴다. 지워진 글자에 붙은 코드는 다음 남은 글자로.
3. 줄이 통째로 새로 생기면 코드 없음, 지워진 줄의 코드는 버린다.

오타 고치기·한 줄 추가·페이지 나누기 변경(빈 줄 넣기/빼기)은 거의 맞는다. 줄을 크게 다시 쓰면 틀린 자리에 붙을 수 있으므로 **자동 저장은 "줄이 모두 같고 페이지 구분만 바뀐 경우"와 "바뀐 글자가 전체의 일정 비율 이하"로 제한**하고, 그 밖은 제안만 하고 사람이 확인하게 하자. Dart 순수 함수라 단위 테스트가 쉽다(예상 150~250줄).

### 2.3 시각 규칙

- 코드를 고치면 `chord_updated_at = _after(old chord_updated_at, now)` 만 올린다. **곡 `updated_at` 은 안 올린다**(이유는 3장).
- 가사만 고치면 `updated_at` 만 오른다(지금 그대로). 재정렬로 코드도 바꿨으면 `chord_updated_at` 도 올린다.

---

## 3. 찬양 동기화 (`sync_snapshot.dart`, `song_sync_repository.dart`, `sync_service.dart`)

### 3.1 `SyncSong` 에 필드를 넣으면 생기는 문제

옛 앱의 `SyncSong.fromJson` 은 모르는 키를 버리고, 자기 파일을 쓸 때 `_songFromRow` 로 다시 만들므로 **코드 없는 같은 판**을 올린다. 곡 `updated_at` 하나로 코드까지 다루면:

1. 새 앱 A 가 코드를 넣음(곡 시각 T2) → 옛 앱 B 가 받아 자기 파일에 **T2, 코드 없음**으로 씀.
2. 새 앱 C 가 합칠 때 A 판과 B 판이 같은 시각 → `winsOver` 는 `tieKey`(내용+파일 이름)로 가른다. 코드를 `tieKey` 에 안 넣으면 둘이 같아 **먼저 읽은 파일이 남는다** → 순서에 따라 C 가 코드를 못 받는다. 넣으면 B 판(코드 없음)이 이길 수도 있다.
3. B 에서 가사를 고치면(T3) B 판이 이겨 `_applySong` 이 코드를 덮는다(빈 값으로 덮게 짜면 **코드 삭제**, 그대로 두게 짜면 어긋남).
4. 새 앱끼리만 써도 "코드만 고침" 때문에 곡 시각이 올라가, 다른 PC 에서 같은 때 가사를 고친 것을 이겨 버린다(가사 수정 유실).

### 3.2 제안: 스냅샷에 별도 구역 `chords`

```json
"chords": [ {"uid": "<곡 uid>", "chord_lyrics": "[G]주 은[D/F#]혜...", "updated_at": 1730000000000} ],
"chord_deleted": { "<곡 uid>": 1730000000500 }   // 선택 — 아래 참고
```

- `SyncSnapshot` 에 `chords: List<SyncChord>` 추가, `toJson`/`fromJson`(모양 틀리면 버림 — 기존 `_str`/`_int` 방식). `format`·`version: 1` 은 그대로 둔다(옛 앱은 `format` 만 본다, 모르는 키는 무시 → 깨지지 않음).
- 합치기 `_mergeChords(txn, remotes, canonical)` 를 `_mergeIn` 의 `_mergeSongs` **뒤**에 둔다(곡 uid 합치기·추가가 끝난 다음). 규칙은 `_mergeTranslations` 와 같다:
  - 키 = `canonical(uid)`(aliases 를 따라감). 같은 키 중 `updated_at` 큰 쪽, 같으면 문자열 비교(어느 PC 든 같은 답).
  - 이 PC 에 그 곡이 없으면 버린다(곡이 지워졌거나 아직 안 옴).
  - 이 PC 값보다 새로우면 `chord_lyrics`·`chord_updated_at` 만 UPDATE.
- **지움**: 별도 지운 기록 대신 `chord_lyrics: null` + 시각을 그대로 싣는 방식(tombstone 을 같은 레코드에)을 권한다. 곡 행이 있는 동안만 의미가 있고 곡이 지워지면 함께 사라지므로 테이블이 필요 없다. 그러려면 DB 도 "지운 시각"을 기억해야 한다 → `chord_lyrics = NULL, chord_updated_at > 0` 을 "지움"으로 본다. `exportSnapshot` 은 `chord_updated_at > 0` 인 곡만 싣는다.
- **옛 앱이 섞이면**: 옛 PC 파일엔 `chords` 가 없다 → 합칠 때 그 PC 는 코드에 대해 아무 말도 안 한 것. 옛 PC 가 가사를 고쳐도 코드 레코드는 그대로라 새 앱에선 **어긋남**(2.1)으로 보이고 지워지지 않는다. 옛 PC 를 거쳐 다른 새 앱으로 전파되지는 않는다(옛 PC 가 중계하지 않음) — 새 앱 PC 끼리는 자기 파일로 서로 받는다. 이것으로 충분하다.
- `SyncService._songKeys`(내 파일이 최신인지 비교하는 키 목록, sync_service.dart 약 552행)에 `'chords'` 를 더해야 '안 올린 수정'이 잡힌다. `hasLocalChanges`/`onSongsChanged` 는 `saveChords` 에서도 부른다.

### 3.3 uid 합치기·중복 정리와의 관계

- `_renameUid`(같은 곡 따로 가져옴 → 작은 uid 로): 행이 그대로 uid 만 바뀌므로 코드 칸이 따라간다. 다른 PC 에서 옛 uid 로 온 `chords` 레코드는 `canonical` 로 맞춰진다.
- `_canonicalLocalRows` 에서 내용이 같은 중복 행을 지울 때 **진 행에 코드가 있고 이긴 행엔 없으면 코드가 사라진다** → 지우기 전에 `chord_updated_at` 이 큰 쪽 코드를 남는 행으로 옮긴다(몇 줄).
- 따로 고쳐 가사가 달라져 새 uid 를 받는 경우(`fresh`): 그 행의 코드는 그대로 따라간다. 문제 없음.

### 3.4 content_hash · 같은 곡 판정에 코드를 넣을까 — **넣지 않는다**

- `SyncSong.contentKey` 는 같은 곡 합치기(`byContent`), 지운 기록 `content_hash`(`_ContentTombstones`), `replaceAllSongs` 의 uid 재사용, `tieKey` 에 모두 쓰인다. 코드를 넣으면
  - 한 PC 만 코드를 단 같은 곡이 "다른 곡"이 되어 **중복 곡**이 생긴다.
  - 옛 버전이 남긴 `content_hash` 와 새 해시가 안 맞아 "동기화를 켜기 전에 지운 곡"이 되살아난다.
- 코드는 곡의 정체가 아니라 덧붙인 정보로 본다. 같은 곡으로 합쳐질 때 코드는 3.2 규칙(나중 것)으로 고른다.
- `SongSyncRepository.preview`(켤 때 확인)는 같은 `_mergeIn` 을 도므로 코드 변경도 "바뀐 찬양" 수에 들어간다. 세는 방법(곡 수로 셀지 따로 셀지)은 화면 담당과 정할 것.

---

## 4. `.wsconti` · 클라우드 콘티 (`worship_conti_repository.dart`)

- **저장** `saveConti`: 곡 행 맵(약 148~160행)에 `'song_chord_lyrics': item.song.chordLyrics`, `'song_transpose': item.transpose` 추가. 조 바꾸기는 항목(콘티 위치)의 값이므로 `SongStagingItem` 에 `transpose` 필드(또는 `_slideNotes` 처럼 uid → 값 맵)를 둔다. 같은 곡을 콘티에 두 번 담고 조를 다르게 할 수 있어야 하므로 **항목 단위**가 맞다.
- **불러오기** `loadConti`(약 270~300행): `song_chord_lyrics` 를 스냅샷으로 읽어 `PraiseSong(chordLyrics:)` 에 넣는다. `storedLyrics == null`(아주 옛 행)이고 라이브러리 곡(`baseSong`)을 쓰는 경로에서만 곡의 지금 코드를 따른다(v19 이후엔 거의 없음).
- **내보내기** `exportContiFile`: `SELECT wci.*` 라 새 칸이 **저절로 실린다**. `portableItemRow` 의 "빈 스냅샷은 지금 곡으로 채움"(`cur_` 칸) 목록에 `song_chord_lyrics ??= cur_chord_lyrics` 를 더할지 결정 — 옛 콘티 행(코드 칸 NULL)을 보낼 때 지금 곡 코드를 실으면 받는 쪽에서 가사 스냅샷과 코드가 어긋날 수 있다. **넣지 않기**를 권한다(NULL = 코드 없음, 스냅샷 원칙). 넣는다면 `chordsMatch(cur_chord, song_lyrics)` 가 참일 때만.
- **가져오기** `_insertImported`: `receivableItemColumns`(PRAGMA)로 받을 칸을 정하므로 새 앱은 저절로 받는다. 값 모양 검사(글자·숫자·null 만)도 그대로 통과한다. `song_transpose` 는 정수 범위(-11~11)를 넘으면 버리는 검사를 하나 더 두자(남이 만든 파일).
- **옛 앱이 받을 때**: 옛 앱의 `receivableItemColumns` 에 없는 칸이라 **조용히 버린다** → 가사는 정상, 코드·조만 빠진다. 깨지지 않는다. 옛 앱이 그 콘티를 다시 올리면 클라우드 판에서 코드가 빠진다(같은 uid 덮어쓰기) — 막을 방법은 없다. 알려 둘 위험(7장).
- 클라우드 콘티는 `.wsconti` 와 같은 파일이므로 추가 작업 없음. 목록 정보 파일(`conti_<uid>.json`)은 손댈 것 없음.

---

## 5. Python ppt_tool

### 5.1 PPTX 내보내기에 코드가 섞이는가 — 지금 구조면 **안 섞인다**

- Dart `PythonBridge.exportPresentation`(python_bridge.dart 310~360행)이 곡마다 `title`·`lyrics`·`english_lyrics`·`extra_lyrics` 만 보낸다. Python `export_presentation`(ppt_tool.py 1988행~)·`add_song_slides` 는 `lyrics` 를 `\n\n` 으로 나눠 그대로 쓴다.
- 위험은 Dart 쪽에서 "코드 붙은 가사"를 `song.lyrics` 자리에 넣어 버리는 실수뿐이다. 규칙: **`PraiseSong.lyrics` 에는 절대 ChordPro 를 넣지 않는다**, 코드는 늘 `chordLyrics` 에만. 관객 화면(`SlidePageData`)·통역(B)·PPTX 가 모두 `lyrics` 를 읽으니 이 하나로 막힌다.
- 막는 장치: Python `test_export_text.py` 에 "payload 에 `chord_lyrics` 키가 와도 무시한다", Dart 쪽 `exportPresentation` payload 에 `[` 가 든 가사가 없다는 테스트(아래 6장).
- 휴대폰 싱어/리모컨(`_buildSingerViewData`)은 지금 "원본만"을 보내는데, 코드는 여기에 **새 키**(`chords`, 페이지별 ChordPro + transpose 적용 후)로 얹는다 — 관객 화면 JSON(`SlidePageData.toJson`)에는 싣지 않는다. 화면 담당 범위.

### 5.2 악보 OCR(`sheet`)이 지금 코드 줄을 버리는 곳

| 위치 | 하는 일 |
|---|---|
| `lyric_line_boxes_by_system`(2314행) | 오선 사이 띠에서 **끝에서부터** 아래 단에 더 붙은 덩어리(그 단의 코드 줄)를 `groups.pop()` 으로 걷어 냄. 기하 단계에서 이미 잘라 OCR 에 안 넘긴다 |
| `erase_staff_symbols`(2916행) | 음표·기둥을 지움(코드 글자는 남음) |
| `is_chord_line`(2453행) | 띠에 섞여 들어온 코드 줄 판별(`_CHORD_TOKEN_RE`·`_LOOSE_CHORD_TOKEN_RE`, `CG’DmCFCG’C` 같은 뭉갠 줄도) |
| `_finish_line`(2743행) | 코드 줄이면 `_CHORD_LINE` |
| `resolve_sheet_lines`(3127행) | `_CHORD_LINE`·`_SECTION_LINE` 을 뺀다 |
| 오선 없는 쪽(`_native_page_lines` 3248행 등) | 코드 줄은 `is_chord_line` 으로 빠지고 괄호 안 연주 메모도 지움 |

### 5.3 2차: 코드를 가사 위치에 살려 가져오기 — 난이도

| 악보 종류 | 방법 | 난이도 |
|---|---|---|
| 글자 박힌 PDF(악보 프로그램 출력) | PyMuPDF `get_text("words")` 에 x 좌표가 있다(`_words_to_system_lines`). 지금 버리는 코드 띠의 낱말도 좌표와 함께 꺼내, 그 아래 단 1절 가사 줄의 **글자 x 위치**(낱말 상자를 글자 수로 나눠 근사)에 가장 가까운 음절 앞에 `[G]` 삽입. 2절 이상은 같은 x 로 복사 | **중간** (300~500줄 + 테스트). 하이픈 지우기·`join_single_syllables` 가 글자 위치를 바꾸므로 원문 오프셋을 끝까지 들고 가야 한다 |
| 그림 악보 + OS OCR | Vision·Windows OCR 이 덩어리 x 좌표는 준다(`_native_line_text`). 코드 띠 이미지를 따로 잘라 읽어야 하고(지금은 잘라 내지도 않음), 코드 글자는 작고 위첨자·♭·♯ 오인식이 많다(`Bo`=B♭) | **어려움** — 위치 정확도 미확인. Swift·C++ OCR 채널 응답 형식은 이미 x·w 를 준다 |
| 그림 악보 + Tesseract | TSV 출력에 낱말 상자가 있어 같은 방식은 가능. 정확도는 가사보다 더 낮을 것(미확인) | **어려움** |
| 오선 없는 "코드 위 가사" 시트(찬양팀 흔한 형식) | 코드 줄 바로 아래 가사 줄을 x 로 짝지음. 고정폭이 아니라 글자 폭 추정 필요 | 중간~어려움 |

권장: 1차 출시는 손 입력(ChordPro 붙여 넣기)만. 2차에 "글자 박힌 PDF" 만 먼저. 출력 계약은 지금 `{lyrics, lines,...}` 에 `chord_lyrics`(같은 줄 구조의 ChordPro, 실패면 키 없음)를 더하는 식으로 하면 Dart 쪽 변경이 작다. `stripChords(chord_lyrics) == lyrics` 를 Python 테스트에서 늘 확인한다.

---

## 6. 테스트 계획

### 기존 파일에 추가

| 파일 | 추가할 것 |
|---|---|
| `test/db_backup_test.dart` | v19 DB 를 열면 `v19.bak` 생기고 v20 칸이 생김. 칸이 이미 있는 DB(내려갔다 다시 올림)도 죽지 않음 |
| `test/conti_snapshot_test.dart` | 저장한 콘티는 곡 코드를 나중에 고쳐도 저장 당시 코드·조 그대로. v19 콘티 행은 코드 NULL |
| `test/sync_test.dart` | ① 코드가 다른 PC 로 감 ② 코드만 고쳐도 곡 `updated_at` 안 오름 ③ **옛 앱 흉내**(스냅샷 JSON 에서 `chords` 키를 뺀 파일 + 가사 수정)와 섞여도 코드 안 지워짐, 어긋남 상태 ④ 같은 시각 두 판 순서와 상관없이 같은 결과 ⑤ 코드 지움 전파 ⑥ 같은 곡 합치기(`_renameUid`)·중복 정리 후 코드 유지 ⑦ 한쪽만 코드 있는 같은 곡이 중복 곡으로 안 갈라짐 ⑧ `preview` 가 DB 안 바꿈 ⑨ `_ownFileUpToDate` 가 코드 수정을 '안 올린 수정'으로 봄 |
| `test/add_new_songs_test.dart` | `addNewSongs` 나누기만 바뀐 곡 갱신 후 코드 재정렬/어긋남, `replaceAllSongs` 가 같은 내용 곡의 코드를 유지 |
| `test/conti_file_test.dart` | `.wsconti` 왕복으로 코드·조 유지. 칸 없는(옛) 파일 가져오기 정상. 범위 밖 `song_transpose` 버림 |
| `test/song_bundle_test.dart` | 곡 모음 내보내기/가져오기에 코드 |
| `test/staged_song_update_test.dart` | 곡 수정 후 '콘티도 바꿀까요'에서 코드도 바뀌고 조는 유지 |
| `test/move_pages_test.dart` | `itemsFromPages`(나누기·복사·옮기기)에서 코드 페이지가 가사 페이지와 같이 잘림 |
| `test/singer_view_test.dart` | 싱어 JSON 에 코드(조 적용)가 실리고 `SlidePageData.toJson`(관객)에는 없음 |
| `python/test_export_text.py` | payload 에 `chord_lyrics` 가 있어도 PPTX 글에 `[` 가 없음 |

### 새 파일

- `test/chord_lyrics_test.dart` — `stripChords`·`chordsMatch`·페이지 나누기·코드만 있는 줄 거부·`transposeChords`(샵/플랫, `D/F#`, `Bbm7`, 12반음 순환, 이상한 토큰 그대로)·자동 재정렬(오타, 줄 추가/삭제, 페이지 구분만 바뀜, 크게 바뀜 = 실패).
- (2차) `python/test_sheet_chords.py` — 글자 박힌 PDF 에서 코드 위치.

---

## 7. 작업량 추정과 위험

### 작업량(백엔드만, 화면 제외)

| 일 | 추정 |
|---|---|
| DB v20 + 도메인 필드 + `saveChords` + `fromMap` | 0.5일 |
| `chord_lyrics.dart` 순수 함수(strip·검사·조 바꾸기) + 테스트 | 1일 |
| 자동 재정렬(diff) + 테스트 | 1~1.5일 |
| 저장 경로 정리(`replaceAllSongs`·`addNewSongs`·`updateSong`·곡 모음·중복 정리) | 1일 |
| 동기화 `chords` 구역 + 합치기 + 옛 앱 흉내 테스트 | 1.5~2일 |
| 콘티 스냅샷·`.wsconti`·조 바꾸기 값 | 0.5~1일 |
| PPTX 누출 방지 테스트 | 0.25일 |
| **소계(1차)** | **약 6~7일** |
| (2차) 글자 박힌 PDF 코드 위치 복원 | 2~3일 |
| (2차) 그림 악보 OCR 코드 위치 | 5일+, 정확도 미확인 |

### 위험

1. **옛 앱 PC 와 섞임** — 곡 레코드에 코드를 실으면 옛 앱이 코드 없는 판을 같은 시각으로 퍼뜨려 코드가 사라지거나 순서 따라 달라진다. → 별도 `chords` 구역 + 자기 시각으로 피한다(3.2). 옛 앱이 가사를 고치면 어긋남은 남는다(지워지진 않음).
2. **원본 가사와 코드 어긋남** — 경로가 여섯 개(2장)라 하나라도 빠지면 틀린 자리에 코드가 뜬다. → 저장하지 말고 읽을 때마다 `chordsMatch` 로 판정, 어긋나면 코드 숨김.
3. **`toMap()` 에 넣는 실수** — 코드를 모르는 경로가 칸을 NULL 로 덮는다. → `toMap` 에서 빼고 전용 메서드로만 쓴다. 리뷰 체크 항목.
4. **관객 화면·PPTX 누출** — `lyrics` 자리에 ChordPro 를 넣으면 렌더러 네 곳에 다 나간다. → 필드 분리 규칙 + 누출 테스트.
5. **페이지 구조 깨짐** — 코드만 있는 줄이 빈 줄이 되어 페이지가 하나 더 생긴다. → 저장할 때 막는다.
6. **`replaceAllSongs`·옛 앱 전체 교체로 코드 유실** — uid 를 다시 못 쓰는 곡의 코드는 사라진다. → 실행 전 수 안내. 자동 백업(`v19.bak`)은 v20 로 올리기 전 것뿐이라 그 뒤 유실은 못 되살린다.
7. **옛 앱이 받은 클라우드 콘티를 다시 올림** — 코드·조가 빠진 판으로 덮인다. 막을 수 없음, 안내 대상.
8. **sqflite 내려가기 동작 미확인** — 옛 앱이 v20 DB 를 열 때의 동작(user_version 을 내리는지, 오류인지)을 실제 확인해야 한다.
9. **조 바꾸기 표기** — 샵/플랫 선택(F# vs Gb), `D/F#` 베이스, 한국식 표기(`도`·`솔`) 등 입력 다양성. 모르는 토큰은 옮기지 않고 그대로 두는 것을 규칙으로.
