# 디자인 검수: 글 상자 서식 패널 (실제 렌더)

## 방법
- 임시 테스트(`test/_tmp_panel_shot_test.dart`, 검수 후 삭제함)로 `PageEditorDialog` 를 1600x1000(배율 1)에서 띄움. 글 상자에 큰 빨간 글자(60pt)·굵은 기울임·글머리 목록을 입히고 첫 줄을 드래그로 고른 상태.
- 테마 3종(밝은·어두운·미드나잇) x 2장(패널 맨 위 / 패널 맨 아래로 스크롤). 예외·오버플로 줄무늬 없음(`takeException` null).
- 버튼 글자(`확인`, `모두 기본값으로`, `취소` 등 TextButton)가 네모(□)로 보이는 것은 테스트 글꼴 로딩 한계(Roboto 자리에 Pretendard 로 대체했으나 일부 굵기 누락)이며 앱 문제가 아님. 글꼴 때문에 그 버튼들의 폭·대비는 **미확인**.
- 사람이 직접 쓰는 상호작용(드롭다운 열기·색 견본 팝업·실제 키보드)은 **미확인**. 크기 칸의 혼합 표시도 이 렌더로는 못 봄.

## PNG
- 밝은: /private/tmp/claude-501/-Users-chaeyeongju-workspace-worship-slides/382aecbc-352f-46fe-a4de-f45211017b73/scratchpad/light_top.png , /private/tmp/claude-501/-Users-chaeyeongju-workspace-worship-slides/382aecbc-352f-46fe-a4de-f45211017b73/scratchpad/light_bottom.png
- 어두운: /private/tmp/claude-501/-Users-chaeyeongju-workspace-worship-slides/382aecbc-352f-46fe-a4de-f45211017b73/scratchpad/dark_top.png , /private/tmp/claude-501/-Users-chaeyeongju-workspace-worship-slides/382aecbc-352f-46fe-a4de-f45211017b73/scratchpad/dark_bottom.png
- 미드나잇: /private/tmp/claude-501/-Users-chaeyeongju-workspace-worship-slides/382aecbc-352f-46fe-a4de-f45211017b73/scratchpad/midnight_top.png , /private/tmp/claude-501/-Users-chaeyeongju-workspace-worship-slides/382aecbc-352f-46fe-a4de-f45211017b73/scratchpad/midnight_bottom.png

## 확인된 것 (문제 없음)
- 도구줄 툴팁·되돌리기 제거: 도구줄에 되돌리기/다시 실행이 없고 창 상단 되돌리기만 있음.
- 소제목 '고른 글자' / '상자 전체 기본값' 구분선 위치 자연스러움. 캡션은 3줄, 잘림 없음.
- 입력칸: 슬라이드 배경색(검정) 위에 슬라이드 글꼴·색. 패널 폭(약 248px)을 넘는 글자 없음(48pt x 0.35 = 약 17px, 60pt = 약 21px).
- 크기 칸은 고른 글자에 60pt 가 걸려 있을 때 '60pt' 로 보였다(상자 기본 48pt 가 아님). 즉 단일 크기 선택은 이미 맞게 보임. 혼합·크기 미지정일 때의 표시는 미확인.
- 대비: 세 테마 모두 소제목·캡션·'상자 전체 기본값' 컨트롤 글자가 읽힘. 미드나잇에서도 포커스·선택 표시 보임.
- 패널은 스크롤됨. 아래 상자 컨트롤(크기 슬라이더·색·정렬·글꼴·넘침 경고)은 스크롤하면 모두 보이고 잘리지 않음.

## 문제

### 1. [높음] 목록 줄이 입력칸에서 밝은 테마일 때 안 보이고, 어두운 테마일 때도 아주 작다
- 증상: 밝은 테마(light_top/light_bottom)에서 '둘째·셋째 항목'(목록)이 입력칸에 **아예 안 보인다**(앱 테마 글자색인 어두운 색이 검정 슬라이드 배경에 묻힘). 어두운·미드나잇에서는 보이지만 다른 줄(17~21px)보다 훨씬 작은 약 6px 로 읽을 수 없다.
- 원인: `QuillEditorConfig.customStyles` 에 `paragraph` 만 넣었다. 목록 블록(`lists`)은 기본 스타일이라 슬라이드 글꼴·색·크기를 안 따르고 textScaler 0.35 가 기본 크기 위에 한 번 더 곱해진다.
- 수정: `page_editor_dialog.dart` `_textProperties` 의 `DefaultStyles(paragraph: …)` 에 같은 기본 TextStyle 로 `lists: DefaultListBlockStyle(base, HorizontalSpacing.zero, VerticalSpacing.zero, VerticalSpacing.zero, null, null)` 도 넣는다(`base` 변수로 뽑아 공유). 글머리 문자도 base 색을 따른다. 위젯 테스트: 목록이 든 글에서 목록 줄 `TextStyle.color` 가 `e.color` 인지 확인.

### 2. [보통] 도구줄이 3줄로 접히고 셋째 줄에 버튼 하나만 남는다
- 증상: 윗줄 4개(크기·굵게·기울임·밑줄) / 둘째 4개(취소선·색·서식 지우기·번호 목록) / 셋째 줄에 글머리 기호 1개. 줄 사이가 넓어(줄당 약 52px) 도구줄이 약 150px 를 먹고, 입력칸이 고른 글자 바로 아래로 밀리며 안내 줄은 첫 화면 아래로 내려간다.
- 수정(택1): ① 패널 폭 280 → 도구줄이 줄당 5~6개라 2줄(크기·B·I·U·취소선 / 색·글머리·번호·서식 지우기)로 끝남. 상자 폭이 늘면 캔버스가 줄어드는 비용(1600 기준 약 32px) 은 작음. ② 폭 유지 시 `showStrikeThrough: false` 로 8개로 줄여 2줄에 맞춤(찬양 슬라이드에서 취소선 쓸 일이 거의 없음). 추천 ① (사용자가 이미 원했던 값).
- 위치: `page_editor_dialog.dart` 약 959행 `width: 280` 주변과 `QuillSimpleToolbarConfig(multiRowsDisplay: true …)`. 지금 패널 폭이 248px 로 렌더되는 것으로 보아 안쪽 패딩/구분선을 포함해 다시 확인 필요.

### 3. [보통] '직접 바꾼 글자 N곳 … [모두 기본값으로]' 안내가 첫 화면에 안 보인다
- 증상: 글꼴 칸 아래 맨 끝(글꼴·넘침 경고 사이)에 있어 1000px 높이에서도 첫 화면에선 잘려 보이고(light_top 맨 아래 `직접 바꾼 글자 2곳…` 반 줄) 스크롤해야 버튼이 나온다. 서식을 바꾼 바로 그 자리('고른 글자' 구역)에서 멀어 기능을 발견하기 어렵다.
- 수정: 이 줄과 버튼을 '고른 글자' 구역 캡션 바로 아래(`_textProperties` 의 구분선 `Divider(height: 28)` 앞)로 옮긴다. 조건(`_directFormatCount() > 0`)은 그대로. 이러면 '상자 전체 기본값' 구역은 상자 컨트롤만 남아 의미도 맞다. 문구도 '위 기본값' → '아래 기본값'으로 바뀐다 → '직접 바꾼 글자 N곳(크기·색·굵기)은 아래 기본값을 따르지 않습니다.'.
- 테스트(page_editor_test.dart 의 '모두 기본값으로…')는 `ensureVisible` 을 쓰므로 위치 이동에 영향 없음.

### 4. [낮음] 입력칸의 선택 손잡이(물방울)가 칸 밖으로 삐져나온다
- 증상: 글자를 고르면 왼쪽 손잡이가 입력칸 왼쪽 테두리를 넘어 패널 여백까지 나가고 글자를 가린다(모든 PNG 의 '첫째 항목' 양옆). 데스크탑이라 마우스 드래그 선택이 주인데도 모바일식 손잡이가 보임.
- 수정: `QuillEditorConfig(enableSelectionToolbar: false …)` 는 메뉴만 끈다. 손잡이를 끄려면 `selectionControls` 를 `EmptyTextSelectionControls()`(flutter/material 의 `TextSelectionControls` 서브클래스)로 주거나 `MaterialTextSelectionControls` 대신 데스크탑 컨트롤(`desktopTextSelectionControls`)을 넘긴다. 시간 대비 이득이 작아 후순위.

### 5. [낮음] 선택된 글자의 하이라이트가 밝은 테마에서 어둡게 보인다
- 증상: 밝은 테마에서 고른 '주일 광고'의 선택색이 어두운 회색(테마 `selectionColor`)이라 슬라이드 검정 배경 위 빨간 글자가 살짝 칙칙해진다. 대비는 읽을 만함.
- 수정(선택): `QuillEditorConfig(...)` 를 `DefaultSelectionStyle(selectionColor: Colors.white24)` 로 감싸거나 `Theme` 로 `textSelectionTheme` 만 입력칸 안에서 덮어쓴다. 급하지 않음.

### 6. [낮음] 색 견본이 도구줄 색 선택(Quill)과 앱 `_swatches` 가 다르다 (이미 알려진 미완)
- 렌더로는 팝업을 열지 않아 **미확인**. 위 '아직 안 한 것' 그대로 남김. 수정 위치는 `QuillToolbarColorButtonOptions` 로 색 목록을 넘기는 방식(`QuillSimpleToolbarConfig` 버전에 따라 다름 — 확인 필요).

## 요약
- 렌더·오버플로·잘림 오류는 없다. 우선 고칠 것은 **1(목록 안 보임, 높음)**, 그다음 **2(도구줄 3줄, 폭 280)** 와 **3(모두 기본값 안내 위치)**.
