# QA 1회차 — 글 상자 부분 서식 (flutter_quill)

검토일 2026-11-15. 대상: 미커밋 변경 전체(`git diff` + `page_rich_text.dart`, `page_rich_text_test.dart`). 소스·테스트는 고치지 않았다.
기획자 문서 파일은 없어 요청에 적힌 수용 기준 요약을 기준으로 삼았다. 디자인(`design.md`)·프론트(`tech-frontend.md`)는 읽었다.
임시 재현 테스트는 레포 `test/zz_qa_probe_test.dart` 로 만들어 돌린 뒤 지웠다(`git status` 에 남은 것 없음).

## 판정: 반려 (치명 0 · 높음 2 · 보통 5 · 낮음 4)

## 1. 직접 실행한 결과

| 명령 | 결과 |
|---|---|
| `flutter analyze` | 1건: `test/page_editor_test.dart:414:69` warning `invalid_null_aware_operator`(`focusNode?.hasFocus` — `QuillEditor.focusNode` 가 null 아님). lib 쪽은 0건 |
| `flutter test` (전체) | `+588: All tests passed!` (약 20초). 스킵·실패 없음 |

두 명령이 통과해도 아래 결함은 기존 테스트가 하나도 잡지 못한다(테스트가 6자리 색·한 상자·서식 후 되돌리기 없음만 다룬다).

## 2. 프론트 문서가 주장한 버그 3건 — 직접 재현

| 주장 | 판정 | 재현 근거(실제 출력) |
|---|---|---|
| B2 Quill 8자리 색 `#FFFF0000` 이 `tryParseHexColor` 에서 null | **사실** | `pageTextSpan` 에 `color:'#FFFF0000'` → `style.color == null`. 실제 Quill `formatSelection(ColorAttribute('#FFFF0000'))` 이 델타에 `{"color":"#FFFF0000"}` 를 넣는 것도 확인. 근원: `color_button.dart:190-193` 가 `'#'+AARRGGBB`. 정규식은 `^[0-9A-F]{6}$`(`export_style.dart:3`) |
| B1 `_loadQuill` 조기 반환 때문에 되돌리기 후 옛 서식 잔존 | **사실** | 창에서 '안녕' 첫 글자 굵게 → 툴바 '되돌리기' 버튼. 요소는 `rich=null` 로 돌아갔지만 Quill 은 `[{"insert":"안","attributes":{"bold":true}},{"insert":"녕\n"}]` 그대로(입력칸 굵게, 캔버스 평문). 이 상태로 '확인' → 저장은 `rich=null`(입력칸과 어긋남). 여기서 한 글자 더 치면 굵게가 되살아난다(프론트 보고 — 이번엔 타이핑 재현은 안 했고 위 상태 불일치만 직접 확인) |
| B3 `Document()..insert` 가 Quill undo 기록에 남아 Ctrl+Z 로 불러온 글이 지워짐 | **사실** | 독립 컨트롤러: 문서 교체 직후 `hasUndo == true`, `undo()` 한 번에 `[{"insert":"\n"}]`. `Document.fromJson` 으로 만들면 `hasUndo == false`. 창 안(`PageEditorDialog`)에서도 열자마자 `hasUndo == true`, '!' 입력 후 undo 2번 → 문서 빔 |

추가 재현:
- 평문 상자를 열어 글만 고치고 확인 → `rich == null`(통과).
- 굵게를 입혔다가 같은 범위에서 굵게 해제 → 확인 시 `rich == null`(통과, `hasFormat` 이 속성 유무로 판정).
- **상자 바꿔 고르기 누수(B1 의 자매 경로)**: 상자 A(굵게 rich)→상자 B(평문이 같고 rich 없음) 시나리오는 위젯 테스트에서 캔버스 탭·Tab 으로 선택을 못 옮겨 **직접 재현 못 함**(탭은 반응 없음, Esc 도 글 포커스를 못 벗어남 → 아래 결함 5). 다만 `_loadQuill` 이 B1 과 같은 분기(`plain == e.text && e.rich == null` → return)이므로 코드상 확정이다. 선택 전환 수용 기준은 **미확인(코드상 실패)**.

## 3. 수용 기준 판정

| 수용 기준 | 판정 | 근거 |
|---|---|---|
| 평문 상자를 열어 글만 고치면 rich 안 생김 | 통과 | 위젯 재현: 글 교체 후 확인 → `rich == null`. `hasFormat` 기준 코드도 일치 |
| 부분 서식이 구운 PNG 에 반영 | **실패(부분)** | 굵게·기울임·밑줄·취소선·크기는 `pageTextSpan` 단위 테스트로 확인. **색은 Quill 이 8자리를 써서 무시됨(B2)**. 실제 PNG 픽셀 검증·`compose` 통합 테스트는 없음(미확인) |
| 글머리·번호 일치 | 부분 통과 | `pageTextSpan` 의 `• `/`N. ` 는 단위 테스트 통과. 입력칸(Quill 들여쓴 목록 모양)과 슬라이드(평문 접두)는 모양이 다르고 마커가 줄 서식·내어쓰기를 안 따름(프론트 R6) — "일치"의 해석에 따라 미달 |
| 서식 모두 지우면 rich 사라짐 | 통과 | 위젯 재현(굵게 후 해제 → null) |
| 깨진 rich 는 평문 | 통과 | `page_rich_text_test` 깨진 rich 테스트 + 창 쪽 `_loadQuill` catch(코드). 단 창에서 깨진 rich 를 열 때의 위젯 테스트는 없음 |
| 넘침 측정 일치 | 통과(코드) | `_textOverflows` 가 `pageTextSpan(e, PageCanvas.fontScale)` 로 캔버스와 같은 스팬을 씀. 서식 상자 넘침 위젯 테스트는 없음 |
| 서식만 입힌 변경을 창 되돌리기로 취소하면 입력칸·캔버스 모두 서식 없음 | **실패** | B1 재현. 캔버스는 평문, 입력칸은 굵게로 남음 |
| 상자 선택 바꾸면 입력칸에 그 상자 글·서식, 이전 글 안 섞임 | **실패(코드상)** | 위 누수 경로. 서식이 다른 상자끼리 전환은 `_loadQuill` 이 문서를 새로 갈므로 정상, **평문이 같고 rich 만 다른** 경우만 샌다. 직접 재현은 못 함 |
| 콘티 저장·불러오기·.wsconti·클라우드·페이지 틀 복사에서 rich 유지 | 부분 통과(미실행) | `toJson`/`fromJson` 왕복 단위 테스트 통과. `page_elements` JSON 에 `rich` 문자열이 실리고 `_backgroundPathSlots` 는 image 의 path 만 건드림(코드). 실제 DB 저장·.wsconti·클라우드·틀 복사 실행은 안 함. `_duplicate`(`copyWith`)는 rich 를 유지 |
| analyze·test 통과 | 부분 통과 | test 588개 전부 통과. analyze 는 test 파일 warning 1건(새로 생긴 것) |
| THIRD_PARTY_NOTICES·CLAUDE.md 갱신 | 부분 통과 | flutter_quill 한 줄, CLAUDE.md 글 상자 부분 서식 항목 추가됨. 전이 의존성 미기재(`url_launcher`·`quill_native_bridge`·`flutter_colorpicker`·`dart_quill_delta` 등), CLAUDE.md '주요 명령어' 목록에 `test/page_rich_text_test.dart` 없음, 파일 목록 트리에 `page_rich_text.dart` 없음 |

## 4. 문서 사이 모순·빠진 경로

1. **디자인 문서는 거의 구현되지 않았다.** 프론트 변경에는 없는 것: 소제목 '고른 글자'/'상자 전체 기본값', '모두 기본값으로' 안내 줄, 입력칸에 상자 글꼴·색·배경색 적용, 크기 축소 미리보기, 크기 칸 실제 값·'기본값으로' 항목, placeholder '글을 입력하세요'(코드는 `'글'`), 입력칸 높이 120~220 가변(코드는 150 고정), 캡션. 기획 수용 기준에는 이 항목들이 없어서 반려 사유는 아니지만, 디자인이 "추천"으로 못 박은 것이 빠졌는지 정리가 필요하다(결정 필요 1~7번이 닫히지 않았다).
2. **되돌리기 버튼 중복.** 디자인은 결정 7 로 Quill 툴바 되돌리기·다시 실행 제거를 추천했는데 코드는 `showUndo`/`showRedo` 를 끄지 않아 기본값(켜짐)이다. 프론트 문서는 이 두 버튼을 다루지 않고 "대화 상자 undo" 만 다룬다. 입력칸에 포커스가 있으면 Cmd+Z 는 Quill 이, 툴바 상단 버튼은 대화 상자가 받아 스택이 둘이다.
3. **bold 해제.** 디자인은 `bold:false` 를 읽도록 렌더러 변경이 필요하다고 했는데 `_inlineStyle` 은 `true` 만 읽는다. 상자 기본이 굵게인 글 상자에서 일부 글자만 굵기를 풀 방법이 없다(툴바에서 눌러도 표시만 바뀌고 슬라이드는 그대로).
4. **디자인 vs 프론트의 사실 차이**: 디자인은 Quill 한국어 툴팁이 나오는지 "미확인"이라 했고 프론트는 `quill_localizations_ko.dart` 가 있다고 했다. 둘 다 실제 화면에서는 안 봤다. 디자인이 말한 Quill 기본 글자 크기도 문서마다 다름(기획 14px/디자인 16px) — 실제 렌더 미확인.
5. **프론트 문서의 `Esc` 서술 불일치.** 프론트는 "Esc 는 입력칸 → 캔버스 포커스(기존 동일)"라고 썼지만 위젯 테스트에서 글 칸 포커스 상태로 Esc 를 보내도 포커스가 `page-editor-text` 에 남았다(아래 결함 5).
6. **빠진 경로**: 기획 수용 기준의 "콘티 저장·불러오기·.wsconti·클라우드·페이지 틀" 은 테스트가 JSON 왕복 한 군데뿐. 창 안 되돌리기·다시 하기·상자 전환·붙여넣기(클립보드 글로 새 상자) 테스트가 없다.

## 5. 결함

1. [높음] 색 선택이 슬라이드에 반영되지 않는다 (B2)
   - 재현: 글 일부를 고르고 툴바 색 버튼으로 아무 색이나 고름 → Quill 이 `#AARRGGBB`(예 `#FFFF0000`) 저장.
   - 기대 / 실제: 캔버스·구운 PNG 에 그 색 / `tryParseHexColor` 가 null 을 돌려 기본 상자 색으로 나옴. 입력칸(Quill 이 직접 그림)과 슬라이드가 다르다. 기존 테스트는 6자리 `#ff0000` 만 써서 못 잡음.
   - 위치: `lib/src/features/praise/presentation/page_rich_text.dart:79`, `lib/src/features/praise/domain/export_style.dart:3,8-13`
2. [높음] 창 되돌리기·다시 하기·상자 전환 뒤 Quill 에 옛 서식이 남는다 (B1)
   - 재현: 글 상자 '안녕' → 첫 글자 굵게 → 툴바 '되돌리기'.
   - 기대 / 실제: 입력칸·캔버스 모두 서식 없음 / 요소는 `rich=null`, Quill 은 굵게 그대로. 이어 입력하면 되살아나 저장, 평문이 같고 rich 가 없는 다른 상자를 고를 때도 같은 분기를 지나 서식이 샌다.
   - 위치: `page_editor_dialog.dart:479-485`(`_loadQuill` 의 `e.rich == null ||` 조건)
3. [보통] Quill Ctrl+Z 가 불러온 글까지 지운다 (B3)
   - 재현: 글 상자를 열자마자(또는 글 입력 후) 입력칸에서 Cmd/Ctrl+Z 반복.
   - 기대 / 실제: 사용자가 친 것만 되돌아감(예전 TextField 동작) / `Document()..insert` 가 기록에 남아 `hasUndo == true`, 문서가 비고 `_onQuillChanged` 로 상자 글이 빈 값으로 저장됨. 창 되돌리기로 복구는 가능하나 놀랄 동작.
   - 위치: `page_editor_dialog.dart:488,491`
4. [보통] 테스트가 핵심 경로를 못 잡는다
   - 없는 테스트: 8자리 색, 서식 입힘→`rich` 생김, 서식 해제→null, 창 되돌리기 후 상태, 서로 다른 rich 상자 전환, 깨진 rich 로 창 열기, Quill Ctrl+Z, 서식 상자 `toJson` 이 `SlideBackground`·`.wsconti` 를 지나는지. 기존 `page_editor_test` 는 `QuillController.replaceText` 로 글만 바꾼다.
   - 위치: `test/page_rich_text_test.dart`, `test/page_editor_test.dart`
5. [보통] 글 칸에서 Esc 로 캔버스 포커스로 못 나온다 (관찰, 실기기 미확인)
   - 재현: 새 페이지로 열어 글 칸 포커스 → `sendKeyEvent(escape)` → 포커스 라벨이 계속 `page-editor-text`. 이어 Tab 도 상자를 안 넘김.
   - 기대 / 실제: 기존 TextField 는 Esc 로 캔버스 포커스 이동(`_onKey` 의 `inText` 분기) / Quill 이 키를 먼저 받아 `_onKey` 에 안 닿는 것으로 보임. 위젯 테스트 환경 한계일 수 있어 실제 macOS 키보드로 확인 필요. 맞다면 키보드만으로 글 칸을 빠져나오지 못하고 Tab 으로 상자 전환·화살표 이동도 못 쓴다.
   - 위치: `page_editor_dialog.dart:_onKey`(Esc 분기 ~745), `_inTextField`(429)
6. [보통] 붙여넣기로 들어오는 서식·embed 는 막지 않는다 (프론트 R3, 미확인)
   - 웹·워드 복사 시 배경색·링크·헤더·이미지 embed 가 입력칸에는 보이고 슬라이드에는 안 보이거나 `text` 에 `￼` 가 섞일 수 있다. 실제 붙여넣기로 확인 안 함.
   - 위치: `page_editor_dialog.dart` `QuillEditor.basic(config: const QuillEditorConfig(placeholder: '글'))`
7. [보통] 빌드 산출물·의존성 정합
   - `macos/Podfile.lock` 이 갱신되지 않음(`quill_native_bridge_macos`·`url_launcher_macos` 가 빠짐). 레지스트리 생성물 6개(linux·windows 포함)와 `pubspec.lock` 의 Flutter 하한 `>=3.44.0` 상향이 커밋 범위 결정 없이 섞여 있다. Windows 의 `file_selector_windows`·`url_launcher_windows` 네이티브 플러그인이 새로 붙었다. Windows·macOS 실제 빌드는 이 환경에서 확인 불가(CI 필요).
8. [낮음] `analyze` warning: `test/page_editor_test.dart:414` 의 `focusNode?.hasFocus` → `.`
9. [낮음] Quill 툴바에 되돌리기·다시 실행 버튼이 남아 대화 상자 되돌리기 버튼과 이중 (모순 2)
10. [낮음] `THIRD_PARTY_NOTICES.md` 에 전이 의존성 미기재, CLAUDE.md 의 '주요 명령어' 목록·파일 트리에 새 테스트·`page_rich_text.dart` 없음
11. [낮음] 입력칸이 슬라이드 크기·글꼴·색·정렬을 반영하지 않음(프론트 R1, 디자인 문제 2) — 크기 120 을 주면 입력칸(약 230x132)이 넘침. 빈 글머리 줄이 `text` 는 비었는데 캔버스에 `• ` 가 보임(R5). 마커가 줄 서식을 안 따름(R6).

## 6. 고쳐야 할 것 우선순위

1. 색 8자리 파싱(`pageTextSpan` 쪽에서 `#`·알파 처리, `tryParseHexColor` 는 다른 곳이 써서 그대로) + 8자리 색 테스트. (결함 1)
2. `_loadQuill` 비교식을 "평문 같음 && (Quill 에 서식이 있으면 그 JSON, 없으면 null) == e.rich" 로 바꾸고 `_onQuillChanged` 와 같은 계산 함수를 공유. 서식 후 창 되돌리기·rich 상자 간 전환 위젯 테스트 추가. (결함 2·4)
3. 문서 만들 때 `Document.fromJson([{'insert': '$text\n'}])` 로(또는 교체 직후 `history.clear()`), Ctrl+Z 테스트. (결함 3)
4. 글 칸 Esc·Tab 이 실제 앱에서 동작하는지 실기기 확인 후 필요하면 Quill 의 키 처리와 `_onKey` 를 이어 준다. (결함 5)
5. 붙여넣기 정책(평문만 받거나 허용 속성만 남기기) 결정. (결함 6)
6. 디자인 결정 7(Quill 되돌리기 버튼 제거)·3(bold 해제 렌더)·소제목 등 디자인 문서 항목을 이번 범위에 넣을지 기획자가 못 박기. (모순 1~3)
7. Podfile.lock·생성물·`pubspec.lock` 하한 커밋 범위 정리, THIRD_PARTY_NOTICES 전이 의존성·CLAUDE.md 명령 목록 보강, test warning 1건 정리. (결함 7~10)
8. 실제 앱에서 한글 IME 조합·macOS 단축키(Cmd+B/I/U)·콘티 저장→불러오기→.wsconti 왕복·PNG 결과는 사람이 확인(이 QA 에서 미확인).
