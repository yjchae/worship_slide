# OBS 자막 — 백엔드(데이터·저장·서버) 기술 검토

작성: 백엔드 개발자 / 기준: 팀장 지시서 `planning/obs-overlay/brief.md`, CLAUDE.md, 실제 코드
(`b_screen_store.dart`·`screen_choice_store.dart`·`export_style_store.dart`·`atomic_file.dart`·`page_template_store.dart`·
`singer_web_server.dart`·`slide_page_data.dart`·`slide_background.dart`·`export_style.dart`·`font_library.dart`·`ppt_tool.py`).
앱 코드는 고치지 않았다. **확인 안 된 것은 '미확인'** 으로 적는다. 기본값 숫자는 모두 **제안**이고 기획자·UI 설계자가 정한다.

---

## 0. 한 줄 결론

- 새 설정 파일 `Application Support/obs_overlay.json` 하나(`ObsOverlayStore`)로 끝난다. **DB 스키마 변경 없음(version 20 유지)**,
  콘티 항목별 설정 없음, `.wsconti`·찬양 동기화·클라우드 콘티 영향 없음, **Python(ppt_tool) 변경 없음**(1단계).
- 서버는 `SingerWebServer` 와 **따로**(`ObsOverlayServer`) 둔다 — 수명(앱 켜 있는 동안 상시)·포트(고정)·키(고정)·바인드 주소가 모두 다르다.
- 키는 한 번 만들어 파일에 남기고 '키 새로 만들기' 로만 바뀐다. 기본은 `127.0.0.1` 전용, 설정에서 '다른 PC 의 OBS 허용' 을 켜면 `0.0.0.0` + 키 필수.

---

## 1. 설정 저장 — `obs_overlay.json`

### 1.1 위치·패턴

| 항목 | 결정(제안) | 근거 |
|---|---|---|
| 파일 | `Application Support/obs_overlay.json` | `b_screen.json`·`screen_choice.json`·`sermon_design.json` 과 같은 곳. PC 마다 다른 값(포트·키·방송 PC 주소)이라 DB·콘티에 넣지 않는다 |
| 코드 | `lib/src/features/praise/data/obs_overlay_store.dart` — `ObsOverlayConfig`(불변, `copyWith`·`toJson`·`fromJson`) + `ObsOverlayStore`(`load`/`save`) | `BScreenConfig`/`BScreenStore` 모양 그대로 |
| 쓰기 | `atomicWriteString`(`atomic_file.dart`) | `ScreenChoiceStore.save`·`ExportStyleStore.save` 는 `writeAsString` 직접이라 쓰다 꺼지면 반쪽 파일이 남는다. 키가 들어 있는 파일이라 반쪽이 되면 OBS 주소가 깨지므로 원자 쓰기 필수 |
| 저장 실패 | `AppLogger.error('[obs] obs_overlay.json 저장 실패', …)` 후 메모리 값은 그대로 사용 | `BScreenStore.save` 와 같음 |
| 같은 키 두 곳 | `ExportStyleStore` 처럼 `fromJson` 과 스토어가 따로 키를 읽는 구조를 만들지 않는다 — **`ObsOverlayConfig.fromJson` 한 곳**만 읽는다 | CLAUDE.md: `ExportStyleStore.load` 가 새 키를 빠뜨려 설정이 돌아간 사고 |

### 1.2 JSON 스키마 초안 (`version: 1`)

색은 앱 규칙대로 `#RRGGBB`(`colorToHex`/`tryParseHexColor` — 6자리만 받는다). 투명도는 따로 0~1 숫자.
글자 크기·두께는 **슬라이드 높이 540pt 기준 pt**(앱 전체 좌표 규칙 `fontScale = 높이/540`, 편집 페이지 `fontSize` 도 같은 기준) —
OBS 페이지는 `calc(N / 540 * 100vh)` 로 그리면 소스 크기를 바꿔도 비율이 유지된다.

```jsonc
{
  "version": 1,

  // ── 서버 ──
  "enabled": false,              // 앱 켤 때 서버를 띄울지. 끄면 서버 자체를 닫는다
  "port": 8766,                  // 제안값(싱어 8765 옆). 1024~65535 밖·숫자 아님 → 기본값
  "key": "k7m2…(16자)",           // 없거나 형식이 틀리면 새로 만들어 저장(§3)
  "allow_lan": false,            // false = 127.0.0.1 만, true = 0.0.0.0 (다른 PC 의 OBS)

  // ── 언제·무엇을 보내나 ──
  "only_while_presenting": true, // true = 발표 중에만 글자, 아니면 빈 화면. false = 발표 보기에서 고른 페이지도
  "follow_blackout": true,       // 관객 블랙아웃이면 OBS 자막도 비운다
  "show_sub": true,              // 보조 줄
  "show_extra": false,           // 추가 보조 줄
  "show_bible_ref": true,        // 성경 참조(제목) 줄
  "show_song_title": false,      // 곡 제목 줄

  // ── 디자인 ──
  "layout": "full",              // "full" = 1920x1080 투명 캔버스에 위치대로 / "band" = 자막 띠만 (프론트·기획 결정)
  "font_family": "Pretendard",   // FontLibrary 이름. 목록에 없으면 그대로 두고 CSS 가 대체 글꼴로(§5)
  "font_size": 40,               // pt@540, 8~200 clamp
  "bold": true,
  "text_color": "#FFFFFF",
  "sub_text_color": "#FFF176",   // ExportStyle 보조 기본색과 같게
  "extra_text_color": "#80DEEA",
  "sub_font_ratio": 0.8,         // kMinFontRatio~kMaxFontRatio(0.3~1.5) — parseFontRatio 재사용
  "extra_font_ratio": 0.7,
  "outline_color": "#000000",
  "outline_width": 2,            // pt@540, 0~20 (0 = 없음)
  "shadow": true,
  "shadow_color": "#000000",
  "shadow_blur": 4,              // pt@540, 0~40
  "band": false,                 // 반투명 띠
  "band_color": "#000000",
  "band_alpha": 0.5,             // 0~1
  "band_padding": 12,            // pt@540, 0~100
  "align": "center",             // left|center|right — HorizontalPosition 이름 재사용
  "vertical": "bottom",          // top|middle|bottom — VerticalTextPosition 이름 재사용
  "offset_y": 0.0,               // 기준선에서 미세 조정(인치, + = 아래). clampTextOffsetY(±2.0) 재사용
  "side_margin": 0.06,           // 좌우 여백, 캔버스 폭 비율 0~0.3
  "max_lines": 0,                // 0 = 제한 없음, 1~6. 넘치면 글자를 줄일지 자를지는 프론트 결정
  "fade_ms": 200                 // 0~1000, 0 = 즉시
}
```

- 기본값 상수는 `export_style.dart` 처럼 파일 맨 위 `const kObs…` 로 두고 UI 와 테스트가 같은 값을 본다.
- enum 은 `values.asNameMap()[json[...]] ?? 기본` (`BScreenConfig.fromJson` 의 `BSide` 와 같음).
- 숫자는 `(json[k] as num?)?.toDouble()` → NaN 이면 기본 → `clamp`. `int` 칸(`port`·`max_lines`·`fade_ms`)은 `round()` 후 clamp.
- **모르는 키는 버리지 않고 보존**할지: 지금 스토어들은 모두 버린다. 이 파일은 한 PC 에서 한 앱만 쓰므로 버려도 된다(새 판에서 옛 판으로 돌아가는 경우만 손해). 보존하지 않는 쪽 제안.
- `version` 은 지금은 읽기만 하고 무시(1 이 아니어도 아는 키는 읽는다). 나중에 의미가 바뀌는 키가 생기면 그때 쓴다.
- 관객 디자인(`ExportStyle`)을 '따르기' 안으로 정해지면 디자인 칸 대신 `"follow_audience_style": true` 하나만 두고 위 디자인 키는 그때 덮어쓰는 값으로 쓴다 — 기획 결정 대기.

### 1.3 깨진 파일 처리

| 상황 | 처리 |
|---|---|
| 파일 없음 | 기본값 + **새 키를 만들어 바로 저장**(키가 파일에 있어야 다음 실행에도 같은 주소) |
| JSON 이 깨짐(`FormatException`)·최상위가 Map 아님 | `page_template_store.dart` 와 같은 방식: 기본값으로 시작하되 **파일은 바로 덮어쓰지 않고** 처음 `save` 때 `obs_overlay.json.broken.bak` 으로 남긴 뒤(이미 있으면 그대로) 쓴다. `[obs] obs_overlay.json 깨짐 — 기본값으로 시작` 로그. 설정 창에 '설정 파일을 읽지 못해 기본값입니다' 한 줄(프론트) |
| 깨진 파일 안 키 | 깨진 파일에서 `"key"` 만 정규식으로라도 건질지 → **안 건진다**(복잡도 대비 이득 작음). 대신 새 키가 생기므로 OBS 주소를 다시 넣어야 한다고 알린다 |
| 칸 하나만 틀림 | 그 칸만 기본값(위 clamp 규칙). 파일 전체를 버리지 않는다 |
| 폴더를 못 엶 | 기본값, `enabled` 는 false 로 보고 서버를 안 띄운다(저장 못 하는 키로 서버를 띄우면 다음 실행에 주소가 바뀐다) |

---

## 2. DB·콘티·동기화 영향

| 대상 | 영향 | 설명 |
|---|---|---|
| SQLite 스키마 | **없음 (version 20 그대로)** | OBS 로 보낼 글은 이미 `SlidePageData`(main/english/extra_text·title·is_bible) 에 다 있다. 새 칸이 필요 없다 |
| 콘티 항목별 OBS 설정 | **1단계 없음** | '이 항목은 OBS 에 안 보내기'·'이 곡만 다른 OBS 위치' 같은 요구가 생기면 2단계에서 `SlideBackground` JSON(`worship_conti_items.background`)에 키(예: `obs_hide`)를 얹는 길이 마이그레이션 없이 가능하다. 단 **지금 `SlideBackground.fromJson`/`toJson` 은 모르는 키를 버린다** — 옛 앱으로 콘티를 다시 저장하면 사라진다(감수할지 기획 결정). 또 그 JSON 은 `.wsconti`·클라우드로 같이 간다 |
| `.wsconti` 내보내기·가져오기 | 없음 | OBS 설정은 PC 설정이지 콘티 내용이 아니다 |
| 찬양 동기화(`SyncSnapshot`) | 없음 | 곡·번역·코드만 싣는다 |
| 클라우드 콘티 | 없음 | `.wsconti` 와 같다 |
| 코드(chord) | **OBS 로 새지 않게 확인만** | `SlidePageData` 에 코드 칸이 없어서 그걸로 만들면 저절로 안 간다. `SingerViewData`(`chord_lines`·`key_label`·`note`·`message`)에서 만들지 않는다 — §6 테스트로 고정 |
| 통역 화면(B) | 없음 | `forB` 는 쓰지 않는다. OBS 는 관객 화면과 같은 원본 기준 |
| 자동 백업(`backupBeforeUpgrade`) | 없음 | 스키마를 안 올리므로 백업도 안 생긴다 |

---

## 3. 키(토큰)·포트·바인드·보안

### 3.1 키

- 형식: `SingerWebServer` 와 같은 글자판 `abcdefghjkmnpqrstuvwxyz23456789`(헷갈리는 0·o·1·l·i 없음) 16자, `Random.secure()`.
  같은 생성 함수를 두 서버가 쓰도록 작은 함수(`newAccessToken()`)로 떼는 것을 제안(지금은 `_start` 안 지역 함수).
- **고정**: 처음 만들 때 저장하고 앱을 다시 켜도 같다. OBS 브라우저 소스 주소에 한 번 넣으면 계속 쓰게.
- 재발급: 설정 창 '키 새로 만들기'(확인창: 'OBS 에 넣은 주소를 다시 넣어야 합니다'). 저장 → 서버는 끄지 않고 키만 바꾸고,
  **붙어 있는 SSE 연결을 모두 끊는다**(옛 키로 붙은 OBS 가 계속 받지 않게). 옛 키 요청은 403.
- 검사: 모든 경로(`/obs`, `/obs/events`, `/obs/state`, `/obs/font/…`)에서 `?k=` 일치. 비교는 길이 같을 때 상수 시간 비교 권장(싱어 서버는 `!=` — 위협 모델상 큰 차이는 없음).
- 로그에 키 전체를 남기지 않는다(`k7m2…` 앞 4자만).
- 저장 위치가 `Application Support` 평문이다 — 싱어 키는 메모리뿐이지만 OBS 키는 읽기 전용 자막이라 평문 저장으로 충분하다고 본다(동기화 키 `sync_key.txt` 도 평문).

### 3.2 포트

- 고정 포트(제안 8766). **다른 프로그램이 쓰고 있으면 아무 포트로 넘어가지 않는다** — 싱어 서버는 빈 포트로 넘어가지만 OBS 는 주소가 바뀌면 조용히 끊긴다.
  대신 상태를 '포트 8766 을 다른 프로그램이 쓰고 있음' 오류로 두고 설정 창에서 포트를 바꾸게 한다(`[obs] 포트 사용 중` 로그).
- 싱어 서버와 같은 포트를 고르지 못하게 막는다(8765 및 싱어가 지금 쓰는 포트). 싱어 서버가 8765 를 못 잡아 아무 포트로 갔을 때 OBS 포트와 겹칠 일은 OS 가 막는다.
- 127.0.0.1 만 비었는지 먼저 보는 싱어 서버의 macOS 함정(`0.0.0.0` bind 가 `127.0.0.1` 점유를 못 알아챔)은 OBS 도 같으므로 같은 검사를 한다 — `allow_lan` 일 때.
- 포트·`allow_lan` 을 바꾸면 서버를 닫고 다시 연다(`start`/`stop` 큐 — 싱어 서버의 `_enqueue` 방식).
- 실제로 8766 이 흔한 프로그램과 겹치는지는 **미확인**.

### 3.3 127.0.0.1 전용 vs 다른 PC

| 경우 | 바인드 | 비고 |
|---|---|---|
| 앱과 OBS 가 같은 PC (기본) | `InternetAddress.loopbackIPv4` | 방화벽 질문 없음(미확인 — OS 마다 다를 수 있으나 loopback 은 보통 묻지 않는다), 망의 다른 기기에서 아예 안 보임 |
| 방송 PC 가 따로 (`allow_lan: true`) | `InternetAddress.anyIPv4` | 처음 켤 때 OS 방화벽 허용 필요(싱어 서버와 같은 안내). 주소는 `lanAddresses` 와 같은 후보(사설 IPv4, 와이파이·유선 우선)로 `http://<IP>:<포트>/obs?k=…` 를 보여 준다. **앱 PC 의 IP 가 바뀌면(DHCP) OBS 주소도 바꿔야 한다** — 설정 창에 지금 주소를 늘 보여 주고 고정 IP 를 권하는 안내 |

- 교회에서 방송 PC 와 앱 PC 가 다른 경우가 흔할 수 있으므로 설정으로 고르게 한다(기본은 끔 — 켜지 않은 사람에게 망 노출이 없도록).
- 터널(cloudflared)은 쓰지 않는다. 바깥 망 OBS 는 범위 밖.
- 노출 범위: 읽기 전용(넘기기·블랙아웃 같은 제어 경로 없음). 내보내는 것은 지금 자막 글자와 글꼴 파일뿐이고 **로컬 경로·이미지·메모·메시지·코드는 싣지 않는다**.
- https 가 아니므로 같은 망에서 엿볼 수 있다(키 포함). 자막 내용이 어차피 방송되는 글이라 감수 가능한 수준으로 본다.

### 3.4 `SingerWebServer` 와 따로 둘지 — **따로** (제안)

| | 싱어 서버 | OBS 서버 |
|---|---|---|
| 켜짐 | 휴대폰 버튼, 발표 끝나면 꺼짐 | 설정 `enabled` 면 앱 켤 때부터 끝날 때까지 |
| 포트 | 8765 → 막히면 아무 포트 | 고정, 막히면 오류 |
| 키 | 켤 때마다 새로, 메모리만 | 고정, 파일 저장 |
| 바인드 | 0.0.0.0 + 터널 | 127.0.0.1(기본) / 0.0.0.0 |
| 경로 | `/`·`/events`·`/state`·`/img/*`·`/pages`·`/control` | `/obs`·`/obs/events`·`/obs/state`·`/obs/font/<n>` |

합치면 싱어 서버의 '발표 끝나면 끔·포트 바뀜·키 바뀜' 규칙을 모두 예외 처리해야 하고, 싱어 서버의 `0.0.0.0` 노출을 OBS 만 쓰는 사람에게도 열게 된다.
겹치는 코드(SSE 클라이언트 목록·15초 ping·`/state` 폴링 응답·`force` close)는 작으므로 1단계는 복사 또는 작은 공용 함수로 충분하다.
OBS 는 같은 PC(또는 LAN)라 SSE 만으로 되지만, CEF 가 SSE 를 문제없이 받는지는 **미확인** → 페이지가 SSE 실패 시 `/obs/state` 폴링으로 내려가는 길을 남겨 둔다(싱어 페이지와 같은 이중화).

### 3.5 서버가 보내는 데이터 (`ObsCaptionData`)

`SlidePageData` 에서 만드는 순수 함수 `obsCaptionFor(SlidePageData?, ObsOverlayConfig, {presenting, blackout})` → JSON:

```jsonc
{ "rev": 12, "visible": true, "kind": "lyrics" /* lyrics|bible|empty */,
  "title": "요한복음 3:16", "main": "…", "sub": "…", "extra": "",
  "design": { /* §1.2 디자인 칸 그대로 + font_url */ } }
```

- 글이 없는 페이지(PPT·편집 페이지 그림, 빈 페이지, 미디어, 자동 여백)는 `visible:false`(빈 자막). 무엇을 보낼지는 기획 결정 — 백엔드는 `kind` 로 가를 수 있게만 둔다.
- 설교 제목 페이지(`SlideBackground.isSermon`): 글이 있으므로 보낼 수 있다. 보낼지는 기획 결정.
- `show_*`·`only_while_presenting`·`follow_blackout` 은 **서버(Dart)에서 미리 적용**해 페이지 JS 가 판단하지 않게 한다(테스트가 쉽다).
- 디자인만 바뀌어도 다시 보낸다(설정 창에서 고치면 OBS 미리보기가 바로 바뀌게). 같은 JSON 이면 안 보낸다(싱어 서버 `_lastJson` 방식).
- 새로 붙은 클라이언트에는 붙자마자 마지막 JSON.

---

## 4. Python(ppt_tool) — 1단계 변경 없음

- 1단계 OBS 자막은 Dart 가 이미 가진 글(곡·성경·빈 페이지 문구)만 쓰므로 Python 은 손댈 게 없다. `RENDER_CACHE_VERSION` 도 그대로.

### 4.1 PPT 그림 페이지 글자 — 이후 단계 아이디어 (범위 밖)

지금 `ImageStagingItem` 은 PNG 경로(+ 전체 원본일 때만 `sourcePath`)뿐이라 **글자를 얻을 곳이 없다**. 길은 셋:

1. **렌더할 때 글자 옆 파일**(추천): `render` 가 페이지 PNG 옆에 `NNNN.text.json`(`{"lines": [...]}`)을 쓴다 — 이미 `NNNN.media.json` 을
   PNG 옆에 두고 Dart `_pptMedia` 가 찾는 방식이 있어서, 나누기·복사·옮기기로 이미지 경로만 옮겨 다녀도 따라간다.
   글자는 `extract_text_from_shape`(가져오기에서 쓰는 것)로 뽑을 수 있다. 문제:
   - 애니메이션 펼치기(`expand_animation_steps`)로 한 슬라이드가 여러 장이 되면 장마다 보이는 문단이 다르다 → 펼친 사본 pptx 에서 장마다 뽑아야 맞다(구현 난이도 미확인).
   - PDF 는 PyMuPDF 로 글자를 뽑을 수 있지만 줄 순서·읽는 순서가 맞는지 미확인.
   - 기존 렌더 폴더에는 이 파일이 없다. `RENDER_CACHE_VERSION` 을 올리면 모두 다시 굽고(느림), 안 올리면 '글자만 뽑는 명령'(`texts <파일> <렌더 폴더>`)을 따로 두어 필요할 때 채운다 — 후자 제안.
   - `.wsconti` 는 이미지만 담으므로 옆 파일은 안 간다(담으려면 `.wsconti` 형식에 추가 — 범위 밖).
   - 렌더 캐시가 `ppt_slides/<해시>/` 라 같은 파일을 쓰는 다른 콘티도 같이 혜택.
2. **원본에서 그때그때**: `sourcePath` 가 있는 항목만 → 나누기·복사한 항목은 null 이라 안 된다. 비추천.
3. **OS OCR 로 PNG 읽기**: 이미 `worship_slides/ocr` 채널이 있다. 배경 그림 위 글자 인식 정확도 미확인, 비추천.

- **슬라이드 편집 페이지**(구운 PNG)는 따로 쉽다: 요소 목록(`SlideBackground.pageElements` 의 `PageTextElement.text`)이 이미 있어서
  Python 없이 Dart 에서 '글 상자 글을 위→아래 순서로 잇기' 로 만들 수 있다. 단 클릭 단계(`appear`/`disappear`)가 있으면 그 장에 보이는 요소만(`visibleAt`). 2단계 후보로 적는다.
- 'PPT 를 편집 페이지로 가져오기'(`layout`) 로 들여온 페이지는 위 편집 페이지 길을 그대로 탄다.

---

## 5. 글꼴 전달

- OBS 페이지는 http 로 열리므로 `file://` 경로나 macOS 발표 창의 data URI 방식을 그대로 못 쓴다(data URI 를 JSON 에 매번 실으면 수 MB).
- `/obs/font/<n>?k=` 로 **지금 디자인 글꼴의 파일만**(`FontLibrary.filesFor(family)` 목록 번호) 내보낸다. 경로를 주소에 넣지 않는다(싱어 서버 `/img/current` 와 같은 원칙).
  페이지는 `@font-face { src: url(/obs/font/0?k=…&v=<판>) }`.
- 앱 목록에 없는 이 PC 글꼴(`FontLibrary.loadSystemFont`, 라이선스상 복사 안 함)은 **내보내지 않는다** — CSS `font-family` 이름만 주고 OBS PC 에 그 글꼴이 깔려 있으면 쓰인다.
  같은 PC 면 보통 깔려 있다. LAN 다른 PC 면 대체 글꼴(설정 창에 안내).
- CEF 가 `@font-face` 로 받은 woff/ttf/otf 를 다 읽는지는 **미확인**(일반 Chromium 이라 될 것으로 보지만 실기 확인 필요).

---

## 6. 로그·테스트

### 6.1 로그 (`app.log`, 머리 `[obs]`)

`AppLogger.info`/`error` 로 다음만 남긴다(페이지 넘길 때마다 남기지 않는다):
- 서버 켬/끔(바인드 주소·포트), 포트 사용 중, 설정 파일 깨짐·`.broken.bak` 만듦, 저장 실패, 키 재발급(앞 4자), 틀린 키 요청(주소·경로, 1분에 한 번만), 클라이언트 붙음/떨어짐 수(붙을 때만).

### 6.2 테스트 계획

새 파일 두 개 + 기존 하나 보강. CLAUDE.md '주요 명령어' 에도 줄을 더한다.

**`test/obs_overlay_store_test.dart`** — 설정(순수 + 임시 폴더)
- 기본값 `toJson → fromJson` 왕복이 같다. 모든 칸.
- 범위 밖 숫자 clamp(`port` 0·70000·문자열, `font_size` 음수·NaN, `band_alpha` 2, `fade_ms` -1, `offset_y` ±5 → ±2.0, 비율 → 0.3~1.5).
- 틀린 enum(`align: "diag"`) → 기본. 틀린 색(`"red"`, `#12345`) → 기본.
- 키: 없음·빈 값·글자판 밖·길이 틀림 → 새 키 + 저장됨. 맞는 키는 그대로 유지(두 번 load 해도 같다).
- 깨진 JSON → 기본값, 원본 그대로, 첫 save 에서 `.broken.bak` 생성, 두 번째 깨짐에서 bak 덮어쓰지 않음.
- 저장은 원자 쓰기(임시 파일이 남지 않음).
- 스토어는 `getApplicationSupportDirectory` 대신 폴더를 주입받을 수 있게(`ObsOverlayStore({Directory? dir})`) — 기존 스토어들은 주입이 없어 테스트가 어렵다.

**`test/obs_overlay_server_test.dart`** — 서버(`singer_web_server_test.dart` 모양, 실제 소켓)
- 키 없음·틀림 → 403, 맞으면 `/obs` 200 html.
- `/obs/events` SSE: 붙자마자 마지막 JSON, `update` 로 바뀌면 받음, 같은 JSON 은 안 보냄.
- `/obs/state` 폴링이 같은 JSON.
- 키 재발급 → 옛 SSE 연결 끊김, 옛 키 403, 새 키 200.
- 기본 바인드는 127.0.0.1 — 사설 IP 로 붙으면 연결 거부(테스트 환경에 사설 IP 가 없으면 skip).
- 포트가 이미 쓰이면 다른 포트로 가지 않고 오류 상태.
- `/obs/font/0` 은 지금 글꼴 파일만, 범위 밖 번호·`..` 는 404. 주소·응답 어디에도 로컬 경로가 없다.
- stop 후 start 가 같은 포트·같은 키.

**`test/obs_caption_test.dart`** (또는 위 파일 안 group) — 순수 함수 `obsCaptionFor`
- 곡: main/sub/extra, `show_sub`·`show_extra` 끄면 빈칸.
- 성경: 참조 제목, `show_bible_ref`.
- 그림 페이지·빈 페이지·미디어·자동 여백 → `visible:false`.
- `only_while_presenting` + 발표 전 → `visible:false`. `follow_blackout` + 블랙아웃 → `visible:false`.
- **누출 없음**: 결과 JSON 에 `image_path`·로컬 경로·`chord`·`key_label`·`note`·`message` 가 없다(`chord_leak_test.dart` 에 OBS 경로 한 줄 추가도 가능).

**Python**: 1단계 변경 없음 → 새 self-check 없음.

### 6.3 확인 못 하는 것 (실기 필요)

- OBS 브라우저 소스가 투명 바탕을 투명으로 합성하는지, SSE·`@font-face`·CSS `-webkit-text-stroke`/`text-shadow` 를 그대로 그리는지 — **미확인**, 사용자 확인.
- Windows 방화벽이 loopback 바인드에도 묻는지 — 미확인.
- macOS 앱 샌드박스/네트워크 권한: 싱어 서버가 이미 0.0.0.0 으로 듣고 있으므로 새 권한은 필요 없을 것으로 보나 127.0.0.1 전용도 같은지 미확인.

---

## 7. 결정할 것 (백엔드 관점에서 기획자에게 넘김)

1. 기본 포트 값(제안 8766)과 '포트 사용 중' 때 아무 포트로 넘어가지 않는 정책 확인.
2. `allow_lan` 기본 끔 확인, 켤 때 안내 문구.
3. 글 없는 페이지(그림·빈·미디어)·설교 제목 페이지를 보낼지.
4. 디자인: 별도(`obs_overlay.json` 디자인 칸) vs 관객 디자인 따르기(`follow_audience_style`).
5. 항목별 OBS 설정(숨기기 등)을 2단계에서 `SlideBackground` JSON 키로 할지 — 옛 앱 재저장 시 사라짐 감수 여부.
6. PPT 그림 페이지 글자(§4.1)를 몇 단계에서 할지, 편집 페이지 글 상자 글(Dart 만으로 가능)을 먼저 할지.
