# QA 2회차 — 2단계 구현 (도형 · 범위 고르기 · 맞춤)

검토: QA · 2026-11-24 · 대상: 커밋 안 된 작업 트리(1단계 변경 포함) · 기준: decisions.md · plan.md 2단계 수용 기준 · design.md s3~s5
소스는 고치지 않았다. '코드 확인' = 소스를 읽고 판단함(실제 마우스·키 입력은 위젯 테스트 범위만).

## 판정: 반려 (차단 0 · 주요 2 · 경미 5)

자동 검사는 모두 통과했다. 반려 이유는 둘 — 틀로 넣을 때 빈 도형이 '첫 빈 글 상자'로 잡혀 편집이 도형에서 시작한다(1), 수용 기준 '옛 코드로 읽으면 도형만 빠진다'를 고정한 테스트가 없다(2).

## 수용 기준 (plan 2단계)
- [x] '도형 ▾'로 사각형·둥근 사각형·타원·선·화살표 넣기 — `PageInsertRow` 도형 메뉴(page_editor_ribbon.dart:208), `_addShape` page_editor_dialog.dart:1040, 테스트 '도형 메뉴로 넣기 → …'
- [x] 채우기·없음·투명도·테두리·없음·두께가 캔버스 = 구운 PNG — 같은 `PageCanvas`/`PageShapePainter`(page_canvas.dart:108-208), 테스트 '굽기: 채우기·테두리·투명도·선이…'
- [x] 사각형·둥근 사각형·타원 더블클릭 = 안에 글, 기본 가로·세로 가운데(fromJson·생성자 기본 middle/center, page_element.dart:166·400), 세로 맞춤 바꾸기(`applyShapeFormat` 'valign' :125)
- [x] 선·화살표는 양 끝 손잡이 2개(`_lineHandles` :2012), 더블클릭 인식기 없음(:1849-1857), Enter·F2·글자 키도 무시(:1292-1315), 테스트 '선: 더블클릭해도…'
- [x] 저장·다시 불러오기·.wsconti — 모두 `SlideBackground.toJson/fromJson` 길, `_backgroundPathSlots` 는 image 만 건드림. 테스트 '도형이 든 배경 JSON(…)이 그대로 돌아온다'
- [ ] 옛 코드(`PageElement.listFromJson`, HEAD)로 읽으면 예외 없이 도형만 빠진다 **(테스트로 고정)** — 동작은 코드 확인으로 맞다(HEAD fromJson 은 `switch(type)` 에 'shape' 가 없어 null, 선의 높이 0 rect 도 먼저 null). 그러나 이를 고정한 테스트가 없다 → 결함 2
- [x] 빈 곳 끌기 = 걸친 요소 모두 고름(`pageElementsInRange` :132, `_updateMarquee` :1185), 맞춤 하나 = 슬라이드 기준·여럿 = 고른 범위 기준(`alignPageElements` :139), 테스트 '빈 곳 끌기 = 범위로 고르기…'

## PageShapeElement extends PageTextElement — 잘못 취급되는 곳 점검 (grep `is PageTextElement`·`whereType<PageTextElement>`·`case PageTextElement`·`PageTextElement(`)
- 문제 없음: 편집 시작(`_startEdit` :656 holdsText), Enter/F2/글자 키(:1292), 더블클릭(:1849), 리본 서식(`_ribbonFormat` :784·`_format` :832·838 holdsText), 도형 서식 판정(`_shapeFormat` :795), 넘침(`_textOverflows` :2233, 도형은 안쪽 여백 뺌), 확인 시 빈 글 상자 지우기(`_confirm` :1353 도형 제외), 빈 글 상자 점선(:1801), 상태 줄·틀 목록·콘티 목록 개수(:1509·page_template_dialog.dart:298-299·praise_home_page.dart:9136), Semantics·캔버스 switch 순서(도형이 글 상자보다 먼저, :1806·page_canvas.dart:94), `newTextBox` 가 도형 제외(:44).
- `copyWith`: 도형이 override 해 `PageShapeElement.withText(super.copyWith(...))` 를 돌려준다 — `applyBoxFormat`·`_onQuillChanged`·`_duplicate`·`_nudge`·끌기·숫자 칸 모두 동적 디스패치라 글 상자로 바뀌지 않는다. `rich` 지우기 sentinel 도 그대로 전달(:489·509).
- `==`/`hashCode`: 글 상자 == 가 `runtimeType` 을 보고(:350) 도형 == 가 `super ==` + 도형 칸(:542) — 같은 글의 글 상자와 도형이 같다고 나오지 않는다.
- `toJson`: 도형 `type:'shape'` + `valign` 늘 기록, 글 상자는 top 이면 `valign` 안 씀(:345) → 옛 글 상자 굽기 캐시 키 그대로(테스트 'valign 없는 옛 글 상자 JSON…').
- `page_to_free.dart`: 글 상자만 만든다(:60·156) — 영향 없음.
- 문제: 결함 1(첫 빈 글 상자), 결함 4(선의 숨은 글).

## 결함
1. [주요] 틀로 새로 넣을 때 빈 도형(띠·자막 상자)이 '첫 빈 글 상자'로 잡혀 편집이 도형 안에서 시작한다
   - 재현(코드 확인): 틀에 빈 사각형 띠(뒤) + 빈 글 상자(광고 내용 자리, 앞)를 두고 '새 페이지 추가' 에서 그 틀 선택 → 커서가 띠 도형 안에 들어가고 친 글이 띠에 들어간다
   - 기대 / 실제: 첫 빈 **글 상자**가 골라져 바로 입력(1단계 테스트 '틀로 새로 넣기: … 첫 빈 글 상자가 골라져 바로 입력') / `whereType<PageTextElement>().where(holdsText && 빔)` 에 도형이 걸린다. 장식 도형은 대개 빈 채로 목록 앞(뒤쪽 층)에 있어 거의 늘 먼저 잡힌다
   - 위치: `lib/src/features/praise/presentation/page_editor_dialog.dart:515-525`
   - 수정안: 조건에 `e is! PageShapeElement` 를 더한다(빈 글 상자가 없으면 지금처럼 첫 고를 수 있는 요소 — 도형이면 고르기만, 편집 시작은 `first is PageShapeElement` 가 아닐 때만). 틀 테스트에 빈 도형을 앞에 둔 경우를 하나 더한다
2. [주요] '1단계 이전 코드로 읽으면 도형만 빠진다'를 고정한 테스트가 없다(수용 기준 문구가 '테스트로 고정')
   - 기대 / 실제: 테스트 있음 / page_shape_test.dart:269 는 **새** 코드의 보존만 본다. 옛 파서 흉내 테스트 없음
   - 위치: `test/page_shape_test.dart`
   - 수정안: HEAD `fromJson`(type 'image'·'text' 만, rect 먼저 파싱)을 테스트 안 `_legacyListFromJson` 으로 옮겨 두고, 새 코드가 쓴 `[글 상자, 사각형(글 있음), 선(높이 0)]` JSON 을 넣어 예외 없이 글 상자 1개만 나오는지 본다
3. [경미] 선 다음에 사각형을 넣으면 선의 흰 테두리 3pt 를 이어받아 흰 채우기 + 흰 테두리가 된다(`newShape` 가 고른/마지막 도형에서 종류 상관없이 stroke 를 복사, 선은 테두리 없음이면 흰색으로 강제). 보이는 차이는 작지만 '기본값 = 테두리 없음'과 다르다 — page_editor_dialog.dart:74-101. 수정안: `from` 은 같은 계열(선↔선, 면↔면)에서만 찾는다
4. [경미] 선·화살표가 JSON 에 글(text)을 들고 오면(3단계 가져오기·손으로 만든 JSON) 화면엔 안 보이는데 자동 이름·콘티 목록 둘째 줄에는 그 글이 나온다 — `pageAutoName` page_editor_dialog.dart:181, praise_home_page.dart:9126. 수정안: 두 곳 조건에 `e.holdsText` 추가(또는 fromJson 에서 선의 글 칸 비우기)
5. [경미] 선 끝점을 아주 멀리 끌면(폭이 `maxSize` 2 를 넘음) `clampFlatRect` 가 폭만 잘라 **고정된 반대쪽 끝점**이 움직인다(왼쪽 기준으로 자름). page_element.dart:62-79·473-477. 수정안: `withLinePoints` 에서 끄는 끝점 쪽을 먼저 잘라 고정점을 지킨다(또는 끝점을 −0.95~1.95 로 clamp 한 뒤 Rect 를 만든다)
6. [경미] 범위 고르기·누름 판정이 선의 테두리 상자 기준이다: 대각선 선의 빈 상자 안에서 끌기를 시작하면 시작 순간(크기 0 범위)부터 그 선이 골라진다 — `pageElementsInRange` :132-135(`Rect.overlaps`). 수정안: 선은 범위와 선분의 교차로 본다(또는 범위가 문턱 이하면 고르지 않음)
7. [경미] 사각형·타원 JSON 에 높이(또는 폭) 0 이 오면 clamp 하지 않고 요소째 버린다(`_parseRect` flat=false, page_element.dart:212). 이 앱은 그런 값을 쓰지 않지만 3단계 가져오기(얇은 rect 띠)에서 요소가 조용히 사라질 수 있다 — 3단계에서 `minSize` 로 올려 받기 권장

## 실행한 확인
- `flutter analyze` → No issues found
- `flutter test`(전체) → All tests passed! (+808)
- 코드 대조: 위 `파일:줄`. grep 대상 `is PageTextElement|whereType<PageTextElement>|case PageTextElement|PageTextElement(|holdsText` (lib 전체), `git show HEAD:…/page_element.dart` 의 fromJson 으로 옛 코드 동작 확인
- 선 높이 0 경로: fromJson(`_parseRect(flat:)` :125·208-211), 끌기·방향키·복제·맞춤(`fitRect` :1059·1129·1164·158), 숫자 칸(`PageRectFields(clamp: e.fitRect)` :2166), 끝점(`withLinePoints`) — 모두 `clampFlatRect` 로 간다. 크기 손잡이·Alt+방향키 크기 바꾸기는 선에서 막힘(:1119, 손잡이 대신 끝점 2개 :1703)
- 되돌리기: 도형 넣기·서식(`_formatShape`, 투명도 끄기는 'begin' 부터 한 묶음 :810-824)·끝점 끌기(:2030)·범위 맞춤(:1049)·숫자 칸 모두 기록 한 번
- 굽기 캐시 키: 글 상자 top 이면 `valign` 미기록(:345), `_renderVersion` 2 그대로(1단계 값)
- 실행 못 한 것: 실제 트랙패드로 선 덮개 누름(8px)·끝점 끌기, 범위 고르기 육안 확인, Windows
