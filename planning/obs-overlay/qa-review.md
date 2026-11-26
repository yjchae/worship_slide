# QA 검토 — OBS 브라우저 소스 자막

- 작성: QA · 2026-11-26
- 읽은 것: `brief.md`, `plan.md`, `tech-frontend.md`, `tech-backend.md`, `mockup.html`, `screens/s2.png`·`s3.png`, CLAUDE.md
- 확인한 코드(읽기만, 고치지 않음): `praise_home_page.dart`(`_sendCurrentSlide` 2494행·호출처 31곳·`_toggleBlackout` 1550행·`_resetPresentationState` 1525행·발표 시작 1490~1516행·`initState`/`onExitRequested` 572행·`_replaceConti` 6339행·`_removeFromStaging` 5778행·`_handleRemoteControl` 2442행·`_onContiItemTap` 6423행), `singer_web_server.dart`, `slide_page_data.dart`, `font_library.dart`, `slide_background.dart`, `macos/Runner/MainFlutterWindow.swift`(발표 창 키), `macos/Runner/*.entitlements`, `pubspec.yaml`
- 표기: **확인됨** = 코드로 봤다 / **미확인** = 코드·실기로 확인 못 함

---

## 0. 1단계 구현 전에 사용자에게 꼭 물을 것 (4개)

1. **슬라이드(이 앱) PC 와 OBS PC 가 같은 컴퓨터인가요?** 다르면 '같은 망 다른 PC 에서 받기'(LAN)를 1단계에 넣어야 하고, 기본 127.0.0.1 만으로는 기능이 아예 안 쓰입니다. (plan Q3 — 세 문서 모두 2단계/옵션으로 미뤄 둠) 같이: OBS 판(버전)·OS(macOS/Windows)도 알려 주세요.
2. **찬양 가사를 콘티에 어떻게 담나요?** (a) 폴더 가져오기로 '텍스트 곡'으로 담는다 / (b) 외부 PPT 를 그림으로 넣는다. (b) 라면 1단계 OBS 자막은 **찬양 내내 비어 있습니다**(그림 페이지 = 투명). 크로마키로 PPT 를 빼고 있다는 설명으로 보아 (b) 가능성이 있습니다. (plan R1)
3. **관객 화면 없이 방송만 하는 예배가 있나요? 그리고 블랙아웃(B)하면 방송 자막도 사라져야 하나요?** '발표 창 없이도 내보내기'를 켜면 지금 코드 구조상 **편집 탭에서 항목을 누르기만 해도 방송 자막이 바뀌고**, 가사 수정 등 여러 경로는 반대로 **갱신이 안 됩니다**(§2-2). 필요 없다면 1단계에서 이 스위치를 빼는 것을 권합니다.
4. **보조 언어(영어 등) 줄을 방송 자막에도 보일까요?** 관객 화면의 '보조 언어' 스위치를 그대로 따를지(프론트안), OBS 에서 따로 켜고 끌지(백엔드안), 시작값만 가져올지(기획안) 세 문서가 다릅니다. 하나로 정해 주세요.

---

## 1. 문서 사이 모순

권고 열: 어느 쪽으로 맞출지. **구현 전에 plan.md 에 '확정 값' 표 하나로 모으고 나머지 문서는 그 표를 가리키게** 할 것.

### 1-1. 데이터(JSON)·경로

| # | 항목 | plan | tech-frontend | tech-backend | mockup | 권고 |
|---|---|---|---|---|---|---|
| C1 | 보임 여부 키 | `visible` | `show` (+`hiddenReason`) | `visible` | — | `visible`. 숨긴 이유(`reason`)는 preview=1 상태 글(s7)에 필요하므로 **같이 싣는다**(프론트 `hiddenReason` 채택, 로컬 정보 아님) |
| C2 | `kind` 값 | `song`/`bible`/`sermon`/`text` | `lyrics`/`bible`/`text` | `lyrics`/`bible`/`empty` | — | plan 값(`song`·`bible`·`sermon`·`text`) + 숨김은 `visible:false` 로만. `empty` 는 두지 않는다 |
| C3 | 줄 구조 | `lines:{main,sub,extra}` | 평평한 `main/sub/extra` | 평평한 `main/sub/extra` | — | 평평한 꼴(두 개발 문서가 같음). plan 고친다 |
| C4 | 제목 칸 | `title` | `heading`(참조 **또는** 곡 제목) | `title` | — | `title` 하나 + `kind` 로 가름. 곡 제목 표시 스위치와 성경 참조 스위치는 따로(아래 C14) |
| C5 | 디자인 전송 | 별도 `design` 메시지(바뀔 때만) | 매 JSON 안 `design` | 매 JSON 안 `design` | — | 매 JSON 안(개발 두 문서). 서버의 '같으면 안 보냄'이 그대로 먹고 새로 붙은 OBS 가 한 번에 다 받는다. plan 고친다 |
| C6 | `rev` | 있음 | 없음 | 있음 | — | **매번 올리는 rev 는 넣지 말 것** — 넣으면 '같은 JSON 이면 안 보냄'이 깨져 디자인 슬라이더·`_sendCurrentSlide` 잦은 호출마다 OBS 가 다시 그린다(페이드가 매번 돈다). 넣으려면 내용이 바뀔 때만 올리고 비교에서 뺀다 |
| C7 | 경로 | `/obs`·`/events`·`/state`·`/font/` | 같음 | `/obs`·`/obs/events`·`/obs/state`·`/obs/font/<n>` | — | **`/obs/…` 접두어**(백엔드). 나중에 그림 페이지 주소(3단계)·다른 출력과 겹치지 않는다. 단 HTML 안 `EventSource('/events'+…)` 를 프론트 문서대로 짜면 404 — 프론트 문서 고칠 것 |
| C8 | 함수 이름·입력 | `obsOverlayFor(slide, page, config, state)` | `obsOverlayDataFor(… _SlideInfo 필드 …)` | `obsCaptionFor(SlidePageData?, …)` | — | **프론트안(필드로 받기)**. `SlidePageData` 에는 `isBlank`·`isAutoSpacer`·맨 앞 빈 페이지(`_leadingBlankUid`) 구분이 없어(확인됨, `_buildSlidePageData` 1403행) 백엔드안으로는 '빈 페이지(문구 있음)'와 자동 여백을 못 가른다 |

### 1-2. 설정 파일 키

| # | 항목 | plan | frontend | backend | mockup | 권고 |
|---|---|---|---|---|---|---|
| C9 | LAN 키 | `allowLan` | `lan` | `allow_lan` | '같은 망의 다른 PC 에서 받기' | `allow_lan` |
| C10 | 발표 전 내보내기 | `outputBeforePresent`(true = 내보냄) | `liveOnly`(true = 안 내보냄) | `only_while_presenting`(true = 안 내보냄) | '발표 창 없이도 내보내기'(켬 = 내보냄) | **뜻이 반대인 이름이 섞였다.** UI 스위치와 같은 방향(`export_without_presentation`, 기본 false)으로 하나만. 테스트로 기본값 고정 |
| C11 | 블랙아웃 따라가기 | `followBlackout` | **설정 없음**("기획 결정") | `follow_blackout` | 스위치 있음 | 넣는다(`follow_blackout`, 기본 true). 프론트 `ObsOverlayConfig` 에 칸 추가 |
| C12 | 설교 제목 내보내기 | `showSermon` 스위치 | 설정 없음 | 설정 없음 | 스위치 있음 | 넣는다(`show_sermon`, 기본 true) |
| C13 | 페이드 | 켬/끔 + 시간(기본값 미정) | `fadeMs`(0 = 끔) | `fade_ms` 기본 200 | 스위치 + 0.3초 | 숫자 하나(`fade_ms`, 0 = 끔). UI 는 스위치+초로 보여도 저장은 하나. 기본값을 한 곳에서 정한다(200 vs 300 모순) |
| C14 | 곡 제목 줄 | `show_song_title` 계열 있음 | `showHeading` 하나(성경 참조) | `show_bible_ref`·`show_song_title` 둘 | 둘 다 체크 | 백엔드(둘) |
| C15 | 관객 글꼴 따라가기 | 체크(기본 켬) | 없음 | 없음(`font_family` 만) | 체크 있음 | 넣는다(`follow_audience_font`). 따라가면 `_updateStyle` 경로로 OBS 도 바뀐다(확인됨 — 끝에서 `_sendCurrentSlide`) |
| C16 | 보조 줄 연동 | 관객 디자인에서 **시작값만** | 관객 `includeEnglishLyrics` **따름** + OBS 끄기만 | OBS `show_sub` **독립** | 체크(시작값 설명) | 사용자 질문 4. 어느 쪽이든 **설교 부제는 이 스위치와 무관하게 보임**(plan §5-1, 관객 규칙과 같음 — `slide_background.dart` 317행 확인됨)을 세 문서 모두에 적는다 |
| C17 | 참조 색 | 있음 | 없음 | 없음(`text/sub/extra` 색만) | 있음 `#FFD66B` | 넣는다(`ref_color`) |
| C18 | 띠 모양(글 폭/화면 폭) | 있음 | 없음 | 없음(`band_padding` 만) | 있음 | 넣는다(`band_width: text|full`) |
| C19 | **빠른 스타일 3개**(외곽선 / 반투명 띠 / 화면 폭 띠) | **없음** | 없음 | 없음 | s3 맨 위에 있음 | 목업에만 있다. 저장 칸이 아니라 '여러 칸을 한 번에 채우는 버튼'으로 정의해 plan 에 올리거나 1단계에서 뺀다. 넣으면 테스트: 누른 뒤 저장된 값, 세부를 고치면 선택 표시가 풀리는지 |
| C20 | 잠시 숨기기(s6 칩) | 있음(저장 안 함) | **없음** | **없음** | 칩·메뉴·앱 바 주황 점 | 두 개발 문서에 상태(`_obsHidden`)·`visible:false` 이유·`_sendObs` 호출을 추가해야 한다 |
| C21 | 그림자 | 켬/끔 + 색 + 흐림 | `shadowBlur`(0 = 없음) | `shadow` bool + blur | 스위치 + 슬라이더 | 백엔드(bool + blur) — 목업과 같다 |

### 1-3. 단위·배치

| # | 항목 | plan | frontend | backend | mockup | 권고 |
|---|---|---|---|---|---|---|
| C22 | 글자 크기 단위 | "pt, 1080 높이 기준"(섞임) | px@1080 | **pt@540** (기본 40 = 80px@1080) | px@1080 (56px) | 사용자에게 보이는 값과 저장 값이 같아야 한다. **px@1080** 권고(목업·프론트, OBS 사용자가 익숙). 백엔드 기본 40pt 는 80px 이라 목업 56px 과 **크기가 다르다** — 기본값도 다시 정할 것 |
| C23 | 세로 위치 | 아래·위 | bottom/top/center + `margin` px | top/middle/bottom + `offset_y` **인치 ±2.0** | 아래·위 + '기준선에서 64px' | 아래·위 + px. 백엔드의 ±2.0인치(=±288px@1080) 상한은 '기준선에서 64px' 의미와 다르다. 관객 `clampTextOffsetY` 재사용 안 함 |
| C24 | 좌우 여백 | 있음 | 없음 | `side_margin` 폭 비율 | 80px | px@1080 |
| C25 | 넘침 기준 | 화면 높이 % (30%) | `maxHeight` px | `max_lines` 줄 수 | 30% | % 하나. `max_lines` 는 버린다 |
| C26 | 넘칠 때 축소 하한 | **하한 없음** | 0.5~1, 하한에서 그대로 넘침 | 미정 | — | 하한 둔다(프론트). 하한 없으면 긴 성경 구절이 읽을 수 없게 작아진다. 하한 값은 실기로 |
| C27 | `/obs` 미리보기 탭 '지금 페이지'·바탕 칩 | 바둑판/검정/밝은 사진 | — | — | 바둑판/카메라/밝은 사진/검정 | 목업(4개). 사소 |

### 1-4. 서버·수명·기타

| # | 항목 | 문서별 | 권고 |
|---|---|---|---|
| C28 | 기본 포트 | plan "구현 때"·backend 8766 제안·mockup 8766·frontend "기획" | 8766 확정 + 8765(싱어 선호 포트) 입력 금지(백엔드). 다른 프로그램과 겹치는지 **미확인** |
| C29 | 키 만드는 시점 | backend: 파일 없으면 **바로** 만들어 저장 / frontend: **처음 켤 때** | 백엔드 — 켜기 전에도 설정 창에 주소가 보여야 한다(s2) |
| C30 | 키 글자판 | backend: 싱어 글자판(소문자·숫자, 헷갈리는 글자 없음) | mockup 예시 `Hq7tP2xZ9mLw4cRb` 는 대문자 섞임 — 목업 예시만 고치면 된다 |
| C31 | 깨진 설정 파일 | frontend: 기본값 + 새 키 + 알림 / backend: 기본값 + `.broken.bak` + **폴더를 못 열면 enabled=false** | 백엔드 + 프론트 알림 문구 둘 다. 테스트로 고정 |
| C32 | 키 재발급 시 붙어 있는 OBS | backend: SSE 모두 끊음 / frontend·plan: 언급 없음 | 끊는다(백엔드). 안 끊으면 옛 주소를 넣은 OBS 가 계속 받는다 |
| C33 | Host 헤더 검사 | plan Q4·frontend 있음(LAN 은 검사 안 함) / backend 없음 | 넣는다(127.0.0.1 모드). 백엔드 테스트 목록에 추가 |
| C34 | OBS 보내는 순서 | plan §5-2 "`_sendCurrentSlide` **끝**(싱어·B 와 같은 자리)" vs plan Q9 "관객 응답을 **기다리지 않고**" / frontend "**맨 앞** 추천" | **맨 앞**. 끝에 두면 ① 배경 영상 페이지는 가사 PNG 굽기를 기다리고 ② 가사 PNG 굽는 사이 다음 장으로 넘어가면 `return`(2507행) ③ 발표 창 실패 catch 도 `return`(2515행) — 셋 다 OBS 가 늦거나 빠진다(확인됨). plan 안의 두 문장도 서로 모순이므로 plan 고친다 |
| C35 | 빈 페이지(문구 있음) | plan: **문구를 자막으로** / frontend 표: 빈 페이지 **숨김**(설교만 `text`) | plan. 관객 화면에 글이 보이면 같게 |
| C36 | 발표 시작 때 보내기 | plan §7 "발표 시작" 포함 / frontend 표에 **없음** | 넣어야 한다 — 발표 시작은 `_sendCurrentSlide` 를 안 지나고 `openWindow` 를 직접 부른다(확인됨, 1490~1516행). 빠지면 첫 장이 다음 넘김 전까지 투명 |
| C37 | 미리보기 정확도 | plan·frontend: Flutter 근사 + '브라우저로 열어 보기' | 목업 s3 문구도 같다. 일치. 단 '브라우저로 열어 보기'의 Windows 구현(`openFile` 에 URL)이 **미확인**(frontend) — 안 되면 버튼을 숨기는지 회색인지 UI 에 정해 둘 것 |

---

## 2. 빠진 경로 — 페이지 글이 바뀌는데 OBS 로 안 가는 곳

`_sendObs` 를 `_sendCurrentSlide` 맨 앞에 두었다고 가정하고, 각 경로가 그 함수를 실제로 지나는지 확인했다.

### 2-1. 발표 중 (관객 창 열림)

| 경로 | 함수(행) | `_sendCurrentSlide` 지남? | 비고 |
|---|---|---|---|
| 넘기기(키·휴대폰·싱어 창 키·자동 넘기기) | `_nextSlide`/`_prevSlide`(2553·2563) | 확인됨 | 휴대폰 `goto`·싱어 `singerKey` 도 이 길 |
| 번호 점프·더블클릭 | `_goToSlide`(2975) | 확인됨(무조건) | |
| 가사 수정 창 저장(콘티 곡) | `_editStagedSongLyrics`(2935) | 확인됨 — 단 `if (_isPresentationOpen)` | 발표 중엔 OK |
| 항목 글 고치기 | `_editStagingItemText`(2849) | 확인됨 — `if (_isPresentationOpen)` | |
| 보조 언어·추가 보조·보조 역본 바꾸기 | `_updateStyle`(830) → `_reapplySubLanguage`/`_reapplyBibleVersions` → 끝 `_sendCurrentSlide` | 확인됨 | |
| 발표 보기 성경 역본 바꾸기 | `_changeBibleVersion`(981, 1083행) | 확인됨 | |
| 디자인(관객) 변경 | `_updateStyle` | 확인됨 | OBS 디자인이 따로면 영향 없음, '관객 글꼴 따라가기'면 필요 |
| 원본 PPT 다시 굽기 | `_applyReloadedSource`(5563) | 확인됨 | 그림 페이지라 OBS 는 어차피 투명 |
| 붙여 넣기 | `_pasteSlides`(4207) | 확인됨 | |
| 끌어 옮기기·되돌리기 | `_moveSlides`(4740)·`_undoMoveSlides`(4782) | 확인됨 | |
| 음성 넣기·되돌리기 | `_onVoiceHeard`(4495)·`_undoVoiceInsert`(4540) | 확인됨 | |
| 페이지 삭제·되돌리기 | `_deleteSlides`(3065)·`_undoDeleteSlides`(3111) | 확인됨 | |
| 콘티 트리 편집(그룹·여러 개 삭제·옮기기) | `_trackedEdit`(6534) | 확인됨 — `if (_isPresentationOpen)` | |
| 끌어 놓아 담기 | `_insertItemsAt`(3432) | 확인됨 — `if (_isPresentationOpen)` | |
| 콘티 뒤에 붙이기 | `_appendConti`(7117) | 확인됨 | |
| 라이브러리 곡 고친 뒤 '콘티도 바꿀까요' | `_offerStagedSongUpdate`(7686) | 확인됨 — `if (replaced>0 && _isPresentationOpen)` | |
| 편집 페이지·설교·미디어·배경·헌금송 | 3570·3605·3695·3771·3849·3896·4943·4955·5041·5081·5107 | 확인됨 | |
| **편집 탭 항목 X 버튼 삭제** | `_removeFromStaging`(5778) | **안 지남(확인됨)** | `_clampCurrentSlideIndex` 로 번호만 바뀌고 아무것도 안 보낸다 → 관객·싱어·OBS 모두 옛 페이지. **기존 문제**지만 OBS 에선 지운 곡 가사가 방송에 남는다. 구현 때 `_sendCurrentSlide` 추가 권고(별도 수정 사항) |
| **찬양 전체 삭제** | 7486행 부근 `setState(_removeStagingWhere …)` | **안 지남(확인됨)** | 위와 같음(발표 중 누를 일은 드묾) |
| 콘티 불러오기(교체) | `_replaceConti`(6339)·호출 7194 | **안 지남(확인됨)** | 발표 중에도 불러오기 자체를 막는 코드는 못 찾음(**미확인** — `_loadContiDialog` 에 `_isPresentationOpen` 검사 없음). 교체되면 `_currentSlideIndex=0` 인데 아무것도 안 보내 관객·OBS 가 옛 콘티 페이지. 기존 문제, OBS 에선 방송 사고 |
| 새 콘티 | `_newConti`(7042) | 발표 중엔 막힘(확인됨) | 발표 전 모드(2-2)에서만 문제 |
| **발표 시작** | 1490~1516행 `openWindow` 직접 | **안 지남(확인됨)** | C36. 반드시 `_sendObs` 추가 |
| **블랙아웃 켬/끔**(키·버튼·휴대폰) | `_toggleBlackout`(1550) — 끝은 `_sendSingerView` | **안 지남(확인됨)** | 별도 `_sendObs` 필요(프론트 문서에 있음). 실패해서 되돌린 경로(1559행)도. 네이티브 발표 창에는 B 키가 없어(macOS `watchKeys` 확인됨, 넘기기·닫기만) Dart 를 거치지 않는 블랙아웃은 없다 — Windows 발표 창 키는 **미확인** |
| **발표 종료**(Ctrl+F4·창 닫힘·`presentationClosed`) | `_resetPresentationState`(1525) — setState 콜백 안 | **안 지남(확인됨)** | `_isBlackout=false` 로도 바뀐다. setState 밖에서 `_sendObs` 필요(프론트 문서 `scheduleMicrotask`) |
| 발표 창 오류로 닫힘 | `_sendCurrentSlide` catch(2513) `return` | OBS 를 끝에 두면 **빠짐** | 맨 앞 + catch 안에서도 숨김 전송 |
| 앱 종료 | `onExitRequested`(573) | 싱어만 끔(확인됨) | `_obs.stop()` 전에 투명 전송 + `Future.wait` 3초. **강제 종료·Windows 에서 발표 창이 열린 채 닫기**는 이 신호가 안 온다(CLAUDE.md) → OBS 페이지의 `onerror` 숨김에만 기댄다 |
| OBS 디자인 변경 | 설정 창 콜백 | 새 코드 | 저장·서버 재시작(포트·LAN·키 바뀔 때만)·전송 |
| 앱 시작 직후 | `initState` | — | 관객 스타일(`_loadSavedStyle`)이 비동기로 읽힌다(확인됨). 서버를 먼저 켜고 첫 JSON 을 보내면 기본 스타일(보조 표시·글꼴)로 한 번 나갈 수 있다 → 스타일·OBS 설정을 다 읽은 뒤 첫 전송 |

### 2-2. '발표 창 없이도 내보내기' 켬 (발표 전)

이 모드는 경로 대부분이 **`if (_isPresentationOpen)` 으로 막혀 있어 갱신이 안 된다**(확인됨): 가사 수정 창 저장(2972), 항목 글 고치기(2931), 끌어 담기(3432), 콘티 트리 편집(6534), 라이브러리 곡 반영(7686), 콘티 불러오기(교체), 새 콘티, X 삭제.
반대로 **편집 탭에서 항목을 한 번 누르기만 해도**(`_onContiItemTap` 6423 → `_currentSlideIndex` 바꾸고 `_sendCurrentSlide` 무조건) **방송 자막이 그 항목 첫 페이지로 바뀐다**(확인됨). plan 은 "발표 보기에서 고른 페이지"라고 했지만 실제 기준은 탭과 무관한 `_currentSlideIndex` 다.

권고: 1단계에서 이 스위치를 빼거나(사용자 질문 3), 넣는다면 ① '발표 보기 탭이 보일 때만' 같은 조건 ② 위 조건부 호출들을 `_sendObs` 무조건 호출로 보강 ③ 편집 탭 클릭으로 방송이 바뀌는 것을 테스트로 막기.

### 2-3. 서버·환경

| 상황 | 문서 대응 | QA 판단 |
|---|---|---|
| 포트 충돌(다른 프로그램) | 대체 포트 안 씀 + 오류 표시(세 문서 일치) | OK. 테스트: 127.0.0.1 만 잡힌 경우까지(싱어 테스트와 같은 방식) |
| 앱을 두 폴더에서 두 벌 실행 | 두 번째 portInUse | OK. 두 번째 앱의 OBS 버튼 빨간 점·문구 확인 |
| 싱어 서버와 포트 | 싱어 8765 못 잡으면 OS 임의 포트(확인됨, `bind(…,0)` 140행) | OBS 를 앱 시작 때 먼저 켜면 겹칠 일 없음. OBS 꺼 둔 채 싱어가 임의 포트로 8766 을 잡은 뒤 OBS 를 켜면 portInUse — 확률 낮음, 문구로 충분 |
| **앱보다 OBS 를 먼저 켬** | plan R2: 미확인, 'OBS 새로 고침' 안내 | 첫 요청이 연결 거부면 CEF 는 오류 페이지에서 **스스로 다시 읽지 않는 것으로 보임(미확인)**. 오류 페이지는 투명이 아닐 수 있어 방송에 흰/회색 화면이 나갈 위험(**미확인**). 실기 1순위 확인. 대안: 설정 창 안내 + 'OBS 소스 속성 새로 고침' |
| 앱 재시작(OBS 그대로) | EventSource 다시 붙음 + 서버가 마지막 JSON | 앱 재시작 직후 서버의 마지막 JSON 은 비어 있음 → 투명. OK |
| 슬립/깨어남 | 문서에 없음 | 깨어난 뒤 SSE 가 반쯤 죽은 연결로 남을 수 있다. 서버 15초 ping 은 서버→클라이언트 방향 쓰기 실패만 잡는다. 페이지 쪽에서 **일정 시간(예: 40초) 아무것도 안 오면 다시 연결**하는 감시가 필요(싱어 페이지와 같은지 **미확인**). macOS App Nap 으로 앱이 가려졌을 때 Dart 타이머·소켓 쓰기가 늦어지는지 **미확인** |
| OBS 소스 '보이지 않을 때 끄기'·'장면 활성 시 새로 고침' 옵션 | 없음 | 켜 두면 장면 바꿀 때마다 페이지를 다시 읽는다 → 붙자마자 마지막 JSON 을 주므로 OK. 다시 읽는 순간 페이드 인이 도는지 확인 |
| 키 재발급 | C32 | 옛 SSE 끊기 + 옛 키 403 |
| 여러 OBS 동시 접속(OBS 2대·스튜디오 모드·브라우저 미리보기) | plan: 연결 수 표시 | 모두 같은 JSON. 연결 수에 '브라우저로 열어 보기' 탭도 세어진다 → 상태 글이 'OBS 2곳'으로 보일 수 있음(문구를 '연결 2곳'으로 권고). 연결 수 `ValueNotifier` 가 끊김 감지 지연(최대 ping 간격) 동안 남는 것 감수 |
| 글꼴 없음 | frontend: 내장 3종은 `rootBundle`, 무료 폰트는 파일, 이 PC 글꼴은 이름만 / backend: `FontLibrary.filesFor` | **backend 안은 틀림** — `filesFor` 는 내장 3종이면 **빈 목록**(확인됨, `font_library.dart` 65행). 기본 글꼴 Pretendard 가 OBS 로 안 가 대체 글꼴로 그려진다. 프론트안(rootBundle) 채택. 이 PC 글꼴·LAN 다른 PC 는 대체 글꼴 — CEF 대체 글꼴 줄바꿈·넘침 다시 맞춤 확인 |
| 글꼴 늦게 도착 | frontend: `document.fonts` load 후 다시 맞춤 | OK. 글꼴 받기 전 첫 프레임이 대체 글꼴로 한 번 보이는지(깜빡임) 실기 확인 |
| 방화벽 | 127.0.0.1 은 안 묻는 것으로 알려짐 | **미확인**(Windows·macOS 둘 다). LAN 은 묻는다 |
| macOS 권한 | entitlements 에 `app-sandbox` 키 없음 | 확인됨(두 파일). Release 에 `network.server` 없음도 샌드박스가 아니라 무관 — 싱어 서버가 이미 Release 에서 listen 한다는 CLAUDE.md 기준 |

---

## 3. 보안·누출 점검

| # | 항목 | 상태 | 권고 |
|---|---|---|---|
| S1 | `SlidePageData.toJson` 재사용 금지 | 확인됨 — `image_path`(80행)·`style.font_files`(로컬 경로, 78행)·`media`(로컬 파일 HTML) 가 실린다 | 화이트리스트 JSON(프론트안). 테스트: 결과 JSON 문자열에 `/Users`·`\\`·`C:`·`Application Support`·`image_path`·`font_files`·`media` 없음 |
| S2 | 코드(chord)·송폼·메모·발표자 메시지·시계 | `_SlideInfo.chordText`·`formText` 는 관객 `SlidePageData` 로 안 간다(확인됨, 주석). `note`·`message` 는 `SingerViewData`+휴대폰 서버에만 | `_SlideInfo` 에서 만들 때 `mainText`·`englishText`·`extraText`·`title` 만 읽게. `SingerViewData` 에서 만들지 않는다. `test/chord_leak_test.dart` 에 OBS 줄 추가: 코드 있는 곡 → OBS JSON 에 `[G]`·`chord`·`key_label` 없음 |
| S3 | 페이지 글자 서식·항목 배경·헌금송 계좌 | 서식(`page_format`)은 색·크기라 무해, 무시 규칙 | 헌금송 계좌 글은 배경 PNG 안이라 OBS 로 안 감(그림 안 보냄) — OK |
| S4 | 글꼴 경로 | `/obs/font/<n>` 번호만 | `..`·범위 밖 n → 404 테스트. 응답 헤더에 파일 이름 없음 |
| S5 | 키 검사 범위 | 모든 경로 `?k=` | `/obs` HTML 도 키 필요(안 그러면 페이지 구조가 열림 — 무해하나 일관성). 403 응답 본문에 키·경로 넣지 않기 |
| S6 | DNS rebinding·다른 웹페이지 | Host 검사(C33) | **CORS 헤더(`Access-Control-Allow-Origin`)를 붙이지 말 것** — 싱어 서버도 안 붙인다(확인됨). 붙이면 키를 아는 경우 외에도 범위가 넓어진다 |
| S7 | 쓰기 경로 | 없음(세 문서 일치) | POST·PUT → 405/403 테스트. `/control` 같은 경로가 생기지 않게 |
| S8 | LAN 모드 | http 평문, 키가 주소에 | 문서대로 감수. 기본 꺼짐 테스트. **터널(cloudflared) 연결 금지** — 싱어 서버와 코드 공유 시 실수로 붙지 않게 |
| S9 | 로그 | 키 앞 4자만, 틀린 키 1분에 한 번 | 테스트로 `app.log` 문자열에 전체 키 없음 |
| S10 | HTML 주입 | `textContent` 만 | HTML 문자열 검사 테스트(`innerHTML` 없음). 글꼴 family 이름을 CSS 에 넣을 때 따옴표·`;`·`}` 이스케이프(이 PC 글꼴 이름은 PPT 에서 온다) |
| S11 | 설정 파일 | 키 평문 | `.wsconti`·동기화·클라우드에 안 실림 — 세 문서 일치. 확인용 테스트 불필요(코드 경로 없음) |

---

## 4. 테스트 항목

### 4-1. 단위·위젯 테스트 (리눅스 CI 에서 돈다)

**`test/obs_overlay_data_test.dart`** (순수 함수)
- 곡: main/sub/extra. 보조 끔(C16 확정 규칙) → sub ''. 추가 보조 끔.
- 설교 페이지: 보조 줄 꺼도 부제 보임. `show_sermon` 끄면 `visible:false`.
- 빈 페이지 문구 있음 → `kind:text` 보임(C35) / 문구 없음 → 숨김.
- 자동 여백·맨 앞 빈 페이지(`_leadingBlankUid`)·곡 안 빈 가사 페이지 → 숨김.
- 그림 페이지(`imagePath != null`)·편집 페이지·미디어 → 숨김. 배경 영상 가사 페이지 → 가사 보임.
- 원본이 공백·줄바꿈뿐 → 숨김.
- 발표 전 + 스위치 끔 → 숨김 / 켬 → 보임. 블랙아웃 + `follow_blackout` 켬/끔. 잠시 숨기기.
- 숨김 이유 `reason` 값(s7 상태 글 4종).
- 성경: `title` = 참조, `show_bible_ref` 끔 → ''. 곡 제목 스위치.
- `page_format` 이 있어도 결과 같음.
- 누출: S1·S2 문자열 검사.
- 같은 입력이면 `toJson` 이 바이트까지 같다(C6, 서버 '같으면 안 보냄'의 전제).

**`test/obs_overlay_store_test.dart`**
- 모든 칸 왕복. 기본값 표(C10·C13·C22 확정값) 고정.
- clamp: port 0·70000·문자열·8765(금지), 크기 음수·NaN, 투명도 2, fade -1.
- 틀린 enum·색(`red`, `#12345`, 8자리) → 기본.
- 키 없음·빈 값·대문자·길이 틀림 → 새 키 + 저장. 맞는 키는 두 번 load 해도 같음.
- 파일 없음 → 키 만들어 바로 저장(C29).
- 깨진 JSON → 기본값, 원본 유지, 첫 save 에서 `.broken.bak`, 두 번째 깨짐에 bak 안 덮음, 깨짐 표시 true.
- 폴더 못 엶 → enabled false.
- 임시 파일 안 남음(원자 쓰기). 폴더 주입 생성자.

**`test/obs_overlay_server_test.dart`** (실제 소켓)
- 키 없음/틀림 → `/obs`·`/obs/events`·`/obs/state`·`/obs/font/0` 모두 403.
- Host 가 `evil.example:8766` → 403(127.0.0.1 모드), LAN 모드는 통과.
- POST·PUT → 405/403. 모르는 경로 404.
- SSE: 붙자마자 마지막 JSON, 바뀌면 받음, 같으면 안 받음, 15초 ping(시간 주입).
- `/obs/state` = SSE 와 같은 JSON.
- 포트를 다른 소켓이 127.0.0.1 로만 잡고 있음 → 다른 포트로 안 감, `error=portInUse`, `running=false`(LAN 모드에서도).
- stop → start: 같은 포트·키, 마지막 JSON 바로 줌.
- start 두 번 = 서버 하나. stop/start 섞어 빠르게 불러도 큐 순서대로.
- 키 재발급 → 옛 SSE 끊김, 옛 키 403, 새 키 200.
- 연결 수 `ValueNotifier`: 붙으면 +1, 끊으면 −1.
- `/obs/font/<n>`: 고른 글꼴 면만(내장 Pretendard 4면은 `fontBytes` 주입으로), 범위 밖·`..`·음수 → 404, 응답·헤더에 경로 없음.
- 기본 바인드가 127.0.0.1(사설 IP 로 연결 거부, 사설 IP 없으면 skip).
- HTML: `EventSource('/obs/events'` 경로가 서버 경로와 같음(C7 회귀), `innerHTML` 없음, `background:transparent`.
- 응답 어디에도 CORS 헤더 없음.

**`test/obs_overlay_page_test.dart`** (praise_home_page 연결, 위젯 — 가짜 서버 주입)
- 발표 시작 직후 첫 장이 OBS 로 감(C36).
- 넘기기·번호 점프·블랙아웃 켬/끔·블랙아웃 실패 되돌림·발표 종료 각각 1회 전송, 최종 상태 맞음.
- 발표 창 `updatePage` 실패(catch) → OBS 숨김.
- 배경 영상 페이지에서 가사 PNG 굽기를 기다리지 않음(가짜 렌더러를 멈춰 둔 채 OBS 는 이미 받음).
- 빠르게 3장 넘김 → OBS 마지막 값 = 마지막 장.
- 보조 언어 바꾸기·가사 수정 창 저장·붙여 넣기·옮기기·음성 넣기·콘티 뒤에 붙이기 후 OBS 글이 새 글.
- 편집 탭 X 삭제·콘티 불러오기(교체) 뒤 OBS 가 지운/옛 콘티 글을 들고 있지 않음(§2-1 보강을 넣는다면).
- '발표 창 없이도 내보내기' 끔에서 편집 탭 클릭 → OBS 숨김 유지. 켬이면 정한 규칙대로(§2-2).
- 앱 종료 요청 → 투명 전송 후 stop, 3초 안에 끝남.
- `chord_leak_test.dart` 에 OBS 줄 추가.

**`test/obs_overlay_dialog_test.dart`**
- 켜기 스위치·주소 복사(클립보드 = `http://127.0.0.1:<port>/obs?k=<key>`)·포트 사용 중 빨간 줄·'고급' 펼친 채 열기.
- 키 새로 만들기 확인창 → 취소면 그대로.
- 슬라이더 0.2초 묶음 저장.
- 빠른 스타일(C19 를 넣는다면) 누르면 칸이 채워짐.
- 발표 보기 칩(s6): 켜져 있을 때만 보임, 숨김 토글 → 주황, 앱 바 점 색.

### 4-2. 실제 OBS 수동 확인 체크리스트 (macOS·Windows 각각, 사용자 PC)

준비
- [ ] OBS 판·OS 기록. 앱 '브라우저로 열어 보기'(preview=1) 바둑판 위 자막이 보인다(Windows 에서 버튼이 동작하는지)
- [ ] OBS 브라우저 소스 URL 넣기, 1920x1080, 기본 '사용자 지정 CSS' 그대로 → **배경이 투명**(카메라가 비친다). CSS 를 지워도 투명인지
- [ ] OBS 캔버스가 1280x720 일 때 소스를 화면에 맞추면 비율대로 줄어든다

내용
- [ ] 찬양 원본+보조 2줄씩 · 외곽선/그림자/띠 · 밝은 화면 앞 가독성
- [ ] 긴 성경 구절 자동 줄바꿈 + 최대 높이 넘으면 축소, 하한에서 읽히는 크기인지
- [ ] 설교 제목 · 문구 있는 빈 페이지 · PPT 그림 · 편집 페이지 · 동영상 페이지 · 자동 여백 → 규칙표대로
- [ ] 글꼴: Pretendard(내장)·무료 폰트·이 PC 글꼴이 OBS 에서 그 글꼴로 보인다. 첫 장에 대체 글꼴이 깜빡이지 않는지
- [ ] 한글 외곽선이 획을 갉아먹지 않는다(text-shadow 8방향)

동기
- [ ] 넘길 때 관객 화면과 OBS 미리보기 차이 체감(동시 / 늦음 ms 대략)
- [ ] 빠르게 10장 넘김 → 마지막 장에서 멈춤, 페이드가 쌓여 깜빡이지 않음
- [ ] 블랙아웃 켬/끔, 잠시 숨기기, 발표 종료 → 투명
- [ ] 배경 영상 곡에서도 OBS 가 늦지 않음

수명·장애
- [ ] **OBS 를 앱보다 먼저 켬** → 방송 화면에 오류 화면/흰 화면이 나가는지, 앱 켠 뒤 저절로 붙는지, 안 붙으면 '새로 고침'으로 되는지
- [ ] 앱 정상 종료 → OBS 투명. 앱 강제 종료(작업 관리자·⌘⌥Esc) → 수 초 안에 투명. 앱 다시 켜면 다시 붙음
- [ ] Windows: 발표 창 연 채 메인 창 닫기(종료 요청 안 오는 경우) → 투명
- [ ] PC 잠자기 → 깨우기 → 넘김이 다시 OBS 로 감(시간 기록)
- [ ] 장면 바꿨다 돌아오기, 소스 '보이지 않을 때 끄기' 켬 상태
- [ ] OBS 2개 소스(또는 OBS + 브라우저 미리보기) 동시 → 둘 다 같이 바뀜, 연결 수 표시
- [ ] 키 새로 만들기 → 옛 주소 OBS 가 즉시 투명(멈춘 가사 아님)
- [ ] 포트 바꾸기 → 옛 주소 끊김 안내
- [ ] 다른 프로그램이 8766 을 잡은 상태로 앱 켜기 → 빨간 점·문구, 앱은 정상
- [ ] 방화벽 창이 뜨는지(127.0.0.1 모드 / LAN 모드)
- [ ] LAN 모드(넣는다면): 다른 PC OBS, 앱 PC IP 바뀐 뒤 안내
- [ ] stt_translate 자막과 하단 겹침 → 위치로 비킬 수 있음
- [ ] 방송 PC CPU 사용량(앱 + OBS + 배경 영상)

---

## 5. 심각한 문제 상위 5개

1. **발표 시작·블랙아웃·발표 종료가 `_sendCurrentSlide` 를 안 지난다**(확인됨). plan 의 "페이지가 바뀌는 모든 길이 지난다"는 전제가 이 셋에선 틀리고, 프론트 문서 표에는 발표 시작이 빠져 있다 → 첫 장 투명·블랙아웃 무시·종료 뒤 마지막 가사가 방송에 남는 사고. 각 자리에 `_sendObs` 를 명시해 넣고 위젯 테스트로 고정.
2. **OBS 전송 위치를 `_sendCurrentSlide` 끝에 두면** 배경 영상 PNG 굽기 대기·stale `return`·발표 창 오류 `return` 에서 늦거나 빠진다(확인됨). plan §5-2 와 Q9 가 서로 모순 — **맨 앞**으로 확정.
3. **편집 탭 X 삭제·콘티 불러오기(교체)는 아무것도 다시 보내지 않는다**(확인됨, 기존 문제). 발표 중이면 지운/옛 콘티 가사가 방송 자막에 그대로 남는다. 그리고 '발표 창 없이도 내보내기' 모드에선 가사 수정 등 조건부 호출이 막혀 갱신이 안 되고, 반대로 편집 탭 클릭만으로 방송이 바뀐다.
4. **기본 글꼴 Pretendard 가 OBS 로 안 갈 수 있다** — 백엔드안 `FontLibrary.filesFor` 는 내장 3종이면 빈 목록(확인됨). 프론트안(`rootBundle`)으로 확정하고 테스트.
5. **JSON·설정 키 이름과 단위가 세 문서에서 다 다르다** — 특히 `liveOnly`/`only_while_presenting`/`outputBeforePresent` 는 **뜻이 반대**, 글자 크기는 pt@540 vs px@1080(기본값이 80px vs 56px), 경로 `/events` vs `/obs/events`(HTML 이 404), 잠시 숨기기·블랙아웃 스위치·설교 스위치·빠른 스타일이 개발 문서에 없음. 구현 전 '확정 값' 표 하나로 모을 것.

그 밖에 실기 최우선 확인: OBS 를 앱보다 먼저 켰을 때 방송에 오류 화면이 나가는지(미확인), 슬립 뒤 SSE 재연결(미확인), 투명 합성(미확인).
