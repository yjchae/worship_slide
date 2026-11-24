# `ppt_tool layout` 출력 계약 (3단계 PPTX → 편집 페이지)

작성: 백엔드 · 2026-11-24 · 구현 `python/pptx_layout.py`(+ `ppt_tool.py` `layout_presentation`), self-check `python/test_pptx_layout.py`.
요소 JSON 은 `lib/src/features/praise/domain/page_element.dart` 의 `toJson` 과 같은 키라 **`PageElement.listFromJson(slide['elements'])` 로 그대로 읽는다.**

## 부르기

```
ppt_tool layout <pptx|ppt 경로> <작업 폴더>
```

- 이름은 plan·QA(M9)·design 수용 기준을 따라 `layout`(백엔드 문서 초안의 `shapes` 는 버림).
- `<작업 폴더>` 는 앱이 만든 빈 임시 폴더를 준다. 꺼낸 그림·배경 PNG 가 여기 생긴다 — 앱이 `page_images/` 로 **복사한 뒤** 폴더를 지운다(경로를 그대로 저장하지 말 것).
- `.ppt` 는 LibreOffice 로 pptx 로 바꾼 뒤 같은 길(LibreOffice 없으면 아래 `libreoffice_missing`).
- stdout = JSON 한 개(ASCII 이스케이프), 경고는 stderr 에 `{"warning": …}` 줄. 걸린 시간: 견본 15~25장 6~10초(PowerPoint 첫 실행은 20초대).
- 렌더 캐시(`ppt_slides/`)를 쓰지 않는다 — 지운 사본은 가져올 때마다 달라서 쌓이기만 한다. 같은 파일을 다시 가져오면 다시 굽는다.
- 앱의 `PythonBridge` 는 기존 `render` 처럼 `Process.run` + JSON 디코드. 취소는 프로세스를 죽이고 작업 폴더를 지우면 된다(Python 은 자기 임시 폴더를 `finally` 로 지우지만 강제 종료면 OS 임시 폴더에 남을 수 있다).

## 오류

| stdout | 뜻 | 앱 |
|---|---|---|
| `{"error": "libreoffice_missing"}` | LibreOffice·PowerPoint 둘 다 없음(또는 PowerPoint 가 못 굽고 LibreOffice 없음) | 기존 LibreOffice 설치 안내(`LibreOfficeInstallDialog`), 설치 뒤 다시 |
| 종료 코드 ≠ 0 + stderr traceback | 파일 없음·깨진 pptx·쪽 수 불일치(`구운 쪽 수(N)가 슬라이드 수(M)와 다릅니다`) | 실패 알림. 쪽 수 불일치는 배경이 다른 장에 붙는 것을 막으려고 일부러 실패시킨다 |

## 성공 JSON

```jsonc
{
  "source_name": "파일 이름.pptx",          // NFC
  "slide_size": {"width": 12192000, "height": 6858000},  // EMU
  "aspect": 1.7778,                         // width/height
  "letterboxed": false,                     // 16:9 가 아님(±0.01) → 가운데에 놓고 여백(4:3 = 양옆 검정)
  "slides": [ /* 슬라이드마다 하나, 원본 순서, 숨긴 장 포함 */ ],
  "fonts": ["맑은 고딕", "배달의민족 도현"],   // 요소가 쓰는 글꼴 전부(빈 글 상자 제외)
  "fonts_missing": ["맑은 고딕"]             // 그중 이 PC 에 없는 것
}
```

### `slides[i]`

```jsonc
{
  "index": 3,                 // 원본 슬라이드 번호(1부터)
  "hidden": false,            // 숨긴 슬라이드면 true — elements [], background_png null. 결정 8 A: 앱은 건너뛰고 결과 창에 'n장 건너뜀'
  "title": "제목 자리표시자 첫 줄" | null,   // sourceName 후보(없으면 '파일 이름 N')
  "background_png": "/작업폴더/bg_003.png" | null,  // 1920x1080 PNG. 요소로 바꾼 도형을 지운 슬라이드(마스터·배경·표·회전 도형 등 포함)
  "elements": [ /* page_elements 그대로, 뒤가 위 */ ],
  "dropped": {"rotated": 1, "table": 1},  // 배경 그림으로 둔 '맨 위 도형' 수(까닭별). 그룹은 1개로 센다
  "effects_lost": 2           // 요소로 받았지만 꾸밈(그림자·네온·윤곽선 글자·형광펜·그림 테두리)을 버린 요소 수
}
```

- 앱 항목: `ImageStagingItem(imagePaths: [구운 PNG], sourceName: title ?? '파일 이름 index', sourcePath: null)` +
  `SlideBackground(color: 검정, imagePath: background_png(복사본), pageElements: elements)` → `PageComposer.compose`(plan 3단계 그대로).
- 결과 창 숫자: '그림으로 둔 요소 K개' = Σ`dropped` 값, '빠진 꾸밈 J곳' = Σ`effects_lost`, '숨긴 슬라이드 n장' = `hidden` 수,
  '16:9 아님(여백을 둠)' = `letterboxed`, '없는 글꼴' = `fonts_missing`. 장 번호가 필요하면 `index`.
- 4:3 은 결정 4대로 **편집 페이지로 만든다**(plan 의 '만들지 않음'은 결정 4 로 바뀜). 좌표·배경 PNG 모두 16:9 캔버스 기준이다.

### `dropped` 까닭

| 값 | 뜻 |
|---|---|
| `rotated` | 회전(rot≠0)한 도형·그림·그룹, 뒤집힌 그룹 |
| `geometry` | 지원 밖 모양(말풍선·별·블록 화살표·custGeom·꺾인 연결선 …), 사각형이 아닌 그림 틀 |
| `fill` | 그라데이션·패턴·그림 채우기(테마 style 이 그라데이션인 도형 포함) |
| `line` | 그라데이션·점선 테두리, 양쪽 끝 모두 화살표 |
| `vertical_text` | 세로 쓰기 |
| `picture_format` | png/jpg 가 아닌 그림(emf·wmf·gif·tiff·svg 만 든 것·링크 그림) |
| `picture_effect` | 투명도·흑백·색 바꾸기·예술 효과가 걸린 그림 |
| `picture_crop` | 음수 자르기(그림 바깥 여백) 등 Pillow 로 못 자르는 자르기 |
| `media` | 동영상·소리(포스터 그림은 배경에 남음) |
| `table` · `chart` · `smartart` · `ole` | graphicFrame 종류 |
| `group` | 자식 하나라도 못 받는 그룹(그룹째 배경) |
| `covered` | 받을 수 있지만 **위에 배경으로 남는 도형이 겹쳐** 같이 배경에 둔 그림·도형(겹침 순서가 뒤집히지 않게). 글 상자는 해당 없음 |
| `other` | 그 밖(AlternateContent·잉크 등) 또는 읽다 난 예외 |

버리는 것(세지 않음): 빈 자리표시자·글 없는 투명 도형, 애니메이션(마지막 상태 = 모두 보임), 노트·전환, 슬라이드 밖에 완전히 나간 요소는 그대로 내보내 Dart `clampRect` 가 안으로 당긴다(PowerPoint 에서도 안 보이니 대개 없다).

## 요소 (page_element.dart 와 같은 키)

공통: `id` = 16자리 hex, `rect` = `[x, y, w, h]` 16:9 캔버스 비율(소수 5자리). 16:9 가 아니면 가운데로 옮긴 좌표다.
글자·두께 단위 = **540pt 기준 pt** = 원본 pt × 540 / 캔버스 높이(pt). 13.333×7.5in 는 ×1, 10×5.625in 는 ×1.333, 10×7.5in(4:3) 는 ×1.

### 글 상자 `type: "text"` — 채우기·테두리가 없는 도형의 글(모양 상관없음)·자리표시자 글

```jsonc
{"type":"text","id":"…","rect":[…],
 "text":"평문(줄 = \\n)", "font_size":44, "color":"#RRGGBB", "bold":false,
 "align":"left|center|right", "font_family":"맑은 고딕",
 "rich":"Delta ops JSON 문자열",   // 서식이 하나라도 있을 때만
 "valign":"middle|bottom"}         // top 이면 키 없음(Dart toJson 과 같다)
```

- `rect` 는 PPT 안쪽 여백(lIns/tIns/rIns/bIns, 기본 0.1in/0.05in)을 뺀 글 자리. `wrap="none"` 상자는 정렬 기준을 두고 폭을 30% 넓힌다(앱 글꼴이 넓을 때 줄이 바뀌지 않게).
- 상자 기본값(`font_size`·`color`·`bold`·`font_family`)은 글자 수로 가장 많이 쓴 값. 정렬은 **첫 글 있는 문단** 정렬(결정 M16 A, justify/dist → left).
- 크기는 `normAutofit fontScale` 을 곱한 값, 8~300 으로 자른다. `lnSpcReduction`·줄 간격·문단 간격·자간·첨자는 버린다.

### 도형 `type: "shape"` — 채우기나 테두리가 있는 rect·roundRect·ellipse, 선·연결선

```jsonc
{"type":"shape","id":"…","rect":[…],"shape":"rect|round_rect|ellipse|line|arrow",
 "fill":"#RRGGBB"|null,"fill_alpha":1,"stroke":"#RRGGBB"|null,"stroke_width":2.0,
 "radius":0.1667,"flip_h":false,"flip_v":false,
 "text":"","font_size":40,"color":"#000000","bold":false,"align":"center","font_family":"Pretendard",
 "rich":"…"/*있을 때만*/,"valign":"middle|top|bottom"}
```

- 채우기는 `solidFill`(+ 테마 `fillRef` 가 단색일 때), 투명도는 색의 `alpha` → `fill_alpha`. 테두리는 `ln` 단색 실선 또는 테마 `lnRef`. 두께 0~40.
- `radius` = roundRect `adj`(짧은 변 대비, 기본 0.1667). 사각형·타원의 `flip_*` 는 원본 값(모양엔 영향 없음).
- 선(`line`, `straightConnector1`): `rect` 의 대각선, **높이나 너비가 0** 일 수 있다(가로선) — Dart `clampFlatRect` 가 받는다. 끝(tailEnd)에 머리가 있으면 `arrow`,
  시작(headEnd)에만 있으면 `flip_h`·`flip_v` 를 뒤집은 `arrow`. 선의 글 칸은 기본값.
- 글 없는 도형의 글 칸은 Dart 도형 기본값(검정 40 가운데 Pretendard).
- 도형 안 글의 안쪽 여백은 앱 고정값(`textInsetH/V`)을 쓴다 — 원본 여백이 다르면 조금 어긋난다.

### 그림 `type: "image"`

```jsonc
{"type":"image","id":"…","rect":[…],"path":"/작업폴더/s003_2.png"}
```

- png·jpg(jpeg)만. `srcRect` 자르기·좌우/상하 뒤집기는 Pillow 로 미리 적용한 파일. 자르기·뒤집기가 없으면 원본 바이트 그대로.
- 파일 이름 `s<장 3자리>_<도형 번호>[_<그룹 안 번호>…].<png|jpg>`. 확장자 그대로 `page_images/` 로 복사하면 된다(`PageComposer` 가 읽는 형식).

## `rich` (Delta) — `page_rich_text.dart` 가 읽는 것만

- 줄 = 문단(`\n`). `<a:br>` 도 `\n`(한 줄 더) — 목록 문단이면 **첫 줄에만** `list`.
- 글자 속성(상자 기본값과 다를 때만): `bold`(true/false), `italic`·`underline`·`strike`(true 만), `color`("#RRGGBB"), `size`(문자열 pt, 소수 1자리까지 예 `"20"`·`"43.2"`), `font`(글꼴 이름).
- 줄 속성: `list`: `"bullet"`(buChar·buBlip) | `"ordered"`(buAutoNum). 글이 없는 문단엔 안 붙인다. 번호 모양(①, a. 등)·시작 번호는 버린다.
- 같은 서식 덩어리는 합친다(`pageRichOps` 와 같은 규칙) — 서식 없는 글과 줄 끝 `\n` 은 한 op.

## 상속·색·글꼴 (Python 이 푼 값만 나간다)

- 글: run `rPr` → (도형) `lstStyle` → 레이아웃 같은 idx 자리표시자 → 마스터 같은 종류 자리표시자 → 마스터 `txStyles`(title/body/other) ·
  (자리표시자가 아니면) `p:style/fontRef` 색 → 프레젠테이션 `defaultTextStyle` → 마스터 `otherStyle`. 문단 정렬·글머리도 같은 사슬. 크기 기본 18pt.
- `bodyPr`(anchor·여백·autofit·wrap·vert)와 자리(xfrm)는 도형 → 레이아웃 → 마스터 자리표시자.
- 색: srgb·scheme(마스터 `clrMap` ← 레이아웃·슬라이드 `clrMapOvr`)·sys(lastClr)·prst(흔한 15색)·scrgb·hsl + `lumMod`·`lumOff`·`satMod`·`tint`·`shade`·`alpha`. 그 밖 변형은 무시.
- 글꼴: 한글·한자·가나가 든 run 은 `ea`, 아니면 `latin`. `+mj-lt`·`+mn-ea` 는 테마에서, 테마 `ea` 가 비면 `<a:font script="Hang">`.
- `fonts_missing`: Python 이 시스템 글꼴 폴더(macOS `/System/Library/Fonts`·`/Library/Fonts`·`~/Library/Fonts`·AssetsV2, Windows `%WINDIR%\Fonts`·사용자 글꼴)의
  name 테이블(ID 1·4·16, **모든 언어 이름**)과 앱 글꼴 목록(`pptx_layout.APP_FONTS` — pubspec 3종 + `assets/fonts/free` 6종)에 없는 이름.
  Flutter 가 실제로 그 이름으로 찾는지는 **미확인** — 프론트가 FontLibrary 기준으로 한 번 더 걸러도 된다.

## 받는 쪽(Dart)에서 주의할 것

- 요소는 늘 배경 그림 **위**에 그려진다. 그래서 배경으로 남는 도형에 덮인 그림·도형은 `covered` 로 같이 배경에 넣었다. 글 상자는 원래 아래에 있었어도 위에 그려진다(드묾).
- `PageElement.fromJson` 이 `clampRect`(w·h 0.02~2, 5% 이상 보이게)로 자리를 고친다 — 아주 작은 글 상자는 0.02 로 커진다.
- 배경 PNG 는 이미 검정 여백까지 그린 1920x1080 이라 `SlideBackground.color` 는 무엇이든 보이지 않는다.
