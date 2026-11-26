# QA 리뷰 — 휴대폰 싱어창·발표자 모드 키 없이 고정 주소 (커밋 ed9f318)

- 브랜치: `claude/epic-cray-g6nlcc`, 커밋 `ed9f318` "휴대폰 싱어창·발표자 모드를 키 없이 고정 주소로"
- 사용자 요구: 발표를 끝냈다 다시 켜거나 연결이 끊겨도 휴대폰(발표자 모드·싱어 화면)이 다시 접속할 필요 없게, 키 없이 IP·포트 주소만으로 열리게
- 검토일: 2026-11-26, 환경: 리눅스 컨테이너(root), Flutter(스크래치패드 설치본), Playwright Chromium(휴대폰 크기 뷰포트 390×844, deviceScaleFactor 2)

## 요약

- **요구 충족: 통과.** 같은 망 주소는 `http://<IP>:8765/`(싱어창)·`/presenter`(발표자 모드)로 키 없이 고정되고, 실제 브라우저에서 서버를 껐다 켜도(짧게·20초·CLOSED 상태 모두) 새로고침 없이 새 내용으로 이어졌다. 발표 시작 때 서버 자동 재시작(`_mobileWebWanted`)도 코드상 맞다.
- 실행 검증: 정적 분석·관련 단위 테스트·전체 테스트·브라우저 시나리오 34개 항목 **모두 통과**(전체 테스트의 실패 1건은 이번 변경과 무관, 아래 참고).
- 발견 사항: **높음 0 · 중간 3 · 낮음 5**. 대부분 "키를 없앤 결과 생기는 보안·안내 문구" 문제이고, 기능 회귀는 찾지 못했다.
- 사용자 결정 필요: 3건(같은 망·터널 주소를 아는 누구나 발표 조작 가능 등).

## 실행한 검증과 결과

### 1. 정적 분석

```
flutter analyze lib/src/features/praise/data/singer_web_server.dart \
  lib/src/features/praise/presentation/praise_home_page.dart \
  test/singer_web_server_test.dart test/presentation_timer_test.dart
→ 1 issue found.
  info • 'package:flutter/material.dart' is deprecated ... • praise_home_page.dart:11:1 • deprecated_member_use
```
- 이 info 는 import 줄(SDK 쪽 폐기 알림)이라 이번 커밋과 무관. 새 경고·오류 없음.

### 2. 관련 단위 테스트

```
flutter test test/singer_web_server_test.dart test/presentation_timer_test.dart
→ 00:00 +16: All tests passed!   (5회 반복 실행 모두 통과)
```

### 3. 전체 테스트 `flutter test` (2회)

| 회차 | 결과 | 실패 |
|---|---|---|
| 1회 | `+834 ~2 -2: Some tests failed.` | `update_script_test.dart` "새 파일을 못 넣으면 기존 파일을 되돌려 놓는다" / `singer_web_server_test.dart` "발표자 모드 페이지 목록·썸네일은 발표자 쪽(p=1)만, 로컬 경로 없이" — `HttpException: Connection closed before full header was received, uri = http://127.0.0.1:8765/img/page/2?v=...&p=1` |
| 2회 | `+835 ~2 -1: Some tests failed.` | `update_script_test.dart` 만 |

- `update_script_test` 실패는 컨테이너가 **root**(uid 0)라 파일 권한으로 쓰기를 막는 테스트가 막히지 않는 것(`Expected: throws FileSystemException / Actual: returned <1>`). 이번 커밋과 무관.
- `singer_web_server_test` 1회 실패는 다시 재현되지 않았다(같은 파일 단독 5회·전체 2회째 통과). 두 요청을 동시에 보내는 자리(`Future.wait([get(imgUrl), get(imgUrl)])`)에서 HttpClient 가 닫히는 중인 keep-alive 연결을 재사용한 것으로 보이며, 테스트 구조는 커밋 전과 같다(키 → `p=1` 만 바뀜). → 낮음-7 로 기록.
- 확인 방법: 다른 프로세스가 8765 를 잡고 있으면 같은 포트를 못 잡는 것을 별도 dart 스크립트로 확인(`Address already in use, errno = 98`) — 테스트 파일 사이 포트 충돌로 생긴 실패는 아니다.

### 4. 실제 브라우저 시나리오 (Playwright Chromium, 휴대폰 뷰포트)

방법: 임시 flutter 테스트 `test/zz_qa_mobile_keyless_test.dart`(끝난 뒤 **삭제함**)로 실제 `SingerWebServer` 를 켜고 `update`(현재·다음·`pages` 3장(가사 1·그림 2)·`note`·`message`), 명령 파일로 stop/start/새 내용 update 를 시켰다. `onControl` 은 받은 action·from·id·on 을 기록하고 상태를 바꿔 다시 `update`. 같은 브라우저 컨텍스트에서 `/` 와 `/presenter` 두 탭을 동시에 열었다.

결과(그대로):

```
PASS 싱어창 첫 내용 표시
PASS 싱어창엔 발표자 메모 없음
PASS 발표자 페이지 내용 표시
PASS 발표자 body.remote
PASS 썸네일 이미지 로드 — [{"src":"/img/page/1?v=cf7337cf67d61337&p=1","ok":true},{"src":"/img/page/2?v=a65c53a2d8216048&p=1","ok":true}]
PASS 모든 페이지 3칸 — 3
PASS 싱어 /state 에 note·message·pages_rev 없음 — clock_ms,current,next,page_number,total_pages,blackout,clock
PASS 발표자 /state 에 note·pages_rev 있음 — clock_ms,current,next,page_number,total_pages,blackout,clock,note,zoom,message,message_id,pages_rev
PASS 싱어 쪽 /pages 403
PASS 싱어 쪽 /control 403
PASS 다음 버튼 → onControl next from=1 — CONTROL next from=1
PASS 썸네일 → onControl goto id=u2:1:false — CONTROL goto from=null id=u2:1:false
PASS goto 뒤 현재 페이지 이미지(/img/current) 로드 — {"src":"/img/current?v=720130443-1795654134062","ok":true}
PASS 발표자 메시지 띠 표시 — {"cls":"show in","text":"설교 5분 남았습니다"}
PASS 싱어창엔 메시지 안 보임
PASS 화면 끄기 길게(touch) → onControl blackout on=1 — CONTROL blackout from=null id=null on=1
PASS 끈 뒤 싱어창 "연결 끊김" 표시
PASS 끈 동안 EventSource 상태(0=재연결중,2=닫힘) — 0
PASS 다시 켠 포트가 같음 — 8765 → 8765
PASS 재시작 뒤 새로고침 없이 싱어창 새 내용 — 1285ms
PASS 재시작 뒤 새로고침 없이 발표자 새 내용
PASS 재시작 뒤 썸네일 다시 로드
PASS 20초 꺼졌다 켜도 싱어창 이어짐 — esState(꺼진 동안)=0
PASS 20초 꺼졌다 켜도 발표자 이어짐
PASS 발표자 머리줄 [발표자 모드|싱어창] — ["발표자 모드","싱어창"]
PASS 발표자 주소 싱어창 모드에 메모 보임 — "발표자 메모 B2"
PASS JS pageerror·예상 밖 콘솔 오류 없음(서버 끈 동안의 네트워크 오류 로그 제외) — []
INFO 네트워크 콘솔 로그 수(서버 끈 동안): 20   (ERR_CONNECTION_REFUSED·ERR_INCOMPLETE_CHUNKED_ENCODING — 서버를 끈 탓, JS 오류 아님)
PASS 요청에 k= 없음 — []
INFO control 요청: ["POST /control?p=1&action=next&from=1","POST /control?p=1&action=goto&id=u2%3A1%3Afalse","POST /control?p=1&action=blackout&on=1"]
INFO 4xx/5xx 응답: []
```

추가 시나리오 — **SSE 가 CLOSED(2)가 되는 경로**(새로 넣은 3초 재연결 코드): 서버를 끈 동안 같은 포트에 503 을 주는 가짜 서버를 5초 띄움 → `readyState = 2` 확인 → 가짜 서버 닫고 실제 서버 다시 켜 새 내용 update.

```
가짜 503 동안 readyState = 2
PASS CLOSED 뒤 3초 재연결로 새 내용 (545ms)
pageerror []
```

- Chromium 은 서버가 그냥 꺼진 경우(연결 거부) EventSource 를 닫지 않고 스스로 다시 붙는다(`readyState 0`). 새 3초 재연결 코드는 비정상 응답(4xx·5xx·다른 프로그램)일 때 쓰인다 — 둘 다 이어짐을 확인했다.
- `/control` 쿼리 조립: `/control?p=1&action=...` 정상(`?`·`&` 순서 맞음, id 는 encodeURIComponent).
- `/presenter` 페이지의 이미지·API 는 모두 `/` 로 시작하는 절대 경로라 경로가 바뀌어도 문제없음(`/presenter/` 꼴은 코드로 확인, 브라우저로는 `/presenter` 만 열어 봄).

스크린샷(`planning/mobile-keyless/screens/`, deviceScaleFactor 2):

| 파일 | 내용 |
|---|---|
| 01-singer.png | 싱어창 `/` 첫 화면 |
| 02-presenter.png | 발표자 모드 `/presenter` 첫 화면(썸네일 3칸) |
| 03-presenter-after-goto.png | 썸네일 3번 누른 뒤 |
| 04-presenter-message.png | 메시지 띠 "설교 5분 남았습니다" |
| 05-singer-offline.png | 서버 끈 뒤 '연결 끊김' |
| 06-singer-reconnected.png / 07-presenter-reconnected.png | 다시 켠 뒤 새로고침 없이 새 내용 |
| 08-presenter-singer-mode.png | 발표자 주소에서 '싱어창'으로 바꿈(메모 보임) |
| 09-presenter-after-closed-reopen.png | CLOSED 뒤 3초 재연결 |

### 5. 잔재 검색

`grep -rn "?k=|remoteToken|싱어 키|발표자 키|리모컨 키|새 QR|QR 을 다시|다시 찍" lib/ CLAUDE.md docs/` — 토큰·`k=`·`keyGone`·`location.search`·403 처리 잔재 없음. 남은 "키" 표현은 아래 낮음-5 의 주석 2곳과 "키 없음" 설명뿐. `docs/` 사용 설명서에는 휴대폰 화면 설명이 없어 고칠 곳 없음.

## 발견 사항

### 중간

**중간-1. 싱어 주소를 받은 사람은 누구나 `/presenter` 를 쳐서 발표를 조작할 수 있는데, 안내 문구는 "넘길 수 없다"고 한다**
- 위치: `lib/src/features/praise/presentation/praise_home_page.dart:2129`('가사만 보는 화면입니다. 이 주소로 연 사람은 페이지를 넘길 수 없습니다.'), 서버 `lib/src/features/praise/data/singer_web_server.dart:485`(`remote = p == '1'`)
- 재현: 싱어 주소 `http://<IP>:8765/` 를 단톡방에 돌림 → 받은 사람이 주소 끝에 `presenter` 를 붙여 열거나, `curl -X POST 'http://<IP>:8765/control?p=1&action=blackout&on=1'` → 관객 화면이 꺼짐(브라우저 시나리오에서 `p=1` 만으로 next·goto·blackout 이 모두 불림을 확인). 발표자 메모(`note`)·메시지도 `GET /state?p=1` 로 누구나 읽는다.
- 예전엔 싱어 QR 을 돌려도 리모컨 키를 몰라 조작이 불가능했다(커밋 전 주석: "싱어 QR 을 단체방에 돌려도 그 키로는 넘기지도, 발표자 메모를 보지도 못한다"). 이 보장이 없어졌다.
- 제안: 사용자 결정 1 에 따라 ① 받아들이면 문구를 "이 화면에선 넘길 수 없지만, 같은 와이파이의 누구나 발표자 주소(/presenter)로 조작할 수 있습니다"처럼 사실대로, ② 막으려면 발표자 쪽에만 **고정(앱 실행 간 유지) 짧은 PIN/키**를 두고 싱어창만 키 없이(요구의 핵심인 "다시 접속 안 해도 됨"은 고정 키로도 충족).

**중간-2. 다른 웹 페이지가 `/control` 을 부를 수 있다(CSRF)**
- 위치: `singer_web_server.dart:527-` (`/control` 은 POST·`p=1` 만 본다. `Origin`·`Host` 검사 없음)
- 재현(코드 근거, 브라우저로 직접 재현은 안 함 — 미확인): 같은 와이파이의 누군가(또는 발표 PC 자신)가 연 아무 웹 페이지가 `fetch('http://192.168.x.x:8765/control?p=1&action=next&from=N',{method:'POST',mode:'no-cors'})` 를 보내면 응답은 못 읽어도 요청은 도착해 넘어간다. 예전엔 토큰을 몰라 불가능. 터널 주소(`*.trycloudflare.com/presenter`)는 인터넷 어디서나 같은 일이 된다.
- 제안: `/control` 에서 `Origin` 헤더가 있으면 요청 `Host` 와 같은 출처일 때만 받기(휴대폰 페이지의 fetch 는 같은 출처라 영향 없음). 터널을 쓸 때도 같은 규칙.

**중간-3. 바깥 망(터널, https) 주소는 발표를 다시 시작하면 바뀌는데, 안내는 무조건 "저절로 다시 연결됩니다"**
- 위치: `praise_home_page.dart:2150`('발표를 끝냈다 다시 시작해도 휴대폰 화면은 저절로 다시 연결됩니다.'), `:2067`, 서버 JS 주석 `singer_web_server.dart:1148`("앱에서 껐다 켜도 같은 주소면 그대로 이어진다")
- 재현(코드 근거): 발표 종료 → `_stop` 이 cloudflared 를 죽이고 `_publicBase=null` → 다음 발표의 `_restartMobileWeb` 이 새 임시 터널을 띄움 → 새 `https://<다른 이름>.trycloudflare.com`. LTE 로 연 휴대폰은 옛 주소를 폴링하며 '연결 끊김'에 머문다. 실제 cloudflared 로는 미확인(이 환경에 없음).
- 사용자 요구는 "IP 와 포트"라 같은 망은 충족이지만, 문구가 터널 쪽 사용자를 오해시킨다.
- 제안: 문구를 "같은 와이파이 주소로 연 휴대폰은 저절로 다시 연결됩니다(바깥 망 주소는 켤 때마다 바뀝니다)"로. 또는 발표 종료 때 터널만은 남겨 두는 방안(앱 실행 동안) 검토 — 사용자 결정 3.

### 낮음

**낮음-1. 발표 시작 때 서버 다시 켜기가 실패하면 로그만 남고 사용자는 모른다**
- 위치: `praise_home_page.dart:1956-1966`(`_restartMobileWeb`)
- 재현(코드 근거): 다시 켤 때 `HttpServer.bind` 가 실패(방화벽·권한 등)하면 `app.log` `[singer-web] 다시 켜기 실패` 만. 휴대폰 버튼은 꺼진 색이라 눈치챌 수는 있다.
- 제안: 스낵바 한 줄("휴대폰 화면을 다시 켜지 못했습니다").

**낮음-2. 8765 를 다른 프로그램이 잡고 있으면 다시 켤 때 포트가 바뀌어 휴대폰이 조용히 못 붙는다**
- 위치: `singer_web_server.dart:123-136`(`_start` 의 빈 포트 대체), 다이얼로그 문구 `praise_home_page.dart:2149`("같은 와이파이 주소는 늘 같습니다")
- 재현: 발표 사이에 다른 프로그램이 8765 를 잡음 → 다음 발표 `_restartMobileWeb` 가 아무 포트로 켬 → 열어 둔 휴대폰·즐겨찾기 주소는 계속 '연결 끊김'. 앱은 알리지 않는다. (이 환경에서 8765 가 비어 있을 땐 껐다 켜도 같은 포트임을 확인 — `8765 → 8765`.)
- 제안: 자동 재시작 때 포트가 지난번과 다르면 스낵바로 새 주소를 알리기. 문구는 "보통 늘 같습니다".

**낮음-3. '끄기'를 안 누르고 발표를 끝내면 다음 발표 때 묻지 않고 망에 다시 열린다**
- 위치: `praise_home_page.dart:1519`, `:1954`
- 의도된 동작이고 다이얼로그 맨 아래 문구에 적혀 있다. 다만 다이얼로그를 다시 열지 않으면 알 길은 툴바 휴대폰 아이콘 색뿐. 키가 없어진 만큼 "말없이 다시 열림"의 무게가 커졌다 — 사용자 결정 2.

**낮음-4. 예전 앱이 준 QR·즐겨찾기(`/?k=…`)로 연 발표자는 말없이 싱어창이 된다**
- 위치: `singer_web_server.dart:485-499`(`k` 무시, 경로 `/` = 싱어창)
- 재현: 업데이트 전 발표자 QR 주소 `http://<IP>:8765/?k=<옛 리모컨 키>` 를 열면 `<body>`(싱어창) — 넘기기 버튼이 없고 안내도 없다. 이미 열려 있던 옛 페이지(옛 JS)는 `/control` 403 을 받아 "주소가 바뀌었습니다 · 새 QR 로 여세요"를 띄운다(옛 코드 동작, 한 번뿐).
- 제안: 업데이트 직후 한 번이라 받아들일 만함. 원하면 `k` 가 붙은 요청에 "주소가 바뀌었습니다: 발표자 모드는 /presenter" 안내.

**낮음-5. 주석 잔재**
- `singer_web_server.dart:182` "같은 망 주소·**키** 유지" — 키가 없다.
- `singer_web_server.dart:1148` "키가 없어서 앱에서 껐다 켜도 같은 주소면 그대로 이어진다" — 터널은 껐다 켜면 주소가 바뀌므로 이 분기(https)에선 사실상 해당 없음(중간-3 과 같은 뿌리).

**낮음-6. 발표 도중 오류 경로(`_sendCurrentSlide` catch)는 `_resetPresentationState` 를 안 거친다** (이번 커밋 전부터)
- 위치: `praise_home_page.dart:2540-2546`
- 확인: 이 경로도 `_singerWeb.stop()` 만 하고 `_mobileWebWanted` 는 그대로라 **다음 발표 시작 때 서버가 다시 켜진다**(요구대로). 다만 타이머·자동 넘기기 정지 등은 이 경로에서 안 되는 기존 문제는 그대로다(이번 변경과 무관, 참고용).

**낮음-7. `singer_web_server_test` 썸네일 동시 요청이 전체 실행 중 한 번 실패(재현 안 됨)**
- 위치: `test/singer_web_server_test.dart:283`
- 위 "전체 테스트" 참고. keep-alive 재사용 경쟁으로 추정(미확인). 테스트 구조는 커밋 전과 같아 이번 변경이 원인일 가능성은 낮다. 계속 보이면 그 두 요청만 새 `HttpClient`(또는 `persistentConnection = false`)로.

### 확인했고 문제없던 항목

- 토큰(`_token`·`_remoteToken`)·`?k=`·403/keyGone·`gone` 처리·`location.search` 모두 제거됨. JS 의 모든 API 요청이 `Q`(`?p=1` 또는 빈 값)로 조립됨: `/state`, `/events`, `/pages`, `/control`, 썸네일 `/img/page/<n>?v=&p=1`.
- 싱어 쪽(`p` 없음): `/state`·SSE 에 `note`·`zoom`·`message`·`message_id`·`pages_rev` 없음, `/pages`·`/img/page`·`/control` 403. `GET /control?p=1` 도 403.
- HTML 응답 `no-store` — 옛 토큰 JS 가 캐시에 남지 않음.
- 서버 재시작 직후 `_restartMobileWeb` 가 `start` 뒤 `setState` + `_sendSingerView` 를 부르므로 휴대폰은 바로 지금 페이지·시계를 받는다. 다시 붙으면 `pagesAsked=''` 로 목록을 다시 받는다(브라우저로 썸네일 다시 로드 확인).
- 발표 종료(`_resetPresentationState`)의 `stop` 과 다음 시작의 `start` 는 같은 큐(`_enqueue`)라 순서가 뒤집히지 않는다.
- 앱 종료 시 터널 정리 경로(`onExitRequested` → `stop`, `killLeftoverTunnel`)는 변경 없음. 실제 cloudflared 로는 미확인.
- 다이얼로그: 발표가 끝나 서버가 꺼지면 '꺼졌습니다 … 다시 켜지고' 문구, '끄기' 를 누르면 `_mobileWebWanted=false`.

## 사용자 결정 필요 사항

1. **같은 와이파이(터널을 켜면 인터넷)의 누구나 발표자 주소로 발표를 넘기고·끄고·메모를 볼 수 있다.** 싱어 주소를 돌린 사람도 `/presenter` 만 붙이면 된다(중간-1·2). 편의(키 없음)를 그대로 둘지, 발표자 쪽에만 앱 실행 간 유지되는 고정 PIN 을 둘지 정해야 한다. 그대로 두면 최소한 안내 문구를 사실대로 바꾸고 `/control` 의 Origin 검사(중간-2)는 넣기를 권한다.
2. 발표를 끝낼 때 '끄기'를 안 눌렀으면 다음 발표에서 묻지 않고 다시 연다(낮음-3). 그대로 둘지, 다시 켤 때 스낵바로 알릴지.
3. 바깥 망(터널) 주소는 발표마다 바뀐다(중간-3). 문구만 고칠지, 터널을 앱 실행 동안 살려 둘지(그동안 인터넷에 열려 있음).

## 남은 미확인 항목

- 실제 iOS Safari·안드로이드 Chrome: 화면 잠금·백그라운드 뒤 SSE 재연결(`visibilitychange` 분기), 화면 꺼짐 방지, 터치 제스처. 이번 검증은 데스크톱 Chromium 휴대폰 흉내뿐.
- Safari 가 서버 꺼짐(연결 거부) 때 EventSource 를 CLOSED 로 만드는지(Chromium 은 CONNECTING 유지). 어느 쪽이든 이어지는 코드지만 실제 기기 확인은 못 함.
- Windows·macOS 방화벽: 같은 포트로 다시 켤 때 허용 창이 다시 뜨는지. 포트 8765 를 다시 잡을 때 OS 별 동작(TIME_WAIT 등) — 리눅스에서는 같은 포트로 바로 다시 잡힘을 확인.
- cloudflared 터널 실제 동작(재시작 때 주소 바뀜, 폴링 재시도): 이 환경에 cloudflared 가 없어 코드로만 확인.
- 실제 앱(`flutter run -d macos`/Windows)에서 발표 종료 → 다시 시작 → 서버 자동 재시작 전 과정: 이 환경에서 데스크톱 앱을 띄우지 못해 코드 리뷰로만 확인.
- CSRF(중간-2)를 실제 다른 출처 페이지로 재현하지는 않았다(코드 근거).
- 와이파이 DHCP 로 PC 의 IP 가 바뀌는 경우 고정 주소가 깨지는 것은 앱 밖 문제라 다루지 않음.
