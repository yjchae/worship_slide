# CLAUDE.md — Worship Slides

## 프로젝트 개요

Flutter 데스크탑 앱(macOS/Windows) + Python 백엔드로 구성된 예배 슬라이드 도구.

1. PPT/PPTX 폴더를 가져와 가사를 SQLite에 저장한다 (악보 이미지에서 OCR로 뽑아낼 수도 있다)
2. 성경(JSON)을 가져와 절 단위로 검색한다
3. 곡·성경·외부 PPT 이미지·빈 페이지를 "콘티"로 조립한다
4. 조립한 콘티를 보조 모니터에 **직접 발표**하거나, PPTX로 **내보낸다**

## 주요 명령어

```bash
flutter pub get
flutter run -d macos          # 실행
flutter build macos           # 빌드
flutter analyze
flutter test                  # test/ (페이지 파싱·슬라이드 렌더·헌금송 배경 굽기 등 단위 테스트)
flutter test test/sync_test.dart      # 찬양 동기화·클라우드 콘티(여러 PC 흉내) 단위 테스트
flutter test test/drive_sync_store_test.dart # 구글 드라이브 저장소(가짜 Drive 서버)·접속 키
flutter test test/db_backup_test.dart # 스키마 올리기 전 DB 자동 백업
flutter test test/bible_search_test.dart # 성경 본문 검색(띄어쓰기 무시·범위·강조·페이지 나누기)
flutter test test/bible_voice_parse_test.dart # 성경 음성 검색: 말 → 역본·책·장·절 (한글 수사·범위·이어 말하기·SRGS 문법)
flutter test test/move_pages_test.dart # 발표 보기 페이지 옮기기·나누기
flutter test test/conti_text_parse_test.dart # 콘티 한번에 넣기: 콘티 글 → 번호·제목·조·(or 곡) + 곡 찾기
flutter test test/extra_language_test.dart # 추가 보조 언어(세 번째 줄) 페이지·콘티 저장·스타일·설교자 화면
flutter test test/lyrics_page_grid_test.dart # 가사 수정 창 페이지 표·넘침 측정 (LYRICS_EDITOR_SHOT=경로 면 창을 PNG 로)
python3 python/test_render.py    # render 명령 self-check (LibreOffice 없으면 skip)
python3 python/test_animation.py # 애니메이션 단계 펼치기 self-check (LibreOffice 불필요)
python3 python/test_export_background.py # 항목별 배경 오버라이드 self-check (LibreOffice 불필요)
python3 python/test_export_text.py       # 가사 줄바꿈 self-check (LibreOffice 불필요)
python3 python/test_export_position.py   # 본문·제목 세로 미세 조정 self-check (LibreOffice 불필요)
python3 python/test_export_extra.py      # 추가 보조 언어(셋째 줄) 문단·색·크기 self-check (LibreOffice 불필요)
python3 python/test_split_language.py    # 한/보조 언어 줄 나누기 self-check (LibreOffice 불필요)
python3 python/test_sheet_lyrics.py      # 악보 가사 추출 self-check (Tesseract 없으면 OCR 부분만 skip)
python3 python/test_media.py             # PPT 안 동영상 꺼내기 self-check (LibreOffice 불필요)
python3 python/test_eot_font.py [pptx]   # PPT 심은 글꼴(EOT/MTX) 풀기 self-check (pptx 를 주면 실제 글꼴까지 풀어 본다)

# 배포용 전체 빌드 (PyInstaller + Flutter 릴리즈 + dist/ 구성)
./scripts/build.sh    # macOS
./scripts/build.ps1   # Windows
```

**중요**: 앱은 `python/ppt_tool/ppt_tool`(PyInstaller 산출물)만 호출한다. 이 폴더는 git에 없으므로
클론 직후·`ppt_tool.py` 수정 시마다 위 빌드 스크립트를 한 번 돌려야 임포트·내보내기·발표가 동작한다.
(빌드 스크립트가 `.venv` 생성 + `python/requirements.txt` 설치까지 알아서 한다.)

## 아키텍처

### Flutter (Dart)

```
lib/
  main.dart                          -- sqflite FFI 초기화 후 WorshipSlidesApp 실행
  src/app.dart                       -- MaterialApp
  src/app_theme.dart                 -- 앱 화면 테마 7종(`AppThemeKind`: 밝은·어두운·레몬·아이보리·스카이·라벤더·미드나잇), Pretendard
  src/app_colors.dart                -- 앱 화면 색·둥글기 토큰 (슬라이드·발표 창·PPTX 색과 무관)
  src/features/praise/
    data/
      praise_database.dart           -- SQLite 스키마 + 마이그레이션 (현재 version 18)
      praise_repository.dart         -- 곡 CRUD (searchSongs, replaceAllSongs, deleteSongsByIds ...)
      worship_conti_repository.dart  -- 콘티 저장/불러오기 (곡 가사 스냅샷까지 함께 보관)
      sync_snapshot.dart             -- 찬양 동기화 파일 모양: SyncSnapshot(PC 한 대분) · SyncSong · SyncTranslation
      song_sync_repository.dart      -- 찬양 동기화 DB 쪽: 내 찬양 스냅샷 만들기 + 다른 PC 스냅샷 합치기·미리 세기
      conti_cloud_repository.dart    -- 클라우드 콘티: .wsconti 를 드라이브에 손으로 올리기/내려받기/지우기
      sync_store.dart                -- 동기화 저장소 SyncStore(폴더 하나에 이름으로 파일) + FolderSyncStore(테스트용)
      drive_sync_store.dart          -- DriveSyncStore(Drive REST v3) + DriveKey(접속 키 `WS1-…`)
      sync_service.dart              -- 동기화 설정(song_sync.json)·접속 키(sync_key.txt)·찬양 동기화 버튼·켤 때 1회 확인·클라우드 콘티
      python_bridge.dart             -- Process.run으로 ppt_tool 실행 (import / render / export / sheet / sheet-finish)
      export_style_store.dart        -- 스타일을 Application Support/export_style.json에 저장
      offering_design_store.dart     -- 헌금송 기본 디자인 → offering_design.json
      offering_background_composer.dart -- 헌금송 디자인을 배경 PNG 한 장으로 굽는다
      background_image_library.dart  -- 공통 배경 이미지 모음(등록 = 앱 폴더로 복사). 헌금송·항목 배경이 같이 쓴다
      atomic_file.dart               -- 임시 파일 → 이름 바꾸기 쓰기 (동기화·설정 파일 공용)
      fnv_hash.dart                  -- FNV-1a 16자리 hex (캐시·공유 파일 이름)
      screen_choice_store.dart       -- 발표·싱어 창 모니터 선택 → screen_choice.json
      sermon_design_store.dart       -- 설교 제목 페이지 마지막 디자인 → sermon_design.json
      singer_web_server.dart         -- 휴대폰 싱어·리모컨 HTTP 서버(SSE) + cloudflared 임시 터널
      app_logger.dart                -- Application Support/logs/app.log (앱 내 "로그 보기"용)
      font_library.dart              -- 내장 무료 폰트를 Application Support/fonts 로 복사해 올린다
      source_file_watcher.dart       -- 바깥 프로그램에서 연 원본 PPT 가 저장되는지 수정 시각·크기로 지켜본다
      libreoffice_installer.dart     -- LibreOffice 설치 확인 + winget(Windows)·Homebrew(macOS) 자동 설치
    domain/
      slide_media.dart               -- SlideMedia (동영상·음악·유튜브 페이지)
      praise_song.dart               -- PraiseSong; 페이지 구분자는 빈 줄(\n\n)
      export_style.dart              -- ExportStyle (가사/성경 각각의 색·크기·정렬·제목 표시 등)
      slide_background.dart          -- SlideBackground (콘티 항목 하나만 배경을 다르게)
      offering_design.dart           -- OfferingDesign (헌금송 배경·계좌·색·크기·띠 높낮이)
      staging_item.dart              -- sealed StagingItem: Song / Bible / Image / Blank
      worship_conti.dart             -- 콘티 모델
      conti_text_parse.dart          -- 콘티 글 파싱(parseContiText) + 제목으로 곡 찾기(ContiSongMatcher, 띄어쓰기·문장부호 무시)
    presentation/
      praise_home_page.dart          -- 단일 화면(약 12,400줄). 검색·성경·디자인·콘티·발표 제어 전부 여기
      slide_page_data.dart           -- 발표 창에 보낼 한 페이지의 JSON 표현
      singer_view_data.dart          -- 싱어 화면에 보낼 현재+다음 페이지 JSON 표현
      slide_render_view.dart         -- 미리보기/썸네일용 Flutter 슬라이드 렌더러 (textOnly = 가사 PNG 굽기용)
      slide_text_layout.dart         -- 가사 상자 글자(원본→보조→추가 보조) + 넘침 측정. 렌더러와 넘침 경고가 같이 쓴다
      lyrics_editor_dialog.dart      -- 가사 수정 창: 페이지 표(좌 원본·가운데 보조·우 추가 보조) / 통째로
      conti_text_import_dialog.dart  -- 콘티 한번에 넣기: 콘티 글 붙여 넣기 → 줄마다 찾은 곡 확인(같은 제목 여럿이면 고르기) → 콘티 끝에 담기
      lyrics_page_grid.dart          -- 페이지 표 순수 모델(나누기·밀기·당기기·합치기) + 가사 페이지 형식 함수
      (data/claude_translator.dart  -- 가사 수정 창 '번역·변환': 원본 페이지 → 로컬 Claude Code CLI(`claude -p --json-schema`, API 키 없음)로 보조·추가 보조 칸 채우기.
                                        언어 이름에 '발음'이 들면 로마자 발음, 아니면 번역. claude 가 깔려 있고 로그인된 PC 에서만 된다)
      slide_backdrop.dart            -- 배경 영상(가사 뒤 반복 재생) 레이어 페이지 HTML + 발표 창 media JSON
      lyrics_overlay_renderer.dart   -- 배경 영상 위에 얹을 가사 투명 PNG 굽기(화면 밖 위젯 렌더)
      presentation_timer.dart        -- 발표 경과 시간(기준 시각 방식). 발표 보기 시계·싱어 화면이 같이 본다
      offering_dialog.dart           -- 헌금송 디자인 등록 / 항목에 적용(높낮이) 다이얼로그
      media_player_html.dart         -- 발표 창 미디어 레이어 페이지 HTML·페이드 JS (mediaPlayerHtml)
      background_image_gallery.dart  -- 배경 이미지·영상 모음 격자 UI
      libreoffice_install_dialog.dart -- LibreOffice·cloudflared 자동 설치 안내창
      offering_overlay_painter.dart  -- 헌금송 띠(라인 + 헌금 + 계좌) painter. 미리보기·PNG 공용
      sync_dialog.dart               -- 동기화 설정 (가져오기 메뉴 '찬양·콘티 동기화'·상태 줄): 접속 키 넣기·찬양 동기화 버튼
      cloud_conti_dialog.dart        -- 클라우드 콘티 목록: 내려받기(이미 있으면 바꾸기)·클라우드에서 지우기
  src/features/bible/
    data/bible_repository.dart       -- 역본·책·장·절 조회, 본문 검색(searchVerses), JSON 임포트
    domain/bible_verse.dart
    domain/bible_text_search.dart    -- 본문 검색 범위(BibleSearchScope)·검색어 나누기·강조 위치·고른 절 페이지 나누기
  src/features/update/update_service.dart -- GitHub Releases(yjchae/worship_slide) 확인·다운로드
```

### 발표 창 (네이티브)

발표 화면은 Flutter가 아니라 **네이티브 창**이다. MethodChannel 3개로 제어한다.

- `worship_slides/presentation` — Dart → 네이티브: open / updatePage / toggleBlackout / close / mediaToggle / mediaSeek,
  싱어 화면 openSingerWindow / updateSinger / closeSingerWindow
- `worship_slides/presentation_main` — 네이티브 → Dart: `presentationClosed`, `singerClosed`, `mediaState`(재생 위치 JSON),
  `singerKey`(`"next"`/`"prev"` — 싱어 화면에 포커스가 있을 때 누른 넘기기 키)
- `worship_slides/save_panel` — 저장 위치 선택 (macOS NSSavePanel)
- `worship_slides/speech` — 성경 음성 검색: `start {grammar, hints}` / `stop`, 네이티브 → Dart `partial`·`final {text}`·`error {message}`
  (macOS `BibleSpeechListener` = Speech, Windows `speech_channel.cpp` = Windows.Media.SpeechRecognition)
- `worship_slides/ocr` — 악보 가사 줄 이미지 OCR: `isAvailable` / `recognize({paths})`
  (macOS `SheetTextRecognizer` = Vision, Windows `ocr_channel.cpp` = Windows.Media.Ocr)

| 플랫폼 | 구현 | 렌더링 |
|--------|------|--------|
| macOS  | `macos/Runner/MainFlutterWindow.swift` (`PresentationWindowController`) | WKWebView + 생성한 HTML/CSS |
| Windows| `windows/runner/presentation_channel.cpp` | GDI `DrawTextW` + GDI+ 이미지 |

보조 모니터가 있으면 그 화면에 borderless 전체화면(`level = .screenSaver`)으로, 없으면 1280x720 창으로 띄운다.

**모니터 선택**: 앱 바 '발표 시작' 옆 모니터 버튼 → 관객·싱어 창 각각 '자동 / 모니터 N'. 네이티브 `getScreens`
(순서 = macOS `NSScreen.screens`, Windows `EnumDisplayMonitors`)가 목록을 주고, `openWindow`·`openSingerWindow` 가
`screen` 번호(-1 = 자동)를 받는다. 이미 열려 있으면 그 모니터로 옮긴다. 선택은 `Application Support/screen_choice.json`
에 번호+이름으로 남고(`ScreenChoiceStore`), **번호와 이름이 둘 다 맞을 때만** 쓴다(`ScreenChoice.resolve`) — 이름이 겹치는
모니터가 흔해서 이름만으로 찾으면 메인 창 모니터를 고를 수 있다. 메인 창 모니터·다른 쪽 창이 쓰는 모니터는 고를 수 없고,
열 때 그렇게 되어 있으면(메인 창을 옮김 등) 자동으로 연다.
전체화면 창은 연 뒤 모니터 해상도가 바뀌어도(프로젝터·AirPlay 가 연결 직후 해상도를 다시 잡음) 옛 크기로 남아 화면 밖으로
넘치므로, 화면 설정이 바뀌면 그 모니터의 지금 크기로 다시 맞춘다(발표·싱어 창). 모니터는 해상도가 바뀌어도 그대로인 값으로 찾는다 —
macOS `didChangeScreenParametersNotification` + `NSScreen.displayID`, Windows `WM_DISPLAYCHANGE` + 장치 이름(`monitor_fit.h`).
모니터가 (잠깐) 없으면 아무것도 안 한다 — 프로젝터는 해상도를 다시 잡으며 잠깐 빠졌다 돌아오는 일이 흔하고, 돌아오면 다음 알림에서 맞춘다
(빠지면 일반 창으로 내리는 처리를 넣었다가, 잠깐 빠진 순간 내려가서 영영 안 돌아와 뺐다).

**싱어 화면**: 발표 중 발표 보기 툴바의 마이크 버튼으로 여는 두 번째 네이티브 창. 디자인(배경·폰트·위치)은
무시하고 현재 페이지(크게, 63%) + 다음 페이지(작게, 37%)를 어두운 고정 레이아웃으로 그린다(글자 크기는 상자에
맞춰 자동). **줄은 원본 그대로**(자동 줄바꿈 없음) — 가장 긴 줄이 들어가게 글자를 줄여서 관객 화면과 줄 수가 같다.
단 그러다 글자가 창 높이의 3.5% 보다 작아지면(긴 성경 구절) 그때만 자동 줄바꿈한다. 스타일을 싣지 않는 별도 JSON(`SingerViewData`)을 받는다. 보조 가사는 디자인의 보조 언어 스위치를 따른다.
- 모니터를 고르지 않았으면(자동) 메인 창도 관객 화면도 아닌 모니터(3번째)가 있으면 거기 전체화면으로, 없으면 메인 창 모니터에 960x600 일반 창으로
  열린다. 사용자가 원하는 모니터로 끌어 놓고 **더블클릭(또는 F, Windows 는 F11 도)** 으로 전체화면을 켜고 끈다. ESC 는
  전체화면 풀기만, 창 닫기는 Ctrl+F4(macOS 는 ⌘F4 도) — 발표 창과 같은 이유(잘못 눌러 꺼지는 사고 방지)
- 열 때 키 포커스를 가져가지 않는다(메인 창 넘기기 단축키 유지). 싱어 창을 클릭해 포커스가 가도 화살표·Space·PageUp/Down 은
  `singerKey` 로 Dart 에 넘겨 똑같이 넘어간다
- **시계·경과 시간**: 머리줄에 `오후 7:32 · 12:05 / 20:00`(목표 80% 넘으면 주황, 넘기면 빨강). 값은 `PresentationTimer`
  (쌓인 시간 + 흐르기 시작한 시각) 하나 — 발표를 시작하면 0부터, 끝나면 멈춘다. 싱어 JSON `clock`
  (`show`·`elapsed_ms`·`running`·`target_ms`·`rev`)을 받은 순간부터 각 화면이 자기 시계로 센다(매초 안 보낸다).
  일시정지·리셋·목표·'싱어 표시' 스위치(발표 보기 경과 시간 칸)는 `rev` 를 올리고 알린다 → `_sendSingerView`.
  흐르는 `elapsed_ms` 는 다시 보낼지 비교할 때 뺀다(`_singerDedupeKey`). 휴대폰 서버는 `elapsed_ms` 를 빼고 저장했다가
  보낼 때 그 순간 값을 `{"clock_ms":N,` 로 맨 앞에 붙인다 — 늦게 연 휴대폰도 맞는 값을 받고, 폴링마다 1.5초 넘게 어긋날 때만 다시 맞춘다
- 갱신은 `_sendCurrentSlide` 에 얹혀 있다(페이지가 바뀌는 모든 경로가 거기를 지난다). 블랙아웃 중에도 가사는 계속
  보이고 "관객 화면 꺼짐" 표시만 뜬다. 발표를 끝내면 같이 닫힌다
- macOS `SingerWindowController`(MainFlutterWindow.swift, WKWebView HTML), Windows `windows/runner/singer_window.cpp`(GDI)
- **휴대폰 싱어 화면**: 발표 보기 툴바의 휴대폰 버튼 → 앱 안 HTTP 서버(`SingerWebServer`, `dart:io`, 포트 8765·쓰고 있으면 아무 빈 포트)를
  켜고 `http://<사설 IP>:<포트>` 와 그 QR(`qr_flutter`, 다이얼로그를 열 때마다 지금 IP 로 새로 만든다)을 보여 준다. 같은 와이파이의 휴대폰 브라우저가 SSE(`/events`)로 같은 `SingerViewData` JSON 을 받는다
  (`_sendSingerView` 에 얹혀 있다 — 네이티브 싱어 창이 닫혀 있어도 보낸다). 페이지 이미지는 로컬 경로를 내보내지 않고
  `/img/current`·`/img/next` 로 지금 두 장만 준다(망 안의 다른 기기가 아무 파일이나 읽지 못하게). 발표를 끝내면 같이 꺼진다.
  모든 요청은 켤 때마다 새로 만드는 토큰(`?k=`, 주소·QR 에 포함)이 맞아야 한다(게스트 와이파이 대비). 이미지는 `v`(경로+수정 시각)가
  지금 것과 다르면 404 + `no-store`(빠르게 넘길 때 브라우저가 엉뚱한 이미지를 기억하지 않게). start/stop 은 큐로 차례만 돈다.
  주소 후보는 사설망 IPv4 만, VPN·가상 머신 인터페이스는 빼고 와이파이·유선을 앞에 둔다(`lanAddresses`).
  화면 꺼짐 방지(`navigator.wakeLock`)는 https 에서만 되므로 같은 망(http) 주소에선 안 걸린다 — 휴대폰 자동 잠금을 끄라고 안내한다.
  처음엔 OS 방화벽이 들어오는 연결을 물으므로 허용해야 한다. 페이지 HTML 은 `singerPageHtml` 상수(네이티브 싱어와 같은 모양·맞춤 규칙)
  - **바깥 망(LTE 등) 주소**: `cloudflared` 가 깔려 있으면 서버를 켤 때 Cloudflare 임시 터널(`cloudflared tunnel --url`,
    계정 불필요)을 같이 띄워 `https://<이름>.trycloudflare.com/?k=<토큰>` QR 을 하나 더 보여 준다(`SingerWebServer.tunnel`).
    LibreOffice·Tesseract 같은 **선택 의존성** — 없으면 다이얼로그 안 '자동 설치' 버튼(`_CloudflaredInstallButton`, `LibreOfficeInstaller` 를 패키지 이름만 바꿔 씀: winget `Cloudflare.cloudflared`·`brew install cloudflared`)이 깔고 `retryTunnel` 로 서버는 그대로 둔 채 터널만 띄운다. 같은 망 주소는 그대로. 찾는 곳은 앱 폴더 →
    Homebrew·`Program Files`·WinGet Links → PATH(Finder 로 띄운 macOS 앱은 PATH 에 Homebrew 가 없다). 서버를 끄면 터널 프로세스도 죽인다.
    **인터넷이 잠깐 끊겨도 주소는 그대로다** — cloudflared 는 처음 붙은 뒤엔 포기하지 않고 같은 터널로 다시 붙는다
    (`supervisor.go` `retryForever`). `--retries 2` 는 다시 붙는 간격을 20~40초로 줄이려는 값(기본 5 면 최대 5분).
    프로세스가 죽었을 때만 `_runTunnel` 이 새로 띄우고, 그러면 주소가 바뀐다(키는 그대로) — 임시 터널로는 피할 수 없다.
    앱 종료는 `AppLifecycleListener.onExitRequested` 에서 끄고, 그 신호가 안 오는 경우(강제 종료, Windows 에서 발표 창이
    열린 채 닫기 — Windows 는 마지막 창일 때만 종료 요청을 보낸다)는 pid 파일(임시 폴더)로 다음 시작 때 치운다(`killLeftoverTunnel`,
    이름이 cloudflared 일 때만). 키는 인터넷에 열리므로 16자
    **임시 터널은 SSE 를 흘려보내지 않는다**(헤더만 오고 본문이 안 온다 — 실제로 확인). 그래서 https 로 열린 페이지는
    `/state`(지금 JSON)를 0.5초마다 묻고(실패하면 3초까지 늘려 계속, 403 = 키 바뀜이면 멈춤, 화면이 가려지면 쉼), http(같은 망)만 SSE 를 쓴다. https 라 `navigator.wakeLock` 도 그쪽에서만 걸린다.
    트래픽은 Cloudflare 를 거쳐 가고(거기서 TLS 가 풀린다), 토큰을 아는 사람은 어느 망에서든 본다
- **휴대폰 발표자 리모컨**: 같은 다이얼로그의 '발표자 리모컨' 쪽 QR. 서버·터널·페이지 HTML 은 싱어와 같고, **키만 다르다**
  (`remoteToken`, 켤 때마다 새로). 리모컨 키로 열면 `<body class="remote">` 로 내보내 제스처가 켜진다 — 좌우 밀기·양쪽 끝(22%) 누르기 = 넘기기,
  두 손가락 = 확대(확대 중 한 손가락 = 옮기기), 가운데 두 번 누르기 = 확대 풀기, '화면 끄기' 0.6초 길게 = 블랙아웃. 발표자 메모도 보인다.
  - `POST /control`(리모컨 키만, GET 은 403) → `SingerWebServer.onControl` = `_handleRemoteControl`. 응답에 바뀐 상태 JSON 을 실어
    터널(폴링)에서도 넘긴 휴대폰은 바로 바뀐다
  - 넘기기는 `from`(휴대폰이 보던 쪽 번호)이 지금 쪽과 같을 때만 — 늦게 온 요청·리모컨 두 대·PC 에서 먼저 넘긴 경우 두 장씩 넘어가지 않게.
    블랙아웃도 토글이 아니라 `on=0|1` 원하는 상태를 보낸다
  - 확대는 발표 보기 '영역 확대'(`_zoomCenter`·`_zoomScale`·`_sendZoom`) 그대로다. 휴대폰의 현재 페이지 칸은 비율이 자유롭고, 그 안에 가운데로 맞춘 **16:9 틀**(`slideFrame`)
    좌표 = 슬라이드 좌표. 단 가사 페이지는 휴대폰이 디자인 없이 글자만 그리므로 확대 위치가 실제 슬라이드 배치와 조금 다를 수 있다(PPT 이미지는 정확)
  - 휴대폰 페이지(싱어·리모컨 공통) 머리줄의 '좌우/위아래' 버튼으로 현재·다음 페이지 배치를 바꾼다. 휴대폰마다 `localStorage`(`singer_layout`)에 기억한다.
    현재·다음 사이 막대(`#split`)를 끌면 비율이 바뀐다(현재 몫 0.3~0.85, 기본 0.65, `singer_split`). 아이폰 가로 노치에 안 잘리게 좌우도 `safe-area-inset` 만큼 띄운다.
    다음 페이지 글자는 현재 페이지 글자의 0.75 배를 넘지 않는다(`fitAll`) — 짧은 다음 가사가 현재보다 크게 보이지 않게
  - `note`·`zoom` 은 `_sendSingerView` 가 얹고, 서버가 싱어 키 쪽에서는 뺀다(`remoteOnlyKeys`) — 싱어 QR 로는 메모를 못 본다

### Python (`python/ppt_tool.py`, 약 3,100줄)

Flutter가 서브프로세스로 호출하고 stdout의 JSON을 읽는다.

- `import <폴더>` — `.ppt`/`.pptx` 재귀 탐색 → 한/영 가사 분리 → `{songs, processed_count, errors, libreoffice_missing}`
- `render <파일> [--no-animation]` — 외부 PPT/PDF 전 페이지를 PNG로
  (애니메이션 펼치기 → soffice → PDF → PyMuPDF → 페이지별 PNG).
  `.pdf`는 soffice 변환을 건너뛰므로 LibreOffice 없이도 된다
- `export <JSON payload>` — 콘티 + 스타일로 새 PPTX 생성 (곡/성경/이미지/빈 페이지 슬라이드)
- `sheet <파일 | --clipboard>` — 악보(이미지·PDF·클립보드 그림)에서 오선 아래 가사만 →
  `{source_name, lyrics, lines, page_count, staff_count, text_layer}`
  (OCR 이 필요한데 Tesseract 가 없으면 `{"error": "tesseract_missing"}`)
- `sheet <파일 | --clipboard> --ocr-lines <폴더>` — OS 내장 OCR 1단계: 가사 줄 이미지만 잘라 두고
  `{needs_ocr: true, job, images}` (OCR 이 필요 없으면 위와 같은 최종 결과)
- `sheet-finish <job.json> <ocr.json>` — 2단계: 앱이 읽은 결과(`{경로: [{text, confidence, x, y, w, h}]}`)로 마무리

## 중요 설계 결정

- **Python 실행 방식**: PyInstaller 실행 파일만 탐색·호출한다 (`.py`를 직접 실행하지 않는다).
  탐색 경로는 CWD·실행 파일 위치·`$PWD`의 모든 상위 폴더 아래 `python/[ppt_tool/]ppt_tool`
- **onefile이 아니라 onedir**: onefile은 호출마다 아카이브를 임시폴더에 풀고 macOS가 매번 검사해서
  **실행 1회당 약 10초**가 든다. onedir는 0.12초
- **가사 페이지 구분자**: 빈 줄(`\n\n`). 예전 `###` 구분자는 DB version 6 마이그레이션에서 일괄 변환됨.
  선행 빈 줄은 "빈 페이지"로 보존된다 (`praise_song.dart` 참고)
- **한/보조 언어 분리 기준** (`is_sub_line`): 한글이 없고 글자(alpha)가 있으면 보조 언어 줄.
  예전엔 라틴 비율 ≥ 60% 였는데 그러면 일본어·중국어가 한국어 쪽에 섞였다.
  숫자·기호만 있는 줄은 alpha 가 없어 예전처럼 본문 쪽에 남는다
  **단, 글자 색이 우선이다.** PPT 는 번역 가사를 다른 색(주로 주황 `FFC000`)으로 칠해 두므로, 한글 줄에 가장 많이 쓴
  색(`_main_lyrics_color`)과 같은 색인 영어 줄은 원곡 가사(`How great is our God`, `(x2)`)로 보고 본문에 남긴다.
  한글 줄이 없으면(영어 원곡) 흰색, 흰 줄도 없으면 가장 많이 쓴 색이 원본 색. 앱 화면의 "한글 가사"는 "원본 가사"로 부른다
- **DB 위치**: 실행 파일 옆 (`worship_slides.db`). macOS는 `.app`에서 3단계 위. 앱 폴더를 통째로 옮겨도 데이터가 따라온다
- **스키마 올리기 전 자동 백업** (`backupBeforeUpgrade`): DB 를 열기 **전에** 파일 헤더(오프셋 60, user_version)를 직접 읽어
  `PraiseDatabase.schemaVersion` 보다 낮으면 `worship_slides.db.v<옛 버전>.bak` 으로 복사해 둔다(임시 이름 → 이름 바꾸기, 남은 `-journal`·`-wal` 도 같이).
  같은 버전 사본이 이미 있으면 두고(처음 것이 가장 믿을 만하다), 새 DB·최신 DB 는 복사하지 않는다. 실패해도 앱은 연다(`app.log` `[db]`).
  옛 앱으로 돌아가야 하면 이 파일을 `worship_slides.db` 로 이름 바꿔 쓴다. 지우지 않는다(버전마다 한 개라 쌓이지 않는다)
- **찬양·콘티 동기화 (구글 드라이브) — 모두 손으로 한다**: 처음엔 1분마다·고친 3초 뒤 자동으로 맞췄는데
  자동이라서 생기는 문제(동시에 쓰기·반쯤 올라온 파일·재시도·시계 차이)가 끝없이 나와 **버튼을 누를 때만** 맞추도록 바꿨다.
  자동으로 하는 건 **프로그램을 켤 때 한 번** 서버를 보고(`SyncService.checkForUpdates`) 새 찬양·바뀐 찬양·새 콘티가 있으면
  알림 창으로 묻는 것뿐이다('나중에 / 콘티 보기 / 찬양 동기화'). 이 확인은 DB 를 안 바꾼다 — 실제 합치기를 트랜잭션 안에서
  돌리고 되돌려 센다(`SongSyncRepository.preview`, 셈이 합치기와 똑같다. 켤 때 한 번이라 그동안 DB 쓰기가 잠깐 막히는 건 감수).
  **지난번에 안 올린 이 PC 의 수정**도 알린다 — 내 파일과 지금 찬양을 비교한다(`_ownFileUpToDate`, 쓴 시각·표시·PC 이름 빼고).
  한 번 알린 클라우드 콘티는 `song_sync.json` 의 `seen_contis` 에 남겨 다음에 켤 때 다시 알리지 않는다(클라우드 창엔 그대로)
  - SQLite 파일을 드라이브에 두지 않는다(두 PC 가 동시에 쓰면 깨지거나 사본이 생긴다)
  - **접속은 Drive REST API 로 직접, 키 하나로** (`DriveSyncStore`): PC 에 드라이브 앱·구글 로그인이 필요 없다. 관리자가
    `scripts/make_sync_key.py`(OAuth 데스크톱 클라이언트 JSON 필요, 콘솔 준비는 스크립트 머리말)를 한 번 돌려 자기 계정으로 로그인하면
    폴더를 만들고 `WS1-` + base64url(JSON: client_id·client_secret·refresh_token·folder_id·folder_name) 키를 출력한다.
    사용자는 동기화 창에 붙여 넣기만 한다(`SyncService.connect` 가 폴더까지 열어 보고 `Application Support/sync_key.txt` 에 저장).
    **키는 git·배포 zip 에 넣지 않는다**(공개 레포) — 관리자가 쓸 사람에게만 따로 건넨다. 모든 PC 가 관리자 계정으로 접속하지만
    권한이 `drive.file` 이라 이 앱이 만든 파일만 보인다(손으로 만든 폴더는 못 본다 → 폴더도 스크립트가 만든다). 동의 화면을
    '프로덕션'으로 게시해야 refresh token 이 7일 뒤 만료되지 않는다. 키를 끊으면(구글 계정 권한) 모든 PC 가 막히고 새 키를 건넨다
  - 파일은 폴더 하나에 평평하게 둔다(하위 폴더를 만들면 두 PC 가 동시에 만들 때 둘이 된다). 드라이브는 같은 이름 파일을 여럿
    둘 수 있어서 쓸 때는 가장 최근 것을 바꾸고 지울 때는 모두 지운다. 올리기는 늘 resumable 한 번(단순 올리기는 5MB 까지).
    테스트는 같은 `SyncStore` 를 로컬 폴더로 구현한 `FolderSyncStore` 로 여러 PC 를 흉내 낸다(`useStore`)
  - **찬양 동기화 버튼**(`syncSongs`): PC 마다 자기 찬양 전부를 JSON 파일 하나로만 쓴다(`<기기 id>.json`).
    누르면 다른 PC 파일들을 읽어 합치고 내 파일을 쓴다. 찬양을 고치면 상태 줄에 '동기화 안 한 찬양 있음'만 뜬다(`hasLocalChanges`)
  - 곡마다 `praise_songs.uid`(무작위 32자 hex) + `updated_at`(ms, DB version 17). id 는 PC 마다·임포트마다 달라서 못 쓴다.
    **곡마다 나중에 고친 쪽이 이긴다**(같은 시각이면 내용 문자열 비교 — 어느 PC 에서든 같은 답). 지운 곡은 `song_tombstones` 에
    남아 다른 PC 에서도 지운다(전체 초기화도). 지운 뒤 다른 PC 에서 고쳤으면 고친 쪽이 이긴다
  - 보조 언어 가사는 곡과 따로 (제목, 언어)마다 맞춘다(`song_translations.updated_at` + `translation_tombstones`) — 곡 레코드에
    실으면 같은 제목의 다른 곡·받는 쪽에만 있는 언어가 지워졌다
  - 두 PC 가 따로 가져온 같은 곡(제목·원본·영어 가사가 **똑같음**)은 작은 uid 로 합치고 `song_uid_aliases`(옛 uid → 지금 uid)에 남겨
    파일에도 싣는다. **제목만 같고 가사가 다르면 둘 다 남긴다.** 합친 뒤 따로 고쳐 가사가 달라졌으면 한쪽에 새 uid 를 준다.
    합치기 반복 중에 uid 를 합치면(`_renameUid`) 뒤에 오는 옛 uid 의 판도 지금 uid 로 다룬다
  - 지운 기록에 **내용 해시**(`content_hash`, 제목·가사 FNV)도 싣는다(`deleted_content`) — 동기화를 켜기 전에 한 PC 에서 지운 곡이
    다른 PC 의 같은 곡(uid 만 다름)으로 되살아나지 않게. 지운 쪽이 같은 내용 곡을 아직 갖고 있으면 번지지 않는다(`_ContentTombstones`)
  - 고치거나 지운 시각은 그 곡의 지금 시각보다 늘 늦게 찍는다(`PraiseRepository._after`, 시계가 앞선 PC 에서 온 곡 대비).
    곡을 열었다 그냥 저장하면(`updateSong` 에 바뀐 게 없으면) 시각을 안 올린다. `replaceAllSongs` 는 같은 제목·가사 곡의 uid 를
    그대로 쓰고(전체 교체가 "모두 삭제 + 새로 추가"로 번지지 않게) 파일 이름만 바뀌었으면 시각을 올린다
  - 기기 id 가 겹치는 PC(설정 폴더째 복제·마이그레이션) 대비: 내 파일에 실행마다 새 표시(`writer`)와 쓴 시각(`written_at`)을 싣고,
    그 시각을 **파일보다 먼저** 설정에 남긴다(못 남기면 쓰지 않는다). 이번 실행에서 쓴 뒤 다른 표시로 바뀌었거나, 처음 볼 때 내
    기록보다 늦게 쓰였으면 다른 PC 다 → 새 id 로 비킨다. `written_at` 은 내용 비교에서 빼고(안 바뀌었으면 다시 안 쓴다) 맨 앞에 붙인다
  - **합칠 때 내 파일(`<기기 id>.json`)도 같이 합친다**(`_withOwn`). 정말 내 것이면 지난 상태라 바뀌는 게 없다. 한 PC 에 앱을 두 군데
    풀면 DB 는 실행 파일 옆이라 따로인데 설정(기기 id·`written_at`)은 Application Support 하나라 같아서 위 검사로도 못 가린다 —
    예전엔 그 파일을 "내 것"으로 보고 안 읽은 채 덮어써서 다른 쪽에서 지운 곡이 영영 안 지워졌다
  - 다른 PC 파일을 못 읽으면(받다 끊김·깨짐) 그 PC 만 빼고 합치고 "N개 못 읽음, 잠시 뒤 다시 눌러 달라"고 알린다
    (`SyncStatus.warning` — 실패(`lastError`)가 아니라 상태 줄은 '동기화 확인 필요').
    레코드 하나가 이상하면 그것만 버린다. 파일 읽기·JSON 풀기/만들기·곡 내용 해시는 `Isolate.run`(곡 수천 곡이면 몇 MB).
    설정 읽기·폴더 바꾸기·동기화·확인은 한 큐로 차례대로 돈다. 임시 파일 → 이름 바꾸기는 `atomic_file.dart` 한 곳
  - **콘티는 클라우드에 올리기·내려받기**(`ContiCloudRepository`, 자동 동기화 없음): '콘티 불러오기' 창의 콘티 옆 구름 버튼 = 올리기,
    '클라우드에서 내려받기'(또는 동기화 창 '클라우드 콘티') = 목록에서 골라 받기·클라우드에서 지우기. 파일은 '파일로 내보내기'와 같은
    `.wsconti`(이미지까지 base64 로 담김) = `conti_<콘티 uid>.wsconti` + 목록용 정보 `conti_<콘티 uid>.json`(찬양 파일과 같은 폴더, `conti_` 로 가른다)
    (정보를 나중에 쓰므로 목록에 보이면 콘티 파일도 다 쓴 것). `worship_contis.uid`(version 17)가 파일 이름이라 같은 콘티를 다시 올리면
    덮어쓰고, 다시 받으면 그 콘티를 바꾼다(`importContiFile(cloudUid:)` — 정보 파일 uid 로 넣는다). '파일에서 가져오기'는 늘 새 콘티다.
    **`.wsconti` 가져오기는 파일에 담겨 온 이미지만 쓴다** — 담기지 않은 경로(보낸 PC 의 로컬 경로)는 버리고(이미지 자리는 없는 파일
    `.missing` → 유실), `image_source_path` 는 안 받고, 미디어는 유튜브만 받는다. 그대로 두면 이 PC 의 같은 경로에 있는 아무 파일이나
    다시 내보내거나 올릴 때 실려 나간다. 클라우드 일은 키가 없거나 폴더를 못 열면 오류로 막는다.
    다시 받을 때 옛 `imported_contis/<시각>/` 이미지 폴더는 지우지 않는다(다른 콘티가 쓸 수도 있어 — 디스크가 조금씩 는다)
  - `.wsconti` 내보내기·가져오기의 파일 읽기·base64·JSON·이미지 풀기는 `Isolate.run`(PPT 수백 장이면 수백 MB). 가져오기는 다 푼 뒤에
    DB 에 넣고, 도중에 실패하면 푼 폴더를 지운다. **이 PC 가 올린 콘티는 클라우드 창에서 다시 받기 버튼을 숨긴다**(원본보다 못한
    사본으로 바뀌지 않게 — 동영상·음악 경로와 '원본 열어 수정' 연결이 빠진다). 다른 PC 에서 받은 콘티를 다시 받을 때도 그렇다고 묻는다
  - '안 올린 수정' 표시는 '찬양 동기화'를 **누른 순간** 이후에 고친 것이 있으면 남는다(`_localChangeCount`)
    정보 파일 uid 는 32자리 hex 만 받는다(파일 이름으로 쓰므로). 받을 때 곡 항목은 `worship_conti_items.song_uid` 로 그 PC 의 곡에
    다시 잇는다(`.wsconti` 공통 — 예전 콘티는 내보낼 때 지금 곡의 uid·가사로 채운다, `portableItemRow`). 클라우드에서 지워도 이미
    받은 PC 의 콘티는 남는다. 동영상·음악 파일은 안 실린다(`.wsconti` 와 같다)
  - **끊기**: 구글 드라이브 요청은 모두 `abortTrigger` 를 단다(`DriveSyncStore._abortable`). 받는 쪽은 조각 사이 30초가 멎으면,
    요청 하나가 10분(`maxRequest`)을 넘으면 끊는다 — 올리기(PUT)는 본문을 다 보낸 뒤에야 응답이 와서 30초 제한을 못 건다.
    손으로는 '동기화 취소'·콘티 올리기 버튼(올리는 중에 누름)·클라우드 창의 X 가 `SyncService.cancel` → 진행 중 요청을 **모두** 끊는다.
    취소는 다음 작업이 시작될 때(`_prepare`·`_requireStore` 의 `resetCancel`)까지 남아서, 요청 사이(합치기·DB 작업 중)에 눌러도 뒤 요청이 안 나간다.
    끊긴 작업은 `cancelledMessage`('취소했습니다.')로 실패하고 화면은 오류 창을 띄우지 않는다(`isCancelled`)
  - 시계가 크게 틀린 PC 는 "나중에 고친 쪽" 판정이 틀릴 수 있다(OS 자동 시간 맞추기를 켜 두면 된다)
- **성경 본문 검색** (성경 검색 탭의 '장절 | 본문' 토글): 본문 모드는 낱말(공백으로 나눔, AND)이 모두 든 절을 찾는다.
  **띄어쓰기는 무시한다** — 낱말도 본문도 공백을 빼고 `LIKE` 로 비교한다(`'이처럼사랑'` 이 `'이처럼 사랑하사'` 에 걸린다).
  FTS 를 안 쓴 이유: SQLite FTS 토크나이저는 공백으로 낱말을 나눠 `'사랑'` 으로 `'사랑하사'` 를 못 찾는다(한국어 조사·어미).
  공백으로 보는 글자는 `bibleIgnoredSpaces`(공백·탭·줄바꿈·NBSP·전각 공백) 하나 — SQL `REPLACE` 사슬과 강조(`bibleMatchRanges`)가 같이 쓴다.
  결과는 정경 순서로 앞 200절, 전체 수는 같은 쿼리의 `COUNT(*) OVER ()`(한 번 훑기, sqlite3 패키지가 SQLite 3.25+ 를 같이 싣는다).
  3만여 절 리눅스 인메모리 측정: 걸리는 절이 적으면 약 40ms(COUNT 따로 = 두 번 훑기는 약 80~120ms), 모든 절이 걸리는 최악은 약 60~110ms
  (창 함수가 걸린 행을 다 모아서 — LIMIT 로 일찍 멈추는 두 번 쿼리는 약 40ms). 실제 검색은 대부분 앞쪽이라 창 함수를 골랐다. 스키마(색인)는 그대로다.
  본문 검색어는 controller listener 로 받는다 — `onChanged` 는 한글 조합이 끝날 때(글자 그대로) 안 불려서 마지막 글자가 검색되지 않았다.
  절 목록은 ListView 가 아니라 줄을 모두 만든다(`_buildVerseList`, 한 장 최대 176절·결과 200절) — '이 장 보기' 가 감긴 줄 높이를 어림하지 않고 그 절로 정확히 간다.
  범위 = 전체 / 구약(앞 39권) / 신약(뒤 27권) / 책 하나. 66권이 아닌 역본은 구약·신약 칸을 숨긴다(`mapBookName` 과 같은 순서 가정).
  결과 줄의 '이 장 보기' = 장절 모드로 그 장을 열고 그 절을 골라 둔다. 본문 모드에선 여러 책·장을 같이 고를 수 있어서
  페이지는 (책, 장)마다 따로 만든다(`bibleVersePages`) — 장절 모드는 묶음이 하나라 예전과 같다
- **성경 음성 검색** (기획 `planning/bible-voice-search/plan.md`): 발표 보기 툴바의 말하는 사람 아이콘. 켜 두면 계속 듣고
  "다니엘 3장 1절에서 10절"·"시편 107편 5절"·"17절"(앞 책·장 이어 말하기)을 들으면 그 구절 페이지를 **현재 페이지 바로 뒤**에 넣는다
  (붙여 넣기와 같은 `_insertItemsAfterSlide`, 관객 화면은 그대로 — 상태 줄 '바로 띄우기'·'되돌리기'). 발표 보기 탭을 떠나면 끈다.
  페이지를 안 넘기고 또 말하면 지난번 넣은 항목 뒤에 잇는다(`_voiceChain`, 순서가 뒤집히지 않게).
  들은 마디는 `_voiceQueue` 로 하나씩 처리하고 중복 표시는 기다리기 전에 남긴다. 되돌리기는 넣기 직전 상태(`_VoiceUndo`)로
  곡·PPT 나눈 것까지 되돌리되, 그 사이 무엇이든(항목·메모·지운 페이지·배경) 바뀌었으면 넣은 항목만 뺀다.
  되돌린 뒤 관객 화면은 넣기 전 기준 페이지(또는 뒤였으면 빠진 장 수만큼 당긴 자리)로. 띄우기·되돌리기 버튼은 다음에 넣거나 되돌릴 때까지 남는다.
  역본은 켤 때 새번역(없으면 첫 역본), 역본 이름을 말하면 그 뒤로 그 역본.
  **DB 역본 이름이 자모가 풀린 꼴(NFD)인 경우가 있어**(실제 DB 에서 확인) 비교는 `composeHangul` 로 합쳐서 한다. 같은 구절은 10분 안에 다시 넣지 않는다.
  항목은 성경 검색 탭 담기와 같은 `_bibleItemsFor`(보조·추가 역본·페이지당 절 수 `_BibleSearchPanelState._versesPerPage`).
  말 → 구절은 순수 함수 `parseBibleVoice`(`bible_voice_parse.dart`, 정경 66권 순서 번호 → 역본 책 이름, 한글 수사, 책 없이 한글 수사로 시작하는
  말은 글 맨 앞일 때만, `N:N` 은 책이 있을 때만 — '오후 3:30'). macOS 는 1.2초 말이 끊기면 그 마디를 `final` 로 넘기고 새 요청으로 잇는다(50초 상한, 온디바이스가 되면 켠다).
  Windows 는 받아쓰기('온라인 음성 인식' 설정 필요) 대신 Dart 가 만든 SRGS 문법(`bibleVoiceGrammar`, 앞뒤 GARBAGE)으로 오프라인으로 듣고
  확신도 Medium 미만은 버린다. 한국어 음성 언어 팩이 필요하다. 켜기·끄기는 한 번에 하나씩(`State::op`), 늦은 켜기는 뒤 요청이 있으면 건너뛴다.
  macOS 는 입력 장치가 바뀌면(`AVAudioEngineConfigurationChange`) 새 장치로 다시 켜고, 없으면(샘플레이트 0) 켜지 않는다 — 그대로 `installTap` 하면 잡을 수 없는 예외로 앱이 죽는다. C++ 은 오류 코드만 보내고 한글 안내는 `SpeechListener._describe`.
  **실제 음성 인식은 사람이 말해 봐야 확인된다**(Windows 는 PR CI 컴파일만)
- **콘티 한번에 넣기** (예배 콘티 머리줄의 목록+ 버튼, `ContiTextImportDialog`): 단톡방에 올리는 콘티 글을 붙여 넣으면 줄마다 곡을 찾아 콘티 끝에 담는다.
  `<…>` 로 시작하는 머리말 줄은 빼고(꺾쇠 뒤에 글이 붙어도), 번호 줄이 있으면 번호 줄 + 번호 없이 `->`·`→` 로 시작하는 이어 부르기 줄만 곡이다.
  번호는 `1.`·`1)` 꼴(뒤에 숫자가 오면 날짜 `11.01` 이라 아님, `:` 는 시각이라 안 받음)이거나 `1 제목` 꼴이 **두 줄 이상**일 때만 — `7 Days` 같은 제목 하나가 번호 모드를 켜지 않게.
  끝의 조(`F`·`Bb`·`F#m`·`F-G`·`(Key Bb)`, 대소문자 가림 — 영어 제목 끝 낱말 보호, 괄호는 짝이 맞을 때만)와 앞의 `->` 는 떼고,
  `(or 다른 곡)` 은 후보로 같이 찾는다. 제목 비교는 한글 자모 합치기(`composeHangul`, NFD 복사 대비) + 소문자 + 글자·숫자만(`normalizeSongTitle`), 괄호 안을 뺀 제목도 본다.
  똑같은 제목이 없을 때만 부분 일치(짧은 쪽 3자 이상, 제목마다 8곡까지).
  **똑같은 제목 곡이 딱 하나일 때만 미리 고른다** — 같은 제목이 여럿이거나 비슷한 제목뿐이면 고를 때까지 '담기'를 막는다(비슷한 제목을 미리 고르면 엉뚱한 곡이 확인 없이 담겼다).
  후보마다 첫 가사·쪽 수·파일 이름을 보이고 마우스를 올리면 가사 앞부분. 없으면 건너뛴다('직접 찾기' = 제목·가사 검색, 입력이 0.2초 멈추면 찾는다).
  정규화한 제목·가사는 `ContiSongMatcher.build`(`Isolate.run`)가 한 번에 만든다(곡 수천 곡이면 화면이 멈췄다).
  담을 때는 `_withSubLyrics` 를 거친다(더블클릭 담기와 같다). 보조 가사를 못 읽은 곡은 원본 가사로 담고 알린다(`app.log` `[conti-text]`)
- **DB 갱신** (`replaceAllSongs`): 전체 삭제 후 재삽입 (증분 갱신 아님)
- **폴더 다시 가져오기** (`addNewSongs`): 같은 제목에 원본 가사까지 같으면 건너뛰고, 원본+보조 가사의 줄 모음
  (순서 무시)이 같으면 나누기 규칙만 바뀐 것으로 보고 **기존 곡을 고친다**(새 곡을 만들지 않는다). 나머지는 새로 넣는다
- **콘티 저장 시 가사 스냅샷**: 곡 id만이 아니라 당시 가사(`song_lyrics`)까지 저장한다.
  나중에 곡을 지우거나 다시 임포트해도 저장한 콘티가 깨지지 않는다
- **새 콘티** (예배 콘티 머리줄, `_newConti`): 확인 후 담긴 항목만 비운다(`_replaceConti`, 불러오기와 같은 초기화). 저장한 콘티는 그대로고 발표 중에는 막는다
- **콘티 파일 내보내기/가져오기** (`.wsconti`, 다른 PC 로 옮기기): 불러오기 다이얼로그의 항목별 내보내기 버튼 /
  "파일에서 가져오기". `exportContiFile` 이 DB 행을 그대로 JSON 에 담고, 행이 가리키는 이미지(PPT 페이지·항목 배경·
  헌금송 PNG 와 그 원본)는 base64 로 같이 넣어 경로 자리를 키로 바꾼다. `importContiFile` 은
  `Application Support/imported_contis/<시각>/` 에 풀고 경로를 되돌려 **로컬 콘티 목록에 새 콘티로 넣는다**.
  `song_id` 는 받는 쪽 DB 와 안 맞으므로 빼고, 곡 제목은 `worship_conti_items.song_title`(DB version 13) 스냅샷으로 간다
- **다국어 (보조 언어)**: 렌더러 네 곳(미리보기·macOS·Windows·PPTX)은 원래부터 본문 아래
  `english_text` 한 줄을 그린다. 그래서 다국어는 **그 칸에 무엇을 넣을지**만 정하는 기능이고
  렌더링 코드는 하나도 안 건드렸다.
  - **찬양**: `praise_songs.english_lyrics` 가 기본 언어('영어')를 그대로 맡고, 그 밖의 언어만
    `song_translations(song_title, language, lyrics)` 에 둔다. 키가 곡 id 가 아니라 **제목**인
    이유 — `replaceAllSongs` 가 전체 삭제 후 재삽입이라 id 가 임포트마다 바뀐다
  - **곡을 콘티에 담는 순간** 선택 언어 가사를 `englishLyrics` 슬롯에 확정해 넣는다
    (`_withSubLyrics`). 가사 스냅샷과 같은 방식이라 슬라이드·미리보기·내보내기·발표·콘티 저장은
    다국어를 전혀 모른다. 언어를 바꾸면 `_reapplySubLanguage` 가 담긴 곡들만 다시 입힌다
  - **폴더 임포트 때 언어를 묻는다.** '영어'가 아니면 곡을 새로 만들지 않고 **제목 기준으로
    가사만** 붙인다 — 같은 곡의 한글 가사가 파일마다 미묘하게 달라 중복 곡이 생기는 걸 막는다
  - **성경**: `ExportStyle.bibleSubVersion` 에 역본 하나를 전역으로 고르면 절을 콘티에 담을 때
    그 역본 본문을 `BibleStagingItem.subText` 에 함께 담는다 (DB `worship_conti_items.bible_sub_text`).
    역본마다 책 이름이 다르므로(창세기/Genesis) `mapBookName` 이 이름 → 정경 순서 index 순으로
    짝을 찾는다. 권 수가 다르면 포기하고 보조 본문 없이 담는다.
    역본을 나중에 바꿔도 **이미 담은 성경 항목에 다시 입힌다**(`_reapplyBibleVersions`, 찬양의 `_reapplySubLanguage` 와 같은 일, 바뀐 칸만).
    역본·책·장·절은 항목 참조(`역본 책 장:절`, `_buildReference`)를 `parseBibleReference` 로 다시 풀어 얻는다 — 참조 모양을 바꾸면 둘 다 고친다
  - `subLanguage`·`bibleSubVersion` 은 `ExportStyle` 에 얹혀 `export_style.json` 에 저장된다.
    렌더러는 둘 다 읽지 않는다 (담을 때 이미 결정되어 있다). `ExportStyleStore.load` 가 예전엔 이 두 키를
    안 읽어서 다시 켜면 '영어'·'없음'으로 돌아갔다 — 새 키를 더하면 `ExportStyle.fromJson` 과 스토어 **두 곳**에 다 넣는다
  - **추가 보조 언어 (관객 화면 세 번째 줄, 기획 `planning/trilingual-display/plan.md`)**: 보조 칸 옆에
    고정 칸 하나를 더 둔다(`List` 로 일반화하지 않음). 곡 `PraiseSong.extraLyrics`(DB `praise_songs` 엔 없음, 콘티 스냅샷 전용),
    성경·빈 페이지 `extraText`, 슬라이드 `SlidePageData.extraText`(JSON `extra_text`). 콘티 저장은
    `worship_conti_items.song_extra_lyrics`·`bible_extra_text`·`blank_extra_text`(DB version 18).
    `pairedPages` 는 `LyricsPage`(korean·english·extra) — 곡을 고치거나 나눌 때는 `copyWith`·`_songWithPages` 로 만들어
    추가 칸을 빠뜨리지 않는다. 언어는 `ExportStyle.extraLanguage`·`bibleExtraVersion`(기본 '' = 없음)을 담을 때 입힌다
    (`_withSubLyrics`·`_reapplySubLanguage`, 성경은 `_loadOtherVersionVerses` + `versesText`). 보조와 같은 언어는 담지 않는다.
    글자 크기는 본문 × 비율(`sub/extra_font_ratio`, 성경은 `bible_*`) — `subFontSizeFor`·`extraFontSizeFor`, 설교 부제
    `englishFontSize` 가 이긴다. 싱어 화면에는 보내지 않는다.
    렌더러 네 곳 모두 보조 다음에 같은 방식으로 셋째 블록을 그린다(Dart `SlideTextLayout.bodySpan`, macOS `.extra-text`,
    Windows `slide_.extra`, PPTX `extra_lyrics` 문단). 발표 창은 비율을 모른다 — `SlidePageData.toJson` 이 그 페이지의
    `english_font_size`·`extra_font_size`(pt)를 계산해 싣는다. 그래서 성경 보조 크기도 이제 성경 본문 기준이다(예전엔 찬양 본문 × 0.8)
  - **휴대폰 화면(싱어·발표자 리모컨)은 원본만** (`_buildSingerViewData(slides, true)` → `_singerWeb.update`): 보조 가사를 뺀다.
    설교 페이지 부제는 내용이라 그대로 보인다. 앱의 발표 보기·네이티브 싱어 창은 예전처럼 다 보인다
    (`SlidePageData.originalOnly` 는 남아 있지만 지금은 아무도 켜지 않는다)
  - **넘침 경고(자동 축소 안 함)**: `SlideTextLayout.overflowRatio` 가 미리보기와 같은 글자 배치로 높이를 재서 5.4인치 상자를 넘으면
    발표 보기 썸네일 빨간 테두리·'넘침' 배지, 콘티 목록 '넘침 N', 가사 수정 창 행 경고·미리보기 점선. 미리보기·macOS 는 넘치면
    상자를 줄여 그리고 Windows·PPTX 는 안 줄이므로 화면마다 다르게 깨진다 — 그래서 경고로 알린다. 값은 "약 N%"(발표 창 줄바꿈과 조금 다를 수 있다).
    발표 창은 보조 블록마다 앞에 틈(Windows 본문 × 0.4, macOS 0.4em)을 두므로 측정도 블록마다 본문 × 0.4 를 더한다. 캐시 키는 해시(`Object.hashAll`)
  - 언어를 바꾸면(`_reapplySubLanguage(subChanged:, extraChanged:)`) **바뀐 칸만** 다시 입힌다. 나눈·고친 곡에서 원본 페이지를 못 찾은
    페이지는 그 칸을 비운다(옛 언어 글이 남지 않게). 바뀜 여부는 '실제로 쓰이는 추가 보조'(보조와 같으면 없음)로 따진다.
    번역이 원본보다 길어 장 수가 바뀌면 `remapTrailingPages` 가 자동 여백 표시·메모만 새 끝으로 옮기고(앞 페이지 번호는 그대로라
    지운 표시를 풀지 않는다), 보던 슬라이드는 (항목, 페이지)로 다시 찾는다
  - **가사 수정 창** (`LyricsEditorDialog`): 한 행 = 관객 화면 한 장. 칸에 빈 줄이 든 글을 넣으면(붙여 넣기·엔터 두 번)
    빈 줄마다 아래 행으로 나누고 그 열의 아래 칸은 밀어 내린다(덮어쓰지 않음, 3조각 이상이면 되돌리기 배너). 칸 도구 '위로 당기기'(위 칸에 잇는다)·
    '아래로 밀기'는 그 언어 열만 옮긴다. 페이지 번호를 눌러 행을 고르고(Shift 범위·⌘/Ctrl 하나씩) 행 메뉴 '복사'·'위/아래에 붙여 넣기' 또는 ⌘/Ctrl+C·V(입력칸 밖 = 표 포커스 `_tableFocus`, 붙여 넣기는 고른 행 아래)로
    세 언어째 옮긴다(`insertRows`, 복사본은 static 이라 창을 닫아도 다른 곡에 붙여 넣을 수 있다, 되돌리기 배너). 저장 형식은 그대로(빈 줄 = 페이지)라 '통째로' 보기와 오가도 잃지 않는다
  - **켜기/끄기**는 리본 찬양 탭 '보조 언어'·성경 탭 '보조 역본' 줄의 스위치 = `includeEnglishLyrics`
    (`include_english_lyrics`). 렌더러 네 곳이 원래부터 읽는 값이라 담긴 보조 가사는 그대로 두고 표시만 끈다.
    값이 하나라 두 탭 스위치가 같이 움직인다
- **항목별 배경 오버라이드**: "헌금송만 다른 배경"처럼 콘티 일부만 배경을 다르게 하는 기능.
  전역 `ExportStyle` 은 그대로 두고, 항목 uid → `SlideBackground`(색 + 이미지 경로) 맵
  (`_itemBackgrounds`)을 따로 들고 다닌다. 메모(`_slideNotes`)와 같은 방식이라 `StagingItem`
  4형제를 건드리지 않는다.
  - 적용은 `ExportStyle.withBackground()` 한 곳. 오버라이드가 있으면 배경 **색과 이미지를
    통째로** 대체하므로, 색만 담긴 오버라이드는 "전역 배경 이미지 위가 아니라 단색"이 된다
  - 발표 창(네이티브)은 페이지마다 style JSON을 통째로 받으므로 자동으로 따라온다.
    macOS 는 WKWebView CSS(`background-size:cover`), Windows 는 GDI+ 로 같은 cover 규칙을
    직접 그린다(`PaintBackgroundImage`). 확대(zoom)도 양쪽 다 배경까지 같이 따라간다
  - **배경 이미지는 PNG/JPG 만** 고르게 막아 뒀다. 미리보기(Flutter)·Windows 발표 창(GDI+)·
    PPTX 세 군데가 모두 확실히 읽는 형식이 이 둘이다 (GDI+ 는 WebP·HEIC 를 못 읽는다)
  - 항목이 만드는 모든 페이지 + 뒤에 자동으로 붙는 여백까지 같은 배경을 쓴다
    (Dart `_allSlides` 는 앞 항목의 uid 를, Python `export_presentation` 은 앞 항목의
    background 를 그대로 빌려 쓴다)
  - 저장은 `worship_conti_items.background` 한 칸(JSON, DB version 11)
- **배경 영상** (가사 뒤 반복 재생, '항목 배경' 다이얼로그의 '배경 영상'): `SlideBackground.videoPath`·`videoDim`
  (JSON `video_path`·`video_dim`, 마이그레이션 없음). 영상은 `BackgroundImageLibrary.videos()`(`Application Support/background_videos/`,
  mp4·m4v·mov) 에서 고른다. **발표 창에서만** 튼다 — 미리보기는 영상 썸네일(`BackgroundImageLibrary.thumbnail`, 없으면 만든다)에 어둡기·가사를 얹고 영상 파일이 없으면 평소 슬라이드, PPTX 는 배경 이미지(없으면 색)를 쓰고, `.wsconti`·클라우드 콘티는
  `mapBackgroundPaths` 가 영상 칸을 지운다(보낼 때·받을 때 둘 다). PPT 이미지 페이지·자체 미디어가 있는 페이지에는 안 깐다(`_backdropFor`).
  - Windows 슬라이드는 부모 창 GDI, 미디어 레이어는 그 위 WebView2 자식 창이라 GDI 글자를 영상 위에 못 그린다. 그래서 **가사만
    투명 PNG 로 구워**(`LyricsOverlayRenderer`, 미리보기와 같은 `SlideRenderView(textOnly: true)` 를 화면 밖에서 1920x1080 으로)
    레이어 페이지가 `배경 색 → 영상(cover) → 어둡게 → 가사 PNG(contain)` 를 겹쳐 그린다. 두 플랫폼이 같은 방식이다
  - 발표 창엔 평소 미디어와 같은 `media` 칸으로 간다(`SlideBackdrop.toPageJson`, `backdrop: true`). **key 는 영상 경로·어둡기뿐**이라
    페이지를 넘기거나 지워도, 붙여 넣기로 곡이 둘로 나뉘어도, 같은 영상 곡이 이어져도 끊지 않는다. key 가 같으면 네이티브는
    `overlay_js`(`setOverlay(url)`)가 바뀌었을 때만 실행한다. 레이어는 다 읽은 PNG 로만 바꾼다(깜빡임 없음)
  - PNG 이름 = 페이지 글자·스타일의 FNV 해시(`lyrics_overlays/ov_<해시>.png`), 하루 지난 것은 처음 쓸 때 지운다. 보낼 때 굽고 다음 페이지는
    미리 굽는다(`_presentablePage`). 굽는 사이 다음 페이지로 넘어갔으면 옛 페이지는 보내지 않는다(`_pageSendSeq`). 못 구우면 평소 슬라이드
  - Windows 는 PNG 폴더를 `https://overlay.worship/` 로 매핑한다(`overlay_dir`). macOS 는 file://. 레이어가 아직 읽히는 중이면
    `overlay_js` 가 false 를 돌려주고 macOS 는 0.2초 뒤 다시 부른다(`applyOverlay`, Windows 는 `Run` 이 미뤄 둔다)
  - 슬라이더를 끄는 동안처럼 요청이 몰리면 아직 안 구운 페이지는 60ms 기다렸다가 더 새 요청이 왔으면 굽지 않는다(`isStale`)
  - 가사가 레이어 안에 있으므로 **영역 확대·포인터도 레이어가 그린다**(`setZoom`·`setPtr`, 슬라이드와 같은 계산).
    네이티브는 확대·포인터가 바뀔 때·새 레이어를 띄울 때 레이어에도 넘긴다(macOS `WKUserScript`·Windows `ZoomPointerJs`)
  - 화면 비율이 16:9 가 아니면 가사 PNG 가 contain 으로 들어가 평소 슬라이드(가로로 늘어남)와 위치가 조금 다르다. 소리는 늘 끈다.
    재생바는 안 뜬다. 블랙아웃은 레이어 전체를 0.4초에 걸쳐 감춘다
- **헌금송**: 찬양을 "배경 이미지 + 노란 '헌금' · '은행 계좌' 두 줄 + 위아래 라인" 위에 띄우는 기능.
  **항목별 배경 오버라이드 위에 얹었다** — 띠까지 그린 그림을 1920x1080 PNG 한 장으로 구워
  (`OfferingBackgroundComposer`) 그 항목의 `SlideBackground.imagePath` 로 건다. 그래서 렌더러 네 곳은
  헌금송을 전혀 모르고, 가사는 평소처럼 그 위에 그려진다.
  - 기본 디자인(배경·은행·계좌·색·크기)은 `OfferingDesign` → `offering_design.json`.
    디자인 리본 '공통' 탭의 헌금송 묶음("헌금송 디자인 등록")에서 고친다
  - 콘티 항목(찬양·빈 페이지)의 헌금송 버튼 → `OfferingDialog`. **띠 높낮이(`bandCenterY`, 인치)는
    곡마다 다르다** — 가사가 긴 곡은 띠를 위/아래로 비킨다. 항목 다이얼로그에는 높낮이·가사 위치만
    있고 배경·계좌·글자·라인은 리본 '공통' 탭에서만 고친다(공통 설정). 아직 등록 전이면 항목 버튼이
    등록 다이얼로그부터 연다
  - 미리보기와 PNG 굽기가 같은 `OfferingOverlayPainter` 를 쓴다. 미리보기에서 맞춘 위치가 곧 실제 위치
  - `SlideBackground.offering` 에 구운 디자인(높낮이 포함)을 함께 저장한다(DB `background` JSON 한 칸,
    마이그레이션 없음). 다시 열어 높낮이만 고치거나, 콘티를 불러왔는데 PNG 가 없으면 다시 굽는 데 쓴다
  - PNG 는 `Application Support/offering_backgrounds/offering_<해시>.png`. 키 = 디자인 JSON + 배경
    원본의 수정 시각·크기. 그리는 방식이 바뀌면 `_renderVersion` 을 올린다. 예전 파일은 지우지 않는다
  - **가사는 띠 위쪽** (`OfferingDesign.lyricsAboveBand`, 기본 **끔** — 켜 두면 찬양 디자인에서 맞춘 가사 위치가 헌금송에서만 확 바뀌어서 껐다. JSON 키 `lyrics_above_band_v2`): 그 항목만 가사를 하단 기준 +
    "상자 아래쪽이 띠 윗선 `lyricsGap`(기본 0.4인치, 다이얼로그에서 0~1.5 조절) 위"가 되는 미세 조정으로 낸다(`OfferingOverlayPainter.lyricsPlacement`).
    가사가 길면 위로 자란다. 값은 `SlideBackground.lyricsPosition`/`lyricsOffsetY`(JSON `text_position`/
    `text_offset_y`)에 실리고 `withBackground()` 가 찬양 가사 키만 덮어쓴다(성경 키는 그대로).
    발표 창은 페이지마다 style 을 받으니 자동, PPTX 는 `ppt_tool.py` `_style_for_item` 이 같은 키를 덮어쓴다.
    미세 조정 범위(±2.0)를 넘는 높이면 잘리므로 다이얼로그가 "띠를 내려 달라"고 알린다.
    그래서 기본 높낮이는 가운데가 아니라 아래쪽(5.9인치)이다
  - **배경 이미지는 공통 모음에서 고른다** (`BackgroundImageLibrary`, 격자 UI `BackgroundImageGallery`):
    여러 장 등록해 두고 리본 '공통' 탭의 전체 배경·헌금송 디자인 등록·"항목 배경" 다이얼로그 세 곳에서 한 장씩 고른다.
    등록하면 `Application Support/offering_images/`(헌금송 전용 시절 이름 그대로) 로 복사하고, 폴더가 곧 목록이다.
    모음에서 지우면 그 파일을 직접 쓰는 일반 항목 배경(저장한 콘티 포함)은 색만 남는다 — 삭제 전에 확인을 받는다.
    헌금송은 따로 구운 PNG 라 영향 없다
  - **배경 영상 모음**도 같은 클래스(`BackgroundImageLibrary.videos()`, `Application Support/background_videos/`, mp4·m4v·mov·webm)다.
    리본 '공통' 탭 미디어 묶음의 '배경 영상'에서 등록·삭제하고, 동영상 페이지 다이얼로그(`_MediaPageDialog`)와 '항목 배경'의 배경 영상(위)이 같은 격자로 고른다.
    썸네일은 영상 옆 `<영상>.thumb.png` — 격자를 먼저 띄운 뒤 없는 것만 `presentation` 채널 `videoThumbnail {path, out}` 으로 하나씩 만든다
    (macOS AVAssetImageGenerator 1초 지점, Windows 탐색기 썸네일 `IShellItemImageFactory`, `.part` 에 쓰고 성공하면 이름 바꾸기).
    못 만들면 아이콘+파일 이름이고 그 실행 동안 다시 시도하지 않는다. 영상 등록도 `.part` 로 복사한 뒤 이름을 바꾼다(큰 파일이 잘려 남지 않게)
  - "항목 배경" 다이얼로그에서 색·이미지를 손으로 바꾸면 헌금송 정보와 가사 위치는 떨어져 나간다(일반 배경이 된다)
- **미디어(동영상·음악·유튜브)**: '새 페이지 추가' 메뉴의 동영상/음악/유튜브 페이지 = `BlankStagingItem.media`(`SlideMedia`,
  DB `worship_conti_items.media` JSON, version 16). PPT 안 동영상은 `ppt_tool render` 가 페이지 PNG 옆에
  `NNNN.media.json`({file, rect}) + 동영상을 꺼내 두고(`extract_slide_videos`, 재생 가능한 mp4·m4v·mov·webm 만) Dart `_pptMedia` 가 찾는다 —
  나누기·복사가 이미지 경로만 옮겨도 따라간다. `.wsconti` 에는 동영상이 안 실린다(포스터 이미지만).
  - 발표 창은 슬라이드 위에 **미디어 레이어**(macOS 두 번째 WKWebView, Windows WebView2 자식 창 `media_layer.cpp`)를 얹는다.
    레이어 페이지 HTML·페이드 JS 는 Dart `mediaPlayerHtml` 하나다(`SlidePageData.toJson` 의 `media.html`). 네이티브는 `fadeOut()`·`toggle()`·`setBlack(on)`·`seek(초)` 만 부른다.
    **재생바**: 레이어 페이지가 0.25초마다 `{"t","d","p"}` 를 올리고(macOS `webkit.messageHandlers.media`, Windows `chrome.webview.postMessage` — 지금 레이어 것만)
    네이티브가 `presentation_main` `mediaState` 로 넘긴다 → `MediaPlayback` → 발표 보기 헤더 아래 `_MediaBar`(멈춤/재생·10초 앞뒤·끌기 = `mediaSeek {t}`).
    큰 화면 setState 를 피하려고 `ValueNotifier` 로만 다시 그린다. 관객 화면엔 재생바가 없다
    `media.key`(항목 uid + 종류·경로·자리)가 같으면 페이지를 다시 그려도 끊지 않는다 — PPT 애니메이션 단계는 이어서 재생된다.
    바뀌면 옛 레이어를 페이드 아웃시켜 `fade_out` 초 뒤 치우고 새 레이어는 바로 띄운다. 음악은 1×1 크기(숨기면 재생이 멈출 수 있다)
  - 페이드: 소리는 0~1 을 제곱해 볼륨으로, 동영상은 투명도까지. 페이드 인은 실제 재생 시작(`playing`·유튜브 PLAYING)부터 센다.
    끝나기 `fade_out` 초 전부터 자동으로 줄인다. PPT 동영상 페이드 = 리본 '공통' `ExportStyle.mediaFadeIn/Out`, 미디어 페이지는 항목마다
  - 유튜브는 출처 없는 페이지(file://·NavigateToString)에서 재생을 막아서(오류 153) macOS 는 `loadHTMLString(baseURL: https://localhost/)`,
    Windows 는 임시 HTML 을 가상 호스트 `https://app.worship/` 로 띄운다. 로컬 파일은 macOS `loadFileURL`, Windows `https://media.worship/`(파일 폴더 매핑)
  - Windows 는 NuGet `Microsoft.Web.WebView2`(정적 로더, `windows/runner/CMakeLists.txt` FetchContent)를 쓴다. 런타임이 없으면 레이어만 안 뜬다.
    배경이 불투명 검정이라 페이드 아웃이 슬라이드가 아니라 검정으로 빠진다(macOS 는 투명). 발표 창은 `WS_CLIPCHILDREN`
  - 확대·포인터는 미디어 레이어를 따라가지 않는다(레이어 아래에 그려진다 — 배경 영상 레이어만 예외). PPTX 내보내기는 미디어 페이지를 빈/문구 페이지로 낸다
  - MuPDF 는 경고를 stdout 에 찍어 결과 JSON 을 깨뜨린다(동영상 PPT 의 PDF 'Screen annotations') — render 에서 끈다
- **설교 제목 페이지**: '새 페이지 추가'(편집 탭 콘티 머리줄·발표 보기 툴바) 메뉴에서 빈 페이지 / 설교 제목 페이지를 고른다.
  설교 제목 페이지 = 문구가 든 `BlankStagingItem` + 항목별 배경 오버라이드. `SlideBackground` 에 `fontFamily`·`fontSize`·`textColor`·`isSermon`
  (JSON `font_family`·`font_size`·`text_color`·`sermon`)을 얹었고 `withBackground()`·`_style_for_item` 이 가사 키만 덮어쓴다 —
  DB 스키마는 그대로다. **주제 = 본문(`mainText`), 부제(예: 말씀 구절) = 보조 줄(`englishText`)**. 부제 크기·색은
  `subFontSize`·`subTextColor`(JSON `english_font_size`·`english_text_color`) → style 의 `english_font_size`·`english_text_color`.
  `english_font_size` 는 렌더러 네 곳이 읽는 새 키로, 없으면 예전처럼 본문의 0.8 배(`ExportStyle.effectiveEnglishFontSize`).
  설교 페이지는 디자인의 보조 언어 스위치를 꺼도 부제가 보인다(`withBackground`·`_style_for_item` 이 `include_english_lyrics` 를 켠다).
  마지막 디자인은 `sermon_design.json`(`SermonDesignStore`)에 남아 다음 설교 페이지의 시작값이 된다.
  설교 페이지의 '배경' 버튼은 `_SermonPageDialog` 를 열고(일반 빈 페이지로 되돌리기 포함), 헌금송 버튼은 숨긴다.
  PPTX 는 문구가 든 빈 페이지를 한 장의 가사 슬라이드로 그린다(예전엔 빈 페이지 문구가 PPTX 에서 빠졌다)
- **표시용 제목** (`PraiseSong.displayTitle`): 발표 슬라이드 제목·콘티 목록·PPTX 는 '(와이드 스크린)'·'와이드스크린'·오타('와일드스크린',
  '와이드 스크림')·'(와이드)'·'.ppt' 를 뗀 제목을 쓴다. DB 제목은 그대로 둔다 — `song_translations` 가 제목을 키로 쓴다
- **문단 안 줄바꿈**: 가져오기(`extract_lines_from_shape`)는 run 과 `<a:br>` 만 이어 붙여 `<a:br>` 에서 줄을 나눈다(필드 `<a:fld>` 는 뺀다).
  예전엔 run 만 이어 붙여 영어 가사가 'historyDeath' 처럼 붙었다. 다시 가져오기의 '나누기만 바뀐 곡' 판정은 공백 뺀 글자 모음 비교다
- **외부 PPT 애니메이션**: LibreOffice가 PDF로 굽는 순간 애니메이션은 사라지고 "다 나타난 마지막
  상태" 한 장만 남는다. 그래서 PDF로 넘기기 전에 pptx의 `<p:timing>`(메인 시퀀스)을 읽어
  **클릭 한 번 = 페이지 한 장**으로 슬라이드를 복제해 둔다 (`expand_animation_steps`).
  움직이는 효과 자체는 재현하지 못하지만 "클릭할 때마다 하나씩 나타난다"는 순서는 살아난다.
  도형 단위(`spTgt`)와 문단 단위(`txEl/pRg`, 가사 한 줄씩 등장) 둘 다 지원하고 사라짐(`exit`)도 따라간다.
  - 문단을 감출 때는 글자만 지우고 빈 문단은 남긴다. 문단째 지우면 나머지 줄이 위아래로 밀린다
  - 슬라이드당 30단계 / 파일당 600페이지를 넘으면 펼치기를 포기하고 원본대로 한 장씩 굽는다
  - 결과는 `image_paths`가 길어지는 것뿐이라 Dart·발표 창·내보내기·콘티 저장은 손댈 게 없다
  - `.ppt`는 XML을 못 여니 pptx로 먼저 바꾼 뒤에 본다. 다만 **LibreOffice가 `.ppt`를 저장할 때
    애니메이션을 버리는 것은 확인됐고, 진짜 PowerPoint가 만든 `.ppt`를 읽을 때 타이밍이
    남는지는 미확인**이다. 안 남으면 그냥 예전처럼 한 장씩 구워진다
- **외부 PPT 수정 (원본 열어 수정)**: 앱 안에 PPT 편집기를 만들지 않고, 원본 파일을 OS 기본 프로그램
  (PowerPoint 등, macOS `open` / Windows 네이티브 `openFile` = `ShellExecuteW`)으로 열어 고치게 한다.
  Windows 에서 `explorer <경로>` 는 경로의 쉼표를 구분자로 읽고, `cmd /c start` 는 Dart 인자 따옴표 규칙
  (공백이 있을 때만 감싼다)과 어긋나서 네이티브로 뺐다. macOS 는 `open` 의 종료 코드로 실패를 가린다. 콘티 항목의 연필 메뉴
  '원본 열어 수정' / '원본에서 다시 불러오기'.
  - `ImageStagingItem.sourcePath` 에 구운 원본 경로를 담는다(DB `worship_conti_items.image_source_path`,
    version 15). **원본의 일부 페이지만 담은 항목(나누기·복사)은 null** — 다시 구우면 전 페이지가 들어와
    페이지가 겹친다. 발표 보기에서 지운 페이지만 빠진 항목은 원본 그대로라 남긴다.
    `.wsconti` 내보내기에서는 뺀다(다른 PC 경로라 뜻이 없다)
  - 저장 감지는 `SourceFileWatcher` 가 2초마다 수정 시각·크기를 본다. `File.watch` 를 안 쓰는 이유 —
    PowerPoint 는 임시 파일에 쓰고 이름을 바꿔 저장해서 파일 하나에 건 감시가 끊긴다. 바뀐 뒤
    **같은 값이 한 번 더 나와야**(저장이 끝나야) 다시 굽는다. 상태는 **비동기**로 읽는다(원본이 NAS·USB 면
    동기 stat 이 발표 넘기기를 멈춘다). 항목을 빼면(`_removeStagingWhere` → `_pruneSourceWatches`) 그
    원본 감시를 끄고, 콘티를 불러오면 모두 끈다 — 다른 콘티가 같은 파일을 쓸 때 멋대로 다시 굽지 않게
  - 다시 구워도 항목 uid 는 그대로라 배경·헌금송·여백 설정은 남는다. **보던 슬라이드는 번호가 아니라
    (항목, 페이지)로 다시 찾는다**(`_findSlideAfterReload`) — 앞 항목 장 수가 바뀌어도 관객 화면이 넘어가지 않게.
    지운 페이지·메모는 `remapReloadedPages`: 장 수가 같으면 그대로, 다르면 지운 표시를 풀고(안내) 범위 밖
    메모만 버린다. 자동 여백(`uid:장수`)의 표시·메모는 새 끝으로 옮긴다
  - Python 은 손댈 게 없다 — 렌더 캐시 키에 원본의 수정 시각·크기가 들어 있어 저장 후 다시 구우면
    새 폴더에 굽고, 예전 콘티가 가리키는 옛 폴더는 그대로 남는다
- **악보 가사 추출**: 오선을 좌표로 먼저 찾아 "오선 아래"만 OCR 에 넘긴다. 제목·작곡가(첫 단 위)와
  코드 기호(다음 단 바로 위)를 글자 모양으로 거르는 것보다 훨씬 정확하다.
  - 오선 찾기는 이미지 처리 라이브러리 없이 **행별 검은 비율**(Pillow `resize((1, h), BOX)` = 가로 평균)
    하나로 한다. 가로로 평균 내면 오선만 1에 가깝고 글자 줄은 0.35를 잘 안 넘는다.
    줄 간격은 모든 선 간격의 **중앙값** — 한 단 안의 간격이 4개, 단 사이 간격이 1개라 늘 줄 간격이 된다
  - **띠를 통째로 넘기지 않고 글 줄 하나씩** 잘라 `--psm 7`(한 줄 모드)로 넘긴다. 가사는 음표에 맞춰
    띄엄띄엄 놓여서 여러 줄 모드(`--psm 6`)는 한 줄을 두 줄로 쪼갠다
  - **코드 기호 거르기**: 오선 사이 글 줄 중 마지막 줄이 위쪽(가사·오선)보다 **아래 단에 더 붙어 있으면**
    그 단의 코드다. 거리 비교라 악보마다 다른 여백에 영향을 안 받는다. `is_chord_line`(C, G7, Am/E 만
    있는 줄)이 2차 그물
  - **하이픈은 양옆 공백까지 지워 붙인다** (`할 - 렐 - 루 - 야` → `할렐루야`). 음절을 잇는 기호라
    공백을 남기면 안 된다
  - **한 글자 토막도 붙인다** (`주 의 인 자` → `주의인자`, `join_single_syllables`). 악보는 음표 하나에
    음절 하나를 놓느라 띄어 쓴 것이라 단어 사이가 아니다. 단, **양쪽이 다 한글일 때만** 붙인다 —
    영어 가사의 `I am a boy` 까지 붙으면 안 되고, 절 번호(`1.`)도 한글이 아니라 떨어져 남는다
  - **글자가 박힌 PDF(악보 프로그램 출력본)는 OCR 을 아예 안 탄다.** PyMuPDF 로 낱말과 좌표를
    꺼내 같은 띠 안의 낱말을 x 순서로 잇는다(`_words_to_lyric_lines`). 오인식이 없고 Tesseract 도
    필요 없다. 오선 찾기는 그대로 구운 이미지로 하므로 **PDF 좌표(72dpi)를 이미지 배율로 맞춰야
    한다**(`OCR_DPI / 72`). 낱말이 하나도 없는 쪽(그림·스캔본)만 OCR 로 넘어간다 →
    그래서 `tesseract_missing` 판정은 파일을 연 **뒤에** 한다
  - **그림 악보는 먼저 다듬는다** (`prepare_sheet_image`): 바탕 펴기(`flatten_background`, 그림자·회색 종이 → 흰색) →
    기울기 바로잡기(`find_skew_angle`, ±4° 중 행 비율 제곱합이 가장 큰 각) → 오선 줄 간격을 22px(`_TARGET_STAFF_SPACING`)로
    맞추는 크기 조정. 작은 캡처(줄 간격 7~8px)는 1·2절 줄 사이 틈이 1~2px 라 두 줄이 한 덩어리로 잡혀 아무것도 못 읽었다.
    문턱값은 둘 — 오선은 Otsu 값(흐린 가는 선도 잡게. 흐린 JPEG 라 Otsu 와 255 의 중간값이 단을 더 찾으면 그 값), 글 줄은 `min(Otsu, 160)`(JPEG 얼룩이 글자로 안 잡히게)
  - **오선에 이어진 악보 기호를 먼저 지운다** (`erase_staff_symbols`): 오선 다섯 줄에서 번져 나가면(마디선·기둥으로 다 이어져 있다)
    음표·기둥·붙임줄이 한 덩어리로 지워지고 가사·코드 글자만 남는다. 그 뒤에 글 줄을 찾는다. 낮은 음표가 오선 아래로
    길게 내려온 실제 악보는 음표+가사 첫 줄이 한 덩어리로 잡혀 '덧줄 음표'로 통째로 버려졌다(가사 절반이 사라짐).
    음표가 글자에 닿은 곳은 글자까지 지워지므로, 가사 줄 높이 안은 원본으로 되살린다 — 줄을 80% 넘게 꿰뚫는 기둥 열만 빼고
    (`restore_lyric_band`). 기둥이 지워지면 다음 단의 코드 줄이 혼자 남으므로 `is_chord_line` 은 띄어쓰기 없는
    `CG’DmCFCG’C` 도 코드로 본다(영문자 대부분이 A~G 대문자·m). 글 줄 높이 중앙값의 40% 미만(붙임줄·저작권 문구)은 버리고,
    60% 미만은 띠 맨 위에서 아래 줄이 더 있을 때만 버린다(소문자뿐인 `for ever` 줄은 60% 쯤이라)
  - **가사 한 줄 이미지** (`_lyric_line_image`): 줄에서 한 줄 간격쯤 떨어진 행에 걸친 덩어리(음표 기둥)를 지운다 —
    단, 글 줄 안에서 가늘 때만(넓으면 흐려서 음표가 글자에 붙은 것이라 글자를 살린다). 음표 자리 때문에 벌어진
    글자 사이를 줄 높이의 0.6 배로 줄이고(`_squeeze_gaps`, 큰 틈 뒤 낱말을 확신도 0·숫자 잡음으로 읽었다),
    글 줄 높이를 48px 로 맞춘 뒤 흑백으로 굳히고 획을 1px 굵힌다(손글씨풍 글꼴의 가는 `라`·`나` 를 빠뜨려서)
  - **언어는 줄마다 따로 읽어 확신도로 고른다** (`_ocr_lyric_line`, TSV 출력): `kor+eng` 를 한 번에 쓰면 한 줄 안에서
    음절마다 언어를 오가며 읽어 한글 줄을 통째로 영문 잡음으로(`뽑의노래로` → `ol Layae`), 영어 줄을 한글로 읽었다.
    점수는 글자 수로 가중한 평균 확신도, 글자 없는 토막(음표를 읽은 숫자)은 0 점. 기둥을 읽은 `l`·`i`·`j` 는 버리고,
    영어 줄의 외따로 선 `|` 는 `I` 로 본다. Tesseract 는 줄마다 스레드 풀로 동시에 돌린다(`OMP_THREAD_LIMIT=1`)
  - **1·2절 순서** (`order_lyric_lines`): 한 단 아래 겹친 절을 위에서 아래로 읽으면 엇갈려 나오므로, 줄 수가 같은 단이
    이어진 구간마다 1절 끝까지 → 빈 줄 → 2절 끝까지로 편다. 빈 줄은 앱에서 페이지 나눔이 된다(`lyrics`; `lines` 엔 빈 줄 없음).
    단 끝에서 하이픈으로 끊긴 영어 낱말(`Lift -` ↵ `ing`)은 앞 줄에 붙인다 — 한글 줄 끝 하이픈은 '음 끌기'라 안 붙인다.
    뒷줄 첫 토막이 흔한 낱말(`for`, `the`…, `_COMMON_ENGLISH_WORDS`)이면 안 붙인다(흐려서 하이픈만 남은 경우)
  - **못 읽은 줄은 자리를 남긴다** (`_finish_line` → None, 코드 줄은 `_CHORD_LINE` 으로 아예 뺀다). 빼 버리면 그 단의 줄 수가
    줄어 2절 줄이 1절로 밀린다. 띠 맨 끝에 섞인 다음 단 코드 줄이 뭉개져 None 이 되는 일이 많아서, 맨 끝 None 은 이웃 단의
    (맨 끝 None 뺀) 줄 수에 맞출 때만 덜어 낸다(`_trim_unread_lines`)
  - '다음 단에 붙은 줄' 규칙은 한 줄 간격 안 + **글자가 성길 때**(쪽의 글 줄 밀도 상위 25% 의 65% 미만, `_sparse_row_limit`)
    + 띠에 다른 줄이 있을 때만이다. 코드 없이 빽빽한 찬송가의 마지막 절을 지키려고. 글자가 박힌 PDF 도 음표를 지운 뒤 줄을 찾는다
  - 다음 단 윗선에 한 줄 간격 안으로 붙은 글 줄 덩어리는 거리 비교 없이 그 단의 음표로 보고 버린다(흐린 그림에선 기둥이
    글 줄로 잡혀 코드 줄과 오선 사이를 메운다). 줄 간격 절반보다 얇은 덩어리는 그 전에 먼저 거른다
  - 측정(LilyPond 로 만든 코드+2절 악보, 300dpi·100dpi 캡처·JPEG·기울어진 사진·그림자+흐림): 예전 평균 약 64%
    (흐린 사진은 33%) → 약 99%. 실제 찬양 악보 사진(손글씨풍 가사 글꼴, 2절+후렴, JPEG): 약 42% → 약 69%.
    줄 구조·절 순서는 맞고 남은 오류는 손글씨풍 글자 오인식(`을`→`옹`, `믿`→`민`) — Tesseract 자체의 한계다
  - 오선 사이 띠에서 **끝에서부터** 아래 단에 더 붙은 덩어리(코드·위로 삐진 음표)를 걷어 내고,
    띠 첫 행부터 검은 첫 덩어리(오선에 붙은 덧줄 음표)도 버린다
  - **오선 없는 가사·코드 악보**(쪽 전체를 한 번에 읽는 경로): 맨 윗줄이 다른 줄보다 1.5배 넘게 크면 제목으로 보고 뺀다.
    `<verse1>`·`[Chorus]`·`후렴` 같은 구조 표시는 `_SECTION_LINE` → 절 나눔(빈 줄)이 된다(`_SECTION_BREAK`).
    괄호 안 연주 메모(`(verse로 갈땐 D/A)`, `(F# if keyup)`)는 코드나 key 가 들어 있을 때만 지운다(`(x2)` 는 남김).
    코드 줄 판별은 앞의 구조 표시(`Inter Bb F Eb`)를 떼고 보고, OCR 이 뭉갠 코드(`Bo`=B♭, `DIC`=D/C)도 줄의 60% 이상이면 코드다
  - 여러 쪽 PDF(콘티 전체)는 모든 쪽을 읽어 **한 곡으로 합친다**(사용자가 고른 방식 — 곡별로 나누지 않는다)
  - **클립보드 붙여넣기** (`sheet --clipboard`, '악보 가져오기' 옆 붙여넣기 버튼): Pillow `ImageGrab.grabclipboard()`
    라 Dart 쪽 클립보드 패키지가 필요 없다. **macOS 는 예외** — Pillow 가 부르는 osascript 가 붙여넣기 허용 창(화면에 안 뜸)에서 멈춰서, 앱(`worship_slides/ocr` `clipboardImage`)이 직접 읽어 파일 경로로 넘긴다. 진행 창엔 '취소'가 있다. 복사한 파일 경로 목록도 받는다. 없으면 `{"error": "clipboard_empty"}`.
    투명 배경 그림은 흰 바탕에 얹어서 읽는다
  - **글자 읽기는 OS 내장 OCR 이 먼저다** (`PythonBridge.extractSheetLyrics`): 오선·줄 찾기와 정리는 Python 이 하고
    (`layout_sheet` → `resolve_sheet_lines`), 잘라 낸 줄 이미지만 앱이 `worship_slides/ocr` 로 읽는다. 실제 악보 사진(손글씨풍
    가사 글꼴)에서 Tesseract 가 약 69% 에 머물러서 넣었다. 두 단계라 ppt_tool 을 두 번 부른다(`--ocr-lines` → `sheet-finish`)
    - macOS: Vision `VNRecognizeTextRequest`(정확 모드, 3번째 판 = 한국어, **macOS 13 이상**). 사전 교정은 끈다(띄엄띄엄 음절을
      엉뚱한 낱말로 바꿀 수 있어서). 좌표는 아래가 0 이라 뒤집어서 넘긴다
    - Windows: Windows.Media.Ocr 한국어 엔진(**한국어 언어 팩/OCR 기능이 깔려 있어야** 함, 영문도 같이 읽는다). C++/WinRT
      `.get()` 은 UI(STA) 스레드에서 못 기다려서 작업 스레드에서 읽고 메시지 전용 창으로 UI 스레드에 넘겨 응답한다.
      확신도를 안 줘서 1.0. `OcrEngine.MaxImageDimension` 을 넘는 그림은 못 읽으므로 Python 이 긴 변을 2500px 로 줄여 보낸다
    - OS OCR 용 줄 이미지는 흑백으로 굳히지 않는다(`binarize=False`). 굳히고 굵힌 글자는 Tesseract 용이다.
      대신 **절반으로 줄이고 흰 여백을 두른다**(`_native_line_image`) — Vision 이 글자 높이 48px·여백 없는 띄엄띄엄한 줄을
      빈 결과로 돌려줬다(콘티 PDF 한 쪽에서 12줄 중 8줄). Windows OCR 에서는 확인 못 했다
    - `isAvailable` 이 false(옛 macOS, 한국어 OCR 없는 Windows)거나 `recognize` 가 PlatformException 이면 Tesseract 로 읽는다.
      답은 앱이 켜져 있는 동안 기억한다
    - **이 경로는 이 레포의 리눅스 환경에서 실행해 보지 못했다**(Swift·C++ 는 CI 에서만 컴파일). 정확도 수치는 Tesseract 기준이다
  - Tesseract 는 LibreOffice 와 같은 **선택 시스템 의존성**이다. 없으면 그 기능만 막고 설치 안내를 띄운다
    (`TesseractMissingException` → `_showTesseractDialog`). `kor` 언어 데이터가 없으면 `eng` 로만 읽는다
  - 읽어 온 가사는 `_SheetLyricsDialog` 에서 고친 뒤 **곡 편집 다이얼로그로 넘어간다**. 그래서
    `_openSongEditor` 는 `song == null` 이 아니라 **`edited.id == null`** 로 새 곡 여부를 가린다
    (악보 초안은 song 은 있고 id 만 없다)
- **LibreOffice 는 내장하지 않고 자동 설치한다** (`LibreOfficeInstaller`, `LibreOfficeInstallDialog`):
  수백 MB 라 내장하면 업데이트 zip(덮어쓰기 방식이라 매번 통째로 받는다)이 무거워진다. 없으면 안내창의 '자동 설치'가
  Windows 는 `winget install --id TheDocumentFoundation.LibreOffice`, macOS 는 `brew install --cask libreoffice` 를 돌린다
  (Homebrew 는 `/opt/homebrew`·`/usr/local` 에서 직접 찾는다). 도구가 없으면 다운로드 페이지만 안내한다.
  성공 여부는 종료 코드가 아니라 **설치 후 `soffice` 가 실제로 있는지**로 가린다 — 찾는 경로는 `ppt_tool.py`
  `get_libreoffice_executable` 과 같아야 한다. 설치되면 하던 일을 다시 한다: 폴더 가져오기는 같은 폴더를 다시
  가져오고(이미 들어간 곡은 중복으로 건너뜀), PPT 이미지 넣기는 못 구운 파일만 다시 굽는다(뒤의 PDF 는 기다리지 않고 먼저 들어간다). 출력은 `app.log` 에 `[libreoffice]`
- **macOS LibreOffice 글꼴** (`_libreoffice_env`): macOS LibreOffice(26.8 에서 확인)는 fontconfig 로 글꼴을 찾는데 기본 설정에
  맥 글꼴 폴더가 없어 한글 글꼴을 하나도 못 쓴다 → 내장 라틴·히브리 글꼴로 그려 **한글이 통째로 빠진 PNG** 가 나왔다(PDF 엔 글자가 있다).
  soffice 를 부를 때마다 맥 글꼴 폴더(+ 앱 내장 무료 글꼴 폴더)를 적은 `~/Library/Caches/worship_slides/fontconfig/fonts.conf` 를
  `FONTCONFIG_FILE` 로 넘긴다. 사용자가 이미 `FONTCONFIG_FILE` 을 정해 뒀으면 건드리지 않는다. 이 수정으로 `RENDER_CACHE_VERSION` 은 macOS 만 3(Windows 는 2 그대로)
- **외부 PPT 는 PowerPoint 가 있으면 PowerPoint 로 굽는다** (`_convert_to_pdf` → `_convert_with_powerpoint`): 파일에 심은 글꼴
  (`ppt/fonts/*.fntdata`, EOT+MTX 압축)을 LibreOffice 는 못 읽고 대체 글꼴로 그려 크기·줄바꿈이 깨진다. PowerPoint 로 PDF 를 만들고
  원본은 저장하지 않는다(우리가 연 문서만 닫고, 우리가 띄웠고 남은 문서가 없을 때만 끈다). 없거나 실패·시간 초과(180초)면 예전 LibreOffice 경로.
  macOS 는 osascript(stdin 스크립트). PowerPoint 는 샌드박스라 처음 보는 폴더의 파일을 열면 '파일 액세스 부여' 창을 띄운다. 그래서 사본을
  **고정 작업 폴더** `Application Support/worship_slides/powerpoint/` 에 겹치지 않는 이름(`slides_<uuid>`)으로 두고 연다 — 처음 한 번 허용하면
  PowerPoint 가 기억한다(사본·PDF 는 끝나면 지우고 폴더는 남긴다). 허용 창이 뒤에 숨지 않게 열기 전에 PowerPoint 를 `activate` 한다.
  (`~$` 이름이면 묻지 않는다는 우회는 실제로는 안 통했다.)
  Windows 는 PowerShell COM(`Presentations.Open(path, ReadOnly, , WithWindow=False)` → `SaveAs(pdf, 32)`, 새 의존성 없음 — **실제 실행은 확인 못 했다**).
  시간 초과가 한 번 나면 하루 동안 PowerPoint 를 건너뛴다(`~/Library/Caches/worship_slides/powerpoint_timeout` 파일). PowerPoint 가 있으면 LibreOffice 없이도 .pptx 는 굽힌다.
  PowerPoint 가 있는데 실패해서 LibreOffice 로 구웠으면 `meta.json` 에 `powerpoint_failed` 를 남기고, 다음 render 때 PowerPoint 를 쓸 수 있으면(시간 초과 표시가 없으면) 같은 폴더에 다시 굽는다.
  숨긴 슬라이드를 PowerPoint 가 PDF 에 넣는지는 **미확인**이다(빠지면 쪽 수가 달라져 동영상 짝짓기가 어긋난다). 이 변경으로 `RENDER_CACHE_VERSION` 은 macOS 5·Windows 4
- **PPT 에 심은 글꼴** (`python/eot_font.py`, `_embedded_font_dir`): `ppt/fonts/*.fntdata` 는 EOT 이고 대개 MicroType Express(MTX) 압축이다.
  LibreOffice 는 못 읽어 대체 글꼴로 그리고(크기·줄바꿈이 깨짐), 심은 글꼴에 **'미리 보기/인쇄만 허용'(fsType 0x4)** 이 섞여 있으면
  macOS PowerPoint 는 문서를 편집 잠금으로 열어 'PDF 로 저장'이 비활성 — AppleScript 저장은 오류도 없이 아무것도 안 한다(그래서 `powerpoint_failed` 만 남았다).
  - 그래서 그런 pptx 는 macOS 에서 PowerPoint 를 건너뛰고(`has_restricted_embedded_fonts`) LibreOffice 로 굽되, 심은 글꼴을 TTF 로 풀어
    이번 변환 전용 폴더에 두고 fontconfig `<include>` + `<dir>` 로 넘긴다(`_libreoffice_env_with_fonts`). 같은 글꼴도 PPT 마다 일부 글자만 담겼을 수 있어 폴더는 변환마다 따로
  - MTX 풀기는 W3C 명세(https://www.w3.org/Submission/MTX/)를 순수 Python 으로 옮겼다: LZCOMP(적응 허프만 3개 + 런 렝스) → CTF(글리프 세 쌍 좌표·push 데이터·hop 코드·cvt) → TTF.
    `hdmx`·`VDMX`(힌팅 결과 캐시)·`DSIG` 는 되살리지 않고 뺀다. 첫 윤곽 값은 '점 수'가 아니라 '끝점 번호(점 수-1)'다(명세 5.7.2 — 반대로 읽으면 글리프 흐름이 어긋난다)
  - 큰 글꼴(맑은 고딕 6MB)은 푸는 데 약 13초라 푼 TTF 는 `~/Library/Caches/worship_slides/embedded_fonts/<sha1>.ttf` 에 캐시한다. 포함 금지(fsType 0x2) 글꼴은 쓰지 않는다
  - Windows 는 LibreOffice 가 fontconfig 를 안 써서 아직 이 경로가 없다(`_libreoffice_env` 가 None). 이 변경으로 macOS `RENDER_CACHE_VERSION` 6
  - macOS PowerPoint '파일 액세스 부여' 창은 폴더를 한 번 허용해도 파일마다 다시 뜨는 일이 있다(이 Mac 에서 확인). 창에서 '선택…'으로 작업 폴더 자체를 골라야 한다
- **PPT 렌더 캐시 위치**: `~/Library/Application Support/worship_slides/ppt_slides/<해시>/`.
  Caches가 아닌 이유 — 저장한 콘티가 나중에 이미지 유실로 깨지면 안 되기 때문.
  (`.ppt`→`.pptx` 변환 캐시는 유실돼도 되므로 `~/Library/Caches/worship_slides/ppt_import_cache/`)
  굽는 방식이 바뀌면 `RENDER_CACHE_VERSION`을 올린다. 키가 달라져 다시 굽지만, 예전 폴더는
  저장된 콘티가 참조하고 있을 수 있으므로 지우지 않는다
- **폰트**: 앱은 번들 폰트(Pretendard/NanumGothic/NanumMyeongjo)를 쓰지만, 내보낸 PPTX를 PowerPoint에서
  열 때 필요하므로 `_ensure_fonts_installed`가 사용자 폰트 폴더에 복사한다.
  단, PyInstaller에는 **Pretendard만** 번들되어 있다
- **내장 무료 폰트** (`FontLibrary`): 무료(OFL) 폰트 몇 종을 `assets/fonts/free/`(라이선스 txt 포함)에
  넣어 두고 **pubspec `fonts:` 가 아니라** 첫 실행 때 `Application Support/fonts/` 로 복사해 올린다 —
  발표 창·PPTX 가 실제 파일 경로를 알아야 해서다. **사용자가 폰트를 직접 추가하는 기능은 라이선스
  책임 문제로 일부러 뺐다.** 폰트를 더 넣을 땐 OFL 등 재배포 가능한 것만, 가변(variable) 폰트는 피한다
  - family 이름은 파일의 name 테이블(name ID 1, 영어)에서 읽는다(`readFontInfo`). Windows GDI 와
    PowerPoint 가 이 이름으로 찾으므로 Flutter `loadFontFromList` 이름도 똑같이 맞춘다
  - Dart 는 style JSON 을 보낼 때(`SlidePageData.toJson`, `PythonBridge.export`) `font_files`
    `[{path, weight}]` 를 붙인다. `export_style.json` 에는 저장하지 않는다.
    macOS 는 data URI `@font-face`, Windows 는 `AddFontResourceExW(FR_PRIVATE)`,
    Python 은 사용자 폰트 폴더에 복사(+ Windows 레지스트리·`AddFontResourceW`)
- **PPTX 배경 XML 위치**: `p:bg` 는 `p:sld` 가 아니라 **`p:cSld` 의 첫 자식**이다.
  자리를 틀리면 PowerPoint 가 배경을 조용히 무시한다 (`_apply_slide_background` 참고)
- **가사 줄바꿈은 `<a:br/>`**: 한 run 의 `<a:t>` 안에 날 줄바꿈 문자를 넣으면 OOXML 상
  줄바꿈이 아니라서 뷰어마다 다르게 그려진다 (LibreOffice 는 가운데 정렬을 무시하고
  줄을 양쪽으로 벌린다). `_add_text_run` 이 줄마다 run 을 만들고 사이에 `<a:br/>` 를 넣는다.
  `<a:br>` 에도 크기·굵기·글꼴을 넣어야 줄 높이가 본문과 같아진다.
  성경 본문은 내어쓰기 때문에 원래 줄마다 문단을 만들므로 이 경로를 타지 않는다
- **좌표계 일치**: 미리보기·발표 창·PPTX가 같게 보여야 한다. 기준은 슬라이드 높이 7.5인치 = 540pt,
  `fontScale = 높이 / 540`. Swift HTML은 `calc(N / 540 * 100vh)`로 맞춘다
- **세로 위치 = 기준선 + 미세 조정**: 상단/중단/하단(`text_position`, `title_vertical_position`)은
  세 칸짜리 고정값이라 그 사이 높이를 못 맞춘다. 그래서 미세 조정 값(인치, + = 아래, ±2.0,
  0.05 단위)을 따로 둔다. 본문은 `text_offset_y`/`bible_text_offset_y`,
  제목은 `title_offset_y`/`bible_title_offset_y` 네 개가 서로 독립이다.
  - **본문 상자는 크기가 고정(0.6인치 위, 5.4인치 높이)이고 미세 조정이 그 상자를 통째로 민다.**
    높이를 건드리지 않으므로 상단/중단/하단 어느 기준을 골라도 밀어 준 만큼 똑같이 움직인다
  - **예전 "본문 상단 여백"(`text_box_top`)은 제거됐다.** 상자의 위쪽만 끌어내려 높이까지
    같이 줄이던 값이라 기준마다 효과가 달랐다 — 상자 아래쪽이 늘 6.0인치에 붙어 있어서
    **하단 기준에서는 아무 효과가 없었고, 중단 기준에서는 절반만** 움직였다. 낼 수 있던 위치
    (상단 0.3~2.2 / 중단 중심 3.15~4.10)는 모두 미세 조정 범위 안에 들어온다.
    예전 `export_style.json` 은 `migrateLegacyTopMargin()`(`export_style.dart`)이 기준선별로
    환산해 미세 조정 값에 더한다 — 상단은 그대로, 중단은 절반, 하단은 0. 콘티는 스타일을
    저장하지 않으므로 옮길 게 없다
  - 제목은 상자 높이가 0.55인치로 고정이라 기준선에 그냥 더하면 된다
    (`slide_render_view.dart`의 `titleTop`, `ppt_tool.py`의 `_add_title_textbox`,
    `presentation_channel.cpp`의 `ty`). macOS 는 제목을 `top`/`bottom` 퍼센트로
    붙이므로 `calc(1.5% ± Nvh)`로 넣는다 — **아래로 미는 값은 `top` 에는 더하고
    `bottom` 에서는 뺀다**. 가운데+중단은 `translateX`/`translateY` 가 서로를 덮으므로
    `translate()` 하나로 합쳐 쓴다
  - 계산하는 곳이 네 군데다. 하나만 고치면 미리보기와 실제 화면이 어긋난다 —
    `slide_render_view.dart`(미리보기), `MainFlutterWindow.swift`(macOS 발표),
    `presentation_channel.cpp`(Windows 발표), `ppt_tool.py`의
    `_lyrics_box_vertical_layout`·`_add_title_textbox`(PPTX).
    허용 범위(±2.0)도 네 곳이 같아야 한다
  - 키가 없는 예전 설정·콘티는 0으로 읽혀 기존 동작 그대로다

- **디자인 리본**: 폰트·색·위치 설정은 오른쪽 패널이 아니라 접이식 리본(`_DesignRibbon`)에 있다.
  메인 탭(편집/발표 보기)·가져오기 메뉴·PPTX 저장·발표 시작은 맨 위 앱 바(`_TopBar`) 한 줄에 있고, 보관함 정보(곡 수·폴더·진행률·버전)는
  맨 아래 `_StatusBar` 다. 리본은 머리줄(디자인 탭)과 내용을 한 카드에 담는다. 두 탭이 같이 쓰고, `_updateStyle` 이 발표 창에 현재 페이지를
  다시 보내므로 발표 중에도 바로 반영된다. 찬양/성경 리본 탭은 편집 탭에선 고른 콘티 항목,
  발표 보기에선 현재 슬라이드를 따라 자동 전환된다.
  - 리본 전체를 `ExcludeFocus` 로 감쌌다. Tab 키로 포커스가 슬라이더에 들어가면 발표 단축키
    (←/→)를 슬라이더가 가로채 슬라이드 대신 값이 바뀐다(위젯 테스트로 확인). 마우스 클릭은
    원래 포커스를 가져가지 않으므로 마우스 조작은 영향 없다
- **앱 화면 테마**: 7종(`AppThemeKind`)을 앱 바 팔레트 메뉴로 고른다(`appThemeKind`, `Application Support/ui_theme.txt` 에 enum 이름 — 예전 `light`/`dark` 값도 그대로 읽힌다).
  밝은·어두운은 원래 상수 그대로, 나머지는 `_tinted()` 로 바탕·선·강조·선택색만 바꿔 만든다. `primary` 는 흰 바탕 위 아이콘·글자로도 쓰이므로 늘 진하게 둔다.
  위젯에 색을 직접 박지 말고 `colorScheme` 을 쓴다 — 그래야 모든 테마를 따라간다.
  테마 색은 바탕·구분선·테두리(`outlineVariant`/`outline`)·탭 밑줄·포커스(`secondary`)·선택 표시(`*Container`)에만 싣는다
- **발표 보기 썸네일 줄 높이**: 현재 슬라이드와 아래 썸네일 줄 사이 막대를 끌어 바꾼다
  (`PresenterViewState.stripHeight`, 최소 80, 현재 슬라이드 쪽에 180 은 남긴다)

## 발표 모드 단축키

`praise_home_page.dart` `_handleKeyEvent` — F5 발표 시작(`_handleStartKey`, 전역 핸들러), →/↓/Space 다음, ←/↑ 이전, 숫자+Enter 해당 슬라이드로 점프, Ctrl+F4 발표 종료(macOS 는 ⌃F4 를 시스템이 가져갈 수 있어 ⌘F4 도. ESC 는 번호 입력 취소만 — 잘못 눌러 꺼지는 사고 방지. macOS·Windows 발표 창도 같다).

발표 보기 탭에서 Ctrl+F(macOS ⌘F) = 곡 찾기 입력칸으로 (`_PresenterConsoleState._handleFindKey`, 전역 핸들러 —
콘솔은 IndexedStack 에 늘 살아 있으므로 `isActive` 로 탭이 보일 때만 받는다). 찾기 범위는 입력칸 옆 '제목 | 가사'
(`PresenterViewState.searchScope`). 제목은 항목 첫 페이지, 가사는 원본·보조 가사가 맞는 그 페이지로 간다.
입력칸 안 ESC 는 발표 종료가 아니라 입력칸에서 빠져나오기만 한다.
F3 = 입력된 검색어로 다음 찾기, F2 = 이전 찾기(같은 전역 핸들러, 끝에 닿으면 처음/끝으로 돈다).

발표 보기 썸네일: ⌘/Ctrl+클릭 = 하나씩 골라 담기, Shift+클릭 = 범위, Delete/Backspace = 고른 페이지 한꺼번에 삭제,
ESC = 고르기 취소, ⌘/Ctrl+C·V = 복사·붙여 넣기(`_handleEditKey`). 복사는 고른 게 없으면 현재 페이지.
붙여 넣기는 현재 페이지 바로 뒤에 새 콘티 항목으로 들어간다 — 같은 곡의 페이지는 곡 한 항목으로 묶고(제목·배경 유지), 자동 여백은 빼고 복사한다.
곡·PPT 중간 페이지면 그 항목을 둘로 나눠(`_splitStagingItem`) 사이에 넣는다(앞부분 끝 빈 가사 페이지는 곡에 담으면 사라지므로 빈 페이지 항목으로 뺀다).
자동 여백은 **같은 곡(제목)·같은 PPT 파일끼리 맞닿는 자리만** 뺀다(`_sameSource`) — 같은 곡 페이지를 붙여 넣으면 이어지고, 다른 곡이면 여백이 생긴다.
여백 페이지 위에서 붙여 넣으면 여백 뒤에 들어간다. 항목을 빼거나 옮기면(`_removeStagingWhere`, `_onStagingReorder`) 앞 항목의 여백 없음 표시가 정리된다.
여백 빼기는 지운 페이지 키가 아니라 항목 uid 집합(`_noSpacerUids`, 썸네일에서 자동 여백을 지워도 여기로 간다)이고, 콘티 저장(`worship_conti_items.no_spacer`, DB version 14)·PPTX 내보내기(`no_spacer`)에도 실린다.
고른 게 없으면 Delete 는 아무것도 안 한다(띄운 페이지 보호).
**끌어 놓기로 페이지 옮기기** (`_moveSlides`, 썸네일 줄·모든 페이지 격자 공통 `_ThumbDragDrop`): 썸네일을 끌어 다른 썸네일의
왼쪽 절반(앞)·오른쪽 절반(뒤)에 놓는다. 골라 담은 페이지를 끌면 고른 것 전부가 간다(곡 통째로 = Shift+클릭으로 고른 뒤 끌기).
외부 PPT 중간에 찬양·말씀을 끼워 넣거나 PPT 안 순서를 바꾸는 용도다. **버리는 페이지는 없다** — PPT 중간에 놓으면 PPT 를 앞·뒤 두 항목으로
나누고 그 사이에 넣는다(붙여 넣기와 같은 `_insertItemsAfterSlide`). 옮긴 페이지는 원래 항목에서 **숨기지 않고 실제로 뺀다**
(`_takePagesOut` — 지운 표시로 숨기면 그 곡을 '수정'할 때 표시가 풀려 같은 페이지가 두 군데 생긴다).
  - 일부 페이지만 담은 항목 만들기는 `itemsFromPages` 하나다(복사·옮기기·나누기 공통, `test/move_pages_test.dart`). 곡 끝에 오는 빈 페이지는
    가사로 담으면 사라지므로 빈 페이지 항목으로 떼고 여백 없이 잇는다(`_SlidePiece.joinNext`). 페이지 전부면 원래 항목 그대로(PPT 원본 경로 유지).
    항목을 다시 만들 때 메모·지운 표시·자동 여백 메모·'여백 없음'은 `_rebuildItem` 이 옮긴다
  - **관객 화면은 보던 페이지 그대로다**: 빼기·나누기·옮기기 단계마다 바뀐 슬라이드 키(`uid:페이지:자동여백`)를 적어 두고 그걸로 다시 찾는다.
    보던 페이지가 없어지면(옮긴 곡의 자동 여백) 옮기지 않은 앞쪽 페이지 → 뒤쪽 페이지 순. 나누기·옮기기로 새 uid 를 받은 항목은
    `_mediaGroups`(새 uid → 원래 미디어 묶음)를 이어받아 재생 중인 동영상을 처음부터 다시 틀지 않는다
  - 놓은 페이지 뒤 항목이 같은 곡·같은 PPT 면 여백 없이 잇는다(복사·붙여 넣기도 같다). 단 나눈 자리·원래 이어져 있던 자리·여백 뒤(그 곡 맨 앞)일 때만 —
    항목 끝(여백 앞)에 놓으면 사용자가 둔 여백(같은 곡 재창 사이 등)은 그대로다
  - 곡 끝 페이지를 옮겨 남은 곡이 떼어 낸 빈 페이지로 끝나면(빈 페이지 항목엔 자동 여백이 없다) 여백 자리에 빈 페이지 항목을 하나 더 둔다(`_rebuildItem`)
  - 끌 페이지는 끌기 시작할 때 번호가 아니라 내용 키(`_dragKey`)로 적어 두고 놓을 때 다시 찾는다. 그 사이 원본 PPT 를 다시 구워 못 찾으면 옮기지 않는다
  - 가장자리 자동 스크롤은 스크롤할 때마다 같은 자리의 포인터 이동을 흘려 넣는다(`GestureBinding.handlePointerEvent`) — Draggable 은 마우스가
    움직일 때만 밑의 썸네일을 다시 찾아서, 마우스를 멈춘 채 놓으면 스크롤 전 썸네일에 놓이거나 놓기가 사라졌다
맨 앞 빈 페이지·자동 여백은 끌 수 없고 놓을 자리로만 쓴다. 끄는 동안 목록 가장자리에 가면 저절로 스크롤한다(`_EdgeAutoScroll`).
툴바 '새 페이지 추가' = 현재 항목 뒤에 빈 페이지를 넣고 바로 편집(`_addBlankAfterCurrentSlide`).
직접 넣은 빈 페이지 앞에도 자동 여백은 그대로 붙는다(예전엔 빈 페이지가 여백 자리를 대신해 장 수가 안 늘었다).

## 배포

- `scripts/build.sh` / `build.ps1` → `dist/worship_slides/` (앱 + `python/ppt_tool/`)
- macOS 배포본에는 Gatekeeper 해제용 `Unlock Worship Slides.command`와 안내 txt가 함께 들어간다 (서명 없음)
- `v*` 태그를 푸시하면 `.github/workflows`가 macOS/Windows zip을 만들어 Release에 올린다
- **PR 을 열면 같은 워크플로가 자동으로 돈다**(문서만 바뀐 PR 은 제외). Swift·C++ 발표 창 코드는
  여기서만 실제로 컴파일되므로 네이티브 쪽 사실상 유일한 검증 수단이다. 브랜치를 직접 빌드해
  받고 싶으면 Actions → Build Release → Run workflow 로 그 브랜치를 골라 아티팩트를 받는다
  (`ppt_tool` PyInstaller 빌드까지 CI 가 하므로 로컬 재빌드가 필요 없다)
- **배포 zip 은 `worship_slides/` 폴더를 최상위에 포함해야 한다.** 앱 내장 업데이터
  (`update_service.dart`)가 압축을 푼 뒤 그 폴더를 찾아 설치 폴더에 덮어쓴다. 폴더가 없으면
  아무것도 복사하지 못하고 조용히 재시작만 한다. Windows 는 `Compress-Archive -Path dist/worship_slides`
  (뒤에 `\*` 를 붙이면 내용물만 담긴다), macOS 는 `ditto --keepParent`
- **Windows 업데이터** (`_applyWindows`): **PowerShell 을 쓰지 않고 앱이 직접 덮어쓴다.** 예전엔 숨은
  PowerShell(.ps1, `-ExecutionPolicy Bypass -WindowStyle Hidden`)에 맡겼는데 실제 PC 에서 스크립트가 한 줄도 안 돌았다
  (로그조차 안 생김 — 백신이 이 조합을 막는 것으로 본다). 지금은 `tar.exe`(Win10 1803+ 기본)로 풀고,
  실행 중이라 잠긴 exe·dll·app.so 는 **덮어쓸 순 없어도 이름은 바꿀 수 있어서** `.old` 로 비켜 둔 뒤 새 파일을 넣고
  (`applyUpdateFiles`), 새 exe 를 띄우고 종료한다. `.old` 는 다음 시작 때 `cleanupWindowsLeftovers`(main.dart)가 지운다.
  과정은 `app.log` 에 `[update]` 로 남는다. **업데이트를 실행하는 건 깔려 있는 옛 버전의 코드**라서,
  고친 업데이터는 한 번 수동으로 덮어써 설치해야 그다음 업데이트부터 쓰인다
- 업데이트는 폴더를 지우지 않고 **덮어쓰기**다. 실행 파일 옆 `worship_slides.db` 가 살아남아야 하기 때문.
  수동으로 새 빌드를 받아 갈아끼울 때도 폴더째 교체하지 말고 덮어써야 곡·콘티가 유지된다
- 앱은 시작 시 `yjchae/worship_slide`(이 레포)의 최신 릴리즈를 확인해 업데이트 배너를 띄운다.
  v1.1.14 까지는 별도 공개 레포 `yjchae/make_ppt-releases` 를 봤다(당시 이 레포가 private).
  그 버전들은 여전히 그쪽만 보므로, 옮긴 뒤 첫 릴리즈 zip 은 `make_ppt-releases` 에도 한 번 올려야 옛 설치본이 넘어온다
  **릴리즈 태그와 `pubspec.yaml`의 version이 같아야 한다**

## 의존성

- Dart: `file_picker`, `sqflite_common_ffi`, `path`, `path_provider`, `package_info_plus`, `http`, `qr_flutter`, `cupertino_icons`
- Windows 네이티브: NuGet `Microsoft.Web.WebView2`(CMake FetchContent, 미디어 레이어)
- Python: `python-pptx`, `pymupdf`, `pyinstaller`, `pillow`(악보 오선 찾기)
- 시스템: LibreOffice(`soffice`) — `.ppt` 임포트와 PPT 이미지 렌더에 필요 (없으면 해당 기능만 비활성)
- 시스템: Tesseract OCR — 악보 가사 추출에 필요. 한국어는 `kor` 언어 데이터까지 (없으면 해당 기능만 비활성)
- 시스템: `cloudflared` — 휴대폰 화면 바깥 망 주소 (선택). OS OCR(macOS Vision·Windows.Media.Ocr)이 Tesseract 보다 먼저
- 라이선스 목록은 `THIRD_PARTY_NOTICES.md`. **의존성·글꼴을 더하면 거기도 적는다** (PyMuPDF 는 AGPL-3.0)

## 기타

- `make_ppt_guide.py`, `make_user_guide.py` — 사용자 가이드 pptx/docx 생성 스크립트 (앱과 무관)
- `docs/` — GitHub Pages 홈(`index.md`)·개인정보처리방침(`privacy.md`, OAuth 동의 화면 게시용)·사용 설명서·동기화 키 안내
- `scripts/make_sync_key.py` — 동기화 접속 키 만들기 (관리자용)
- `AGENTS.md` — 이 파일을 가리키는 포인터
