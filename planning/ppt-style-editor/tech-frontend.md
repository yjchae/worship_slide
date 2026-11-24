# 슬라이드 편집 창을 PowerPoint 처럼 — 프론트엔드 기술 문서

대상 코드: `lib/src/features/praise/presentation/page_editor_dialog.dart`(1939줄), `page_canvas.dart`, `page_rich_text.dart`,
`domain/page_element.dart`, `page_template_dialog.dart` (+ 같이 바뀌어야 하는 `page_to_free.dart`, `praise_home_page.dart` 9117~9134행).
이번 회차는 문서만 썼다. 앱 코드는 고치지 않았다.

표기: **확인** = 이 레포 코드 또는 `~/.pub-cache/hosted/pub.dev/flutter_quill-11.6.0` 소스를 직접 읽어 확인, **미확인** = 추정이거나 실행해 보지 못함.
기준선: `flutter test test/page_editor_test.dart test/page_image_test.dart test/page_rich_text_test.dart test/page_template_test.dart` → 41개 모두 통과(2026-11-24, 이 문서 쓰기 전).

---

## 0. 지금 구조 (요약, 확인)

| 부분 | 위치 | 하는 일 |
|---|---|---|
| 캔버스 | `page_canvas.dart` `PageCanvas` | 1920x1080 논리 크기 `SizedBox` + `FittedBox(fit: fill)`. 요소마다 `Positioned`, 글 상자는 `OverflowBox(topCenter)` + `Text.rich(pageTextSpan(e, 2.0))`. 굽기(`PageComposer.compose` → `renderWidgetToImage`)도 같은 위젯 |
| 글 렌더 | `page_rich_text.dart` `pageTextSpan` | Delta JSON 을 **한 개의 TextSpan** 으로. 줄은 `\n`, 목록은 앞에 `'• '`·`'N. '` 평문 접두(내어쓰기 없음), 정렬은 상자 하나(`align`) |
| 편집 창 | `page_editor_dialog.dart` | 위 `_toolbar`(44px 한 줄, 넣기·복제·삭제·순서·되돌리기) / 가운데 `_canvasArea` / 오른쪽 `_propertiesPanel`(폭 320). 글은 패널의 `QuillEditor.basic`(textScaler 0.35, 1591~1630행)에서 쓴다 |
| 요소 위 조작 | `_canvas`(1139) 의 `Stack` | `PageCanvas` 위에 요소마다 `_elementOverlay`(누르기·끌기, `onDoubleTap: _focusText`) + 고른 요소의 `_handles`(8개) |
| 되돌리기 | `PageEditHistory`(187) | 요소 목록 통째로 50개. 글 입력은 `_editSession`(포커스가 머무는 동안 1건) |
| 키 | `_onKey`(763) | 루트 `Focus.onKeyEvent`. 입력칸에 포커스(`_inTextField`)면 Delete·방향키·Z·Y·V 를 `ignored` 로 넘긴다 |

---

## 1. 캔버스 위 글 상자 안에서 바로 편집

### 1-1. 결정: 편집기를 `PageCanvas` 안, 그 요소 자리에 끼운다

`PageCanvas` 에 인자 두 개를 더한다(굽기에서는 둘 다 null 이라 지금과 같다).

```dart
PageCanvas({…, this.editingId, this.editor})
// 요소 루프: e.id == editingId 이면 글 대신 editor 를 같은 Positioned/OverflowBox 자리에
```

- **같은 `Positioned` → 같은 `OverflowBox` 경로**를 타므로 편집 중 글자 자리와 굽기 자리가 레이아웃 단계부터 같다.
  편집기를 화면 좌표의 별도 `Transform.scale` 로 띄우는 방법도 있지만 배율·반올림·세로 정렬 계산을 한 벌 더 두게 된다.
- `FittedBox` 는 transform 이라 캐럿·선택·클릭 위치는 Flutter 가 알아서 바꾼다. IME 후보 창 위치는 flutter_quill 이
  `renderEditor.getTransformTo(null)` 을 `setEditableSizeAndTransform` 으로 넘기므로 축소된 캔버스에서도 맞다(**확인**:
  `raw_editor_state_text_input_client_mixin.dart:430-431`). 실제 한글 IME 창 위치는 **미확인**(사람이 쳐 봐야 함).
- 요소 루프 `Positioned` 에 `KeyedSubtree(key: ValueKey(e.id))` 를 단다 — 글자 하나 칠 때마다 대화 상자가 `setState` 로
  `PageCanvas` 를 다시 만들어도 편집기 State(캐럿·IME 조합)가 유지되게. 편집 중 순서 바꾸기(⌘])는 막는다(아래 키 표).
- `PageCanvas` 는 "주변 테마를 안 탄다"는 원칙이 있다(굽기와 같게). 편집기는 선택 색이 필요하니 `editor` 위젯 쪽에서
  `Theme`·`DefaultSelectionStyle`·`Localizations.override(FlutterQuillLocalizations.delegate)` 를 감싸 넘긴다. 굽기 경로에는 들어가지 않는다.

**Quill 을 굽기에도 쓰지 않는 이유(확인)**: Quill `TextLine.build` 가 `Localizations.localeOf(context)` 를 부르는데
(`text_line.dart:190`), 굽기 환경 `renderWidgetToImage`(`lyrics_overlay_renderer.dart:122`)는 `MediaQuery`+`Directionality` 만 준다.
게다가 상자마다 컨트롤러·포커스가 생긴다. 그래서 **굽기는 우리 렌더러, 편집은 Quill, 둘의 배치를 같은 규칙으로 맞춘다**(1-3).

### 1-2. 편집기 설정 (flutter_quill 11.6.0, pubspec.lock 확인)

```dart
QuillEditor(
  controller: _quill, focusNode: _textFocus, scrollController: _quillScroll,
  config: QuillEditorConfig(
    editorKey: _editorKey,              // GlobalKey<EditorState> — 클릭 자리에 캐럿 놓기
    scrollable: false,                  // 기본 true. OverflowBox(maxHeight 무한) 안이라 스크롤 뷰를 쓰면 안 된다
    padding: EdgeInsets.zero,           // 기본값도 zero (editor_config.dart:32)
    expands: false,
    enableSelectionToolbar: false,
    onTapOutsideEnabled: false,         // 아래 1-4
    customStyles: pageQuillStyles(e),   // 1-3, 굽기와 같은 규칙
    customLeadingBlockBuilder: pageListLeading,   // 1-3, 목록 기호를 우리 위젯으로
    customActions: { UndoTextIntent: …, RedoTextIntent: …, HideSelectionToolbarIntent: … }, // 1-5
  ),
)
```

- 크기: 지금 패널처럼 **기본 글자는 pt 그대로(`e.fontSize`) 두고 `MediaQuery(textScaler: TextScaler.linear(PageCanvas.fontScale))`**
  로 감싼다. Quill 은 `size` 속성 값을 그대로 논리 px 로 쓰므로(`text_line.dart:623-636`) 이렇게 해야 `size: 60`(pt)이
  캔버스에서 120px = 굽기(`pageTextSpan` 의 `size * fontScale`)와 같다. Quill 줄은 `MediaQuery.textScalerOf(context)` 를 따른다(**확인** `text_line.dart:183,191`).
- 단, 목록 들여쓰기 폭은 textScaler 를 안 탄다(`TextBlockUtils.defaultIndentWidthBuilder` 가 `paragraph.style.fontSize` 를 그대로 씀,
  **확인** `text_block_utils.dart`). 그래서 `DefaultListBlockStyle` 의 `indentWidthBuilder`·`numberPointWidthBuilder` 를 **×fontScale** 로 준다.

### 1-3. 편집 화면 = 굽기 결과 (줄 높이·문단 간격·글머리)

지금 `pageTextSpan`(한 덩이 TextSpan)과 Quill 줄 렌더는 아래가 다르다(모두 소스로 **확인**):

| 항목 | Quill (편집) | 지금 `pageTextSpan` (굽기) | 맞추는 방법 |
|---|---|---|---|
| 줄 높이 | 줄마다 `StrutStyle.fromTextStyle(줄 기본 스타일)`(`text_line.dart:173`) — 작은 글자만 있는 줄도 기본 크기 높이 | strut 없음 → 작은 글자 줄은 낮아진다 | 굽기도 줄마다 같은 strut |
| `height` | 지금 패널은 `_previewBase` 에 `height: 1.2`(516행) | 없음(글꼴 기본) | 둘 다 **없음(null)** 으로 통일 |
| 문단 간격 | `VerticalSpacing.zero` 로 넣어 둠. 단 `lists` 기본값은 `lineSpacing (0,6)`(`default_styles.dart:475-482`) | 없음 | `paragraph`·`lists` 둘 다 zero (지금 패널 설정 그대로) |
| 글머리 | 줄 왼쪽에 **따로 그린 기호 위젯** + 본문은 **내어쓰기**(폭 `fontSize*2`, 번호는 `defaultNumberPointWidthBuilder`, 기호 오른쪽 여백 `fontSize/2`) (`text_block.dart:255-345`) | `'• '` 를 글 앞에 붙임 → 둘째 줄이 기호 아래로 감긴다 | 굽기를 Quill 방식으로 |
| 기호 서식 | 그 줄 **첫 글 덩어리의 size·color**, 글머리는 굵게, 나머지는 `defaultStyles.leading`(지금 미설정 = 테마 글자색) | 상자 기본 서식 | 공용 기호 위젯 + `leading` 스타일 = 상자 기본 |
| 정렬 | 줄 속성 `align` 없으면 `TextAlign.start`(`text_line.dart:276-288`) — 상자 `align` 을 모른다 | 상자 `align` | 1-3-2 |

#### 1-3-1. 결정: 굽기 렌더러를 "줄 단위"로 바꾸고 편집기와 한 함수를 나눠 쓴다

`page_rich_text.dart` 에 순수 함수 하나 + 위젯 하나:

```dart
/// Delta → 문단 목록. 굽기(PageTextBlock)·넘침 측정·Quill customStyles 가 같이 쓴다.
List<PageTextLine> pageTextLines(PageTextBody e, double fontScale);
// PageTextLine = (InlineSpan span, TextAlign align, StrutStyle strut, PageListMarker? marker)
// PageListMarker = (String text('•' | 'N.'), TextStyle style, double width, double gap)

class PageTextBlock extends StatelessWidget   // Column(줄마다 Row[기호 칸 SizedBox(width), Expanded(RichText(strut))])
double measurePageText(PageTextBody e, double fontScale, double width); // 같은 줄 목록으로 TextPainter 높이 합
```

- 폭은 Quill 과 같은 공식: 글머리 `TextBlockUtils.defaultNumberPointWidthBuilder(base, 1)`, 번호 `…(base, 연속 번호 줄 수)`
  — flutter_quill 이 이 클래스를 공개한다(`flutter_quill.dart` 31행 export, **확인**). base = 상자 기본 크기(pt) × fontScale.
- 기호 위젯은 하나(`pageListLeading`)를 만들어 Quill 의 `customLeadingBlockBuilder`(`Widget? Function(Node, LeadingConfig)`, **확인**)
  에도 넘긴다 → 편집·굽기 기호 모양이 같은 코드.
- `PageCanvas._text` 를 `PageTextBlock` 으로, `_textOverflows`(1813)·`page_to_free.dart:92` 를 `measurePageText` 로 바꾼다.
  `pageTextSpan` 은 지우거나 `pageTextLines` 위의 얇은 함수로 둔다(쓰는 곳이 없으면 지운다).
- 렌더 결과가 바뀌므로 `PageComposer._renderVersion` 1 → 2. 이미 구운 PNG 는 그대로 쓰이고(콘티가 경로를 가리킴),
  그 페이지를 다시 열어 확인하면 새 방식으로 구워진다 — 글머리 감김·작은 글자 줄 높이가 조금 달라질 수 있다(감수, 알림 불필요).
- ponytail: 줄 간격(lnSpc)·문단 앞뒤 간격은 지원하지 않는다. 3단계 가져오기에 필요하면 그때 `PageTextLine` 에 칸을 더한다.

#### 1-3-2. 정렬: 줄 속성 `align` + 상자 `align` 은 기본값

Quill 은 상자 정렬을 모르므로 편집 중 가운데 정렬 상자가 왼쪽으로 보인다(지금 패널도 그렇다). 결정:

- 문서를 Quill 에 넣을 때(`_loadQuill`) `align` 속성이 없는 줄에 상자 `align` 을 채워 넣는다(기록 없이 `Document.fromJson`).
- 요소로 돌려받을 때(`_quillRich`) **상자 `align` 과 같은 `align` 속성은 지우고** 서식이 남았는지 본다 → 서식 없는 글은 계속 `rich == null`.
  이 정규화를 순수 함수 `normalizeRich(ops, boxAlign)` 로 빼 테스트한다.
- `pageTextLines` 는 줄 속성 `align` 이 있으면 그것, 없으면 상자 `align`. → 편집 중 문단마다 정렬을 바꿀 수 있게 되고(PowerPoint 와 같음), 3단계 가져오기의 문단 정렬도 받을 수 있다.
- 옛 앱은 `rich` 의 `align` 을 무시한다(상자 정렬로 보임). 굽힌 PNG 는 그대로라 화면엔 영향 없음.

#### 1-3-3. 같아졌는지 검증 (새 테스트, 1-8)

위젯 테스트에서 같은 요소를 (a) `PageTextBlock`, (b) 캔버스 안 편집 모드 `QuillEditor` 로 각각 그리고 줄마다
`RenderParagraph` 의 전역 위치·높이를 비교(허용 1px). 글머리·번호(10줄 이상 = 폭 변화)·작은 글자 줄·가운데/오른쪽 정렬·빈 줄 포함.
줄바꿈 위치가 같다는 보장은 이 테스트로만 확인된다 — 그 전까지는 **미확인**.

### 1-4. 편집 모드 상태와 포인터

- 새 상태 `String? _editingId`(편집 중인 글 상자/도형). **포커스와 묶지 않는다** — 리본 버튼·색 대화 상자로 포커스가 잠깐 빠져도 편집은 계속된다.
  지금 `_textFocus` 리스너(332행)가 포커스를 잃으면 `_editSession=false` 하는 것은 유지(묶음 끊기용).
- 들어가기: (1) 고른 글 상자를 한 번 더 클릭, (2) 더블클릭, (3) Enter(지금 `_focusText` 자리), (4) '글 상자 추가' 직후·새 페이지·틀의 첫 빈 상자(지금 `addPostFrameCallback(_focusText)` 자리).
  - (1)(2)는 다음 프레임에 `_editorKey.currentState!.renderEditor.selectPositionAt(from: 전역 좌표, cause: SelectionChangedCause.tap)`
    로 **누른 자리에 캐럿**(API 존재 **확인** `editor.dart:99`, `raw_editor.dart:84`). 더블클릭은 이어서 `selectWordAtPosition`.
  - (3)(4)는 지금처럼 전체 선택(새 상자는 빈 글이라 캐럿만).
- 나가기: Esc(상자는 고른 채로), 캔버스 빈 곳·다른 요소 클릭, 리본 '글 상자 추가'·'도형'·그림 넣기, 확인/취소. 나갈 때 `_editSession=false`.
- 포인터: 편집 중인 요소의 `_elementOverlay` 는 **안쪽을 `IgnorePointer`** 로 바꿔 클릭·드래그가 아래 `PageCanvas` 의 편집기로 가게 하고,
  **테두리 띠(화면 6px)만** 끌기(옮기기)를 받는다. 손잡이(`_handles`)는 그대로 위에 있다. 이 구조는 Stack 위→아래 히트 테스트 순서로 된다(**확인**: `_canvas` 의 Stack 은 `PageCanvas` 가 맨 아래).
- `onTapOutsideEnabled: false` 로 둔다. Quill 기본은 데스크톱에서 편집기 밖 마우스 누름이면 `focusNode.unfocus()`(**확인** `raw_editor_state.dart:360-385`)
  — 리본 버튼을 누를 때마다 포커스가 빠진다. 밖 클릭 처리는 우리가 위 '나가기' 규칙으로 한다.
  (지금 패널 툴바에서 포커스가 유지되던 것은 Quill 툴바가 서식 적용 뒤 키보드를 다시 요청해서로 보인다 — 원인 **미확인**, 새 구조에선 의존하지 않는다.)
- 빈 글 상자 점선(`_DashedBorderPainter`)과 '글 상자' 글자는 편집 중이 아닐 때만. 편집 중에는 Quill `placeholder` 를 쓰지 않는다(캔버스에 회색 글이 크게 보여 굽기와 헷갈림).

### 1-5. 키 (요소 조작과 겹치는 것)

루트 `_onKey` 는 그대로 두되 `inText` 대신 `_editingId != null && _textFocus.hasFocus` 를 본다. 키는 포커스된 Quill 이 먼저 받고(그 `Shortcuts`/`Actions`), 처리 안 한 것만 루트로 올라온다.

| 키 | 편집 중 | 상자만 고름(편집 아님) |
|---|---|---|
| Delete·Backspace | Quill(글자 지우기) | 요소 삭제(지금 그대로) |
| 방향키 | Quill(캐럿) | 요소 옮기기 / Alt=크기 (지금 그대로) |
| Space·Enter·Tab | Quill. Tab 은 Quill 기본(들여쓰기 끔 상태에서 동작은 **미확인**) — 필요하면 `customShortcuts` 로 막음 | Enter=편집 들어가기, Tab=다음 요소 |
| Esc | **편집 나가기**(상자 고른 채) | 고르기 풀기 → 창 닫기(지금 그대로) |
| ⌘/Ctrl+Z, ⇧Z, Y | **창 되돌리기 하나**(아래) | 창 되돌리기 |
| ⌘/Ctrl+B·I·U | Quill(`ToggleTextStyleIntent` → 고른 글자) | 상자 전체에 적용(2-2 규칙) — `_onKey` 에 추가 |
| ⌘/Ctrl+C·X·V·A | Quill(글자) | V=그림/글 붙여 넣기(지금 그대로) |
| ⌘/Ctrl+D, ⌘[ ] | **무시**(지금은 입력칸에서도 ⌘D 가 상자를 복제한다, 777행) | 복제·순서(지금 그대로) |

- **Esc**: Quill 이 Esc 를 `HideSelectionToolbarIntent` 로 받고 선택이 유효하면 늘 처리해 삼킨다(**확인** `default_single_activator_intents.dart:14`, `editor_keyboard_shortcut_actions.dart:518-531`).
  그래서 지금 코드의 "입력칸 Esc → 캔버스로"(804행)는 실제로 안 불릴 수 있다(**미확인**, 테스트 없음).
  → `customActions: {HideSelectionToolbarIntent: CallbackAction(onInvoke: (_) => _exitEdit())}` 로 받는다.
- **되돌리기 하나**: Quill 은 ⌘/Ctrl+Z → `UndoTextIntent`, ⌘/Ctrl+Y → `RedoTextIntent` 이고(macOS 도 다시 하기가 ⌘Y, **확인**) 둘 다
  `Action.overridable`(**확인** `editor_keyboard_shortcut_actions_manager.dart:231-236`). `customActions` 로 둘을 `_undo`/`_redo` 로 바꾼다.
  ⌘⇧Z 는 Quill 에 없어(SingleActivator 는 shift 를 정확히 비교) 루트 `_onKey` 로 올라오므로 거기서 받는다(지금의 `if (inText) ignored` 를 뺀다).
  Quill 문서 자체의 history 는 쌓여도 쓰지 않는다.
- **되돌린 뒤 캐럿**: `_applyHistory` → `_syncFields` → `_loadQuill` 이 `document` 를 갈아 끼우면 선택이 사라진다. 갈기 전 `selection.baseOffset`
  을 들고 있다가 새 문서 길이로 잘라 `updateSelection(…, ChangeSource.silent)` (`ChangeSource.silent` 존재 **확인** `document.dart:636-645`).
  되돌린 결과 편집 중 요소가 없어지면(상자 추가를 되돌림) 편집에서 나간다.
- **기록 묶음**: 지금은 포커스가 머무는 동안 1건이라, 캔버스 안에서 길게 쓰면 되돌리기 한 번에 전부 사라진다. 묶음을 이때 끊는다:
  편집 들어갈 때, 서식 명령(리본·⌘B 등) 직전, 입력이 1초 멈췄을 때(`Timer`, `_editSession=false`). ponytail: 낱말 단위가 아니라 시간 단위.
- 한글 조합 중(`composing`)에 방향키·Esc 처리 순서는 **미확인** — 실제 macOS·Windows IME 로 확인할 항목(1-8 수동 검증).

---

## 2. 서식 도구를 상단 리본으로

### 2-1. 배치 (PowerPoint 홈 탭 흉내, 지금 `_toolbar` 44px 줄을 대체)

```
[삽입: 그림▾ 붙여넣기 글상자 도형▾] | [글꼴: (Pretendard ▾)(48 ▾) B I U S A▾] | [단락: ≡좌 ≡가 ≡우 ⊤⊥중(세로) • 1.] | [도형: 채우기▾ 테두리▾ 두께▾] | [정렬: 앞 뒤 맨앞 맨뒤 · 복제 삭제] | [↶ ↷]
```
- 묶음 아래 작은 이름(글꼴·단락·도형…). 높이 약 72px. 좁은 창은 `SingleChildScrollView(horizontal)` — 접히는 리본은 만들지 않는다.
- 해당 없는 묶음은 **비활성(흐림)**, 숨기지 않는다(자리가 흔들리지 않게): 그림 고름 → 글꼴·단락·도형 비활성, 아무것도 안 고름 → 전부 비활성(삽입·되돌리기만).
- 리본 전체를 `TextFieldTapRegion` 으로 감싼다 — Quill 의 탭 영역 묶음과 같은 그룹이라 리본을 눌러도 "밖 누름"이 아니다(1-4 의 `onTapOutsideEnabled:false` 와 이중 안전).
- **Quill 툴바 위젯(`QuillSimpleToolbar`·`QuillToolbarToggleStyleButton` 등)은 쓰지 않고 우리 `IconButton` 으로 만든다.** 이유: '상자 전체' 모드에서는
  Quill 컨트롤러 선택이 없거나 접혀 있어 `formatSelection` 이 다음 입력 서식(toggledStyle)만 바꾼다(**확인** `quill_controller.dart:359-368`). 적용 대상을 우리가 골라야 한다.
  색 고르기는 기존 `HexColorDialog`(style_fields.dart) + `_swatches`, 글꼴은 `FontLibrary.fonts`(FontFamilyPicker 와 같은 목록) 드롭다운, 크기는 숫자 입력 + 목록(24~120).
  → `FlutterQuillLocalizations` 는 편집기에만 필요(편집기가 요구하는지 자체는 **미확인**, 지금처럼 감싸 둔다).

### 2-2. 적용 규칙: 상자 전체 vs 고른 글자

| 상태 | 크기·색·굵게·글꼴 | 기울임·밑줄·취소선 | 정렬·글머리·번호 | 버튼 표시값 |
|---|---|---|---|---|
| 편집 중 + 글자 고름 | 고른 글자에 `_quill.formatSelection` | 같음 | 고른 글자가 걸친 **문단** | `getSelectionStyle()`(없으면 상자 기본) |
| 편집 중 + 캐럿만 | Quill 기본(다음에 칠 글자, toggledStyle) | 같음 | 캐럿 문단 | 같음 |
| 상자만 고름(편집 아님) | **상자 기본값을 바꾸고 그 속성의 직접 지정을 글 전체에서 지운다**(PowerPoint: 상자 고르고 빨강 = 전부 빨강) | 글 전체 범위에 `formatText(0, len)` 토글 | 정렬은 상자 `align` + 줄 `align` 모두 지움, 목록은 전체 문단 | 상자 기본. 글자마다 다르면 '혼합'(빈칸) |

- '상자만 고름' 의 크기·색·굵게 처리 = 지금 `_clearDirectFormats`(532행)를 속성 하나만 지우도록 일반화 + `copyWith(기본값)`. 한 번의 `_commit` 로 묶어 되돌리기 1건.
  그러면 지금의 '상자 전체 기본값' 구역과 '직접 바꾼 글자 N곳 … 모두 기본값으로' 안내는 **필요 없어진다**(지운다).
- 글꼴을 글자 단위로도 바꾸려면 `pageTextLines` 가 Quill `font` 속성을 읽어야 한다(지금 `_inlineStyle` 은 안 읽음). 한 줄 추가로 되고 3단계 가져오기(런마다 글꼴)에 필요하므로 넣는다.
  `font` 값이 `FontLibrary` 에 없는 이름이면 그 글자는 상자 글꼴로 그린다(Flutter 대체 글꼴로 엉뚱하게 그리지 않게).
- 도형 채우기·테두리는 늘 요소 단위(글자 선택과 무관). 글 상자에도 채우기·테두리를 허용할지는 4절 모델 결정을 따른다.

### 2-3. 오른쪽 패널: 없애지 말고 "속성 패널"로 줄인다 (제안)

- 남길 것: 아무것도 안 고름 → 페이지 이름·페이지 배경(틀 배경 칩·색·배경 그림 모음 — 리본에 넣기엔 크다), 그림 → '원래 비율로'·파일 없음 경고,
  글/도형 → 넘침 경고(`measurePageText`)와 짧은 안내만. 폭 320 → 260.
- 뺄 것: Quill 툴바·입력칸·'상자 전체 기본값' 구역·'모두 기본값으로'.
- 대안(비추천): 패널을 완전히 없애고 배경을 리본 '디자인' 탭으로 — 탭 전환 UI 와 배경 갤러리 팝업이 새로 필요해 범위가 커진다.
- 넘침은 패널만이 아니라 캔버스에서도 보이게: 편집 아닐 때 넘친 상자 아래쪽 테두리를 `cs.error` 점선(편집 창 오버레이만, 굽기 무관).

---

## 3. 도형 요소 `PageShapeElement`

### 3-1. 모델 (`domain/page_element.dart`)

```dart
enum PageShapeKind { rect, roundRect, ellipse, line, arrow }   // JSON 'rect' | 'round_rect' | 'ellipse' | 'line' | 'arrow'
enum PageTextVAlign { top, middle, bottom }

/// 글 상자·도형이 같이 쓰는 글 칸. pageTextLines·편집기·리본이 이 타입만 본다.
mixin PageTextBody { text, rich, fontSize, color, bold, align, fontFamily, vAlign }

final class PageShapeElement extends PageElement with PageTextBody {
  kind, fill (Color?, null=없음), stroke (Color?, null=없음), strokeWidth (pt, 540 기준, 0.25~20),
  flipH, flipV,          // 선·화살표 방향: rect 의 어느 모서리에서 어느 모서리로
  + PageTextBody 칸
}
// JSON: {"type":"shape","kind":"rect","rect":[…],"fill":"#RRGGBB"|null,"stroke":"#RRGGBB"|null,"stroke_width":2,
//        "flip_h":false,"flip_v":false, "text":…, "rich":…, "font_size":…, "color":…, "bold":…, "align":…, "font_family":…, "v_align":"middle"}
```

- `PageTextElement` 에도 `vAlign`(기본 top = 지금 동작, JSON 키 없으면 top)을 더한다 — 3단계 가져오기 글 상자의 세로 기준(anchor)용.
- 색은 지금처럼 6자리(`colorToHex`). 투명도(PPTX alpha)는 받지 않는다(3단계는 4절 표).
- 둥근 사각형 반경은 짧은 변 × 0.1667 고정(PowerPoint 기본 조정값과 같은 비율이라고 알려져 있으나 **미확인**). ponytail: 반경 조정 손잡이 없음.
- **선·화살표의 rect**: 수평선은 높이 0 이다. 지금 `clampRect`(w·h ≥ 0.02)와 `_parseRect`(w·h > 0)가 막는다.
  → `kind` 가 line·arrow 이면 짧은 쪽 0 을 허용하는 `clampLineRect`(긴 쪽만 ≥ minSize) + `fromJson` 분기. `resizePageRect` 의 `min` 도 선이면 0.
- **옛 앱 호환(확인)**: 옛 `PageElement.fromJson` 은 모르는 `type` 을 null 로 버린다(page_element.dart 끝 `return null`). 그래서 옛 앱은
  구운 PNG(화면·PPTX)는 그대로 보여 주지만 **편집 창을 열면 도형이 사라지고, 그대로 확인하면 없어진 채 저장**된다. 감수할지 결정 필요(아래 위험).
  대안 = 도형을 `type:'text'` + 추가 칸으로 저장(옛 앱에선 글만 남음) — 선·화살표가 글 상자로 보여 더 이상하므로 비추천.

### 3-2. sealed 타입 추가로 같이 고칠 곳 (확인, grep)

| 위치 | 지금 | 바꿀 것 |
|---|---|---|
| `page_canvas.dart:78-85` `switch (element)` | 그림/글 | 도형 분기(아래 3-3) |
| `page_editor_dialog.dart` `_elementOverlay` Semantics(1228), `_propertiesPanel`(1414) | 그림/글 | 도형 라벨 '도형: 사각형 …'·패널 |
| `pageAutoName`(62), `_confirm` 빈 글 거르기(883), `newTextBox`(36), `_onQuillChanged`·`_syncFields` | `PageTextElement` 만 | `PageTextBody` 로. 빈 도형은 **빼지 않는다**(글이 없어도 모양이 내용) |
| `page_template_dialog.dart:298-300` | `images = 전체 - 글` | 도형을 그림으로 세지 않게 `'도형 N개'` |
| `praise_home_page.dart:9121-9134` 콘티 목록 둘째 줄 | 글 상자 글, 없으면 그림 수 | 도형 글도 글로. 파일 담당은 팀장 확인 필요 |
| `worship_conti_repository.dart:768-777` `_backgroundPathSlots` | `type=='image'` 만 | 손댈 것 없음(도형엔 경로가 없다, 확인) |

### 3-3. 그리기 — `CustomPainter`

`PageCanvas` 의 도형 분기: `Stack(fit: expand, [CustomPaint(painter: PageShapePainter(e, fontScale)), 글(1-3 PageTextBlock, 안쪽 여백 + vAlign)])`.

- `PageShapePainter`(page_canvas.dart): `paint` 에서 `fill` 이 있으면 채우고 `stroke` 가 있으면 `strokeWidth * fontScale` 로 그린다.
  rect·roundRect·ellipse 는 상자 안쪽으로 반 두께 들여 그려(테두리가 상자 밖으로 안 나가게 — PowerPoint 는 선 가운데 기준이라 반 두께 차이는 감수) `drawRect`/`drawRRect`/`drawOval`.
  line·arrow 는 `flipH/flipV` 로 시작·끝 모서리를 정해 `drawLine`, arrow 는 끝에 삼각형 머리(두께 × 3 정도, 상수 하나).
  `shouldRepaint` = 요소 `!=`.
- 글 자리: 안쪽 여백 = PPTX 기본 bodyPr 여백(좌우 0.1in, 위아래 0.05in → 1080px 기준 14.4px·7.2px). 이 값은 OOXML 기본값으로 알려져 있으나 **미확인** — 3단계 백엔드가 lIns 등을 실제로 넘겨 주면 그 값을 칸으로 받는다(지금은 상수).
  vAlign 은 `OverflowBox(alignment: top/center/bottom)` — 넘치면 PowerPoint 처럼 위아래(가운데)로 삐져나온다. 편집기도 같은 `OverflowBox` 안이다(1-1).
- 선·화살표는 글 칸 없음(편집 들어가기 안 함, 리본 글꼴·단락 비활성).

### 3-4. 손잡이·고르기

- rect·roundRect·ellipse: 지금 손잡이 8개 그대로(`keepAspect` 는 Shift 일 때만 — 그림과 반대, PowerPoint 와 같음).
- **line·arrow: 끝점 손잡이 2개**로 한다(8개면 대각선 상자를 잡게 되어 수평선 높이 0 에서 망가진다). 끝점을 끌면 두 끝점 → `rect`(min/max) + `flipH/flipV` 를 다시 계산하는 순수 함수
  `lineFromPoints(Offset a, Offset b)`·`linePoints(e)` 를 두고 테스트. Shift = 45° 단위로 붙이기(선택, 작은 함수라 넣음).
- 선 고르기 히트 영역: 상자 그대로면 수평선(높이 0)을 못 누른다. 오버레이에서 선 요소만 `rect` 를 화면 12px 이상으로 부풀리고, 안쪽 누름이 선에서 화면 8px 이내일 때만 고르기(`HitTestBehavior` 대신 `onTapDown` 에서 거리 검사).
- 리본 '도형▾' 메뉴 → 슬라이드 가운데에 기본 크기로 넣고(사각형 0.3×0.3, 선 0.3×0) 바로 고른다. 기본 채우기 = 마지막으로 쓴 도형 것(없으면 흰색 채우기·테두리 없음), `newTextBox` 와 같은 "이어받기" 규칙.
  끌어서 그리기(PowerPoint 의 + 커서)는 이번엔 안 한다 — 제안으로 남김.
- 도형 더블클릭 → 도형 안 글 편집(1절 그대로). 글이 비어 있으면 vAlign 기준 자리에 캐럿.

---

## 4. 3단계 (백엔드 PPTX 가져오기)에서 프론트가 받을 것

백엔드가 슬라이드 하나를 `page_elements` 목록(지금 JSON 형식 + 3절 `shape`)으로 만들어 주면 프론트는 **그대로 `PageElement.listFromJson`** 으로 읽고
편집 창(`PageEditorDialog(elements:, background:)`)을 연다. 프론트가 PPTX 를 해석하지 않는다.

| PPTX 쪽 | 프론트가 받는 꼴 | 받을 수 없을 때 (백엔드가 할 일) |
|---|---|---|
| 위치·크기(EMU) | `rect` 0~1 (슬라이드 cx·cy 로 나눔) | 슬라이드가 16:9 가 아니면 백엔드가 가운데 맞춤 후 비율로(규칙은 백엔드 문서) |
| 글 상자·도형 글 | `text`(평문) + `rich`(Delta ops: bold·italic·underline·strike·color 6자리·size pt·font, 줄 `align`·`list`) + 상자 `font_size`·`color`·`font_family`·`align`·`v_align` | 줄 간격·문단 간격·들여쓰기 수준·글자 간격·그림자·외곽선 글자는 버리고 경고 |
| normAutofit(글 줄이기) | 이미 줄인 `size`/`font_size` | 백엔드가 fontScale 을 곱해서 준다 |
| 글꼴 이름 | `font_family`·`font` | 앱 `FontLibrary` 에 없으면 프론트는 상자 글꼴로 그린다(2-2). 경고는 백엔드 |
| 도형 rect·roundRect·ellipse·line·straightConnector1(+tailEnd) | `shape` kind | 그 밖의 prstGeom(삼각형·별·화살표 도형·자유형)은 **그림으로**(아래) |
| 단색 채우기·선 | `fill`·`stroke`·`stroke_width`(pt) | 그라데이션·패턴 → 첫 정지점 색(또는 평균) 단색 + 경고. 투명도 → 버리거나 배경과 섞은 색 |
| 회전(`rot`)·뒤집기 | 선만 `flip_h/flip_v`. 그 밖의 회전은 **모델에 없다** | 회전된 글 상자·도형: 회전 없이 + 경고, 또는 그림으로. 회전된 그림: 돌린 그림 파일로 구워서 |
| 그룹(`grpSp`) | 없음 — 평평한 목록만 받는다 | 백엔드가 자식 좌표를 그룹 변환(chOff/chExt)으로 풀어 펼친다. 그룹 회전은 위와 같음 |
| 그림(`pic`) + 자르기(srcRect) | `image` 요소 `path` | 자르기·회전·효과는 백엔드가 파일에 구워서. 경로는 `page_images/`(`BackgroundImageLibrary.pages()`)에 등록된 파일 |
| 표·차트·SmartArt·동영상 | — | 그 영역을 슬라이드 렌더 PNG 에서 잘라 그림 요소로(가능하면), 안 되면 빼고 경고 |
| 배경 | `SlideBackground`(색 + 배경 그림) | 그라데이션 배경은 그림으로 |
| z 순서 | 목록 순서(뒤가 위) | spTree 순서 그대로 |

- **경고 전달**: 결과에 `warnings: [{kind, count}]`(예: `rotation`, `gradient`, `unsupported_shape`) 를 같이 달라. 프론트는 편집 창 아래 메시지 줄(`_showMessage`)에
  '가져오며 바꾼 것: 회전 3개 풀림 · 그라데이션 2개 단색으로' 한 줄로 보인다. 형식은 백엔드와 합의 필요(이 문서의 제안).
- 받은 값은 지금처럼 `fromJson` 에서 clamp(크기 8~300pt, rect clampRect, 모르는 값 버림) — 신뢰 경계라 줄이지 않는다.
- 요소 수가 많을 때(수십 개) 편집 창 성능: 글자 한 번에 대화 상자 전체 `setState` → 모든 `PageTextBlock` 다시 레이아웃. 수십 개까지는 괜찮을 것으로 보이나 **미확인**.
  느리면 편집 중 요소 외에는 `RepaintBoundary` + 요소 `==` 로 다시 안 그리게(위젯 캐시)를 그때 넣는다.

---

## 5. 기존 테스트 영향

| 파일 | 영향 |
|---|---|
| `test/page_editor_test.dart` | `_quill(t)` 가 `find.byType(QuillEditor)` 로 찾는다(36행) — 편집기가 **편집 중일 때만** 캔버스에 생기므로, 새 페이지 테스트(169, 469)는 처음부터 편집 중이라 그대로 되지만 215·264행 테스트도 편집 모드인지 확인 필요. 264행 '모두 기본값으로' 테스트는 그 버튼을 없애므로 **'상자만 고름 + 리본 색 = 직접 색 지움' 테스트로 바꾼다**. 204행 툴팁 `'글 상자 추가 (고른 글 상자와 같은 글꼴·색)'`·251행 `'^되돌리기'`·331행 붙여넣기 툴팁은 리본에서 같은 문구를 유지하면 그대로. 순수 함수 테스트(resizePageRect·newImageRect·PageEditHistory·pageAutoName·newTextBox)는 그대로(선 min 0 분기 추가 시 기존 기대값 불변) |
| `test/page_rich_text_test.dart` | `pageTextSpan(...).text`·`.children` 를 본다(13·48·60·77행). 렌더를 `pageTextLines` 로 바꾸면 **기대 모양이 바뀐다** — 글머리가 접두 글자가 아니라 marker 가 된다. 같은 사례를 `pageTextLines` 기준으로 다시 쓴다(8자리 색·bold:false·깨진 rich 사례는 그대로 살린다) |
| `test/page_image_test.dart` | 요소 JSON 왕복·clamp·`page_elements`·`.wsconti` 경로는 그대로 통과해야 한다(도형은 경로 없음). 165행 '화면 밖 굽기' 는 배경·그림 픽셀만 봐서 영향 없음으로 보이나 `_renderVersion` 변경은 파일 이름만 바꾼다 |
| `test/page_template_test.dart` | 틀 JSON 왕복은 영향 없음. 기본 틀 3개(`page_template_store.dart:108-130`)는 글 상자 그대로 |

## 6. 새 테스트 항목

1. `pageTextLines`: 글머리·번호 marker 텍스트·폭(1자리/3자리 번호), 첫 글 덩어리 size·color 를 기호가 따름, 줄 `align` 우선·없으면 상자 `align`, strut = 상자 기본, `font` 속성(FontLibrary 에 없으면 무시).
2. `normalizeRich`: 상자 align 과 같은 줄 align 은 지워져 서식 없으면 null, 다른 align 은 남음. `_loadQuill` 이 넣은 align 이 rich 로 새지 않음.
3. **편집·굽기 일치**(1-3-3): `PageTextBlock` 과 편집 모드 `QuillEditor` 의 줄 위치·높이 1px 안. `measurePageText` == `PageTextBlock` 높이.
4. 편집 모드 위젯: 더블클릭 → 편집(캐럿이 누른 쪽 반), Esc → 나감·상자는 고른 채, 편집 중 Delete 는 글자만·요소 수 그대로, 편집 아닐 때 Delete 는 요소 삭제, 편집 중 ⌘D 무시.
5. 되돌리기 하나: 편집 중 입력 → (1초 경과 흉내) → 입력 → Ctrl+Z 두 번이 창 기록으로 한 묶음씩 되돌아가고 캐럿이 문서 안에 남음. 리본 굵게 = 기록 1건.
6. 리본 적용 규칙: 상자만 고름 + 색 → 상자 color 바뀌고 rich 의 color 직접 지정이 사라짐(기울임 유지) / 편집 중 글자 고름 + 색 → 그 글자만.
7. 리본 누름이 편집을 끝내지 않음(`TextFieldTapRegion`, `onTapOutsideEnabled:false`).
8. `PageShapeElement` JSON 왕복·틀린 값 버림·line 높이 0 허용·옛 형식에 `v_align` 없으면 top.
9. `lineFromPoints`/`linePoints` 왕복(4방향 flip), Shift 45° 붙이기.
10. `PageShapePainter` 화면 밖 굽기: 채우기 색 픽셀·테두리 없는 도형·선 끝 픽셀(page_image_test 165행 방식).
11. 수동(사람): macOS·Windows 한글 IME 조합 중 캐럿·후보 창 위치, 조합 중 Esc·방향키, 축소된 캔버스에서 캐럿 두께가 보이는지.

## 7. 작업 순서와 위험도

| 순서 | 작업 | 위험 |
|---|---|---|
| 1 | `pageTextLines`/`PageTextBlock`/`measurePageText` + `_renderVersion` 2, 기존 렌더·측정 교체 (패널 편집기는 그대로) | 중 — 기존 페이지를 다시 구우면 글머리 줄 감김이 바뀐다 |
| 2 | Quill 설정을 같은 규칙(customStyles·leading·align 정규화)으로 맞추고 일치 테스트(6-3) | **상** — 일치가 안 되면 이 기능의 핵심 약속이 깨진다. 여기서 막히면 1·2 를 되돌리고 "편집 중에는 Quill, 나오면 굽기"(살짝 튐)로 후퇴 |
| 3 | 캔버스 안 편집(`editingId`·`editor` 슬롯·오버레이 IgnorePointer·클릭 자리 캐럿) + 키 표 + 되돌리기 하나 | 상 — 포커스·제스처(더블클릭 지연·끌기와 글자 선택 충돌)·IME. 사람 확인 필수 |
| 4 | 리본(우리 버튼) + 적용 규칙, 패널 축소 | 중 — UI 양이 많다. 동작은 순수 함수로 테스트 가능 |
| 5 | `PageShapeElement` 모델·페인터·손잡이(선 끝점)·sealed 분기 정리 | 중 — 옛 앱에서 도형이 편집 시 사라짐(호환) |
| 6 | 3단계 수신(경고 줄, vAlign·font·줄 align 은 1~5 에서 이미 받음) | 낮 (프론트 몫만) |

1~2 는 화면 변화 없이 먼저 넣을 수 있어 따로 내보낼 수 있다(지금 패널 편집기도 내어쓰기·정렬이 굽기와 같아지는 이득).

## 8. 결정이 필요한 것

1. 옛 앱에서 편집 창을 열면 도형이 빠진 채 저장되는 것을 감수할지(구운 PNG 는 그대로 보임).
2. 오른쪽 패널을 '속성 패널'(260px)로 남길지(추천) / 없애고 배경을 리본 탭으로 옮길지.
3. 이미 구운 편집 페이지를 다시 열었을 때 글머리 감김이 조금 달라지는 것을 알릴지(추천: 안 알림).
4. 3단계 경고 형식 `warnings:[{kind,count}]` — 백엔드와 합의.
