# OBS 자막 — 프론트(Flutter/Dart) 기술 설계

작성: 프론트 개발자 · 근거: `brief.md`, CLAUDE.md, 아래 코드(읽고 확인한 것만 적는다. 확인 못 한 것은 **미확인**).

읽은 코드
- `lib/src/features/praise/data/singer_web_server.dart` — `SingerWebServer`(start/stop 큐 `_enqueue`, `_start` 의 127.0.0.1 선점 검사 후 `anyIPv4` bind, 실패하면 포트 0, 토큰 `?k=` 16자, `/events` SSE + 15초 `: ping`, `_lastJson` 같으면 안 보냄, `/img/*` 는 경로 대신 주소), `singerPageHtml`(글자는 `textContent`, `fitBox` 이분 탐색 글자 맞춤)
- `lib/src/features/praise/presentation/slide_page_data.dart` — `toJson` 에 `image_path`(로컬 경로)·`style.font_files`(로컬 경로)·`media.html` 이 실린다
- `praise_home_page.dart` — `_sendCurrentSlide`(2494행 부근, 관객 → `_sendB` → `_sendSingerView`), `_sendSingerView`(2317행 부근), `_toggleBlackout`(1550행 부근), `_resetPresentationState`(1525행 부근, `_singerWeb.stop()`), `_updateStyle`(830행 부근, 끝에 `_sendCurrentSlide`), `initState` 의 `AppLifecycleListener.onExitRequested`(572행 부근, 싱어 서버를 3초 제한으로 끔), `dispose`(688행 부근), `_buildSlidePageData`(1403행 부근), `_SlideInfo`(114행)
- `data/b_screen_store.dart`·`data/screen_choice_store.dart`·`data/atomic_file.dart` — 설정 JSON 저장 패턴(`fromJson` 이 틀린 값은 기본값/clamp, 깨진 파일은 기본값, `atomicWriteString`, 실패는 `AppLogger`)
- `data/font_library.dart` — 내장 3종(`bundledFamilies`: Pretendard·NanumGothic·NanumMyeongjo)은 pubspec `fonts:` 자산이라 **디스크 파일이 없다**(`filesFor` 가 빈 목록). 무료 폰트는 `Application Support/fonts/` 파일(`FontLibrary.fonts[].files`)
- `presentation/style_fields.dart` — `FieldBox`·`ColorField`·`HexColorDialog`·`FontFamilyPicker`
- `macos/Runner/DebugProfile.entitlements`(`network.server` 있음)·`Release.entitlements`(`network.client` 만) — 둘 다 `com.apple.security.app-sandbox` 키가 **없다**

---

## 1. 서버: 싱어 서버에 `/obs` 를 더할까, 새 클래스를 둘까

| | A. `SingerWebServer` 에 `/obs` 추가 | B. 새 `ObsOverlayServer` (추천) |
|---|---|---|
| 수명 | 싱어 서버는 휴대폰 버튼으로 켜고 `_resetPresentationState`·`_sendCurrentSlide` 실패 경로에서 `stop()` 한다. OBS 는 앱이 켜져 있는 동안 늘 있어야 하므로 이 꺼짐 경로를 모두 "OBS 쪽은 남기기"로 갈라야 한다 | 앱 시작 때 켜고 종료 때 끈다. 발표·휴대폰과 무관 |
| 포트 | 8765, 쓰고 있으면 **아무 빈 포트**(`bind(..., 0)`) — 주소가 바뀌면 OBS 설정이 깨진다 | 고정 포트. 못 잡으면 **다른 포트로 가지 않고** 알린다 |
| 키 | 켤 때마다 새 토큰 | 설정 파일에 고정 |
| bind | `anyIPv4`(휴대폰용) + 터널(cloudflared)로 인터넷에 열린다 | `127.0.0.1` 기본(다른 PC OBS 옵션만 LAN) — 인터넷으로 안 나간다 |
| 코드 | 1,500줄 파일에 조건 분기 추가, 기존 테스트(`test/singer_web_server_test.dart`)가 잡는 동작(포트 대체·stop 시 비우기)과 충돌 | 200~300줄 새 파일. SSE·키 검사 모양은 싱어 서버를 본떠 쓴다 |

**추천: B.** 수명·포트·키·노출 범위 네 가지가 모두 반대라 한 클래스에 넣으면 분기만 는다. 공통으로 쓸 것은 `SingerWebServer.lanAddresses()`(static, LAN 옵션 주소 표시)뿐이고 그대로 부른다.

### 1-1. `lib/src/features/praise/data/obs_overlay_server.dart` (새 파일)

```
class ObsOverlayServer {
  ObsOverlayServer({this.fontBytes});            // 테스트에서 글꼴 읽기를 바꿔 끼운다
  final running = ValueNotifier(false);           // 설정 창이 듣는다
  final error = ValueNotifier<ObsServerError?>(null); // portInUse / other
  Future<void> start({required int port, required String key, required bool lan});
  Future<void> stop();
  bool get isRunning;
  void update(ObsOverlayData data);               // JSON 이 같으면 안 보낸다
  String urlFor(String host);                     // http://<host>:<port>/obs?k=<key>
}
```

- **start/stop 큐**: 싱어 서버의 `_enqueue` 와 같은 방식(앞 작업 실패가 뒤를 막지 않게 `catchError`).
- **bind**: 기본 `HttpServer.bind(InternetAddress.loopbackIPv4, port)`. LAN 옵션이면 `anyIPv4`.
  싱어 서버 주석대로 macOS 에선 다른 프로그램이 127.0.0.1:port 만 잡고 있어도 0.0.0.0 bind 가 성공하므로, LAN 모드에서도 **127.0.0.1 선점 검사를 먼저** 한다(`ServerSocket.bind(loopbackIPv4, port)` 후 close — `_start` 와 같은 순서). OBS 는 같은 PC 면 127.0.0.1 로 붙으므로 이 검사가 빠지면 OBS 가 엉뚱한 프로그램에 붙는다.
- **포트 충돌**: `SocketException` 이면 **빈 포트로 대체하지 않는다**. `error.value = portInUse`, `running.value = false`. 상태 줄·설정 창이 "포트 N 을 다른 프로그램이 쓰고 있습니다. 설정에서 포트를 바꾸면 OBS 브라우저 소스 주소도 바꿔야 합니다" 를 띄운다. 포트는 설정 파일에 있으므로 사용자가 바꾸면 그 뒤로는 고정이다.
  - 같은 앱을 두 군데(두 폴더) 켜면 두 번째가 portInUse 가 된다 — 이건 정상 동작으로 둔다(설정 `Application Support` 는 하나라 키도 같다).
  - 기본 포트 값은 기획에서 정한다(싱어 8765 와 다른 값). 싱어 서버는 8765 를 못 잡으면 OS 가 주는 임의 포트(`bind(…, 0)`)로 가는데, 그게 OBS 포트와 겹칠 가능성을 없애려면 OBS 서버를 **앱 시작 때 먼저** 켜서 자리를 잡아 둔다(싱어 서버는 휴대폰 버튼을 눌러야 켜지므로 순서상 자연히 그렇게 된다).
- **요청 검사** (`_handle`)
  1. `?k=` 가 설정 키와 다르면 403(싱어 서버와 같은 안내 문구 꼴).
  2. **Host 헤더 검사**: 127.0.0.1 모드면 `Host` 가 `127.0.0.1:<port>`·`localhost:<port>` 일 때만. 브라우저에서 연 악성 페이지가 DNS rebinding 으로 127.0.0.1 에 붙는 경우를 막는다(키가 있어 실질 위험은 낮지만 비용이 거의 없다). LAN 모드는 검사하지 않는다(사설 IP 가 바뀔 수 있음).
  3. GET 만 받는다. `/control` 같은 쓰기 경로는 **없다** — OBS 페이지는 받기만 한다.
- **경로**
  - `GET /obs` → `obsOverlayHtml`(1-2). `Cache-Control: no-store`.
  - `GET /events` → SSE. 붙자마자 `retry: 1000\n` + 지금 JSON(`data: …`). 15초마다 `: ping`(싱어와 같다 — 끊김 감지). `res.bufferOutput = false`.
  - `GET /state` → 지금 JSON 한 번(디버그·폴백용. OBS 는 같은 PC 라 SSE 로 충분하다고 보지만 CEF 에서 SSE 가 실제로 이어지는지는 **미확인** → 페이지는 SSE 가 10초 안에 첫 데이터를 못 받으면 `/state` 1초 폴링으로 내려간다).
  - `GET /font/<n>` → 글꼴 파일(아래 1-3). 그 외 404.
- `stop()` 은 `close(force: true)` 후 클라이언트를 닫고 `_lastJson` 은 **남긴다**(다시 켤 때 바로 보내려고 — 싱어 서버와 다른 점, 싱어는 발표 단위라 비운다).

### 1-2. `obsOverlayHtml` (같은 파일 아래 Dart `const` 문자열, 외부 파일 없음)

- **투명 바탕**: `html,body{background:transparent;margin:0;overflow:hidden}`. OBS 브라우저 소스 기본 '사용자 지정 CSS' 에 `background-color: rgba(0,0,0,0)` 가 들어 있다고 알려져 있으나 **미확인 — 사용자 확인 항목**. 페이지 자체가 투명이면 둘 다 맞는다.
- **좌표계**: 1920x1080 을 기준으로 `--u: calc(100vh / 1080)` 를 두고 모든 크기를 `calc(N * var(--u))` 로 쓴다(앱의 540pt 기준 `calc(N / 540 * 100vh)` 와 같은 발상). OBS 소스 크기를 1280x720 으로 해도 비율대로 줄어든다.
- **구조**: `#stage`(전체) 안에 `#band`(반투명 띠, 선택) → `#ref`(성경 참조/곡 제목), `#main`, `#sub`, `#extra`. 띠는 아래·위·가운데 기준 + 여백(디자인 값).
- **글자 넣기**: 늘 `textContent`(싱어 페이지와 같다, HTML 주입 없음). 줄은 `white-space: pre-wrap; word-break: keep-all`.
- **외곽선·그림자**: 외곽선은 `-webkit-text-stroke` 를 쓰면 획 안쪽까지 먹어 한글 획이 가늘어지므로 `paint-order: stroke fill` 과 함께 쓴다. CEF(Chromium) 판의 `paint-order` 지원 여부는 **미확인** → 대안으로 `text-shadow` 8방향(외곽선 두께 = 오프셋)을 쓰는 안을 기본으로 하고, 그림자는 그 뒤에 하나 더 붙인다. 둘 중 고르는 것은 OBS 에서 실제로 보고 정한다(사용자 확인 항목).
- **자동 글자 축소**: `#lines` 의 최대 높이 = 디자인 '최대 높이(1080 기준 px)'. 넘치면 `singerPageHtml` 의 `fit()` 과 같은 이분 탐색으로 전체 배율(`--fit`, 0.5~1)을 줄인다. 원본·보조·추가 보조는 같은 배율로 같이 준다(비율 유지). 하한에 닿으면 그대로 두고 넘친다(잘라내지 않음).
- **페이드**: 두 레이어(`.layer.a`/`.b`)를 번갈아 쓴다 — 새 내용을 안 보이는 레이어에 넣고 맞춤까지 끝낸 뒤 `opacity` 전환(디자인 `fade_ms`, 0 = 즉시). 같은 내용이면(키 비교) 아무것도 안 한다. 숨김(`show:false`)은 지금 레이어만 페이드 아웃.
- **연결**: `new EventSource('/events'+location.search)`. `onerror` 이면 **즉시 숨긴다** — 앱이 꺼지거나 멈췄을 때 마지막 가사가 방송에 얼어붙는 것보다 안 보이는 게 낫다. 다시 붙으면 서버가 지금 JSON 을 먼저 보내므로 저절로 돌아온다.
- **글꼴**: JSON 의 `font` (`{family, faces:[{url, weight}]}`)를 받아 처음 볼 때 `new FontFace(family, 'url(...)', {weight})` → `document.fonts.add` → `load()` 끝난 뒤 맞춤을 다시 한다(글꼴이 늦게 와서 넘침 계산이 틀리지 않게).
- **미리보기 모드**: `?k=…&preview=1` 이면 바탕에 체커보드를 깐다(설정 창 '브라우저로 열어 보기'용 — 일반 브라우저는 투명을 흰색으로 그린다).

### 1-3. 글꼴 `/font/<n>`

- 서버는 **디자인에서 고른 글꼴 하나의 면들만** 번호로 내보낸다(경로를 주소에 넣지 않는다 — 싱어 `/img/page/<n>` 와 같은 원칙).
- 무료 폰트: `FontLibrary.filesFor(family)` 의 파일을 읽는다.
- 내장 3종: 디스크 파일이 없으므로 `rootBundle.load('assets/fonts/<파일>')` 로 읽는다. 이름 → 자산 표는 pubspec 과 같은 상수로 둔다(`Pretendard` 4면, `NanumGothic`·`NanumMyeongjo` 각 2면). 서버는 `fontBytes` 콜백으로 받아 테스트에서 바꿔 끼운다.
- **이 PC 글꼴**(`FontLibrary.systemFamilies`, PPT 가져오기로 읽어 올린 것)은 **내보내지 않는다** — 라이선스 원칙(복사·재배포 안 함)과 같다. OBS 가 같은 PC 면 CSS `font-family` 이름만으로 시스템 글꼴을 찾을 수 있으므로 `faces` 없이 이름만 보낸다. LAN 모드(다른 PC OBS)는 그 PC 에 없으면 대체 글꼴 — 설정 창에 안내.
- `Content-Type: font/ttf` 또는 `font/otf`, `Cache-Control: max-age=86400`(주소에 판 값 `v=` 를 붙여 바뀌면 새로 받게).

---

## 2. 보낼 JSON — 새 `ObsOverlayData` (SlidePageData 재사용 안 함)

`SlidePageData.toJson` 은 `image_path`·`style.font_files`·`media.html`(로컬 파일 경로가 든 HTML)을 싣는다. 이걸 받아 지우는 방식은 새 칸이 생길 때마다 새는 길이 생기므로, **필요한 칸만 새로 만든다**(화이트리스트).

새 파일 `lib/src/features/praise/presentation/obs_overlay_data.dart` (순수 Dart, 테스트 대상)

```
class ObsOverlayData {
  final bool show;          // false = 숨김(이유는 hiddenReason, 디버그·테스트용)
  final String kind;        // 'lyrics' | 'bible' | 'text'(설교 제목 등)
  final String main, sub, extra;
  final String heading;     // 성경 참조 또는 곡 제목('' = 없음)
  final ObsDesign design;   // 2-1
  final ObsFont font;       // family + faces(url 만)
  Map<String,dynamic> toJson();
}

/// 순수 함수. _SlideInfo 가 private 이라 필드로 받는다.
ObsOverlayData obsOverlayDataFor({
  required bool live,          // 발표 중인가(설정 '발표 전에도' 면 늘 true)
  required bool blackout,
  required String mainText, englishText, extraText,
  required String? title,
  required bool isBible, isImage, isBlank, isAutoSpacer, hasMedia, isSermon,
  required ObsDesign design,
  required ObsFont font,
});
```

숨김 규칙(기획 결정 표에 올릴 기본안)
| 상황 | 기본안 |
|---|---|
| 발표 전(`!_isPresentationOpen`) | 숨김. 설정 '발표 전에도 내보내기' 켜면 발표 보기 현재 페이지 |
| 블랙아웃 | 숨김(설정으로 '블랙아웃 무시' 가능하게 할지는 기획) |
| PPT·편집 페이지(`imagePath != null`) | 숨김 — 글자가 없다. 그림을 OBS 로 보내는 것은 이번 범위 밖 |
| 빈 페이지·자동 여백·맨 앞 빈 페이지 | 숨김 |
| 미디어 페이지 | 숨김 |
| 설교 제목 페이지(문구 있는 빈 페이지 + `isSermon`) | 기획 결정. 기본안 = `kind:'text'` 로 주제·부제를 보인다 |
| 곡 | main/sub/extra. 보조·추가 보조는 OBS 디자인의 줄 스위치로 따로 끈다(관객 `includeEnglishLyrics` 와 별개로 둘지 따를지 기획 결정 — 기본안: 따른다 + OBS 쪽 끄기만 추가) |
| 성경 | main/sub/extra + `heading` = 참조(`title` — 성경 항목은 `item.reference` 가 들어간다, 1292행 부근) |

- 원본 글이 공백뿐이면 숨김.
- 페이지 서식(`page_format`)·항목 배경·관객 디자인 위치는 **안 따른다**(OBS 디자인 하나). 코드(`chordText`)·송폼·메모도 안 싣는다.
- JSON 에는 경로가 하나도 없다: 글꼴은 `/font/<n>?v=` 주소만.

### 2-1. OBS 디자인 `ObsDesign` + 설정 파일

새 파일 `lib/src/features/praise/data/obs_overlay_store.dart` — `b_screen_store.dart` 와 같은 모양.

```
class ObsOverlayConfig {
  bool enabled;        // 기본 false
  int port;            // 기본값은 기획 결정
  String key;          // 처음 만들 때 16자(싱어와 같은 글자 집합, Random.secure)
  bool lan;            // 다른 PC 의 OBS 허용, 기본 false
  bool liveOnly;       // 발표 중에만, 기본 true
  ObsDesign design;
}
class ObsDesign {
  String fontFamily; bool bold;
  double fontSize;            // 1080 기준 px
  double subRatio, extraRatio;
  Color color, subColor, extraColor;
  double outlineWidth; Color outlineColor;
  double shadowBlur; Color shadowColor;     // 0 = 없음
  bool band; Color bandColor; double bandOpacity;  // 반투명 띠
  String anchor;               // bottom | top | center
  double margin;               // 1080 기준 px
  String align;                // left | center | right
  double maxHeight;            // 넘치면 축소
  bool showHeading;            // 성경 참조
  bool showSub, showExtra;
  int fadeMs;                  // 0 = 끔
}
class ObsOverlayStore { load(); save(config); }   // Application Support/obs_overlay.json
```

- `fromJson` 은 틀린 값을 기본값으로, 숫자는 clamp(`BScreenConfig.fromJson` 처럼). 파일 전체가 깨져 키를 못 읽으면 새 키가 생겨 OBS 주소가 바뀐다 — 이때 `load()` 가 깨짐 표시를 돌려주고 설정 창·스낵바가 "설정 파일을 읽지 못해 OBS 주소가 바뀌었습니다. OBS 브라우저 소스 주소를 다시 넣어 주세요" 를 띄운다(페이지 틀 저장소의 '깨진 파일' 알림과 같은 방식). 키만 틀린 꼴이면(글자 집합 밖) 역시 새로 만든다.
- 키는 **처음 켤 때 한 번** 만들고 저장한다. 설정 창 '주소 새로 만들기'(키 재발급, 확인창 — OBS 주소도 바꿔야 함).
- 저장은 `atomicWriteString`, 실패는 `AppLogger.instance.error`.
- 키는 이 PC 설정 파일에만 있다(동기화·`.wsconti` 에 안 실림).

---

## 3. `praise_home_page.dart` 에 끼우는 자리

새 필드: `final ObsOverlayServer _obs = ObsOverlayServer();`, `ObsOverlayConfig _obsConfig = …;`, `final _obsStore = ObsOverlayStore();`

| 위치 | 변경 |
|---|---|
| `initState` (572행 부근) | `_obsStore.load()` → `enabled` 면 `_obs.start(...)` 후 `_sendObs()`. 실패(portInUse)는 스낵바 + 상태 줄 표시 |
| `AppLifecycleListener.onExitRequested` | 싱어 서버와 **나란히** `_obs.stop().timeout(3s).catchError` (둘을 `Future.wait` 로 — 하나가 늦어도 3초 안에 닫히게) |
| `dispose` (688행 부근) | `_obs.stop()` |
| `_sendCurrentSlide` (2494행 부근) | 끝에 `_sendObs(slides)`. **`_isPresentationOpen` 과 무관하게** 부른다(발표 전엔 `show:false` 가 나간다). catch 경로(발표 창 실패로 `_isPresentationOpen = false` 하고 `return`)에서도 숨김이 나가야 하므로 `return` 앞에 `_sendObs(slides)` 를 넣거나 `finally` 로 뺀다. 관객 창 응답을 기다리지 않게 하려면 `_sendObs` 를 맨 앞에 둘지 기획과 상의 — **추천: 맨 앞**(텍스트라 비용이 작고, OBS 가 관객 화면보다 늦을 이유가 없다. `seq != _pageSendSeq` 검사는 필요 없음 — 늘 지금 값을 보낸다) |
| `_toggleBlackout` (1550행 부근) | 상태를 바꾼 직후와 실패로 되돌린 뒤 `_sendObs()` |
| `_resetPresentationState` (1525행 부근) | `_singerWeb.stop()` 옆에 `_sendObs()`(서버는 **끄지 않는다**, 숨김만). setState 콜백 안에서 불리므로 `scheduleMicrotask` 로 밖에서 보낸다 |
| `_updateStyle` (830행) | 이미 끝에서 `_sendCurrentSlide` 를 부르므로 추가 없음(보조 언어 바뀜 → 글이 바뀜) |
| OBS 디자인 변경 | 설정 창 콜백 `_updateObsConfig(config)` → 저장 + 필요하면 서버 재시작(포트·LAN·키가 바뀐 경우만) + `_sendObs()` |
| `_appBarActions` (8195행 부근) | 모니터 버튼 옆 'OBS 자막' 아이콘 버튼(켜져 있으면 점 표시, 포트 오류면 경고색). 누르면 설정 창 |
| 상태 줄 `_StatusBar` | portInUse 일 때만 'OBS 자막 꺼짐(포트 사용 중)' |

`_sendObs` 본문(새 메서드)
```
void _sendObs([List<_SlideInfo>? slides]) {
  if (!_obs.isRunning) return;
  slides ??= _allSlides;
  final s = slides.isEmpty ? null : slides[_currentSlideIndex.clamp(0, slides.length - 1)];
  _obs.update(obsOverlayDataFor(
    live: _isPresentationOpen || !_obsConfig.liveOnly,
    blackout: _isBlackout, ... s 의 필드 ...,
    isBlank: s == null || s.isBlank || s.stagingUid == _leadingBlankUid,
    isSermon: s?.background?.isSermon ?? false,
    design: _obsConfig.design, font: _obsFont));
}
```
- 같은 JSON 이면 서버가 안 보낸다(디자인 슬라이더를 끌 때 `_sendCurrentSlide` 가 자주 불려도 OBS 쪽 트래픽은 내용이 바뀔 때만).
- 페이지 바뀜 경로가 모두 `_sendCurrentSlide` 를 지난다는 것은 CLAUDE.md·코드 주석(2494행 부근) 기준. 콘티 편집으로 지금 페이지 **글만** 바뀌는 경로(가사 수정 창 저장 등)도 이 함수를 부르는지는 호출처 32곳을 전수 확인하지 않았다 → **구현 때 확인**(빠진 곳이 있으면 싱어 화면도 같이 늦는 기존 문제다).

---

## 4. 설정 UI — 새 파일 `lib/src/features/praise/presentation/obs_overlay_dialog.dart`

`ObsOverlayDialog(config, server, onChanged)` — 다이얼로그(통역 화면 설정 `BScreenSettingsDialog` 와 같은 자리·모양).

1. **켜기 스위치** + 상태(켜짐 / 꺼짐 / 포트 사용 중 + 이유).
2. **주소 줄**: `http://127.0.0.1:<port>/obs?k=<key>` 읽기 전용 + '복사'(`Clipboard.setData`) + '브라우저로 열어 보기'(`…&preview=1`, macOS `open`, Windows 기존 네이티브 `openFile`(5377행 부근 사용처) — URL 을 넘겨도 되는지는 **미확인**, 안 되면 `url_launcher` 같은 새 의존성 대신 `cmd`·`explorer` 를 쓰지 말고 주소 복사만 둔다).
   - 안내 문구: "OBS → 소스 추가 → 브라우저 → URL 에 붙여 넣기, 너비 1920·높이 1080".
   - 고급(접힘): 포트 숫자 칸, '다른 PC 의 OBS 에서 받기'(LAN) 스위치 + `SingerWebServer.lanAddresses()` 주소 목록, '주소 새로 만들기', '발표 전에도 내보내기'.
3. **디자인 칸**: `FontFamilyPicker`(글꼴), 크기·비율 숫자(`FieldBox`), `ColorField` 로 글자·보조·추가 보조·외곽선·그림자·띠 색, 외곽선 두께·그림자 흐림·띠 투명도 슬라이더, 위치(아래/위/가운데)·정렬·여백, 줄 스위치(참조·보조·추가 보조), 페이드(ms).
   - 슬라이더를 끄는 동안은 화면만 바꾸고 저장·전송은 0.2초 묶어서(`Timer`) — 디자인 리본과 같은 이유.
4. **미리보기**: 16:9 칸, 바탕은 체커보드(`CustomPainter`), 그 위에 Flutter 로 그린 근사 자막(`ObsOverlayPreview`). 지금 페이지가 숨김이면 예시 가사로.
   - **HTML 과 픽셀이 같지 않다**(Flutter 텍스트 vs Chromium). 정확한 모습은 '브라우저로 열어 보기' 또는 OBS 에서 — 창에 그렇게 적는다. 앱에 웹뷰 패키지가 없어서(pubspec 확인) 같은 HTML 로 미리 보려면 새 의존성이 필요하다 → 이번엔 안 넣는다.

---

## 5. 네이티브·OS

- **네이티브(Swift·C++) 변경 없음.** 서버·페이지 모두 Dart, 발표 창 채널도 안 건드린다.
- **macOS**: entitlements 두 파일 모두 `app-sandbox` 키가 없어 샌드박스가 아니다(코드 확인). 싱어 서버가 이미 Release 빌드에서 listen 한다(CLAUDE.md). 따라서 추가 엔타이틀먼트 없음. macOS 애플리케이션 방화벽은 127.0.0.1 bind 에 묻지 않는 것으로 알려져 있으나 **미확인**. LAN 모드는 싱어 서버와 같은 '들어오는 연결 허용' 창이 뜰 수 있다.
- **Windows**: 127.0.0.1 만 bind 하면 Windows Defender 방화벽 허용 창이 안 뜨는 것으로 알려져 있으나 **미확인(실제 PC 확인 필요)**. 앱이 이미 싱어 서버(0.0.0.0)로 허용을 받은 PC 라면 LAN 모드도 같은 실행 파일 규칙으로 통과할 것으로 보이나 **미확인**.
- OBS 브라우저 소스(CEF) 쪽: 투명 합성·SSE 유지·`FontFace` API·`paint-order` 지원 모두 **미확인 → 사용자(OBS 쓰는 분) 확인 항목**. 페이지는 SSE 실패 시 `/state` 폴링으로, `paint-order` 대신 `text-shadow` 외곽선으로 떨어지게 짠다.

---

## 6. 테스트 계획

| 파일 | 항목 |
|---|---|
| `test/obs_overlay_server_test.dart` | 키 없거나 틀리면 403(`/obs`·`/events`·`/state`·`/font/0`) · Host 가 다르면 403(127.0.0.1 모드) · `/events` 붙자마자 지금 JSON · 같은 JSON 은 다시 안 보냄 · 바뀌면 보냄 · **포트를 다른 소켓이 잡고 있으면 다른 포트로 안 가고 `error=portInUse`·`running=false`**(싱어 테스트 404행 '127.0.0.1:8765 만 잡고 있으면' 과 같은 방식으로 재현) · 끄고 켜도 같은 포트·키로 다시 열리고 마지막 JSON 을 바로 줌 · start 두 번 = 서버 하나 · POST 는 405/403 · `/font/<n>` 은 고른 글꼴 면만, 범위 밖 n 은 404 · 응답 어디에도 로컬 경로(`/Users`, `C:\`, `Application Support`)가 없음 · HTML 이 `EventSource`·`textContent` 를 쓰고 `innerHTML` 을 안 씀(문자열 검사) |
| `test/obs_overlay_data_test.dart` | 발표 전 숨김 / `liveOnly=false` 면 보임 · 블랙아웃 숨김 · 그림 페이지·빈 페이지·자동 여백·미디어 숨김 · 원본 공백뿐이면 숨김 · 성경 `heading` = 참조, `showHeading=false` 면 '' · `showSub/showExtra` 끄면 빈 칸 · 설교 페이지(기획 결정값) · `toJson` 에 `image_path`·`font_files`·`media` 키 없음 |
| `test/obs_overlay_store_test.dart` | JSON 왕복 · 틀린 숫자 clamp · 모르는 enum 은 기본값 · 깨진 파일 → 기본값 + 깨짐 표시 · 키 형식(16자, 글자 집합) · 키는 한 번 만들면 다시 load 해도 같음 |
| `test/obs_overlay_dialog_test.dart` | 스위치 켜기 → onChanged · 복사 버튼이 지금 주소를 클립보드에 · 포트 사용 중 표시 · 슬라이더 묶음(0.2초에 한 번 저장) |

CLAUDE.md '주요 명령어' 에 위 테스트 줄을 더한다(구현 때).

---

## 7. 기획에 넘기는 결정 항목(프론트 의견)

1. 서버 분리(추천 B) · 기본 127.0.0.1 + LAN 옵션 여부
2. 기본 포트 값 · 포트 충돌 시 대체 포트 **안 씀**(추천)
3. 발표 전 내보내기 기본값(추천: 발표 중에만)
4. 블랙아웃 = 숨김(추천)
5. PPT·편집 페이지 = 숨김(추천) / 설교 제목 페이지 표시 여부
6. 디자인: 관객 디자인과 **따로**(추천 — 관객 위치·배경·페이지 서식은 방송 자막에 안 맞는다), 캔버스 1920x1080 투명 + 아래 기준(추천 — OBS 에서 크롭·이동만 하면 되고, 띠 크기 페이지는 글 길이마다 소스 크기가 바뀌어 OBS 배치가 흔들린다)
7. 보조 줄 표시: 관객 `includeEnglishLyrics` 를 따르고 OBS 쪽에서 추가로 끌 수만(추천)
8. 앱 연결이 끊기면 즉시 숨김(추천)
