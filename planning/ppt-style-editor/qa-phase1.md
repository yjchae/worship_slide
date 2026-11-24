# QA 1회차 — 1단계 구현 (캔버스 안 편집 · 리본 · 여러 개 고르기)

검토: QA · 2026-11-24 · 대상: 커밋 안 된 작업 트리(git diff) · 기준: decisions.md · plan.md 1단계 수용 기준 · design.md · qa-review.md
소스는 고치지 않았다. '코드 확인' = 소스를 읽고 판단함(실제 키 입력·IME 는 실행 못 함).

## 판정: 반려 (차단 0 · 주요 1 · 경미 4)

자동 검사는 모두 통과했다. 반려 이유는 하나 — '상자 고른 채 글자 키 = 편집 시작 + 덧붙임'이 한글 입력기에서 첫 글자를 깨뜨린다(아래 1).

## 수용 기준 (plan 1단계, decisions 2 로 고친 것 포함)
- [x] 더블클릭 = 그 자리 커서, 친 글이 캔버스 위 실제 글꼴·크기·색, 오른쪽 패널에 글 칸 없음 — page_editor_test '더블클릭 = 그 자리 편집…', `PageCanvas(editingId:, editor:)` page_canvas.dart:106-111
- [x] '글 상자' 넣으면 바로 입력 — `_addTextBox` → `_startEdit` page_editor_dialog.dart:868-873, 테스트 '새 페이지: 제목 글 상자를 바로 고치고…'
- [x] 편집 중 Delete·Backspace 는 글자만, Esc 1회 = 편집 끝(고른 채), 2회 = 해제, 3회 = 닫기 흐름 — Quill `_ExitIntent` page_text_editor.dart:131-136 → `_exitEdit`; `_onKey` page_editor_dialog.dart:1053-1067(inText 면 Delete·방향키 무시), 테스트로 확인
- [x] 편집 중 ⌘/Ctrl+D 무시(handled, 복제 안 함) page_editor_dialog.dart:1014-1016, ⌘[ ] 무시 :1040-1041, ⌘V 는 편집기로 :1010
- [x] 편집 중과 아닐 때 줄바꿈·줄 수 같음(24·40·96pt × Pretendard·나눔명조 × 정렬 × 목록) — 새 test/page_text_layout_test.dart 1px 안으로 통과
- [x] 구운 PNG = 캔버스 줄바꿈 — 굽기도 같은 `PageTextBlock`(page_canvas.dart:111), 기존 굽기 테스트 통과
- [x] 글자 일부 굵게 = 그 글자만 / 상자만 고르고 굵게 = 상자 bold=true + Delta 에 bold 없음 — `applyBoxFormat` page_rich_text.dart:666-705, `_format` page_editor_dialog.dart:665-678, 테스트 2개
- [x] 리본 글꼴·크기·색 = 커서·고른 글자 값, 섞이면 빈칸 — `pageTextFormatOf` page_rich_text.dart:616-642, `FontFamilyPicker(selected: null)` style_fields.dart:762
- [x] 편집 한 번 = 창 되돌리기 한 묶음, 편집 중 ⌘Z 는 Quill 글자 단위(결정 1) — `_editSession` :511-516·534·569, 테스트 '편집 중 되돌리기는 글자 단위…'
- [x] Shift/⌘·Ctrl+클릭 3개 함께 끌기·Delete·⌘Z 한 번 복원, 손잡이는 하나일 때만 — `_startDrag` 기록 1회 :966-977, `_delete` :890-898, 테스트 'Shift+클릭으로 여러 개…' (⌘/Ctrl+클릭은 같은 코드 경로 :1577-1579, 테스트는 Shift 만)
- [x] (결정 2로 바뀐 기준) 옛 페이지 = 같은 모양(글머리 줄 제외) — `_renderVersion` 2 page_canvas.dart:127. 영향(코드 확인): 콘티가 가리키는 옛 PNG 는 그대로 쓰이고, 새로 굽는 곳은 PNG 가 없을 때 `_restoreFreePages`(praise_home_page.dart:3797)·편집 창 '확인'·항목 배경 바꾸기·틀 미리보기뿐. 옛 파일은 안 지운다. strut 도입으로 '상자보다 작은 글자만 있는 줄'은 줄 높이가 상자 기본 크기로 커진다 — CLAUDE.md 에 감수로 적혀 있음
- [x] 굽기에 Quill 위젯 의존 없음 — `PageTextBlock` 은 RichText 뿐, Localizations 불필요. page_rich_text.dart:5 가 `TextBlockUtils`(순수 정적 함수, 기호 칸 폭)만 가져온다
- [x] `PageUnknownElement` 보존 — 읽기 page_element.dart:63-74(모르는 글자 type → 날 JSON, rect 없어도 보존), 쓰기 `toJson() => raw` :296. 저장 경로 전체가 `SlideBackground.toJson/fromJson`(slide_background.dart:209·242)을 지나므로 DB 콘티·`.wsconti`(worship_conti_repository.dart `_backgroundPathSlots` :770 은 image 만 건드림)·틀(page_template_store.dart 같은 SlideBackground)에서 그대로 돌아간다. 편집 창: 그리지·고르지 않음(`_selectable` :473, 덮개 :1453, Tab 순환 :957), `_confirm` 이 빼지 않음 :1156-1159, 복제·삭제·순서는 고른 것만. 개수 표시: praise_home_page.dart:9134·page_template_dialog.dart:299 둘 다 `whereType<PageImageElement>` 라 '그림'으로 안 셈. 테스트 3곳(page_image·page_rich_text·page_editor '모르는 종류 요소는…')

## 결함
1. [주요] 상자 고른 채 글자 키 덧붙이기가 한글 입력기에서 첫 글자를 영문 자모로 넣거나 조합을 깨뜨린다
   - 재현(코드 확인, 실기 미확인): macOS 한글 2벌식, 글 상자 하나 고름(편집 아님) → '한' 입력(ㅎ=g 키)
   - 기대 / 실제: '한' 이 덧붙음 / 첫 키는 캔버스 Focus(입력기 연결 없음)가 받아 `event.character` 를 확정 글자로 바로 `replaceText` 한다. macOS 한글 입력기는 키보드 배치가 아니라 입력기라 이때 `character` 는 대개 라틴 'g' → 'g' + 'ㅏㄴ'(다음 키부터 Quill 이 조합). 'ㅎ' 이 오더라도 조합 밖 확정 글자라 'ㅎ'+'ㅏㄴ' 으로 갈라진다. Windows 는 IME 켜짐이면 VK_PROCESSKEY 로 오거나 라틴 글자가 올 수 있어 역시 맞지 않는다. 포커스 이동이 다음 프레임(:554 addPostFrameCallback)이라 빠르게 치면 둘째 키도 캔버스가 받을 수 있다. 현 테스트(:415)는 `keyX` 하나만 보내 IME 를 재현하지 못한다
   - 위치: `lib/src/features/praise/presentation/page_editor_dialog.dart:1101-1120`
   - 수정안: (가, 1단계 권장) 글자 키는 `_startEdit()` 만 하고 글자는 넣지 않는다(`KeyEventResult.handled`) — 결정 3 을 사실상 C 로 줄이고 상태 줄에 'Enter·더블클릭·글자 키: 편집 시작' 안내. 첫 키 하나를 잃지만 틀린 글자는 안 들어간다. (나, 이후) 글 상자 하나를 고른 동안 캔버스 대신 화면 밖 1px `EditableText`(또는 `TextInput.attach`)에 포커스를 둬 IME 를 붙여 두고, 첫 `TextEditingValue`(조합 포함)가 오면 `_startEdit()` 후 그 글·composing 범위를 Quill 로 넘긴다. (가)를 고르면 '키 문자가 ASCII 면 덧붙이기' 같은 절충은 쓰지 말 것 — 한글 입력기 상태의 'g' 도 ASCII 다
2. [경미] Esc·방향키를 한글 조합 중에 누를 때 조합 글자 처리(확정/버림)와 후보 창 위치 미확인 — Quill `customShortcuts` Esc 가 먼저 잡는다(page_text_editor.dart:131-136). 사람이 macOS·Windows 에서 확인 필요(qa-review 1단계 사람 확인 항목 그대로)
3. [경미] `PageUnknownElement.toJson()` 이 내부 맵 `raw` 를 그대로 돌려주고, `raw` 는 얕은 복사라 중첩 맵을 원본 JSON 과 공유한다 — 받는 쪽이 고치면 요소 값이 바뀐다(지금 그런 쓰는 곳은 없음). 위치: page_element.dart:73·296. `toJson` 에서 `jsonDecode(jsonEncode(raw))` 또는 깊은 복사 권장
4. [경미] `.wsconti` 경로 칸이 `type == 'image'` 만 실어(worship_conti_repository.dart:775) 앞으로 경로를 가진 새 type 이 생기면 그 경로는 보낸 PC 로컬 경로 그대로 받는 PC 에 남는다(CLAUDE.md '담기지 않은 경로는 버린다' 원칙과 어긋남). 2단계 도형은 경로가 없어 지금은 영향 없음 — 경로 있는 type 을 더할 때 이 함수도 같이
5. [경미] ⌘/Ctrl+클릭 여러 개 고르기는 위젯 테스트가 없다(Shift 만). 같은 분기(:1577-1579)라 위험은 낮다

## 실행한 확인
- `flutter analyze` → No issues found
- `flutter test`(전체) → All tests passed! (+793)
- 코드 대조: 위 각 줄의 `파일:줄`. `grep PageUnknownElement|pageTextSpan|whereType<Page` 로 남은 호출·개수 문구 확인(pageTextSpan 호출 남은 곳 없음)
- 실행 못 한 것: 실제 한글 IME 입력(macOS·Windows), 트랙패드 테두리 띠 끌기, 옛 PNG 와 v2 PNG 육안 비교
