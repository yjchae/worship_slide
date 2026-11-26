# QA 재검증 — OBS 자막 1단계 구현

- 작성: QA · 2026-11-26 · 대상 커밋 `6e4f5af`(OBS 브라우저 소스용 찬양·말씀 자막 (1단계))
- 읽은 것: `plan.md`(사용자 확정 사항), `qa-review.md`, 새 파일 4개(`obs_overlay_store.dart`·`obs_overlay_server.dart`·`obs_caption.dart`·`obs_overlay_dialog.dart`), `praise_home_page.dart` 변경, `test/obs_*.dart`, `font_library.dart`·`atomic_file.dart`(참고)
- 실행: `flutter test test/obs_caption_test.dart test/obs_overlay_store_test.dart test/obs_overlay_server_test.dart test/obs_overlay_dialog_test.dart` → **23개 모두 통과**.
  따로 임시 테스트를 만들어 돌려 보고 지웠다: ① 깨진 `%zz` 쿼리 → 403 응답(멈춤 없음) ② start/stop 21번 섞어 부르기 → 마지막 상태대로 `running`(큐 순서 지킴)
- 사용자 확정 사항: 방송 PC ≠ 앱 PC(`allowLan` 기본 true) · 찬양은 텍스트 곡 · 블랙아웃·발표 전은 관객 화면 따라가기(투명) · 보조 언어는 OBS 설정에서 따로
- 표기: **확인됨** = 코드·테스트로 봤다 / **미확인** = 실기가 필요하다. 앱 코드는 고치지 않았다.

---

## 1. qa-review.md 항목 — 해결 여부

### 1-1. 심각한 문제 상위 5개

| # | qa-review 지적 | 상태 | 근거 |
|---|---|---|---|
| 1 | 발표 시작·블랙아웃·발표 종료가 `_sendCurrentSlide` 를 안 지난다 | **해결됨(조건부)** | 세 곳 모두 메인 `setState` 를 부르고(`_openPresentation` 1522, `_toggleBlackout` 1569·1575, `_closePresentation` 1562·`presentationClosed` 656 → `_resetPresentationState`), 메인 `build`(7887)의 `_scheduleObsSync` 가 그린 뒤 `_syncObs` 를 부른다. **단 '화면을 다시 그려야' 나간다** → 아래 N1 |
| 2 | OBS 전송을 `_sendCurrentSlide` 끝에 두면 늦거나 빠진다 | **해결됨** | 맨 앞 `_syncObs(slides)`(2618). 배경 영상 PNG 굽기·stale `return`·발표 창 오류 `catch` 와 무관. catch 쪽 `setState(_isPresentationOpen=false)` 도 build 훅으로 투명이 나간다 |
| 3 | 편집 탭 X 삭제·콘티 불러오기(교체)는 아무것도 안 보낸다 | **OBS 는 해결됨** / 관객·싱어는 그대로(기존 문제) | 둘 다 `setState` → build 훅. 그 결과 **X 삭제 직후 OBS 는 새 지금 페이지, 관객 화면은 옛 페이지**로 서로 다를 수 있다(N8). '발표 창 없이도 내보내기'는 사용자 결정으로 빠져 §2-2 는 해당 없음 |
| 4 | 기본 글꼴 Pretendard 가 OBS 로 안 갈 수 있다 | **해결됨** | `obsFontSources` 가 내장 3종은 에셋(`rootBundle`), 무료 글꼴은 `FontLibrary.filesFor`, 이 PC 글꼴(`systemFamilies`, `fonts` 목록 밖)은 이름만 — 라이선스 쪽도 맞다. 서버 테스트 '글꼴: 내장 글꼴은 에셋' 통과 |
| 5 | JSON·설정 키·단위가 문서마다 다르다 | **해결됨** | 설정 키 한 벌(`obs_overlay.json` snake_case), 크기·거리 px@1080, 경로 `/obs/…`(HTML 의 `EventSource('/obs/events'` 와 서버 경로 일치), 빠른 스타일 3개 = 여러 칸을 채우는 버튼. plan.md 에 확정 사항·달라진 것 적힘 |

### 1-2. 그 밖의 항목

| 항목 | 상태 | 메모 |
|---|---|---|
| C6 매번 오르는 `rev` 금지 | 해결됨 | `rev` 없음. 같은 JSON 이면 `update` 가 안 보낸다 |
| C7 경로 접두어 | 해결됨 | `/obs`·`/obs/events`·`/obs/state`·`/obs/font/<n>` |
| C19 빠른 스타일 | 해결됨 | 저장 칸 아님. 선택 표시는 없다(풀림 문제 자체가 없음) |
| C20 잠시 숨기기 | 해결됨(형태 바뀜) | 설정 창 스위치 + 앱 바 주황 점. 발표 보기 칩은 없다(plan 에 적힘). 예배 중 설정 창을 열어야 해서 한 번 더 누른다 — 낮음 |
| C26 축소 하한 | 해결됨 | 이분 탐색 하한 0.2 |
| C29 키 바로 만들기 | 해결됨 | `load` 가 키 없으면 만들어 저장 |
| C31 깨진 파일 | 일부 | `.broken.bak` 남김·기본값. 두 번째 깨짐에 bak 를 **덮는다**, 깨지면 곧바로 새 키로 원본을 덮는다(N10) |
| C32 키 재발급 시 옛 연결 끊기 | 해결됨(코드) / 테스트 없음 | 재시작 → `_stop` 이 모든 SSE 를 닫는다. 옛 키 EventSource 는 403 을 받고 다시 붙지 않는다 |
| C33 Host 검사 | **없음** | 기본이 LAN 허용(0.0.0.0)이라 의미가 줄었다. 127.0.0.1 모드에서도 키가 막으므로 낮음 |
| C34 보내는 순서 | 해결됨 | 위 2 |
| C35 문구 있는 빈 페이지 | 해결됨 | `kind:'text'` |
| C36 발표 시작 첫 장 | 해결됨(조건부) | build 훅. N1 |
| 앱 종료 | 해결됨 | `onExitRequested` 에서 `Future.wait([_singerWeb.stop(), _obs.stop()])` 3초, `_stop` 이 닫기 전에 투명 한 번. 강제 종료는 페이지가 1초 뒤 감춤 |
| 앱 시작 직후 기본 스타일로 한 번 나감 | 해결됨 | `_loadSavedStyle` 의 `setState` 뒤 build 훅이 글꼴·글을 다시 맞춘다 |
| S1·S2 누출(경로·코드·메모) | 해결됨 | `ObsSlide` 는 글 3칸·제목·불 값만. `designJson` 에 키·포트 없음(테스트). 단 `chord_leak_test.dart` 에 OBS 줄은 **안 더했다** |
| S5 모든 경로 키 | 해결됨 | 403 본문에 키·경로 없음 |
| S6 CORS 헤더 | 해결됨 | 안 붙인다 |
| S7 쓰기 경로 | 해결됨 | GET 아니면 403 |
| S9 로그에 키 | 해결됨 | 로그엔 포트·망 모드만 |
| S10 HTML 주입 | 해결됨(글자) / 일부(글꼴 이름) | 글은 `textContent`. 색은 Dart 에서 `#RRGGBB` 만. 글꼴 이름은 `"` 만 뺀다(N9) |
| 슬립·끊긴 연결 감시 | **남음** | 페이지에 '한동안 아무것도 안 오면 다시 붙기'가 없다(N3) |
| 포트 충돌 | 해결됨 | 127.0.0.1 먼저 잡아 보고 0.0.0.0 — 다른 프로그램이 127.0.0.1 만 잡아도 `portInUse`(테스트). 8765(싱어) 입력 금지는 **없음**(낮음) |
| 설정 창 슬라이더 0.2초 묶음 저장 | **남음** | N4 |
| 페이지 연결 위젯 테스트(`obs_overlay_page_test`) | **없음** | §3 |

---

## 2. 새로 찾은 문제

| # | 심각도 | 위치 | 내용 · 재현 | 권고 |
|---|---|---|---|---|
| N1 | **중간** | `praise_home_page.dart` 2552 `_scheduleObsSync`, 1569·1522·1540 | 발표 시작·블랙아웃·발표 종료·X 삭제·콘티 교체는 **메인 창이 프레임을 그려야** OBS 로 간다(`addPostFrameCallback` 은 프레임을 요청하지 않고, 그 프레임이 실제로 그려질 때만 돈다). 메인 창을 최소화하거나 다른 창에 완전히 가린 채 **휴대폰 리모컨으로 블랙아웃**하면 macOS 는 가려진 창의 프레임을 멈출 수 있어 OBS 가 창을 다시 볼 때까지 옛 가사를 띄울 수 있다(**미확인**, Windows 최소화도 미확인). 넘기기는 `_sendCurrentSlide` 가 직접 보내 영향 없음 | build 훅은 안전망으로 두고 `_toggleBlackout`(값 바꾼 직후·되돌린 직후), `_openPresentation`(setState 뒤), `_resetPresentationState` 를 부르는 두 곳(setState 뒤), `_removeFromStaging`·`_replaceConti` 뒤에 `_syncObs()` 를 직접 부른다. 실기: 메인 창 최소화 + 휴대폰 블랙아웃 |
| N2 | **중간** | `obs_overlay_server.dart` 360~367 `loadFonts` | 글꼴을 바꿀 때 예전 `ObsFont` 면을 `document.fonts` 에서 **지우지 않는다**. ① 앱 글꼴(Pretendard) → 이 PC 글꼴(파일 없음, `fonts:[]`)로 바꾸면 `font-family: ObsFont,"<새 이름>"` 의 `ObsFont` 가 여전히 Pretendard 라 **새 글꼴이 안 보인다**(OBS 소스를 새로 고칠 때까지). ② Pretendard → 나눔고딕: Pretendard 500·600 면이 남아 제목 줄(굵기 600)은 Pretendard, 본문은 나눔고딕으로 섞인다 | 글꼴 묶음이 바뀌면 이전에 더한 `FontFace` 들을 `document.fonts.delete()` 로 빼거나, 묶음마다 다른 family 이름(`ObsFont_<v>`)을 쓰고 CSS 도 그 이름으로. 테스트: HTML 에 `fonts.delete` 또는 버전 붙은 이름이 있는지 |
| N3 | **중간** | `obs_overlay_server.dart` 389~393 | 사용자 구성이 **두 PC(와이파이·유선)** 라 연결이 반쯤 죽는 일(공유기 재시작·와이파이 끊김·앱 PC 잠자기)이 현실적이다. 서버 15초 `: ping` 은 SSE **주석**이라 페이지의 `onmessage` 가 안 불려 페이지는 "조용함"과 "죽음"을 가르지 못한다. TCP 가 끊긴 것을 모르는 동안(수 분) OBS 는 **옛 가사를 띄운 채** 넘김을 놓친다 | 서버 ping 을 `event: ping\ndata: 1\n\n` 처럼 이벤트로 보내고, 페이지가 40초 넘게 아무것도 못 받으면 `es.close()` 후 새 `EventSource`(+ 그동안 감춤). 실기: 방송 PC 랜선 뽑았다 꽂기·와이파이 끄기 |
| N4 | 중간 | `obs_overlay_dialog.dart` 74 `_set` → `praise_home_page.dart` 2532 `_applyObsConfig` | 슬라이더를 끄는 동안 **틱마다** ① 12,000줄 메인 화면 `setState`(전체 다시 그리기 + `_allSlides` 두 번) ② `atomicWriteString(flush:true)` 를 기다리지 않고 동시에 여러 번. 임시 이름은 달라 파일이 깨지진 않지만 끝나는 순서가 뒤섞이면 **한 틱 전 값이 마지막에 저장**될 수 있고, Windows 는 동시 rename 이 `FileSystemException` 으로 `app.log` 에 오류를 남길 수 있다(미확인). 큰 콘티에서 슬라이더가 끊겨 보일 수 있다 | 저장은 0.3초 디바운스(창 닫을 때 한 번 더), 디자인만 바뀐 경우 메인 `setState` 없이 `_obsConfig` 만 바꾸고 `_syncObs()`(앱 바 버튼은 `enabled`·`port` 만 본다) |
| N5 | 낮음 | `praise_home_page.dart` 2552~2593 | build 마다(서버 켜져 있으면) 프레임 뒤 `_allSlides` 를 **다시** 만든다(캐시 없음, build 가 이미 7884 에서 만든다) + `jsonEncode` + FNV. 무한 루프는 없다 — `_syncObs` 는 `setState` 를 안 부르고, `clients`/`status` `ValueNotifier` 는 값이 같으면 알리지 않으며 듣는 쪽(앱 바 버튼·설정 창)은 자기만 다시 그린다(확인됨). `_obsSyncScheduled` 로 프레임당 한 번 | build 에서 만든 `slides` 를 콜백으로 넘긴다(`_scheduleObsSync(slides)`) |
| N6 | 낮음 | `obs_overlay_server.dart` 155~158 | 끄기 전 '투명' 을 `write` 한 바로 뒤 `server.close(force: true)` — 소켓을 바로 부숴 투명 메시지가 못 나갈 수 있다(리눅스 테스트는 통과). 못 나가도 페이지가 1초 뒤 `onerror` 로 감추므로 방송 영향은 1초 | `force` 전에 각 응답 `close()` 를 짧게(예: 300ms) 기다린다 |
| N7 | 낮음 | `obs_overlay_dialog.dart` 49·`praise_home_page.dart` 2512 | `_initObs` 가 끝나기 전(시작 직후 수 ms)에 설정 창을 열면 기본값(키 '')으로 열리고, 그 상태에서 값을 하나라도 바꾸면 키 없는 기본 설정이 저장돼 **디자인을 덮는다**(키는 `fromJson` 이 '' 로 받아 다음 실행에 새 키 → OBS 주소가 바뀜) | 로드 전엔 메뉴 항목을 막거나 `_obsLoaded` 를 기다린다 |
| N8 | 낮음(정보) | `_removeFromStaging` 5898 | 발표 중 편집 탭 X 삭제 뒤 **OBS 는 새 지금 페이지, 관객·싱어는 옛 페이지**(관객 쪽은 기존 문제). 방송과 현장이 잠깐 다르다 | 기존 문제를 고칠 때 `_sendCurrentSlide()` 를 넣으면 같이 맞는다(qa-review §2-1 권고 그대로) |
| N9 | 낮음 | `obs_overlay_server.dart` 336 | 글꼴 이름의 `"` 만 빼고 `\` 는 남긴다. 이름이 `\` 로 끝나면 `"…\",sans-serif` 가 닫히지 않아 `font-family` 가 통째로 무시되고 `ObsFont` 도 안 쓰인다. CSS 속성 대입이라 다른 속성 주입은 안 된다 | `\` 도 빼거나 `CSS.escape` |
| N10 | 낮음 | `obs_overlay_store.dart` 331~342 | 읽기가 **잠깐** 실패해도(Windows 백신이 파일을 잡음 등) 깨진 것으로 보고 기본값 + 새 키로 바로 덮는다 → OBS 주소가 조용히 바뀌고 디자인이 사라진다(`.broken.bak` 는 남음, 두 번째엔 그것도 덮음). 키 칸만 틀린 경우(손으로 대문자)도 새 키 | `FileSystemException` 은 한 번 다시 읽고, 진짜 깨졌을 때 bak 가 이미 있으면 덮지 않는다. 설정 창에 '설정 파일이 깨져 새로 만들었다' 알림 |
| N11 | 낮음 | `obs_overlay_dialog.dart` 132 `_applyPort` | 8765(싱어 선호 포트)를 막지 않는다. 싱어가 먼저 켜져 있으면 `portInUse` | 8765 입력 거절 + 문구 |

키 누출 점검: 키는 주소·설정 창·`obs_overlay.json` 에만. 로그·툴팁·403 본문·`designJson` 에 없음(확인됨). 글꼴 URL 에 키가 들어가지만 이미 키를 가진 페이지에만 간다. LAN 모드는 http 평문이라 같은 망에서 엿들으면 키가 보인다 — 기획대로 감수. 기본이 0.0.0.0 이라 게스트 와이파이에 연결된 PC 면 그 망 전체에서 접속을 시도할 수 있다(키 16자 ≈ 79비트라 추측은 불가).

포트 충돌(macOS 두 벌 실행): 첫 앱이 0.0.0.0:8766 이면 두 번째 앱의 127.0.0.1 확인 bind 는 SO_REUSEADDR 로 통과할 수 있으나 이어진 0.0.0.0 bind 가 실패해 `portInUse` — 코드상 맞다(**미확인**, 실기).

---

## 3. 빠진 테스트 (권고)

- **페이지 연결 위젯 테스트 없음**: 발표 시작 첫 장·블랙아웃 켬/끔·블랙아웃 실패 되돌림·발표 종료·`updatePage` 실패·X 삭제·콘티 교체 뒤 OBS JSON. build 훅에 기대는 길이라 회귀가 쉽다(N1 을 고치면 더 필요)
- `chord_leak_test.dart` 에 OBS 줄(코드 있는 곡 → OBS JSON 에 `[G]`·`chord`·`key_label` 없음)
- 서버: 키 재발급 → 옛 SSE 끊김·옛 키 403·새 키 200 / 연결 수 +1·−1 / LAN 모드 bind
- 설정 창: 키 새로 만들기 확인창 '취소'면 그대로, 주소 복사 문자열
- HTML: 글꼴 바꿈 처리(N2), 끊김 감시(N3) 문자열 검사

---

## 4. 실제 OBS 수동 확인 체크리스트 (방송 PC = OBS, 앱 PC 따로 — 사용자 구성)

준비
- [ ] OBS 판·두 PC 의 OS 기록. 앱 설정 창 '이 PC 브라우저에서 열어 보기' → 바둑판 위 자막(Windows `rundll32` 로 열리는지)
- [ ] 첫 켜기에서 앱 PC 방화벽 창(macOS·Windows) → 허용. 허용 안 하면 방송 PC 에서 안 열리는 것도 확인
- [ ] 방송 PC OBS '브라우저' 소스에 설정 창 첫 주소(`http://<앱 PC IP>:8766/obs?k=…`), 1920x1080 → **배경 투명**(카메라가 비친다). 기본 '사용자 지정 CSS' 를 지워도 투명
- [ ] 앱 PC 에 IP 가 여럿(유선+와이파이)일 때 첫 주소가 방송 PC 와 같은 망 주소인지
- [ ] OBS 캔버스 1280x720 에서 소스를 맞추면 비율대로 줄어듦

내용
- [ ] 찬양 원본 + 보조(OBS 설정 '보조 언어' 켬/끔이 관객 화면 스위치와 따로 움직임)
- [ ] 성경 참조 줄·긴 구절 → 최대 높이 넘으면 축소, 하한에서도 읽히는지
- [ ] 설교 제목(부제는 보조 꺼도 보임), 문구 있는 빈 페이지, PPT 그림·편집 페이지·동영상·자동 여백 → 투명
- [ ] 빠른 스타일 3개(외곽선·반투명 띠·화면 폭 띠), 위/아래 기준선, 좌·가운데·우 정렬
- [ ] 글꼴: Pretendard·나눔·무료 글꼴이 방송 PC 에서 그 글꼴로(방송 PC 에 안 깔려 있어도). 첫 장에 대체 글꼴 깜빡임
- [ ] **글꼴 바꾸기**: Pretendard → 나눔고딕 → '이 PC 글꼴' 순서로 바꿔 OBS 가 새로 고침 없이 따라가는지(N2)
- [ ] 한글 외곽선(16방향 text-shadow)이 획을 갉아먹지 않음

동기
- [ ] 넘김 때 관객 화면과 OBS 차이 체감
- [ ] 빠르게 10장 넘김 → 마지막 장, 페이드 겹쳐 깜빡임 없음
- [ ] 발표 시작 첫 장·블랙아웃 켬/끔(키·버튼·**휴대폰 리모컨**)·발표 종료 → 투명/복귀
- [ ] **메인 창을 최소화(또는 다른 창으로 완전히 가림)한 채** 휴대폰 리모컨으로 블랙아웃·넘기기 → OBS 가 곧바로 따라가는지(N1)
- [ ] 잠시 숨기기 → 투명 + 앱 바 주황 점, 다시 켜면 지금 페이지
- [ ] 배경 영상 곡에서도 OBS 가 늦지 않음
- [ ] 발표 중 편집 탭 X 로 지금 곡 삭제 → OBS·관객 화면이 각각 무엇을 띄우는지 기록(N8)

수명·장애
- [ ] **OBS 를 앱보다 먼저 켬** → 방송 화면에 오류/흰 화면이 나가는지, 앱 켠 뒤 저절로 붙는지, 안 붙으면 소스 '새로 고침'으로 되는지
- [ ] 앱 정상 종료 → 1초 안에 투명. 강제 종료 → 1초 안에 투명. 다시 켜면 다시 붙어 지금 페이지
- [ ] Windows: 발표 창 연 채 메인 창 닫기 → 투명
- [ ] **방송 PC 랜선 뽑기 30초 → 꽂기**, 공유기 재시작, 앱 PC 잠자기 → 깨우기: 다시 붙는 데 걸린 시간, 그동안 옛 가사가 남았는지(N3)
- [ ] 장면 바꿨다 돌아오기 / 소스 '보이지 않을 때 끄기'·'장면 활성 시 새로 고침' 켬
- [ ] OBS 소스 2개(또는 OBS + 브라우저) 동시 → 같이 바뀜, 설정 창 연결 수
- [ ] 키 새로 만들기 → 옛 주소 OBS 가 즉시 투명(멈춘 가사 아님) / 포트 바꾸기 → 옛 주소 끊김
- [ ] 다른 프로그램이 8766 을 잡은 채 앱 켜기 → 빨간 점·문구, 앱 정상. 앱 두 벌 실행
- [ ] '다른 PC 에서 받기' 끄면 방송 PC 에서 안 열리고 앱 PC 브라우저만 열림
- [ ] 슬라이더를 빠르게 끈 뒤 앱을 다시 켜서 마지막 값이 남았는지(N4)
- [ ] stt_translate 자막과 하단 겹침 → 위치로 비킴
- [ ] 두 PC CPU(앱 + 배경 영상 / OBS 인코딩)

---

## 팀장 반영 (2026-11-26)

| # | 조치 |
|---|---|
| N1 | `_scheduleObsSync` 를 프레임 콜백 → `scheduleMicrotask` 로 바꿈(창을 다시 그리지 않아도 돈다). `_toggleBlackout`·`_openPresentation`·`_resetPresentationState`·`_removeStagingWhere`·`_replaceConti` 에서 직접 예약 |
| N2 | OBS 페이지 글꼴 묶음마다 새 이름(`ObsFont<n>`)을 쓰고 옛 `FontFace` 를 지움 — Playwright 로 바꾼 뒤 면이 하나만 남는 것 확인 |
| N3 | ping 을 `data: {"ping":1}` 로 보내고, 페이지가 40초 넘게 아무것도 못 받으면 감추고 새로 연결 |
| N4 | 디자인만 바뀌면 메인 `setState` 생략, 저장은 0.3초 디바운스(종료·dispose 때 남은 저장은 바로) |
