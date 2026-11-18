# 콘티 트리(폴더) · 끌어 놓기 추가 · 성경 역본 바꾸기 — 프론트엔드 기술 검토

작성 기준: master 6ded6c2. 줄 번호는 `lib/src/features/praise/presentation/praise_home_page.dart`(이하 home) 기준이고 코드를 읽은 결과다. 앱 코드는 고치지 않았다.
"미확인" = 실제로 돌려 보지 않았거나 읽기만으로 단정 못 한 것.

## 0. 지금 구조 (읽은 결과)

- 콘티 = 평면 `_stagingItems: List<({int uid, StagingItem item})>`(home:~388 근처) + 그룹은 `_itemGroups: Map<int uid, String>`(home:388). 그룹은 "같은 이름이 이어진 항목"(별도 폴더 개체 없음). DB `worship_conti_items.item_group` 한 칸, `.wsconti` 에도 같은 칸. Python(PPTX)·싱어·휴대폰·네이티브 창은 그룹을 아예 모른다(grep: `python/ppt_tool.py`·`slide_page_data.dart`·`singer_view_data.dart`·`python_bridge.dart` 에 item_group 없음).
- 편집 탭 목록 = `_StagingPanel._buildCard`(home:7585~) 안의 `ReorderableListView.builder`(home:7752, `buildDefaultDragHandles:false`, 우측 `ReorderableDragStartListener`(home:8071) 손잡이, `onReorderItem: _onStagingReorder`(home:4961)). 행마다 `ItemGroupChip`(`conti_group_widgets.dart`, 팝업으로 이름 고르기·직접 입력·그룹 없음)이 있고 `_setItemGroup`(home:5531)이 `_itemGroups` 를 바꾼다. 머리줄 라벨 버튼 = `_assignGroupRange`(번호 범위 일괄 지정, 되돌리기 스낵바).
- 그룹을 따라 옮기는 곳은 이미 여러 곳: `_removeStagingWhere`(home:4212, 그룹 제거), `_onStagingReorder`(4961, 그룹을 유지한 채 위치만 이동 — 그래서 **지금은 끌어도 그룹이 안 바뀐다**), `_splitStagingItem`(3460~3509), `_insertItemsAfterSlide`(3899~3932, 놓은 자리 항목의 그룹을 이어받음), 되돌리기 스냅샷 `_VoiceUndo`(194~247), 콘티 불러오기(5514)·붙이기(5639).
- 발표 보기 격자·썸네일 줄의 그룹 = `slideGroupSections(slideGroups)`(`slide_group.dart`, 순수 함수) — `_itemGroups[s.stagingUid]` 를 슬라이드별로 펼친 `List<String?>` 만 받는다(home:6412, 13903, 15181).
- 담기 경로(모두 **맨 끝 `_stagingItems.add`**): 찬양 더블클릭·끌기 `_addSongToStaging`(2842), 콘티 한번에 넣기 `_importContiText`(2851~, 끝에 담음), 성경 `_addBibleItem`(2896, `_previewStagingUid` 를 새 항목으로). 빈 페이지·편집·미디어는 `_indexAfterSelectedItem`(2905, 고른 항목 뒤)에 `insert`.
- 끌어 놓기는 이미 있다: 찬양 검색 결과 줄 `Draggable<PraiseSong>`(home:8370) → 콘티 패널 전체 `DragTarget<PraiseSong>`(home:7503, `onDropSong`=`_addSongToStaging`, "놓은 자리와 상관없이 맨 끝"). **성경은 끌기 없음**(`_buildVerseTile` 은 `CheckboxListTile`, home:9516~; 담기는 `_addSelectedVerses` → `onAddItem`).
- 발표 보기에서 끌어 놓는 방식은 썸네일 `_ThumbDragDrop`(home:15300~, `DragTarget<_ThumbDrag>`·좌/우 절반 판정·삽입선), `_EdgeAutoScroll`, `cancelDrag` 가 이미 검증돼 있다 — 재사용할 패턴.
- 성경 역본: 전역 `ExportStyle.bibleSubVersion`/`bibleExtraVersion` 이 담을 때 `BibleStagingItem.subText/extraText` 로 확정되고, 바꾸면 `_updateStyle`(home:~750) → `_reapplyBibleVersions`(895~)가 **담긴 모든 성경 항목의 보조·추가 칸만** 다시 입힌다. 본문 역본은 항목 `reference`(`개역개정 요한복음 3:16-18`)의 앞 단어이고 `parseBibleReference(reference, _bibleVersions)`(`bible_text_search.dart:162`)가 풀어 준다. 다른 역본 장 읽기 = `_loadOtherVersionVerses`(home:8549, `mapBookName` 으로 책 짝 찾기), 본문 줄 만들기 = `verseNumbersText`, 참조 만들기 = `_buildReference`(home:~8579). 66권이 아닌 역본은 `mapBookName` 이 null.

## 1. 설계 비교

### 안 A — 평면 모델 유지 + '표시 행(row)' 변환 (추천)
- 데이터(`_stagingItems`·`_itemGroups`·DB·`.wsconti`·PPTX·동기화)는 **그대로**. 화면에서만 `rows = contiRows(items, groups, collapsed)` 로 "그룹 머리 행 + 들여쓴 항목 행"을 만든다(순수 함수 = 새 `conti_tree.dart`).
- 폴더 = 이어진 같은 이름 구간(지금 규칙과 동일). 항목 이동 = 그 항목의 `_itemGroups` 를 놓은 자리에 맞춰 바꾸고 `_stagingItems` 순서를 옮기는 것뿐.
- 발표 보기 격자는 이미 같은 데이터에서 구간을 만든다 → 동작 일관성이 공짜. 새 마이그레이션·형식 변경 없음, 옛 앱도 그대로 읽는다.
- 한계: ① 빈 그룹을 저장하지 못한다(§3-1에서 완화). ② 떨어져 있는 같은 이름은 별개 폴더(현재 규칙 그대로, 접기 상태는 이름 기준이라 둘이 같이 접힘 — 감수). ③ 중첩(폴더 안 폴더) 불가 — 요구에 없음.

### 안 B — 진짜 트리 모델 (`StagingNode` + children)
- `_stagingItems` 소비처가 home 에만 113곳(grep -c) — 전부 평탄화 어댑터 또는 재작성. `_allSlides`·`_splitStagingItem`·`_insertItemsAfterSlide`·`_VoiceUndo`·붙여 넣기·음성 넣기·되돌리기·콘티 저장/불러오기/`.wsconti`/클라우드 콘티가 다 닿는다.
- DB 스키마 20 → 21(폴더 행 또는 parent 칸), `.wsconti`·클라우드 콘티 형식 변경(옛 앱 호환 문제), `test/conti_group_test.dart`·`conti_file_test.dart`·`conti_snapshot_test.dart` 등 재작성.
- 얻는 것은 빈 폴더 저장·중첩뿐인데 요구에 없다. **비추천.**

**추천: 안 A.** 단, 안 A 의 핵심 변경은 목록 위젯을 `ReorderableListView` 에서 걷어 내는 것이다(§2-3, 이유 포함).

## 2. 변경점 (안 A)

### 2-1. 새 파일 `presentation/conti_tree.dart` (순수 Dart, 위젯 없음)
- `sealed class ContiRow` = `ContiHeaderRow(name, count, collapsed, empty)` | `ContiItemRow(itemIndex, uid, group?)`.
- `List<ContiRow> contiRows(List<int> uids, Map<int,String> groups, Set<String> collapsed, {List<EmptyGroup> empty})` — 이어진 같은 이름 구간 앞에 머리 행. `collapsed` 이름이면 그 구간 항목 행은 뺀다(머리 행에 `count`). 빈 그룹(§3-1)은 머리 행 + 비어 있음 안내.
- `ContiDrop resolveDrop(List<ContiRow> rows, int rowIndex, bool lowerHalf)` → `({int insertIndex, String? group})`. 규칙(방향 모호함을 없애려고 행의 위/아래 절반으로 가른다):
  - 항목 행 위 절반 = 그 항목 앞, 그 항목의 그룹. 아래 절반 = 그 항목 뒤, 그 항목의 그룹(그룹 마지막 항목 아래 절반 = 그룹 끝에 들어감).
  - 그룹 머리 행 위 절반 = 머리 앞, **그룹 없음**(그룹 밖으로 나오는 길). 아래 절반 = 그 그룹의 맨 앞(접힌 그룹이면 맨 끝).
  - 빈 목록 / 목록 아래 빈 공간 = 맨 끝, 그룹 없음.
  - 발표 보기 `_insertItemsAfterSlide` 의 "그룹 마지막 뒤여도 앞 그룹" 과 같은 결과가 되는 것을 테스트로 고정(`test/conti_tree_test.dart`).
- `moveGroupBlock` 은 만들지 않는다(그룹째 옮기기 = 요구에 없음, 아래 §3-2 질문).

### 2-2. home 상태·메서드
- 상태: `final Set<String> _collapsedGroups = {};`(접기, 저장 안 함 — 콘티 불러오기·새 콘티 때 비움), `_emptyGroups`(§3-1).
- 새 `_placeStaging({required List<int> movedUids, required int insertIndex, required String? group})`:
  `_onStagingReorder`(4961)와 같은 일을 하나로 — `_removeStagingWhere`(그룹 지워지는 부작용 때문에 지금처럼 `group` 을 먼저 빼 두고 다시 넣는 방식은 버리고, 새 그룹을 직접 쓴다) → insert → `_noSpacerUids.remove(앞 항목)` → `_clampCurrentSlideIndex`. **여러 항목을 한꺼번에 옮길 필요는 v1 에 없다**(한 항목씩) — 다중 선택은 §3-3 질문.
  - 놓은 곳이 접힌 그룹 안이면 항목 수가 보이게 머리 행이 갱신될 뿐 자동 펼침은 안 한다.
- 새 `_insertNewItems(List<StagingItem> items, int insertIndex, String? group)`: `_stagingItems.insert`, uid 부여, `_itemGroups[uid]=group`, `_noSpacerUids.remove(앞 항목)`, `_previewStagingUid`=첫 새 항목. 끝에 넣을 때만 예전과 동일(앞 항목 여백 표시 정리 포함).
- `_addSongToStaging(song, {ContiDrop? at})` · `_addBibleItem(item, {at})`: `at == null` 이면 지금 동작 그대로(맨 끝) → 더블클릭·담기 버튼 호환.
- **보던 슬라이드 보존(위험, 아래 R2)**: 중간 삽입·이동은 `_currentSlideIndex`(번호)를 밀어 버린다. 발표 중에 편집 탭에서 하면 다음 `_sendCurrentSlide` 때 관객 화면이 엉뚱한 페이지가 된다. `_onStagingReorder` 는 지금도 `_clampCurrentSlideIndex` 만 한다(기존 결함). 새 경로는 직전 `_slideInfoKey(현재)`(home:636)를 적어 두고 삽입 뒤 같은 키를 `_allSlides` 에서 다시 찾아 `_currentSlideIndex` 를 맞춘다(`_findSlideAfterReload` 4749 참고). 못 찾으면 그대로 둔다.
- 되돌리기: 스낵바 '되돌리기' 한 번(`_assignGroupRange` 패턴: 이전 `_stagingItems`·`_itemGroups` 사본, 그 사이 바뀌었으면 uid 가 살아 있는 것만 복원). v1 에서는 생략 가능.
- 그룹 만들기·이름 바꾸기·풀기(그룹 해제 = 그 구간 항목의 `_itemGroups` 제거) 메서드 3개 — 모두 `_itemGroups` 키 갱신. 이름 정규화는 기존 `normalizeItemGroup`(12자, 공백 정리). **같은 이름이 떨어진 자리에 이미 있으면 이어 붙는지 헷갈림** → 그룹 만들기는 기존 이름과 같으면 거절하고 알린다.

### 2-3. 목록 위젯 (`_StagingPanel._buildCard` home:7585~8100)
- `ReorderableListView.builder` → `ListView.builder`(rows 기준) + 행마다 `DragTarget`/`Draggable`. 이유: `ReorderableListView` 는 "슬롯 번호"만 주고 가로 위치·행 절반을 알려 주지 않아 "그룹 마지막 뒤 = 안인가 밖인가" 를 가를 수 없고, 헤더 행이 끼면 `onReorder` 의 새 인덱스 변환도 복잡하다. 대신 이미 검증된 `_ThumbDragDrop` 방식(절반 판정·삽입선·`cancelDrag`·`_EdgeAutoScroll`)을 세로로 옮긴다. 잃는 것 = 재정렬 애니메이션(미확인 수준의 취향 문제).
- 드래그 페이로드 3종을 한 타입으로: `sealed class ContiDragData` = `ContiItemDrag(uid)` | `ContiSongDrag(PraiseSong)` | `ContiBibleDrag(Future<List<BibleStagingItem>> Function() build)`. 단, 기존 `Draggable<PraiseSong>`(8370)·`DragTarget<PraiseSong>`(7503)는 **바꾸지 않고** 행 `DragTarget<PraiseSong>` 만 추가해도 된다(페이로드 타입을 안 바꾸는 쪽이 수정이 적다). 패널 전체 `DragTarget<PraiseSong>` 는 "행 밖 빈 공간 = 맨 끝" 폴백으로 남긴다. 중첩 DragTarget 에서 가장 안쪽이 이기는지는 Flutter 쪽 동작 기억에 의존 — **미확인**, 위젯 테스트로 확인할 것(R4).
- 항목 행: 기존 손잡이(`ReorderableDragStartListener`)를 `Draggable<ContiItemDrag>`(손잡이만 끌기 — 행 전체를 끌면 InkWell 탭·더블클릭과 충돌)로 교체. 들여쓰기(그룹 안이면 왼쪽 16~20px + 세로선), 번호 `${index+1}` 은 **전체 항목 번호 유지**(`_assignGroupRange` 번호 범위 대화상자와 맞아야 함). `sameTitleOrdinals`·`ordinals[index]`(7591·7912)는 itemIndex 기준으로 그대로.
- 그룹 머리 행(새 위젯 `ContiGroupHeader`, `conti_group_widgets.dart`): 접기 화살표·폴더 아이콘·이름·`N개`·`⋯` 메뉴(이름 바꾸기 / 그룹 풀기 / 그룹 삭제 = 안의 항목까지 지우지 않음, 풀기만). 머리 행 클릭 = 접기/펼치기. 머리 행은 끌 수 없다(그룹째 이동은 v1 제외).
- 기존 `ItemGroupChip`: **유지**(요구 "지금은 칩으로 지정"의 대체이지만 키보드 사용자·빠른 지정용으로 남기는 편이 안전). 행이 이미 그룹 안(들여쓰기)이면 칩 `dimmed` 를 항상 켜거나 숨겨 시각 중복을 줄인다 → 결정 필요(§3-4).
- 상단 머리줄: 기존 라벨 아이콘(번호 범위 지정, `onGroupRange`) 옆에 '그룹 추가'(폴더+) 버튼 1개. 그룹 만들기 = 이름 대화상자(기존 `_GroupNameDialog` 재사용, `presetGroupNames` 칩 제안) → 빈 그룹 머리 행이 고른 항목 뒤(없으면 맨 끝)에 생김.
- 접힘(`isCollapsed` = 패널 전체 접기, home:6375)일 땐 목록이 안 보이므로 드롭 대상 없음 — 기존 동작 유지, 펼치라고 안내 문구만.
- 빈 콘티 안내 문구(7727)에 "원하는 자리에 끌어 놓을 수도 있습니다" 한 줄(문구는 기획/디자인 확인).

### 2-4. 성경 검색 탭 끌기 (home:9516~ `_buildVerseTile`, `_addSelectedVerses` 9017)
- 절 줄을 `Draggable<ContiBibleDrag>` 로 감싼다(손잡이 아이콘 또는 행 전체 — 체크박스 탭과 충돌하므로 `LongPressDraggable` 또는 앞에 grab 아이콘 중 택일, 결정 필요 §3-5). 끌 때 대상 = 그 절이 체크돼 있으면 **체크된 절 전체**, 아니면 그 절 하나. 피드백 = `성경 N페이지`/`요 3:16` 한 줄 칩(찬양과 같은 모양).
- 페이로드에 `build` 콜백: 패널 내부 `_bibleItemsFor(...)` 호출(`_versesPerPage`·`widget.subVersion/extraVersion` 은 패널이 안다) → 비동기(장 단위로 DB 읽음). home 의 drop 핸들러는 놓는 순간 **위치를 uid 앵커로 적고**(`before/after uid + group`), `await build()` 뒤에 앵커 항목이 아직 있으면 그 자리에, 없으면 맨 끝에 넣는다(그 사이 콘티를 고쳤을 수 있음). 중복 드롭 방지 플래그.
- 담은 뒤 `setState(() => _selectedVerseIds.clear())`·스낵바 `N페이지 추가됨` 은 기존 `_addSelectedVerses` 와 같게. 기존 '담기' 버튼·`onAddItem`(맨 끝) 그대로.
- 위젯 경계: 패널 → home 로 `onAddItem` 외에 드롭 데이터를 올리는 길이 필요 없다(페이로드가 콜백을 들고 있음).

### 2-5. 찬양 검색 결과 → 콘티 (home:8370, 7503)
- 기존 `Draggable<PraiseSong>` 는 그대로. 목록 행 `DragTarget<PraiseSong>` 의 `onAccept` → `_addSongToStaging(song, at: resolveDrop(...))`. `_withSubLyrics` 가 비동기라 위와 같이 앵커 방식.
- '콘티 한번에 넣기'(`_importContiText`)는 끝에 담기 그대로(요구 밖). 선택한 그룹이 있으면 그 그룹 끝으로 넣는 옵션은 제안으로만.

### 2-6. 발표 보기 (`slide_group.dart`, home:13903·15181)
- `slideGroupSections` 는 **그대로**: `_itemGroups` 에서 펼치는 입력이 같으므로 편집 탭 트리와 항상 일치한다.
- 일관성 손질만: 머리줄 아이콘을 편집 탭 폴더 아이콘과 맞추기(`label_outline` → 폴더) — 취향, 필수 아님. **발표 보기에서 접기는 넣지 않는다**(접힌 곳 페이지를 못 넘기는 사고 방지 — 접기는 편집 탭 전용, 결정 필요 §3-6).
- 발표 보기 썸네일 끌기(`_moveSlides`→`_insertItemsAfterSlide`)는 이미 "놓은 자리 항목의 그룹을 이어받는다" — 트리 규칙(§2-1)과 일치하므로 수정 불필요. 빈 그룹 머리 행은 슬라이드가 없으니 격자에 안 나온다.

### 2-7. 성경 역본 바꾸기 (요구 3) — 가능, 재사용 가능
- 의미 확인 필요(§3-7): "역본을 바꿔 표시" = (a) 그 항목의 **본문 역본**을 다른 역본으로 교체(참조·본문 모두) / (b) 이미 있는 전역 보조 역본 칸(그대로, 모든 항목) 중 하나. (b)는 `_reapplyBibleVersions` 가 이미 한다 → 요구는 (a)로 읽고 설계한다.
- 새 `Future<void> _changeBibleVersion(int uid, String newVersion)`:
  1. `ref = parseBibleReference(item.reference, _bibleVersions)` — null 이면 안내 후 중단(손으로 고친 참조).
  2. `map = await _bibleRepository.mapBookName(bookName: ref.book, fromVersion: ref.version, inVersion: newVersion)` — null(권 수 다름) 이면 안내 후 중단. (`_loadOtherVersionVerses` 는 map 결과를 안 돌려주므로 책 이름이 필요한 이번에는 `mapBookName` 직접 + `getVerses`. 코드 몇 줄 중복은 감수, 헬퍼 추출은 하지 않음.)
  3. `verses = getVerses(version:newVersion, bookName:map, chapter:ref.chapter)` → `text = verseNumbersText(ref.verses, {…})`. 그 역본에 없는 절은 빠진다(`verseNumbersText` 동작) — 모두 비면 중단 + 안내.
  4. 새 `reference = _buildReference(newVersion, map, ref.chapter, [...ref.verses])`, `subText`/`extraText` 는 기존 값 유지하되 **새 본문 역본이 현재 보조/추가 역본과 같으면 그 칸은 비운다**(같은 글이 두 줄로 나오는 것 방지, `_bibleItemsFor` 규칙과 동일).
  5. `_stagingItems[i] = (uid, item: BibleStagingItem(...))`, 항목 `identical` 검사(읽는 사이 고쳤으면 고친 쪽 유지, `_reapplyBibleVersions` 와 동일 패턴), 그 뒤 `_sendCurrentSlide()`(관객·싱어 갱신). 장 수는 항상 1이라 슬라이드 번호 안 바뀜.
- UI: 발표 보기 현재 슬라이드 툴바(home:14230~14340 줄, 가운데에 `PopupMenuButton<_AddPage>`·음성·말풍선 버튼이 있는 줄)에 **현재 슬라이드가 성경일 때만** 보이는 역본 메뉴 버튼 하나(`PopupMenuButton<String>`, 항목 = `widget.bibleVersions`, 현재 역본에 체크). `_PresenterConsole` 에 `bibleVersions`(전달됨, home:6586)·`onChangeBibleVersion(int stagingUid, String version)` 콜백 추가. 현재 슬라이드가 성경인지는 `_SlideInfo.isBible`(home:97)·`stagingUid` 로 안다.
- 편집 탭 콘티 행에도 같은 메뉴를 붙일지는 제안(필수 아님).
- 저장 호환: 참조·본문이 바뀐 `BibleStagingItem` 이므로 DB·`.wsconti` 형식 그대로. 되돌리기: 스낵바 '되돌리기'(이전 item 보관 → identical 이면 복원).
- 잘 안 되는 경우: 역본이 66권이 아님·참조가 손으로 고쳐짐·그 역본에 그 절 번호 없음(번호 체계가 다른 역본) → 알리고 아무것도 안 바꾼다. 한글 역본 이름의 NFD 문제(CLAUDE.md 음성 검색 항목)가 `_bibleVersions` 와 `reference` 사이에도 있는지는 **미확인**(지금 `_reapplyBibleVersions` 가 같은 파싱을 쓰고 있으니 같은 위험을 이미 지고 있다).

## 3. 결정이 필요한 것 (팀장·대표)
1. **빈 그룹 저장**: 안 A 는 DB 에 빈 그룹을 못 담는다. 완화 = 메모리(`_emptyGroups`: 이름 + 앞 항목 uid, 그룹에 항목이 들어오거나 콘티를 불러오면 정리, 저장·재시작 시 빈 폴더는 사라짐)로 간다. 저장까지 원하면 안 B(스키마 21)로 가야 한다. 어느 쪽?
2. 그룹째 옮기기(폴더 머리를 끌어 순서 바꾸기)가 필요한가? (v1 제외 가정. 필요하면 `moveGroupBlock` + `ContiGroupDrag` 추가.)
3. 항목 여러 개를 한꺼번에 그룹에 넣기(다중 선택 끌기)가 필요한가? 현재 편집 탭 목록엔 다중 선택이 없다 → v1 한 개씩. 번호 범위 지정이 그 역할을 이미 한다.
4. `ItemGroupChip` 을 트리 안에서 유지 / 숨김 / 그룹 밖 항목만 표시.
5. 성경 절 끌기 방식: 절 줄 왼쪽 grab 아이콘 vs 길게 눌러 끌기(체크박스 탭과의 충돌 때문).
6. 발표 보기에서 그룹 접기 필요? (안전상 비추천.)
7. 요구 3 의미: 본문 역본 교체(위 설계)인지, 항목마다 다른 보조 역본인지.

## 4. 위험
- R1. **ReorderableListView 제거 회귀**: 재정렬(손잡이), 스크롤 중 자동 스크롤(`_EdgeAutoScroll` 같은 것 필요 — 목록이 길면 그룹 밖으로 끌기가 힘듦), 포커스·`ValueKey(uid)`. 위젯 테스트 필수. 대안(비추천): ReorderableListView 를 두고 `onReorder` 새 인덱스만 쓰는 방식 — 그룹 경계 모호로 "그룹 끝에 넣기"가 불가능해서 기각.
- R2. **발표 중 편집 탭 삽입/이동 시 `_currentSlideIndex` 어긋남**(§2-2). 기존 `_onStagingReorder` 에도 있는 결함이라 이번에 같이 막지 않으면 "끌어 놓기가 쉬워지는 만큼" 사고 확률이 오른다. 발표 중 편집 탭 삽입을 막는 대신(예: `_newConti` 방식) 키 재탐색을 택하는 것을 추천.
- R3. 번호 의미: 번호 범위 지정(`_assignGroupRange`)은 전체 항목 번호 기준 — 접힌 그룹의 항목도 번호를 차지하므로 번호가 건너뛰어 보인다. 접힌 머리 행에 `3~5번` 범위를 표시.
- R4. 중첩 `DragTarget<PraiseSong>`(패널 전체 + 행)에서 어느 쪽이 받는지 — 미확인. 패널 전체 타깃의 "후보 있음" 테두리(7508)가 행 위에서도 깜박일 수 있어 정리 필요.
- R5. `_noSpacerUids` 정리: 중간에 넣거나 옮길 때 앞 항목의 '여백 없음' 표시를 지우는 규칙(`_onStagingReorder` 의 한 줄)을 모든 새 경로가 같게 따라야 한다. 빠뜨리면 항목 사이 자동 여백이 사라지거나 중복.
- R6. 성경 드롭의 비동기: 놓은 뒤 DB 읽는 동안 사용자가 콘티를 또 바꿀 수 있음 → uid 앵커 + 소멸 시 맨 끝 폴백(§2-4).
- R7. 접기 키가 이름이라 이름이 같은 두 구간은 같이 접힘(감수). 그룹 이름 바꾸기 시 접기 집합도 옮긴다.
- R8. 7번 성경 역본 변경 시 길이가 달라져 글자 넘침 가능 → 기존 `overflowCounts` 경고가 그대로 뜬다(추가 작업 없음). 확인 필요(미확인: 실제 역본 간 길이 차).

## 5. 폰·네이티브·다른 담당 변경 필요 여부
- **필요 없음.** 그룹은 `SlidePageData`·`SingerViewData`·macOS/Windows 발표·싱어 창·휴대폰 HTML·Python(PPTX)에 실리지 않는다. 성경 역본 바꾸기는 항목 본문이 바뀔 뿐 `SlidePageData` 모양 그대로다(`_sendCurrentSlide` 가 처리). 백엔드(저장 형식·DB) 변경 없음 — 안 A 한정. (안 B 를 택하면 백엔드: 스키마 21·`.wsconti`·클라우드 콘티 형식 변경 필요.)
- 빌드 스크립트·`ppt_tool` 재빌드 불필요.

## 6. 테스트 항목
단위(순수 함수, `test/conti_tree_test.dart`):
- `contiRows`: 그룹 없음 / 이어진 같은 이름 한 구간 / 떨어진 같은 이름 두 구간 / 접힘 / 빈 그룹 / 항목 0개.
- `resolveDrop`: 항목 위·아래 절반, 그룹 마지막 항목 아래 절반 = 그룹 안, 다음 그룹 머리 위 절반 = 그룹 밖, 머리 아래 절반 = 그룹 맨 앞(접힘이면 맨 끝), 목록 끝.
- `_insertItemsAfterSlide` 규칙과 같은 결과인지(발표 보기 끌기와 트리 끌기 일관성) — 두 함수를 같은 입력으로 비교하는 테스트가 어렵다면 규칙 표를 주석 + 케이스로 고정.
- 성경 역본 바꾸기: 참조 풀기 실패·`mapBookName` null·일부 절 없음·새 역본 = 보조 역본일 때 sub 비움(가짜 `BibleRepository`, `test/bible_*` 패턴 참고).
위젯(`flutter test`):
- 항목을 그룹 머리 아래 절반에 끌어 놓으면 `_itemGroups` 에 그 이름이 들어가고 행이 들여써진다. 그룹 밖 위 절반에 끌면 이름이 빠진다.
- 찬양 `Draggable<PraiseSong>` 을 행에 놓으면 그 자리에 담긴다 / 행 밖 빈 곳은 맨 끝 / 더블클릭은 여전히 맨 끝.
- 성경 절(체크 여러 개)을 끌어 그룹 안에 놓으면 페이지 수만큼 들어가고 스낵바 문구가 맞다 / '담기' 버튼은 맨 끝.
- 접기·펼치기, 접힌 그룹 머리 행 `N개`, 번호가 전체 번호 유지.
- 기존 `thumb_click_test.dart` 가 안 깨지는지(발표 보기 쪽 제스처 무변화), `slide_group_test.dart` 그대로 통과.
- 발표 중(관객 창 열림 흉내) 중간 삽입 뒤 `_currentSlideIndex` 가 같은 슬라이드를 가리키는지 — home 전체 위젯 테스트가 어려우면 키 재탐색 함수를 순수 함수로 빼서 단위 테스트.
회귀: `flutter analyze`, `flutter test`(특히 `conti_group_test`·`conti_append_test`·`move_pages_test`·`slide_group_test`·`thumb_click_test`).
수동(미확인으로 남을 것): 실제 마우스로 긴 목록 가장자리 자동 스크롤, 발표 중 편집 탭 끌기, 두 모니터에서 관객 화면 유지.

## 7. 작업량·순서 제안
1) `conti_tree.dart` + 테스트 → 2) `_placeStaging`/`_insertNewItems` + 찬양 행 드롭(기존 Draggable 재사용) → 3) 목록 위젯 교체(헤더·접기·들여쓰기) → 4) 성경 끌기 → 5) 역본 바꾸기(독립이라 먼저/나중 아무 때나 가능, 병행 가능). 2~4 가 같은 파일(home)·같은 위젯이라 한 사람이 순서대로 하는 편이 충돌이 적다.
