# PowerPoint 같은 슬라이드 편집 — 백엔드 기술 문서

작성: 백엔드 개발자 · 2026-11-24 · 앱 코드는 고치지 않았다(조사·설계만).
'미확인' = 이 문서를 쓰며 실행해 보지 못한 것. 수치는 직접 잰 것만 적었다.

## 0. 지금 구조 (읽은 코드)

- 요소: `lib/src/features/praise/domain/page_element.dart` — `sealed PageElement{id, rect(0~1)}`,
  `PageImageElement(path)`, `PageTextElement(text, rich, font_size(540pt 기준), color, bold, align, font_family)`.
  `PageElement.fromJson` 은 `type` 이 `image`·`text` 가 아니면 **null → `listFromJson` 이 버린다**.
- 저장: `SlideBackground.pageElements` → 배경 JSON `page_elements`(`slide_background.dart:209,242`) → DB
  `worship_conti_items.background` 한 칸. `isFreePage = pageElements != null`.
- 굽기: `presentation/page_canvas.dart` `PageCanvas`(1920x1080) + `PageComposer.compose`, 파일 이름 키에
  `_renderVersion = 1`(page_canvas.dart:117). 결과 PNG 하나가 `ImageStagingItem.imagePaths` 가 된다.
- 부분 서식: `presentation/page_rich_text.dart` — Quill Delta 에서 `bold·italic·underline·strike·color·size·list(bullet/ordered)`
  만 읽는다. `size` 는 540pt 기준 pt(`_inlineStyle`, page_rich_text.dart:70). **문단 정렬(`align`)·세로 맞춤은 Delta 에서 안 읽는다**(정렬은 상자 단위).
- 경로 칸: `WorshipContiRepository._backgroundPathSlots`(worship_conti_repository.dart:770) — `page_elements` 중
  `type == 'image'` 의 `path` 만 `.wsconti`·클라우드에 싣는다. `mapBackgroundPaths` 는 **날 JSON 맵을 고치므로 모르는 type 도 그대로 지나간다.**
- 페이지 틀: `data/page_template_store.dart` — `templateDesign(...).toJson()` 으로 `page_templates.json` 에 쓴다(요소는 `SlideBackground` 를 거쳐 객체로 왕복).
- PPTX 내보내기: `PythonBridge.exportPayload`(python_bridge.dart:336)가 이미 `background.toJson()`(= `page_elements` 포함)을 싣는다.
  Python `add_image_slides`(ppt_tool.py:1979)는 구운 PNG 만 그림 한 장으로 넣는다.
- Python 명령: `main()`(ppt_tool.py:3369) — import / export / render / sheet / sheet-finish / clipboard. python-pptx 1.0.2(.venv 에서 확인).

## 1. 데이터

### 1-1. 도형 요소 JSON (제안)

```json
{
  "type": "shape",
  "id": "16자리 hex",
  "rect": [x, y, w, h],
  "shape": "rect",              // rect | round_rect | ellipse | triangle | right_arrow | line … (앱이 그릴 줄 아는 것만)
  "fill": "#RRGGBB" | "#AARRGGBB" | null,   // null = 채우기 없음
  "line_color": "#RRGGBB" | null,           // null = 선 없음
  "line_width": 2.0,             // pt, 540pt 기준(글자 크기와 같은 단위). 0~50 clamp
  "rotation": 0,                 // 도, 시계 방향. 0~360
  "text": "평문", "rich": "Delta JSON 문자열|생략",
  "font_size": 40, "color": "#FFFFFF", "bold": false, "align": "center", "font_family": "Pretendard",
  "valign": "middle"             // top | middle | bottom
}
```

- 글 칸 이름·뜻은 `PageTextElement.toJson` 과 **똑같이** 둔다 → 렌더(`pageTextSpan`)·편집기를 그대로 쓴다. Dart 는
  `PageShapeElement` 가 글 칸을 공유하도록(공통 부분을 뽑든 필드를 복제하든) 프론트가 정한다.
- `rotation`·`valign` 은 도형만이 아니라 **글 상자·그림에도 필요**하다(PPTX 가져오기 — 2장). 처음부터 세 종류 공통 칸으로
  두자(없으면 0·`top`). `valign` 기본: 글 상자 `top`(지금 동작), 도형 `middle`(PowerPoint 도형 기본이 가운데).
- 모서리 둥글기(`roundRect` 의 `adj`)·화살표 비율 같은 조정값은 1단계에서 뺀다(기본 모양). 가져올 때 값이 다르면 모양이 조금 다르다.
- `shape` 에 앱이 모르는 값이 오면 `rect` 로 읽는다(요소를 버리지 않는다).

### 1-2. 옛 앱 호환 — 도형이 사라지는 길

옛 앱(지금 배포본)은 `type: shape` 를 `fromJson` 에서 버린다. 실제로 사라지는 시점:

| 옛 앱 동작 | 결과 |
|---|---|
| 콘티를 불러와 발표만 함 | **문제없음** — 관객 화면은 구운 PNG(`imagePaths`)를 본다 |
| `.wsconti` 내보내기·가져오기, 클라우드 올리기·받기 | **보존** — `mapBackgroundPaths` 가 날 JSON 을 고친다(도형엔 경로가 없어 손댈 칸도 없음) |
| 콘티 **저장**(새로·덮어쓰기) | **조용히 사라짐** — `saveConti` 가 객체에서 `SlideBackground.encode`(worship_conti_repository.dart:240)로 다시 쓴다. PNG 엔 도형이 남아 있어 당장 보이는 건 같다 |
| 편집 창 열고 '완료' | 도형 없이 다시 굽는다 → 화면에서도 사라짐 |
| 불러올 때 PNG 가 없음(`_restoreFreePages`) | 도형 없이 다시 굽는다 |
| 페이지 틀 저장(`page_templates.json`) | 틀을 하나라도 고치면 전체를 객체에서 다시 쓰므로 도형이 사라짐 |

판단: 옛 앱이 이미 배포돼 있어 옛 앱 쪽은 못 고친다. 받아들일 수 있는 이유 — 사라지는 건 옛 앱으로 **저장·편집**할 때뿐이고
내장 업데이터가 있다. 대신 **이번 판에 '모르는 요소 통과'를 같이 넣는다**: `fromJson` 이 모르는 `type` 을 버리지 말고 날 맵을 든
`PageUnknownElement(raw)` 로 두고 `toJson` 은 그 맵을 그대로 돌려준다(그리지 않음, 편집 창에서 고를 수 없음, 넘침·이름 계산 제외).
그러면 **다음** 새 요소(표 등)부터는 이번 판 앱에서 사라지지 않는다. 비용은 클래스 하나 + 테스트 하나.
`rotation`·`valign` 같은 **기존 type 에 더한 칸**도 같은 문제(옛 앱 `toJson` 이 모르는 칸을 버림)가 있으니 출시 노트에
"여러 PC 를 쓰면 모두 업데이트" 를 적는다. 스키마 버전으로 막는 방법은 없다(옛 앱이 칸을 안 본다).

### 1-3. 그 밖

- **DB 스키마 변경 없음.** 배경 JSON 한 칸 안에서 끝난다(스키마 20 그대로).
- `_backgroundPathSlots`: 도형은 경로가 없어 고칠 것 없다. 단 2장 가져오기에서 도형에 **그림 채우기**(`blipFill`)를 받기로 하면
  경로 칸이 생기므로 그때 이 함수에 더한다. 1단계는 그림 채우기를 `image` 요소로 바꿔 넣어(아래) 이 함수를 안 건드린다.
- 페이지 틀: `templateDesign` 이 `pageElements` 를 그대로 옮기므로 Dart 쪽 수정은 `PageElement` 직렬화뿐.
- 굽기 캐시: 그리는 방식이 바뀌므로 `PageComposer._renderVersion` 을 2 로. 키에 요소 JSON 이 들어가 도형이 있는 페이지는 어차피 새 키다.
- 구운 PNG 길은 그대로다 — 렌더러 네 곳·싱어·통역·PPTX(그림) 는 손댈 것 없음.

## 2. PPTX 가져오기 → 요소 단위 편집

### 2-1. 명령 설계

```
ppt_tool shapes <pptx|ppt> <out_dir>
→ stdout {"slide_width": EMU, "slide_height": EMU,
          "slides": [{"index": 1, "background": {"color": "#RRGGBB"|null, "image": "경로"|null},
                      "elements": [요소 JSON …], "dropped": [{"kind": "chart", "name": "…"}…]}],
          "warnings": [...]}
```

- 요소 JSON 은 1-1 모양 그대로(앱이 `PageElement.listFromJson` 으로 바로 읽음). 그림은 `<out_dir>/<슬라이드>_<n>.<ext>` 로 꺼내 경로를 싣는다.
  앱은 가져올 때 `page_images/` 로 복사(지금 그림 요소와 같은 규칙).
- `.ppt` 는 `convert_ppt_group_to_pptx`(LibreOffice) 로 먼저 바꾼다 — LibreOffice 없으면 `{"error": "libreoffice_missing"}`.
- 캐시: render 처럼 `get_ppt_cache_key` 식(경로+크기+mtime) 폴더에 둘 수 있으나 **1단계는 캐시 없이** 매번 뽑는다(가져오기는 한 번 하는 일).
- 결과 하나 = 슬라이드 하나 = 편집 페이지 하나(`ImageStagingItem` + `page_elements`). 슬라이드를 고르는 UI 는 프론트.

### 2-2. 위치·크기

- `rect = [left/W, top/H, width/W, height/H]`(W·H = `prs.slide_width/height`, EMU).
- **슬라이드 비율이 16:9 가 아니면**(4:3 = 9144000x6858000, 레포 `tmp_sample/sample_song.pptx` 가 그렇다) 앱 캔버스는 16:9 라 그대로 나누면 가로로 늘어난다.
  → 높이 기준으로 맞추고 가로 가운데 정렬(레터박스): `s = 1/H`, `x = (left·s) / (16/9) + (1 − (W/H)/(16/9))/2`. 양옆은 배경색.
- 회전: `shape.rotation`(python-pptx, 도). 앱 `rect` 는 회전 전 상자, 회전은 가운데 기준 — PPTX 와 같은 정의라 그대로 옮긴다.
  `flipH/flipV` 는 1단계 무시(도형 모양이 대칭이면 차이 없음, 화살표는 방향이 뒤집힌다 — `warnings`).
- **그룹**: 앱은 그룹이 없으므로 풀어서 자식을 평평하게 낸다. 자식 좌표는 그룹 `xfrm` 의 `chOff/chExt → off/ext` 로 변환:
  `x' = off.x + (x − chOff.x)·ext.cx/chExt.cx`(y 같음), 크기는 비율만큼. 중첩 그룹은 바깥까지 차례로 곱한다.
  그룹 회전은 자식 중심을 그룹 중심 기준으로 돌리고 자식 회전에 더한다. python-pptx 는 그룹 안 자식의 `left/top` 을 **자식 좌표계 값 그대로** 준다
  (스크래치 샘플에서 `chOff == off` 인 경우만 봤다 — 다른 경우는 위 식으로 계산해야 함, 실제 PowerPoint 파일로는 **미확인**).
- `clampRect`(w·h ≤ 2, 슬라이드 안 5% 이상)에 걸려 잘리는 요소(슬라이드 밖으로 빼 둔 요소)는 버리고 `dropped` 에 적는다.

### 2-3. 글자

- run → Delta op: `{"insert": text, "attributes": {bold, italic, underline, strike, color: "#RRGGBB", size: "<pt>"}}`,
  문단 끝 `"\n"` op 에 `{"list": "bullet"|"ordered"}`. **중간 형식을 따로 만들지 않고 바로 Delta** — 앱 렌더러가 이미 읽는다.
- 크기 단위: 앱은 540pt 기준. PPTX pt 를 `× 540 / (H / 12700)` 로 바꾼다(16:9 13.333x7.5in 면 ×1).
- 줄바꿈 `<a:br>` → `"\n"`(문단과 구분 못 함 — 앱은 둘 다 줄바꿈). 필드(`<a:fld>`, 슬라이드 번호·날짜)는 그 시점 글자(`a:t`)를 그대로 넣는다.
- 상자 기본값(`font_size`·`color`·`font_family`·`bold`·`align`)은 그 상자에서 **가장 많이 쓴** 값, run 값이 그것과 다를 때만 Delta 속성으로.
  서식이 하나도 없으면 `rich` 생략(지금 규칙과 같다).
- 정렬: 앱은 상자 단위만이다. 문단마다 다르면 첫 문단(또는 가장 많은 쪽)을 쓰고 `warnings`. `justify` → `left`.
- 세로 맞춤: `bodyPr@anchor` t/ctr/b → `valign`. 안쪽 여백(`lIns/tIns/rIns/bIns`, 기본 0.1in/0.05in)은 1단계엔 rect 를 그만큼 줄여 흉내 낸다.
- 줄 간격(`lnSpc`)·자간(`spc`)·글자 위아래 첨자·하이퍼링크·문단 들여쓰기: 버린다(앱에 칸 없음). 글머리 기호 모양(`buChar`)은 `•` 하나로.
- **자동 맞춤**: `bodyPr/normAutofit@fontScale`(1/1000 %)·`lnSpcReduction` 이 있으면 모든 크기에 fontScale 을 곱해 넣는다
  (PowerPoint 가 마지막에 계산한 값이라 그대로 쓰면 비슷하게 보인다 — 실제 파일 비교는 **미확인**). `spAutoFit`(상자가 글에 맞춰 늘어남)은 무시.
- **글꼴**: `a:latin@typeface`/`a:ea@typeface`(한글은 `ea` 가 먼저). `+mj-lt`/`+mn-ea` 같은 테마 글꼴은 테마 `fontScheme` 에서 풀어 낸다.
  앱이 가진 글꼴(FontLibrary 내장 + Pretendard) 이 아니면 **이름은 그대로 두되** 앱이 그릴 때 없는 글꼴로 대체된다 —
  Flutter 가 시스템 글꼴을 이름으로 찾는지는 플랫폼마다 다르고 **미확인**. 안전하게는 shapes 결과에 `missing_fonts` 를 실어 프론트가 알리게 한다.
- **심은 글꼴**(`ppt/fonts/*.fntdata`): `eot_font.eot_to_ttf` 로 TTF 를 풀 수 있다(이미 render 에서 씀). 앱 글꼴 목록에 올리는 건
  FontLibrary 의 "사용자가 글꼴 추가 안 함" 원칙(라이선스)과 부딪힌다 — **1단계는 안 올린다.** 결정 필요(대표).

### 2-4. 상속 — python-pptx 가 안 주는 값

스크래치 샘플(`python-pptx` 로 만든 '제목 및 내용' 슬라이드)로 확인한 것:
- placeholder 의 **위치·크기는 레이아웃에서 상속돼 나온다**(`left/top` 이 레이아웃 값).
- **글자 크기·색·글꼴은 상속 안 됨**: 제목 run `font.size = None`. 실제 값은 마스터 `p:txStyles/p:titleStyle/lvl1pPr/defRPr@sz=4400` 에 있었다.
- 도형 채우기를 따로 안 준 타원은 `fill.type = None` 이고 실제 채우기는 `<p:style><a:fillRef idx="3"><a:schemeClr val="accent1"/>` 였다.

그래서 값마다 아래 순서로 찾는 작은 해석기가 필요하다(모두 lxml 로 XML 직접):

1. run `rPr` → 문단 `pPr/defRPr` → 상자 `lstStyle/lvlNpPr/defRPr`
2. (placeholder 면) 레이아웃의 같은 `idx`/`type` placeholder 의 `lstStyle` → 마스터 같은 placeholder → 마스터 `txStyles`(title/body/other, 레벨별)
3. (일반 도형이면) `p:style/fontRef` 색 → 프레젠테이션 `defaultTextStyle`
4. 테마 기본(`minor` 글꼴, `tx1` 색)

채우기·선: `spPr` 의 `solidFill`/`noFill`/`ln` → 없으면 `p:style` `fillRef`/`lnRef`(색은 그 안의 `schemeClr`, `idx` 는 테마 `fmtScheme` 의 몇 번째 스타일 —
기본 테마 `fillRef idx=3` 은 그라데이션이다 → 1단계는 그 색 단색으로).

**테마 색**: 마스터 rels 의 THEME 파트 `clrScheme`(샘플: `dk1 = sysClr windowText lastClr`, `accent1 = 4F81BD`) + 마스터 `clrMap`(`tx1→dk1`, `bg1→lt1`) +
레이아웃·슬라이드의 `clrMapOvr`. `sysClr` 는 `lastClr` 을 쓴다. 변형 `lumMod/lumOff/tint/shade/alpha` 는 PowerPoint 가 아주 흔히 쓴다 —
`lumMod/lumOff`(HSL 밝기), `alpha`(→ `#AARRGGBB`), `tint/shade` 를 구현한다. `satMod`·`hueOff` 등 나머지는 무시하고 `warnings`.

### 2-5. 도형·그림·배경

- 도형: `prstGeom@prst` → `shape` (rect, roundRect→round_rect, ellipse, triangle, rightArrow… 앱이 그릴 수 있는 목록과 1:1). 목록 밖 `prst`·`custGeom` 은 2-6.
  선이 `prstGeom line`/`cxnSp`(연결선)은 `shape: line` 하나로(화살촉 무시).
- 채우기: `solidFill` 만 단색. `gradFill` → 첫 정지점 색(또는 2-6 그림으로 굽기), `pattFill` → 전경색, `blipFill`(도형 안 그림) → 그 도형 자리에 `image` 요소, `noFill` → null.
- 선: `ln@w`(EMU → pt ×540/H pt), `ln/solidFill`, `ln/noFill`. 점선(`prstDash`)·끝 모양 무시.
- 그림(`p:pic`): `shape.image.blob`·`.ext` 로 꺼낸다(python-pptx). **자르기 `srcRect`(`crop_left` 등)** 가 있으면 Pillow 로 잘라 저장한다.
  EMF/WMF/SVG(`svgBlip`) 는 앱이 못 그린다(`PageComposer._decode` 가 Flutter 코덱) → 함께 든 PNG 대체 그림(`a:blip r:embed`)을 쓰고, EMF 뿐이면 2-6.
  그림 테두리·그림자·투명도 무시.
- 배경: 슬라이드 `p:bg` → 없으면 레이아웃 → 마스터. `bgPr/solidFill` → 배경 색, `bgPr/blipFill` → 그림 꺼내 배경 그림, `bgRef`(테마 배경 스타일) → 색만.
  그라데이션 배경 → 첫 정지점 색. (`follow_master_background` 로 어느 쪽인지 python-pptx 가 알려 준다 — 샘플에서 True 확인.)
- 레이아웃·마스터에 박힌 **비-placeholder 도형**(로고·띠): 슬라이드에 보이므로 요소로 같이 낸다(맨 뒤에, 슬라이드 요소보다 아래). `showMasterSp="0"` 이면 뺀다.
- 빈 placeholder(글 없는 '제목을 입력하세요')는 낸다 말다 — 안 낸다(발표 화면엔 안 보임).

### 2-6. 못 옮기는 것 — 떨어뜨리는 규칙

표(`graphicFrame` tbl)·차트·SmartArt·OLE·수식·동영상·`custGeom`·3D·그라데이션 글자·워드아트 효과.

선택지:
- (가) **버린다** + `dropped` 에 이름을 적어 앱이 "표 1개·차트 1개는 옮기지 못했습니다" 를 띄운다. 비용 0.
- (나) **그 요소만 그림으로 굽기**: 요소 하나만 남긴 슬라이드 사본을 만들어 LibreOffice/PowerPoint 로 PDF → 그 상자 영역만 잘라 PNG.
  배경을 투명하게 뽑을 수 있는지(PDF 에서 슬라이드 배경을 안 칠하게 하고 `get_pixmap(alpha=True)`)는 **미확인**. 변환 한 번이 수 초라(값은 미측정)
  요소 수만큼 부르면 느리므로, 사본 하나에 "굽기 필요한 요소마다 한 장"씩 슬라이드를 만들어 **한 번에** 변환한다.
- (다) **원본 렌더에서 잘라 쓰기**: `render --no-animation` 으로 구운 슬라이드 PNG(이미 있는 길·캐시)에서 그 요소 상자만 잘라 불투명 그림 요소로.
  변환 추가 없음. 단점 — 밑의 배경·겹친 다른 요소가 같이 찍힌다(표·차트는 보통 빈 자리에 있어 쓸 만하다고 봄, **미확인**).

추천: 1단계 (가), 2단계 (다), (나)는 (다)가 부족하다고 확인된 뒤.
애니메이션은 버린다(편집 페이지는 PNG 한 장). 클릭 단계가 필요한 슬라이드는 지금처럼 'PPT 이미지로 넣기'(render) 를 쓰라고 안내.

### 2-7. 기존 흐름과의 관계

- **render(PPT 이미지 넣기)는 그대로 둔다.** 정확한 모양·애니메이션 단계·동영상이 필요하면 render, 고쳐 쓰려면 shapes. 둘은 다른 명령·다른 결과.
- 가져온 편집 페이지는 원본과 끊긴다(`ImageStagingItem.sourcePath = null`). '원본 열어 수정'·`SourceFileWatcher` 다시 굽기는 이 항목에 걸지 않는다 —
  다시 뽑으면 앱에서 고친 것을 덮어쓴다. (원하면 나중에 "원본에서 다시 가져오기(앱 수정 버림)" 를 따로.)
- 심은 글꼴 제한(fsType 0x4) 파일도 shapes 는 XML 만 읽으므로 PowerPoint 없이 된다.

## 3. 다시 PPTX 로 내보내기

| 방식 | 비용 | 결과 |
|---|---|---|
| A. 지금처럼 구운 PNG 한 장 | 0 | 보이는 그대로. PowerPoint 에서 글자 못 고침 |
| B. 네이티브 도형·글 상자로 | `add_image_slides` 옆에 `add_free_page_slide` 하나(약 150~250줄 예상) + Delta→run 변환 + self-check | PowerPoint 에서 고칠 수 있음. 글꼴이 없는 PC 에선 줄바꿈이 달라질 수 있음 |

B 가 쉬운 이유: payload 에 `page_elements` 가 **이미 실린다**(python_bridge.dart:391) — Dart 수정 없음. python-pptx 로
`add_shape(MSO_SHAPE.ROUNDED_RECTANGLE…)`·`fill.solid()`·`line.width`·`rotation`·`text_frame` run 서식이 모두 되는 것을 스크래치에서 확인했다.
그림은 `add_picture`(경로가 없으면 그 요소만 빼고 `warnings`). 글꼴은 `_ensure_fonts_installed` 를 요소 글꼴마다 부른다. 크기 단위 ×1(내보내기 슬라이드가 13.333x7.5in).

추천: **B 를 하되 2단계**(편집기·가져오기 다음). A 는 남겨 두고 B 에 못 옮기는 게 있으면(모르는 요소·없는 그림) 그 페이지만 A 로 떨어뜨린다.
'가져오기 → 앱에서 고침 → 내보내기' 왕복은 같은 변환표(prst↔shape, Delta↔run)를 두 방향으로 쓰니 한 파일에 둔다.

## 4. 단계·작업량·위험

| 단계 | 백엔드 일 | 위험 |
|---|---|---|
| 1. 도형 요소 | Dart `PageShapeElement` 직렬화(프론트와 나눔), `PageUnknownElement` 통과, `_renderVersion` 2, 테스트 | 옛 앱 저장 시 도형 사라짐(1-2) — 업데이트 안내로 감수 |
| 2. 가져오기 1차 | `shapes` 명령: 위치·그룹·회전·글(Delta)·도형·그림·배경·상속 해석기·테마 색, 못 옮기는 건 (가) | **가장 큰 위험 = 상속 해석**. 실제 PowerPoint 파일은 테마·레이아웃이 제각각이라 스크래치 샘플로는 부족. 교회에서 쓰는 실제 PPTX 몇 개로 확인 필요(레포엔 python-pptx 가 만든 단순 샘플뿐) |
| 3. 내보내기 B | `add_free_page_slide` + self-check | 글꼴 대체로 줄바꿈 차이 |
| 4. 가져오기 2차 | (다) 원본 렌더에서 잘라 넣기, 그라데이션·EMF 대체 | 잘린 그림에 다른 요소가 같이 찍힘 |

작업량은 사람-일로 못 박지 않는다(실제 파일 확인 전이라 상속 해석 범위가 안 정해짐). 상대 크기: 2 > 3 ≈ 4 > 1.

## 5. self-check 테스트 (python/test_*.py 형식, LibreOffice 불필요)

`python/test_shapes.py` — python-pptx 로 샘플을 스크래치에 만들어 `shapes` 결과를 assert:
- 16:9 슬라이드의 글 상자 rect 가 EMU/슬라이드 크기와 같다(소수 4자리)
- 4:3 슬라이드는 레터박스(x 가 가운데로 줄어듦, h 는 그대로)
- 그룹(`chOff ≠ off`, `chExt ≠ ext` 로 직접 XML 을 고친 것) 안 자식 좌표 변환, 중첩 그룹
- 회전 15° 가 `rotation: 15`
- run 서식 → Delta: 굵게·기울임·밑줄·색·크기, 문단 `\n`, 글머리 `list: bullet`, `<a:br>` → `\n`
- placeholder 제목 글자 크기가 마스터 `titleStyle` 값(기본 템플릿 44pt)으로 나온다
- `schemeClr accent1` → 테마 값(기본 템플릿 `#4F81BD`), `lumMod 75000` 적용 값
- `p:style fillRef` 만 있는 도형의 채우기 색
- `normAutofit fontScale="62500"` 이면 크기 × 0.625
- 그림 꺼내기: 파일이 생기고 `srcRect` 자르기가 적용된 크기
- 표·차트(XML 로 graphicFrame 을 넣은 것)는 `elements` 에 없고 `dropped` 에 있다
- 배경 `solidFill` 색, 마스터 배경 상속

`python/test_export_free_page.py` (3단계): `page_elements` 를 담은 export payload → 슬라이드에 도형·글 상자 수, 채우기 색, 회전, run 크기·색, 그림 위치.

Dart: `test/page_image_test.dart` 에 도형 JSON 왕복·모르는 type 통과(`toJson` 이 받은 맵 그대로)·`shape` 모르는 값 → rect.

## 6. 이 문서에서 확인한 것 / 못 한 것

- 확인(스크래치 `python-pptx` 샘플, .venv python-pptx 1.0.2): placeholder 위치 상속됨, 글자 크기 상속 안 됨(마스터 4400), 테마 `clrScheme`·`clrMap` 읽기,
  `p:style fillRef` 가 기본 도형 채우기, 그룹 `chOff/chExt` 읽기, 회전 setter/getter, 그림·도형·run 서식 쓰기.
- 미확인: 실제 PowerPoint 가 만든 파일의 상속·그룹 변환 결과, Flutter 가 없는 글꼴 이름을 시스템에서 찾는지, 요소 단위 투명 굽기(2-6 나),
  normAutofit 를 곱했을 때 PowerPoint 와 같아 보이는지, 변환 시간.
