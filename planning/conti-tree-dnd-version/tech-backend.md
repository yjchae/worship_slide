# 콘티 트리 폴더 · 자유 위치 담기 · 발표 중 성경 역본 바꾸기 — 백엔드(데이터) 조사

조사만 했고 앱 코드는 고치지 않았다. 실행해 본 것은 없다(모두 코드 읽기, 실제 동작은 '미확인').
경로는 `lib/src/features/praise/` 기준. `praise_home_page.dart` = `presentation/praise_home_page.dart`.

## 1. 지금 구조 (사실)

- 그룹 = 항목 행마다 이름 문자열 하나. `worship_conti_items.item_group TEXT`(NULL = 없음).
  - 칸 추가: `data/praise_database.dart` `ensureItemGroupColumn`(`onOpen`, 멱등, 스키마 20 그대로). 새 DB `CREATE TABLE` 에도 있음(193줄).
  - 이름 정리: `data/worship_conti_repository.dart:41` `normalizeItemGroup` (trim, 12자, 빈 값 null).
  - 저장: 같은 파일 `saveConti` 223줄 `row['item_group'] = normalizeItemGroup(itemGroups[uid])`.
  - 불러오기: `loadConti` 389줄 → `LoadContiResult.itemGroups`(uid → 이름).
  - `.wsconti` 내보내기: `exportContiFile` 이 `portableItemRow` 로 DB 행을 그대로 담으므로 `item_group` 이 실림.
    가져오기: `_insertImported` 598줄 `receivableItemColumns`(현재 DB 칸만) + 622줄 정규화.
- **그룹 순서·범위는 저장하지 않는다.** 항목 위치(`position`)로 정해지고, 같은 이름이 **연속**한 구간이 한 그룹이다
  (`presentation/slide_group.dart` `slideGroupSections`, 떨어진 같은 이름은 다른 구간).
- 작업 콘티 메모리 상태: `praise_home_page.dart:388` `_itemGroups: Map<int,String>`.
  옮기는 곳: 나누기 3460~3509, 넣기 3927~3932, 지우기 4212, `_onStagingReorder` 4961, 불러오기 5514, 뒤에 붙이기 5639.
- 파이썬 `ppt_tool.py` 에 `item_group` 관련 코드가 **없다**. `PythonBridge.exportPayload`(`python_bridge.dart:332`)에도 그룹이 안 실린다 → PPTX 는 그룹을 모른다.
- 찬양 동기화(`song_sync_repository.dart`·`sync_snapshot.dart`)는 콘티 행을 건드리지 않는다(CLAUDE.md, 위 파일에 conti 항목 없음). 클라우드 콘티 = `.wsconti` 파일 올리기·받기뿐.
- `.wsconti` 헤더 `{format, version:1, name, created_at}` — 가져오기는 `format` 만 검사(532줄), `version` 은 안 본다. 모르는 헤더 키는 무시된다.

## 2. 요구 1 — 그룹을 폴더(트리)로

### 안 A (추천): 스키마 버전 그대로, `item_group` 재사용 + 빈 폴더용 칸 하나
1. **폴더 소속 = `item_group` 에 경로 문자열**. 깊이 1이면 지금과 같고, 중첩이 필요하면 `시작곡/찬양`처럼 `/` 로 잇는다.
   - 구분자 `/` 는 폴더 이름에서 금지(`normalizeItemGroup` 이 이름 한 조각 단위로 처리하도록 분리: 조각 12자·깊이 3 이하·`/` 제거). 전체 한도는 `normalizeItemGroupPath` 같은 새 함수로 두고, `saveConti`·`loadConti`·`_insertImported` 의 세 호출을 그쪽으로 바꾼다.
   - 폴더 순서·트리 모양은 **항목 순서에서 계산**한다(저장 안 함). 같은 폴더 항목은 연속해야 하며, 드롭 로직이 그걸 지킨다(§3). 연속이 깨진 옛 데이터는 `slideGroupSections` 처럼 별개 구간으로 보면 된다.
2. **빈 폴더 저장**: 항목이 없으면 `item_group` 에 흔적이 남지 않는다. 방법 비교:
   - (a) `worship_contis.group_meta TEXT`(JSON `{"empty":["경로",...]}`) 칸 추가 — `ensureItemGroupColumn` 과 같은 `_addColumnIfMissing` 패턴으로 `onOpen` 에서 멱등 추가, **스키마 버전 20 유지**. 옛 앱은 모르는 칸을 지나가고 `listContis` 는 칸을 명시해 읽어 영향 없음. **추천.**
   - (b) 더미 항목(빈 `item_type`) 행 — 항목 수·발표 슬라이드·PPTX·`position` 이 어긋나서 기각.
   - (c) 저장하지 않고 세션 동안만 — 저장 전엔 쓸 만하나 빈 폴더가 콘티를 다시 열면 사라진다. 사용자가 "빈 폴더를 미리 만들어 둔다"를 원하면 부족.
   - 저장 위치가 `worship_contis` 라서 `saveConti` 두 갈래(새로 저장 / `overwriteUid` 덮어쓰기)가 `group_meta` 를 같이 쓰고, `loadConti` 는 반환 타입 `LoadContiResult` 에 `emptyGroups` 를 더해야 한다.
3. **접힘 상태 저장 안 함 권장** — 화면 편의 값이고 콘티 내용이 아니다. 저장하면 열 때마다 접힌 채라 혼란. 필요하면 `ui` 쪽 앱 설정으로(콘티 단위 아님). 폴더 순서도 저장 안 함(항목 순서가 곧 순서).
4. 옛 앱이 새 DB·파일을 읽을 때: `item_group` 에 `A/B` 가 있으면 옛 앱 `normalizeItemGroup` 이 12자로 **잘라서** 읽고, 옛 앱에서 다시 저장하면 잘린 값이 된다(경로가 깨짐). 깊이 1·12자 이하면 영향 없음. 이건 감수할 위험(§5).

### 안 B: 새 테이블 `worship_conti_groups(conti_id, path, position, collapsed)` + 스키마 21
순서·빈 폴더·접힘을 정석으로 저장하지만 마이그레이션·`.wsconti`/백업(`backupBeforeUpgrade`) 영향·옛 앱 호환(버전 21 DB 를 옛 앱이 열 수 있는지)을 모두 새로 다뤄야 한다. 이점이 안 A 와 크게 다르지 않아 비추천.

### 결론
**안 A**: `item_group` 경로 문자열(필요하면) + `worship_contis.group_meta`(빈 폴더만). 중첩 없이 1단계 폴더면 충분하다면 `group_meta` 만 더하고 `item_group` 은 손대지 않아도 된다(요구의 '트리'가 중첩을 뜻하는지는 **미확인** — 기획 확인 필요).

## 3. 요구 2 — 성경·찬양을 콘티 임의 위치에 (드래그앤드롭)
- DB 영향 없음: `saveConti` 가 `stagingItems` 순서대로 `position = i` 를 쓰므로 어디에 끼워도 저장된다.
- 지금은 `_addBibleItem`(`praise_home_page.dart:2896`)이 맨 끝에 `add`, 곡 담기(2846·2881)도 끝, 성경 음성·붙여 넣기는 `_insertItemsAfterSlide`(3922 근처)로 '놓은 페이지 뒤'. 임의 위치 DnD 는 후자를 재사용하는 것이 안전(여백·그룹·`renamed` 키 처리 포함).
- 그룹 관련 규칙(변경점): 드롭 대상이 폴더 안이면 `_itemGroups[uid]` 에 그 폴더 경로를 준다(넣기 3927~3932 와 같은 방식). 폴더 **사이** 경계에 놓을 때 앞/뒤 폴더 중 어느 쪽인지는 UI 가 명시해야 한다(현재 규칙은 '앞 그룹에 든다').
- `_noSpacerUids`(자동 여백 표시, `saveConti` 의 `no_spacer`)는 항목 uid 집합이라 위치와 무관하게 저장되나, 끼워 넣은 자리 앞 항목의 여백 표시 정리가 필요하다(`_onStagingReorder` 4961 참조).
- 곡은 `_withSubLyrics` 를 거쳐 담아야 보조 가사 스냅샷이 생긴다(2846 근처 담기 경로 재사용).

## 4. 요구 3 — 담아 둔 성경 항목의 역본을 발표 보기에서 바꾸기
저장 위치(사실):
- `domain/staging_item.dart:22` `BibleStagingItem{reference, text, subText, extraText}`. **역본 이름은 별도 필드가 아니라 `reference` 문자열 앞(`개역개정 요한복음 3:16-18`)에 들어 있다.**
- DB: `bible_reference`(=reference), `bible_text`(본문, `N. 본문` 줄), `bible_sub_text`, `bible_extra_text`(`worship_conti_repository.dart` 185~188 저장 / 339~348 불러오기). 역본 칸 따로 없음.
- 따라서 항목의 **주 역본을 바꾸려면 `reference`·`text`·`subText` 를 새로 만들어 항목을 교체**하면 되고, 스키마 변경은 필요 없다. 콘티를 저장(또는 덮어쓰기)하면 바뀐 값이 그대로 남는다. 저장하지 않으면 안 남는다(작업 콘티 메모리 상태일 뿐).
- 이미 있는 도구: `_reapplyBibleVersions`(`praise_home_page.dart:895`)가 보조·추가 역본을 담아 둔 항목에 다시 입힌다 — `parseBibleReference`(`bible/domain/bible_text_search.dart:162`) → `_loadOtherVersionVerses`(8548) → `verseNumbersText`. 같은 길로 주 역본 본문도 만들 수 있다:
  `parseBibleReference(item.reference, _bibleVersions)` → `_loadOtherVersionVerses(repo, 새역본, ref.version, ref.book, ref.chapter)`(책 이름은 `mapBookName` 이 역본 간 대응) → `text = verseNumbersText(ref.verses, 맵)`, `reference = _buildReference(새역본, 새 책 이름, ref.chapter, ref.verses)`. 책 이름이 역본마다 다르므로(창세기/Genesis) 새 책 이름도 맵핑 결과를 써야 한다. 현재 `_loadOtherVersionVerses` 는 본문 맵만 돌려주고 책 이름은 안 주므로 **책 이름을 같이 돌려주는 함수가 하나 필요**하다.
- 현재 보조 역본은 `ExportStyle.bibleSubVersion` 전역 한 값이라 '항목 하나만 다른 역본으로 표시'는 현재 모델에 없다. 항목별로 바꾸려면 위처럼 항목 내용을 교체(저장되는 방식)하는 것이 스키마 없이 되는 유일한 길이다. 표시만 바꾸고 원본을 유지하는 방식은 새 칸(예: `bible_display_version`)이 필요하다 — 추천하지 않는다.
- 바꾸면 새 주 역본이 보조/추가 역본과 같아질 수 있다 → 그 칸을 비워야 한다(`_bibleItemsFor` 가 같은 역본이면 안 담는 규칙과 맞춘다). 반대로 옛 주 역본을 보조 칸으로 보내는 '맞바꾸기'는 정책 결정 필요(미정).
- 슬라이드 키: 성경 항목은 한 장이고 항목 uid 가 그대로라 `_slideInfoKey`(`uid:페이지:자동여백`)가 안 바뀐다 → 발표 중 교체해도 보던 페이지가 유지된다(`_reapplyBibleVersions` 도 같은 전제). 교체 직후 `_sendCurrentSlide` 호출은 프론트 몫.
- PPTX: `ppt_tool.py` export 는 `bible` 항목의 reference/text/sub text 를 payload 로 받아 그린다 — 교체된 값이 그대로 나가므로 변경 불필요(미확인: payload 의 정확한 키 이름은 `python_bridge.dart:342~358` 부근, 이번에 끝까지 읽지 않음).

## 5. 변경점 요약 (파일·함수 단위)
| 파일 | 변경 |
|---|---|
| `data/praise_database.dart` | `ensureContiGroupMetaColumn`(`worship_contis.group_meta TEXT`) 추가, `onOpen` 호출, 새 DB `CREATE TABLE worship_contis` 에도 칸 추가. `schemaVersion` 은 20 유지(`backupBeforeUpgrade` 대상 아님) |
| `data/worship_conti_repository.dart` | (경로 사용 시) `normalizeItemGroupPath` 추가 후 `saveConti`·`loadConti`·`_insertImported` 에서 사용. `saveConti` 파라미터 `emptyGroups`, `LoadContiResult.emptyGroups`. `exportContiFile` 헤더에 `groups`(빈 폴더 목록) 더하기, `_unpackContiFile`·`_insertImported` 에서 읽어 `group_meta` 로 저장(없는 옛 파일은 빈 값) |
| `domain/worship_conti.dart` | 필요 시 `WorshipConti` 에 변화 없음(목록은 칸 명시 SELECT) |
| `praise_home_page.dart` (프론트 몫) | 폴더 트리 UI·`_itemGroups`·빈 폴더 상태 보관, DnD 삽입(`_insertItemsAfterSlide` 재사용), 주 역본 바꾸기 함수(`_reapplyBibleVersions` 옆) |
| `python/ppt_tool.py` | **변경 없음** — PPTX 에 그룹 개념이 없다 |
| 동기화(`song_sync_repository.dart` 등) | **변경 없음** — 콘티 행을 안 건드린다 |
| 클라우드 콘티(`conti_cloud_repository.dart`) | 코드 변경 없음 — `.wsconti` 를 그대로 올리므로 헤더·`item_group` 값이 자동으로 실림. 목록 정보 JSON 은 그대로 |

## 6. 호환·위험
- **옛 앱이 새 `.wsconti` 를 읽을 때**: 모르는 헤더 키(`groups`)는 무시, `item_group` 은 현재도 칸이 있어 읽음. 경로 값은 옛 앱이 12자로 자름(깊이 1·짧은 이름이면 무손실). 빈 폴더는 옛 앱에선 사라짐. 크래시 위험은 코드상 없음(미확인: 실제 옛 빌드로 열어 보지 않음).
- **새 앱이 옛 파일을 읽을 때**: `groups` 없음 → 빈 폴더 없음, `item_group` 없으면 그룹 없음 (기존 테스트 `conti_group_test.dart` 53줄과 같은 경우).
- **옛 앱이 새 DB 를 열 때**: `worship_contis.group_meta` 는 모르는 칸이라 지나감. 단 옛 앱이 같은 콘티를 다시 저장하면 `group_meta` 가 초기화되어 빈 폴더가 사라진다(감수).
- 경로 안의 `/`: 사용자가 이름에 넣으면 트리가 깨진다 → 입력·`.wsconti` 가져오기·불러오기 모두에서 정규화(남이 만든 파일이므로 가져오기에서 반드시).
- 폴더 연속성: DnD 삽입·`_onStagingReorder`·곡 나누기가 폴더 연속성을 깨면 같은 폴더가 둘로 갈린다. 저장·불러오기는 이를 고치지 않으므로 삽입 시점에 지키거나 불러올 때 병합 규칙을 정해야 한다.
- 성경 역본 교체: ① `parseBibleReference` 실패(모르는 역본·손으로 고친 참조) ② 66권이 아닌 역본이라 `mapBookName` 이 null ③ 새 역본에 그 절이 없음(절 구분 차이, `verseNumbersText` 가 있는 절만 담아 일부만 나옴) ④ 본문 길이가 달라져 넘침 경고(`overflowRatio`) ⑤ 가사 수정처럼 손으로 고친 본문이 덮임 → 실패 시 항목은 그대로 두고 알려야 한다. 읽는 사이 항목이 바뀌었으면 `identical` 비교로 건너뛰는 `_reapplyBibleVersions` 방식을 따른다.
- 역본 이름이 NFD 로 저장된 DB 가 있다(CLAUDE.md 음성 검색 항목) → 역본 이름 비교는 `composeHangul` 로.

## 7. 테스트 항목 (`test/conti_group_test.dart` 확장 + 새 파일)
1. 저장·불러오기 왕복: 경로 `item_group`, 빈 폴더 `group_meta`, 덮어쓰기 저장(`overwriteUid`)에서 둘 다 갱신·유지.
2. `normalizeItemGroupPath`: `/`·공백·12자·깊이 한도·빈 조각.
3. `.wsconti` 왕복: 빈 폴더 보존, `groups` 키 없는 옛 파일(빈 폴더 없음), `groups` 에 이상한 값(숫자·중첩 배열·`/` 포함) 방어, `item_group` 에 긴 경로.
4. 칸 없는 DB(옛 DB)를 열면 `group_meta` 가 멱등 추가(기존 80줄 테스트와 같은 방식), 옛 방식 `SELECT`·`listContis` 동작.
5. 옛 앱 시늉: 새 칸이 있는 DB 에서 `group_meta` 를 안 쓰는 옛 방식 insert 가 되는지.
6. 클라우드 콘티: 올렸다 받으면(`FolderSyncStore`) 폴더·빈 폴더 유지(`test/sync_test.dart` 패턴).
7. DnD 삽입: 폴더 안·경계·폴더 끝에 성경/곡 삽입 후 `_itemGroups`·`position`·`no_spacer` 가 맞고 폴더가 연속(순수 함수로 빼서 테스트 — `move_pages_test.dart` 패턴).
8. 성경 역본 교체: ① 같은 책 이름 역본 간(개역개정→새번역) `reference`·`text` 생성 ② 책 이름이 다른 역본(KJV) ③ 새 역본에 일부 절 없음 ④ 66권 아닌 역본 실패 ⑤ 새 주 역본 = 보조 역본일 때 보조 칸 비우기 ⑥ 교체 뒤 `saveConti`→`loadConti` 로 `bible_reference`·`bible_text`·`bible_sub_text` 유지 ⑦ PPTX payload(`exportPayload`)에 교체된 값이 실림.
9. `python3 python/test_export_text.py` 등 기존 PPTX 테스트는 그대로 통과해야 함(변경 없음 확인용).

## 8. 열린 질문 (기획 확인)
- '트리'는 폴더 안에 폴더(중첩)까지인가, 1단계 폴더인가? → 안 A 의 `/` 경로 도입 여부가 갈린다.
- 빈 폴더를 저장해야 하는가? → 아니면 `group_meta` 칸도 필요 없다(가장 작은 변경: 스키마·파일 형식 변경 0).
- 역본 변경이 해당 항목만인가, 콘티 전체 성경 항목인가? 옛 주 역본을 보조로 보내는가?
