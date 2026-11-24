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
- stdout = JSON 한 개(ASCII 이스케이프), 경고는 stderr 에 `{"warning": …}` 줄, 진행 상황은 stderr 에 `{"progress": …}` 줄(아래). 걸린 시간: 견본 15~25장 6~10초(PowerPoint 첫 실행은 20초대).
- 렌더 캐시(`ppt_slides/`)를 쓰지 않는다 — 지운 사본은 가져올 때마다 달라서 쌓이기만 한다. 같은 파일을 다시 가져오면 다시 굽는다.
- 앱의 `PythonBridge.layout` 은 `Process.start` 로 띄워 stdout 을 모으고 stderr 를 줄 단위로 읽는다.
- **취소**: macOS 는 앱이 SIGTERM → Python 이 `Cancelled` 로 빠져나오며 자식 프로세스 그룹(soffice → soffice.bin, osascript)을 죽이고
  (`_run_child` 가 자식을 새 세션으로 띄워 `killpg`), PowerPoint 변환 중이었으면 **우리가 연 사본만** 닫고(`_MAC_POWERPOINT_CLOSE_SCRIPT`),
  임시 폴더를 `finally` 로 지운 뒤 종료 코드 130. 20초 안에 안 끝나면 앱이 SIGKILL. 앱은 끝날 때까지 기다린 뒤 작업 폴더를 지운다.
  Windows 는 SIGTERM 을 못 받으므로 앱이 `taskkill /PID <pid> /T /F` 로 트리째 끊는다 — Python `finally` 가 안 돌아 OS 임시 폴더
  (`praise_ppt_layout_*`)가 남을 수 있고, PowerPoint(COM 서버는 우리 자식이 아니다)는 숨은 사본을 연 채 남을 수 있다. **Windows 는 실제 실행 미확인.**

## 진행 줄 (stderr, 한 줄에 JSON 하나)

| 줄 | 때 | 앱 진행 창 |
|---|---|---|
| `{"progress": "convert"}` | `.ppt` → pptx 바꾸기 전 | 'PPT 를 pptx 로 바꾸는 중…' |
| `{"progress": "read", "n": 3, "total": 15}` | 슬라이드마다 읽기 전(n 은 1부터, 숨긴 장 포함) | '슬라이드 읽는 중… (3 / 15)' |
| `{"progress": "render"}` | 배경 굽기(두 번 굽기) 전 | '배경 굽는 중…' |
| `{"progress": "render", "n": 2}` | 애니메이션 걸린 배경 도형이 있는 파일만 — A 판을 구운 뒤 B 판 굽기 전 | '배경 굽는 중…' (같아도 된다) |
| `{"progress": "fonts"}` | 앱 목록 밖 글꼴이 있어 시스템 글꼴을 훑기 전 | '글꼴 확인 중…' |

모르는 단계는 앱이 무시한다(문구 그대로). `progress` 도 `warning` 도 아닌 stderr 줄은 실패했을 때 오류 문구가 된다.

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
  "fonts_missing": ["맑은 고딕"],            // 그중 앱 목록에도 이 PC 에도 없는 것
  "fonts_installed": [                       // 앱 목록엔 없지만 이 PC 에 깔린 것 — 앱이 이 파일을 읽어 그 이름으로 올린다(복사 안 함)
    {"family": "배달의민족 도현", "path": "/System/Library/AssetsV2/…/BMDoHyeon-Regular.otf", "index": 0}  // index = TTC 안 몇 번째
  ]
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
  "effects_lost": 2,          // 요소로 받았지만 꾸밈(그림자·네온·윤곽선 글자·형광펜·그림 테두리)을 버린 요소 수
  "steps": 3,                 // 클릭 단계 장 수(1 = 애니메이션 없음, 숨긴 장도 1). 요소 appear·disappear 의 최댓값 + 1
  "anim_lost": {"exit": 1}    // 살리지 못한 애니메이션(아래 표) — 0 이 아닌 것만, 하나도 없으면 키 없음
}
```

### 애니메이션 (`appear`·`disappear`·`steps`·`anim_lost`)

- 메인 시퀀스(`p:timing`)의 **클릭 순서만** 살린다. 효과 종류·속도·지연·강조·트리거는 버린다(늘 '나타내기'·'사라지기' 한 번).
- 요소 `"appear": k`(k ≥ 1) = k 번째 클릭에 나타난다. 처음부터 보이면 키 없음.
- 요소 `"disappear": k`(k > appear) = k 번째 클릭에 사라진다(사라짐 효과 `presetClass="exit"`). 끝까지 보이면 키 없음.
  **단계 s 에서 보임 = `appear ≤ s` 이고 (`disappear` 없음 또는 `s < disappear`)**. 처음부터 보이던 요소의 사라짐은 `disappear` 만 있다.
- 한 슬라이드 안 `appear`·`disappear` 는 **합쳐서 1..n 연속**(쓰인 단계만 다시 매김), `steps` = n + 1. 애니메이션 없는 슬라이드는 `steps: 1` 말고는 예전 JSON 과 같다.
- 도형마다 **첫 효과가 나타남이면 그 단계에 나타나고**(아니면 처음부터 보임) 그 뒤 **첫 사라짐**에 사라진다. 쉬는 장에서 한 번도 안 보이는 도형
  (자동 시작 첫 묶음에서 사라짐, 같은 클릭에 나타났다 사라짐)은 요소에서 빼고 배경에서도 지운다(세지 않음). 사라진 뒤 다시 나타나는 것은 `exit` 로 세고 사라진 채 둔다.
- 첫 클릭 묶음이 클릭 없이 시작(첫 효과 `nodeType` 이 `withEffect`·`afterEffect`)하면 그 묶음은 처음부터 보인다(빈 첫 장이 생기지 않게). 긴 지연도 마찬가지.
- 그룹째 나타나거나 사라지면 그 그룹에서 나온 요소 모두 같은 `appear`·`disappear`.
- **배경으로 남는 도형**(`dropped`)에 걸린 애니메이션: 그 도형까지 있는 A 판과 지운 B 판을 두 번 굽는다. `background_png` = B 판,
  도형의 바깥 상자를 A 판에서 잘라 `type: "image"` 요소(`appear`·`disappear`, 파일 `s<장>_<도형 번호>.png`)로 **요소 목록 맨 앞**에 넣는다.
  회전 도형은 바깥 상자째, 1920x1080 해상도 그대로. 굽지 않으면(앱 밖 시험) 이 애니메이션은 없어진다.

| `anim_lost` 키 | 뜻 (값 = 도형 수) |
|---|---|
| `paragraph` | 문단 단위 등장 — 상자째 **첫 문단 단계**에 나타난다(`appear` 있음). 문단 단위 사라짐은 무시(끝까지 보임) |
| `exit` | 사라진 뒤 다시 나타남 — 다시 나타남은 무시(첫 사라짐부터 끝까지 안 보임) |
| `group_child` | 그룹 안 도형만 노린 효과 — 처음부터 보임 |
| `overlap` | 배경 도형끼리 겹치는데 (나타남, 사라짐) 단계가 다름 — 잘라 내면 서로 비치므로 처음부터 끝까지 배경에 남김 |
| `too_many` | 단계(나타남·사라짐 합쳐)가 30(`ANIM_MAX_STEPS_PER_SLIDE`) 넘음 — 그 슬라이드 애니메이션 모두 버림(값 = 걸린 맨 위 도형 수) |

- 앱 항목: `ImageStagingItem(imagePaths: [단계마다 구운 PNG — steps 장], sourceName: title ?? '파일 이름 index', sourcePath: null)` +
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

버리는 것(세지 않음): 빈 자리표시자·글 없는 투명 도형, 애니메이션 효과 모양(클릭 순서만 `appear`·`disappear` 로 살림), 노트·전환, 슬라이드 밖에 완전히 나간 요소는 그대로 내보내 Dart `clampRect` 가 안으로 당긴다(PowerPoint 에서도 안 보이니 대개 없다).

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

모든 요소에 `"appear": k`·`"disappear": k` 가 붙을 수 있다(위 '애니메이션').

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
  Flutter 는 시스템 글꼴을 이름으로 찾아 주지 않으므로 앱이 `fonts_installed` 파일을 `loadFontFromList` 로 올린다(`FontLibrary.loadSystemFont`, 다시 켠 뒤엔 `ensureFamilies` 가 이름으로 다시 찾는다).

## 받는 쪽(Dart)에서 주의할 것

- 요소는 늘 배경 그림 **위**에 그려진다. 그래서 배경으로 남는 도형에 덮인 그림·도형은 `covered` 로 같이 배경에 넣었다. 글 상자는 원래 아래에 있었어도 위에 그려진다(드묾).
- `PageElement.fromJson` 이 `clampRect`(w·h 0.02~2, 5% 이상 보이게)로 자리를 고친다 — 아주 작은 글 상자는 0.02 로 커진다.
- 배경 PNG 는 이미 검정 여백까지 그린 1920x1080 이라 `SlideBackground.color` 는 무엇이든 보이지 않는다.
