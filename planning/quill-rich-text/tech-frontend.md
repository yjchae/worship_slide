# 슬라이드 편집 글 상자 부분 서식 (flutter_quill) — 프론트엔드 코드 검토

검토 대상: 미커밋 변경 전부(`git diff` + `page_rich_text.dart`, `page_rich_text_test.dart`). 소스·테스트는 고치지 않았다.
확인 방법: 코드 읽기 + 레포 밖 임시 프로젝트(`scratchpad/probe`, 레포를 path 의존성으로 건 위젯 테스트)로 실제 실행.
기존 `flutter test test/page_rich_text_test.dart test/page_editor_test.dart test/page_image_test.dart` 28개 통과, `flutter analyze` 변경 4파일 이슈 없음.
표기: **확인** = 실행·소스로 확인, **미확인** = 코드상 추정이거나 실행 못 함.

## 1. 변경점

| 파일 | 함수·위치 | 내용 |
|---|---|---|
| `lib/.../domain/page_element.dart` | `PageTextElement.rich` (신규 필드, ~166-175) | Delta ops JSON **문자열**(없으면 null). `text`(평문)는 따로 유지 |
| 〃 | `copyWith(rich: _keep)` | 센티널로 "안 넘기면 유지 / null 넘기면 지움" |
| 〃 | `toJson` `'rich': ?rich`, `fromJson` | null 이면 키 생략, 빈 문자열·문자열 아님은 null 로 읽음. `==`·`hashCode` 에 rich 포함 |
| `lib/.../presentation/page_rich_text.dart` (신규) | `pageTextSpan(e, fontScale)` | 편집 창 미리보기·굽기·넘침 측정 공용 TextSpan. rich 없으면 예전 평문 1덩이, 깨진 JSON 은 평문 폴백 |
| 〃 | `_richChildren` | Delta 를 `\n` 으로 줄을 나눠 span 구성, bullet(`• `)·ordered(`N. `) 접두 |
| 〃 | `_inlineStyle` | bold·italic·underline·strike·color·size(pt, 540pt 기준 → ×fontScale) |
| `lib/.../presentation/page_canvas.dart` | `_text` | `Text` → `Text.rich(pageTextSpan(...))`. 굽기 캐시 키는 `e.toJson()` 을 쓰므로 rich 자동 포함 |
| `lib/.../presentation/page_editor_dialog.dart` | `_quill`, `_syncingQuill` (298-299) | `_textController` 를 `QuillController.basic()` 로 교체 |
| 〃 | `_loadQuill` (479), `_onQuillChanged` (498), `_syncFields` (461), `_focusText` (469) | 선택 글 상자 ↔ Quill 문서 동기화, 변경 시 `_replaceInSession(copyWith(text: 평문, rich: 서식 있으면 JSON))` |
| 〃 | `_inTextField` (429) | `_textFocus.hasFocus ||` 추가 (Quill 은 `EditableText` 가 아니라서 필요) |
| 〃 | `_textProperties` (~1448) | `TextField` → `QuillSimpleToolbar`(굵게·기울임·밑줄·취소선·색·크기·글머리·번호·서식 지우기) + `QuillEditor.basic`(높이 150, `_textFocus`) + 안내 문구 |
| 〃 | `_textOverflows` (1677) | `pageTextSpan` 으로 측정 |
| 〃 | 파일 끝 `trimRightNewline` extension | Quill 평문 끝 `\n` 하나 제거 |
| `pubspec.yaml` / `pubspec.lock` | `flutter_quill: ^11.6.0` | 전이 의존성 약 25개, lock 의 flutter 하한 `>=3.38.4` → `>=3.44.0` |
| 생성 레지스트리 6개, `THIRD_PARTY_NOTICES.md` | — | 아래 9번 |
| `test/page_editor_test.dart` | 글 칸 접근을 `QuillEditor.controller` 로 | |
| `test/page_rich_text_test.dart` (신규) | JSON 왕복·서식·번호·깨진 rich | |

## 2. 실제 버그

### B1. 편집 창 되돌리기·다시 하기 뒤 Quill 이 옛 서식을 그대로 보이고, 다음 입력 때 되살려 저장한다 — 확인 (높음)
- `page_editor_dialog.dart:480-484` `_loadQuill` 의 "이미 같으면 그대로" 조건: `plain == e.text && (e.rich == null || e.rich == jsonEncode(Quill 델타))`.
  `e.rich == null` 이면 Quill 문서에 서식이 있어도 **무조건 return** 한다.
- 시나리오(위젯 테스트 재현): 글 상자 "안녕" 선택 → 첫 글자 굵게(`_history` 에 기록, rich 생김) → 툴바 '되돌리기' → 요소는 `rich=null` 로 돌아갔지만 Quill 은 `[{"insert":"안","attributes":{"bold":true}},{"insert":"녕\n"}]` 그대로.
  이어서 "!" 를 치고 확인하면 저장된 요소 rich 는 `…굵게 안…녕!` — 되돌린 굵게가 되살아난다. 캔버스 미리보기(평문)와 입력칸(굵게)이 서로 다르게 보이는 상태도 생긴다.
- 같은 원인으로 다른 상자를 고를 때도 새는 경로가 코드상 있다(`_select` → `_syncFields` → `_loadQuill`): 서식 있는 상자 A 에서 **평문이 같고 rich 가 null 인** 상자 B 를 고르면 early-return 해서 B 입력칸에 A 의 서식이 보이고, B 를 고치면 그 서식이 B 에 저장된다.
  이 B 경로는 위젯 테스트에서 캔버스 탭으로 상자를 못 골라 **미확인**(코드상으로만).
- 고칠 방향: 조건을 "평문 같음 && (Quill 에 서식 있으면 그 JSON, 없으면 null) == e.rich" 로 비교(= `_onQuillChanged` 의 `rich` 계산을 함수로 빼서 공유).

### B2. 색을 고르면 슬라이드에는 색이 안 나온다 — 확인 (높음)
- flutter_quill 색 선택(`color_button.dart:190-193`)은 `#AARRGGBB`(8자리, 예 `#FFFF0000`)로 저장한다. `page_rich_text.dart:79` 가 쓰는 `tryParseHexColor`(`export_style.dart:3,8-13`)는 정규식 `^[0-9A-F]{6}$` 라 8자리를 받지 못해 **null → 색이 조용히 무시된다**.
- 실행 결과: `pageTextSpan` 에 `#FFFF0000` 넣으면 `style.color == null`. `ColorAttribute('#FFFF0000')` 이 델타에 그대로 들어가는 것도 확인.
- 그래서 편집 창 입력칸(Quill 이 직접 그림)에는 빨강, 캔버스·굽기 결과에는 상자 기본색. 기존 테스트는 `'#ff0000'`(6자리)만 써서 통과한다.
- 고칠 방향: `pageTextSpan` 쪽에서 `#`·공백 떼고 8자리면 알파 포함으로 파싱(6자리도 유지). `tryParseHexColor` 는 다른 곳이 쓰므로 건드리지 말 것. 8자리 색 테스트 추가.

### B3. Quill 자체 되돌리기(Cmd/Ctrl+Z)가 글 상자를 불러오기 이전까지 지울 수 있다 — 확인 (중간)
- `_loadQuill` 이 `Document()..insert(0, e.text)` (page_editor_dialog.dart:488, 491)로 문서를 만들면 그 삽입이 Quill 문서 기록(history)에 들어간다. 글에 포커스를 두고 Ctrl+Z 를 누르면 사용자가 친 것뿐 아니라 **불러온 원래 글까지** 되돌려져 문서가 `[{"insert":"\n"}]` 로 비었다(테스트: 입력 직후 Ctrl+Z → 빈 문서; 400ms 병합 때문에 실제 타이밍에선 몇 번 눌러야 나오지만 도달 가능).
  결과는 `_onQuillChanged` 로 상자 글이 비게 저장된다.
- 이전 `TextField` 는 프로그램이 넣은 초기 글을 되돌리지 않았다. 퇴보다.
- 고칠 방향: `Document.fromJson([{'insert': '$text\n'}])` 로 만들거나 문서 교체 뒤 `_quill.document.history.clear()`.

### B4. 대화 상자의 `_history` 와 Quill 내부 undo 의 관계 (되돌리기/다시하기 충돌 여부) — 확인
- 글에 포커스가 있으면 `_inTextField` 가 true → `_onKey` (page_editor_dialog.dart:706-731)가 Ctrl/Cmd+Z·Y 를 `ignored` 로 넘기고 Quill 의 단축키가 처리한다. 이 undo 도 문서를 바꾸므로 `_onQuillChanged` → `_replaceInSession`(같은 묶음이면 기록 안 함)으로 요소에 반영된다. **키로는 두 스택이 겹치지 않는다**(테스트: 글에 포커스 두고 Ctrl+Z → 대화 상자 undo 는 안 돌았고 Quill 만 되돌아감, Delete 도 상자를 안 지움).
- 겹치는 곳은 **툴바의 대화 상자 되돌리기 버튼**과 B1·B3: 버튼은 `_applyHistory`(679) → `_syncFields` → `_loadQuill` 인데 위 B1 의 early-return 이 있고, 문서를 새로 갈면 Quill 쪽 기록은 초기화되므로(`document=` 세터가 새 `Document`) 그 뒤 Ctrl+Z 는 B3 로 이어진다.
- `_loadQuill`/`_onQuillChanged` 의 `_syncingQuill` 가드는 올바르게 동작: 문서를 교체하는 동안(`document=` 세터가 `notifyListeners`)은 `_onQuillChanged` 가 즉시 return 해서 다른 상자를 덮어쓰지 않는다(확인: 선택 변경·되돌리기에서 요소 목록이 의도 없이 바뀌지 않음, 기존 28개 테스트 통과). `_select` 가 `_editSession=false` 를 먼저 하므로 선택 전환 뒤 첫 입력은 새 기록 1건이 정상적으로 생긴다.
- `_focusText`(469)의 `updateSelection`(전체 선택)은 `_onQuillChanged` 를 부르지만 평문·rich 가 같아 return → 허위 기록 없음(확인).

## 3. 위험·미흡 (버그까지는 아니나 처리 필요)

- **R1. 입력칸이 슬라이드 크기를 반영하지 않는다 — 확인(실행)**. Quill 은 `size` 값을 논리 픽셀 그대로 그린다. 크기 120 을 준 글자는 입력칸(230x132)에서 문단 높이 276 이 되어 칸을 넘친다(툴바 크기 목록이 24~120). 미리보기 캔버스와 입력칸의 상대 크기가 다르다. 입력칸 글꼴·정렬도 상자 설정(`fontFamily`·`align`)을 안 따른다(Quill 기본 글꼴, 왼쪽). 안내 문구는 있지만 사용자가 크기를 입력칸에서 보고 고르기 어렵다.
- **R2. 텍스트 일치 가정이 깨지는 경로 — 미확인(코드상)**. `text` 와 `rich` 는 `_onQuillChanged` 한 곳에서만 같이 바뀌어 동기가 유지되지만 `copyWith(text: …)` 만 하면 rich 가 그대로 남아 **렌더는 rich 를 따른다**(`pageTextSpan` 은 rich 가 있으면 `text` 를 안 본다, page_rich_text.dart:21-27). 지금 레포 안에 그렇게 부르는 곳은 없다. 테스트가 이 동작을 명시(`copyWith(text:'x').rich` 유지)하고 있어 위험을 알고 있는 설계이나, 미래 수정에서 함정이다.
- **R3. 붙여넣기로 들어오는 서식 — 미확인(실행 못 함)**. `quill_native_bridge`(macOS 플러그인) 때문에 HTML 클립보드 붙여넣기가 켜진다. 웹·워드에서 복사하면 font·background·header·link·align·blockquote·이미지 embed 가 델타에 들어올 수 있다. `pageTextSpan` 은 인식 못하는 속성을 무시하지만 `text`(평문)에는 embed 가 `￼` 로 들어가 글 길이·`trim().isEmpty` 판정과 어긋날 수 있다. 입력칸에는 보이는데 슬라이드엔 안 보이는 속성이 생길 수 있다(배경색·링크 등). 실제 붙여넣기로 확인 필요. 막으려면 `QuillEditorConfig` 에서 붙여넣기를 평문으로 제한하거나 저장 때 허용 속성만 남기는 필터.
- **R4. 한글 IME 조합 — 미확인(실제 입력 필요)**. 코드상 `_onQuillChanged` 는 조합 중에도 문서가 바뀔 때마다 불리고(Quill 은 조합 글자도 문서에 넣는다) `_replaceInSession` → `setState` 로 대화 상자 전체가 다시 그려진다. `_loadQuill` 은 입력 중 호출되지 않아 조합을 끊지는 않을 것으로 보이나 실기기 확인 전엔 단정 못 함. 키 입력·커서 이동마다 `toDelta().toJson()` + `jsonEncode`(두 번)를 돌려 긴 글에서 비용이 있다(선택만 바뀌어도 불림).
- **R5. 빈 글 상자 판정과 마커 — 확인(코드)**. `_confirm`(826-830)·`_elementOverlay`(1169)는 `e.text.trim().isEmpty` 를 쓴다. 글머리/번호만 있고 글자가 없는 상자는 평문이 비어 확인 때 **빠지지만**, 편집 캔버스는 `pageTextSpan` 이 `• ` 를 그려 그 상자에 점이 보인 채 점선 '빈 상자' 표시와 겹친다. 평문과 `text` 는 항상 같은 값(`trimRightNewline`)이라 일치 자체는 문제없다: 끝 줄바꿈을 한 번만 떼므로 사용자가 끝에 친 빈 줄은 `text` 에 남고 `pageTextSpan` 도 그 빈 줄을 그린다(확인: `a\n\n` → text `a\n`, span `a\n`).
- **R6. 마커·줄 서식 — 확인(코드)**. 글머리/번호 마커는 줄 첫 글자 서식이 아니라 기본 스타일로 그려지고(굵게·색·크기 안 따름), 내어쓰기(줄바뀜 시 들여쓰기)가 없다. 줄 정렬은 상자 하나(Quill 정렬 버튼은 껐다)라 문제 없음. 서식 지우기(`showClearFormat`)는 글머리 줄 속성도 지운다. 번호 매기기는 `endLine` 에서 줄마다 갱신해 연속 ordered 줄만 1,2,3 … 이고 사이에 평문 줄이 끼면 1 부터 다시 시작 — Quill 입력칸과 같다. 들여쓰기(`indent`)는 툴바에서 껐으므로 번호가 중첩될 일은 없으나 붙여넣기로 들어오면 무시된다(R3).
- **R7. `size` 문자열 — 확인**: 툴바가 넣는 값은 double(`60.0`)이고 `_inlineStyle` 은 `'${a['size']}'` 를 `double.tryParse` 하므로 정상. `small/large/huge` 같은 이름 값은 무시(null). clamp 는 `PageTextElement.minFontSize..maxFontSize`. 툴바 크기 버튼에 현재 값 표시는 `items` 가 `'24'` 문자열이라 델타의 `24.0` 과 이름 매칭이 안 될 수 있다(미확인, 표시 문제뿐).

## 4. 요청한 항목별 결론

1. **되돌리기/선택 전환**: 위 B1·B3·B4. `_syncFields→_loadQuill` 은 가드(`_syncingQuill`) 덕에 `_onQuillChanged` 를 잘못 부르지 않고 다른 상자를 덮어쓰지 않는다(확인). 단 early-return 조건 때문에 **옛 서식이 남는** 문제가 있다.
2. **`_editSession`**: 글 포커스를 잃으면 리셋(332-334), `_select`·`_applyHistory` 에서도 리셋 — 한 번 타이핑 묶음이 기록 1건. 툴바 버튼을 눌러도 글 포커스가 유지돼(확인: 굵게 버튼을 눌러도 `focusNode.hasFocus == true`) 타이핑+서식이 한 묶음. 색 대화 상자를 열면 포커스가 빠져 묶음이 끊긴다(정상 범위). 크기 슬라이더와 `_editSession` 을 공유하는 점은 기존대로.
3. **단축키**: `_inTextField` 에 `_textFocus.hasFocus` 를 더한 것은 필요했고 올바르다(Quill 은 `EditableText` 가 아님). 글 포커스에서 Delete·Backspace·화살표·Space·Enter·Tab 은 `inText || !_canvasFocus.hasPrimaryFocus` 로 `ignored`(확인: Delete 로 상자 안 지워짐), Cmd+V·Z·Y·`[` `]` 는 `inText` 시 `ignored` 로 Quill 이 처리. **Cmd+D(복제)만 입력칸에서도 가로채는 기존 동작이 그대로**(page_editor_dialog.dart:720) — Quill 에는 Cmd+D 가 없어서 새로 생긴 충돌은 아님. Esc 는 입력칸 → 캔버스 포커스(기존 동일). macOS 에서 Cmd+B/I/U 는 Quill 단축키가 아래쪽에서 먼저 받으므로 `_onKey` 와 충돌 없음(Quill 기본 단축키; 실제 macOS 키 입력은 미확인 — 테스트 플랫폼이 macOS 가 아님, 위 Ctrl+Z 도 Ctrl 로 확인).
4. **캐시 키**: `_cacheKey` 가 `elements.map(toJson)` 을 해시하고 `toJson` 이 `rich` 를 싣는다(확인) → 서식을 바꾸면 PNG 도 새로 구워진다. 서식 없는 상자의 `toJson` 은 예전과 키 구성이 같아(rich 키 생략, `_renderVersion` 그대로) 기존 캐시가 유지된다. 평문 렌더가 `Text`→`Text.rich(TextSpan(text, style))` 로 바뀌었지만 같은 스타일 병합이라 결과는 같을 것으로 본다(픽셀 비교는 **미확인**).
5. **저장·왕복**: 확인(코드+단위 테스트) — `SlideBackground.pageElements` → `page_elements` JSON 에 `rich` 문자열이 그대로 실려 DB 항목 배경 JSON·`.wsconti`·클라우드 콘티·페이지 틀(`page_templates.json` 의 `design`)을 지나도 유지된다. `_backgroundPathSlots`(worship_conti_repository.dart:708)는 `type == 'image'` 의 `path` 만 건드려서 글 상자 rich 는 손대지 않는다. 틀 편집(`templateMode`)은 빈 글 상자도 `_elements` 그대로 남기므로 rich 도 같이 남는다. 옛 앱이 새 파일을 읽으면 `rich` 키를 무시하고 평문 `text` 로 보인다(하위 호환 OK). 반대로 서식 있는 상자를 **옛 앱이 고쳐 저장하면 rich 가 사라진다**(감수).
6. **Quill 형식**: B2(색 8자리 → 무시, 확인), size 는 R7(정상), 줄 구분은 R5·R6.
7. **빈 상자 판정**: R5.
8. **문서 끝 개행·IME**: `trimRightNewline` 이 맨 끝 `\n` 하나만 떼는 방식은 `Document` 가 항상 `\n` 으로 끝나는 불변식과 맞다(확인: 빈 문서 → `''`, `a\n\n` → `a\n`). 기존 글(예: `안녕\n`)은 `Document()..insert(0,'안녕\n')` → 평문 `안녕\n` 으로 복원돼 왕복 일치. IME 는 R4 미확인.
9. **의존성·빌드**: 아래.

## 5. 의존성·빌드 영향 (9번)

- 의도치 않은 생성물 변경: `flutter_quill` → `url_launcher`·`quill_native_bridge`(+`_macos`·`_windows` 등)가 들어와
  - macOS `GeneratedPluginRegistrant.swift`: `quill_native_bridge_macos`(네이티브 플러그인, 클립보드 HTML 읽기)·`url_launcher_macos` 추가.
  - Windows: `file_selector_windows`·`url_launcher_windows` 가 `generated_plugins.cmake`·`generated_plugin_registrant.cc` 에 추가(둘 다 네이티브 DLL 플러그인 → Windows 빌드에 새 CMake 의존성이 붙는다). `quill_native_bridge_windows` 자체는 Dart + win32(FFI)라 목록에 안 나온다.
  - Linux 레지스트리에도 `url_launcher_linux` 가 추가됐다(앱 대상은 macOS/Windows라 영향 없음, 단 생성물이 커밋 대상이면 같이 커밋).
- **`macos/Podfile.lock` 이 갱신되지 않았다 — 확인**. 레포가 추적하는 Podfile.lock 에 `quill_native_bridge_macos`·`url_launcher_macos` 가 없다. 로컬 `flutter build macos` 때 `pod install` 로 바뀌지만 커밋엔 빠져 있다. Podfile 의 `platform :osx, '12.0'` 과 플러그인 podspec 최저 10.14 는 충돌 없음.
- `pubspec.lock` 의 `sdks.flutter` 가 `>=3.38.4` → `>=3.44.0` 으로 올랐다(전이 의존성 요구). CI(`build-windows.yml`)는 `channel: stable` 만 지정(버전 고정 없음)이라 최신 stable 이면 통과. 이 PC 는 3.47.8 이라 문제 없음. 단 옛 Flutter 로 빌드하던 사람이 있으면 막힌다.
- `Localizations.override` 로 `FlutterQuillLocalizations.delegate` 만 입력칸 아래에 건다(앱 전체 MaterialApp 은 안 건드림). Quill 은 `ko` 번역을 갖고 있다(`quill_localizations_ko.dart` 확인). 앱이 `locale` 을 고정하지 않아 OS 언어를 따른다.
- 네이티브 코드(Windows C++·macOS Swift) 소스는 이 변경에서 직접 안 바뀌었다. **Windows·macOS 실제 빌드·실행은 이 환경에서 확인하지 못했다**(CI 로만 가능). `quill_native_bridge_macos` 가 샌드박스 앱에서 클립보드를 읽는 권한은 미확인(`macos/Runner/*.entitlements`).
- `THIRD_PARTY_NOTICES.md` 에 flutter_quill 한 줄만 추가됨. 전이 의존성(quill_native_bridge, dart_quill_delta, flutter_colorpicker, html, markdown, intl, url_launcher…)은 적지 않았다. 레포 규칙("의존성을 더하면 거기도 적는다")상 직접 의존성만 적는 기존 관례(qr_flutter·qr 처럼 직계 전이는 같이 적은 선례 있음)와의 정합은 확인 필요.

## 6. 권장 수정 순서

1. B2 색 8자리 파싱 + 테스트(영향 큼, 한 줄 수준).
2. B1 `_loadQuill` 비교식 교체(서식 판정 공유) + 되돌리기 후 서식 제거 테스트.
3. B3 `Document.fromJson` 으로 만들기(또는 history.clear).
4. R3 붙여넣기 필터 여부를 정하고, R4 IME·macOS 단축키·Windows 빌드는 실기기/CI 로 확인.
5. `macos/Podfile.lock` 갱신·커밋 여부, 레지스트리 생성물 커밋 범위 결정.

## 7. 재현 방법

레포 파일을 만들지 않고 `scratchpad/probe` 임시 프로젝트(pubspec 에 `worship_slides: path`, `flutter_quill: 11.6.0`)에서 `flutter test` 로 돌렸다.
핵심 출력: `COLOR for #FFFF0000 => null`, 되돌리기 뒤 `quill: [{"insert":"안","attributes":{"bold":true}},…]`, 되돌리기 뒤 입력 → `rich=[…굵게…"녕!\n"]`, Ctrl+Z → `[{"insert":"\n"}]`, 글 포커스에서 Delete 후 상자 유지.
