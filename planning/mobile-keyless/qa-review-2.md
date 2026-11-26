# QA 리뷰 2 — 휴대폰 발표자 모드 PIN 4자리 (커밋 364a244)

- 브랜치: `claude/epic-cray-g6nlcc`, 커밋 `364a244` "휴대폰 발표자 모드에 PIN 4자리 (싱어창은 그대로 주소만)"
- 대상: 지난 QA(`qa-review.md`, 커밋 ed9f318)의 지적 "키 없는 고정 주소 뒤 발표자 조작을 누구나 할 수 있다"에 대해 사용자가 고른 "발표자 모드에만 PIN 4자리(PC 에서 정하고 발표자 휴대폰에서 입력)"
- 검토일: 2026-11-26, 환경: 리눅스 컨테이너(root), Flutter(스크래치패드 설치본), Playwright Chromium(휴대폰 뷰포트 390×844, deviceScaleFactor 2, isMobile·hasTouch)
- 앱 코드는 고치지 않았다. 임시 테스트 `test/zz_qa_pin_test.dart`·`test/zz_qa_dialog_test.dart` 는 검증 뒤 **삭제함**.

## 요약

- **요구 충족: 통과.** PIN 없이 `/presenter` 를 열면 PIN 입력 페이지, 맞으면 쿠키로 기억하고(새 탭·서버 재시작 뒤에도 안 물음), 싱어창은 PIN 없이 열린다. PIN 없는 휴대폰의 발표자 쪽 요청(`p=1`)은 상태·SSE·목록·썸네일·조작 모두 401 이고 `onControl` 이 불리지 않았다. PC 에서 PIN 을 바꾸면 열려 있던 발표자 휴대폰이 약 3.1초 뒤 PIN 을 다시 묻는다. 다른 출처 페이지(쿠키가 실리는 같은 호스트·다른 포트 포함)의 POST 는 막힌다.
- 실행 검증: 정적 분석·관련 단위 테스트(5회)·전체 테스트·브라우저 시나리오 **모두 통과**(전체 테스트 실패 1건은 지난번과 같은 root 환경 탓 `update_script_test`).
- 지난 발견 사항 12건(중간 3·낮음 7 + 사용자 결정 관련): **해결 5 · 일부 1 · 그대로 3 · 재현 안 됨 1** (아래 표).
- 새 발견 사항: **높음 0 · 중간 1 · 낮음 6**.
  - 중간-1: PIN 바꾸기 창을 닫을 때마다(바꾸기·Enter·Esc·취소 모두) 디버그 빌드에서 `A TextEditingController was used after being disposed` 오류 — 같은 구조로 위젯 테스트에서 재현.
- 사용자 결정 필요: 3건(4자리 PIN 대입 한계·터널 잠금 한 묶음, PC 화면 PIN 노출, 지난번 미결 2건).

## 지난 발견 사항 판정 (qa-review.md)

| # | 내용 | 판정 | 근거 |
|---|---|---|---|
| 중간-1 | 싱어 주소를 받은 누구나 `/presenter` 로 조작 가능, 문구는 "넘길 수 없다" | **해결** | 발표자 쪽은 PIN 쿠키가 있어야 한다(브라우저로 확인: 쿠키 없는 휴대폰의 `p=1` 요청 6종 모두 401, `onControl` 안 불림). 싱어창 문구도 "PIN 없이 누구나 열 수 있고, 페이지는 넘길 수 없습니다"로 사실과 맞다(`praise_home_page.dart:2153`). |
| 중간-2 | 다른 웹 페이지가 `/control` 을 부를 수 있음(CSRF) | **해결** | 모든 POST 에 Origin 검사(`singer_web_server.dart:674-680`) + 쿠키 SameSite=Lax + PIN. 같은 호스트·다른 포트 페이지(같은 사이트라 쿠키가 실림)에서 `no-cors`·`credentials:'include'` fetch 와 폼 POST 를 보내도 `onControl` 안 불림, Origin 이 다르면 403 확인. Origin 없는 POST 는 받지만(낮음-2) PIN 쿠키가 있어야 하므로 CSRF 경로는 아니다. |
| 중간-3 | 터널 주소는 발표마다 바뀌는데 "저절로 다시 연결" 문구 | **해결(문구)** | 터널 칸에 "이 주소는 발표를 다시 시작하면 바뀌므로 그때는 새 QR 로 여세요"(`:2090-2091`), JS 주석도 고침. 다만 쿠키가 호스트마다라 터널로 여는 발표자는 발표마다 PIN 도 다시 넣어야 하는데 그 안내는 없다 → 낮음-5. |
| 낮음-1 | 자동 다시 켜기 실패를 사용자가 모름 | **해결** | `_restartMobileWeb` catch 에 스낵바(`:1970`), `_showSnack` 이 `mounted` 를 본다. 실제 실패 상황으로는 미확인(코드 근거). |
| 낮음-2 | 포트가 바뀌면 휴대폰이 조용히 못 붙음 | **일부** | 다이얼로그 문구에 "PC 의 IP 가 바뀌거나 다른 프로그램이 포트 8765 을 쓰고 있으면 주소가 바뀝니다"가 들어갔다. 자동 다시 켜기 때 포트가 바뀌면 알리는 처리는 없다. |
| 낮음-3 | '끄기' 안 누르면 다음 발표 때 묻지 않고 다시 열림 | **그대로** | 사용자 결정 미결(아래 4). PIN 이 생겨 위험은 싱어창(가사 열람)뿐으로 줄었다. |
| 낮음-4 | 옛 `/?k=…` 발표자 QR 이 말없이 싱어창이 됨 | **그대로** | 변경 없음. 업데이트 직후 한 번이라 받아들일 만하다. |
| 낮음-5 | 주석 잔재(`:182`·`:1148`) | **해결** | 두 곳 고침. 남은 "키" 표현(`:18`, `:133`, `:1046`)은 "토큰이 없다"는 뜻이라 사실과 맞다. |
| 낮음-6 | `_sendCurrentSlide` 오류 경로가 `_resetPresentationState` 를 안 거침 | **그대로(범위 밖)** | 이번 커밋과 무관한 기존 동작. |
| 낮음-7 | 썸네일 동시 요청 테스트 한 번 실패 | **재현 안 됨** | 관련 테스트 5회·전체 1회 모두 통과. 테스트 구조는 그대로라 원인 미확인. |

## 실행 검증

### 1. 정적 분석

```
flutter analyze lib/src/features/praise/data/presenter_pin_store.dart \
  lib/src/features/praise/data/singer_web_server.dart \
  lib/src/features/praise/presentation/praise_home_page.dart \
  test/singer_web_server_test.dart test/presenter_pin_store_test.dart
→ 1 issue found.
  info • 'package:flutter/material.dart' is deprecated ... • praise_home_page.dart:11:1 • deprecated_member_use
```
- 지난번과 같은 기존 폐기 알림뿐. 새 경고·오류 없음.

### 2. 관련 단위 테스트 (5회 반복)

```
flutter test test/singer_web_server_test.dart test/presenter_pin_store_test.dart test/presentation_timer_test.dart
→ 00:00 +22: All tests passed!   (5회 모두)
```

### 3. 전체 테스트 `flutter test` (1회)

```
01:19 +841 ~2 -1: Some tests failed.
Failing tests:
  test/update_script_test.dart: 새 파일을 못 넣으면 기존 파일을 되돌려 놓는다(설치본이 깨지지 않게)
```
- 지난번과 같은 root 환경 탓(권한으로 쓰기를 막는 테스트가 root 라 안 막힘). 이번 커밋과 무관.

### 4. 브라우저 시나리오 (Playwright Chromium, 휴대폰 뷰포트)

방법: 임시 flutter 테스트가 실제 `SingerWebServer`(PIN `4321`)를 켜고 `update`(가사 1장·그림 2장 목록·`note`), 명령 파일로 stop/start/PIN 바꾸기. `onControl` 은 받은 action 을 파일에 남긴다. 같은 컨텍스트 = 발표자 휴대폰, 다른 컨텍스트 = PIN 없는 다른 휴대폰.

결과(그대로):

```
PASS PIN 없이 /presenter → PIN 입력 페이지 — 200
PASS PIN 화면엔 발표자 페이지(body.remote) 없음
PASS PIN 틀림 문구 — PIN 이 맞지 않습니다.
PASS 맞는 PIN → /presenter 로 이동 — http://127.0.0.1:8765/presenter
PASS 맞는 PIN → 발표자 페이지
PASS 쿠키 ws_pin HttpOnly·Lax·1년 — {"httpOnly":true,"sameSite":"Lax","days":365,"value":"4321"}
PASS JS 에서 쿠키(=PIN) 못 읽음
PASS 발표자 썸네일 로드(쿠키 자동 실림) — [{"src":"/img/page/1?v=2d66e779a74b5315&p=1","ok":true},{"src":"/img/page/2?v=d9b9db40c808ee28&p=1","ok":true}]
PASS 새 탭에서도 PIN 다시 안 물음
PASS 싱어창은 PIN 없이 가사 표시
PASS 싱어창에 발표자 메모 없음
PASS PIN 없는 휴대폰의 p=1 요청 모두 401 — {"keys":["current","next","page_number","total_pages","blackout"],"p1":401,"pages":401,"thumb":401,"control":401,"events":401}
PASS 싱어 /state 에 발표자 전용 값 없음 — current,next,page_number,total_pages,blackout
INFO PIN 없는 휴대폰: /img/current 접근(싱어와 같은 공개 이미지) — 404   (현재 페이지가 가사라 그림 없음)
PASS PIN 없는 요청으로 onControl 안 불림 — []
INFO PIN 없이 /presenter?p=1 상태 — 401
PASS 다음 ▶ → onControl next — ["CONTROL next from=1 id=null on=null"]
PASS 썸네일 → onControl goto — [..., "CONTROL goto from=null id=u2:1:false on=null"]
PASS 쿠키 있는 같은 출처 POST blackout → 200·onControl — 200
PASS 다른 출처(같은 호스트 다른 포트, 쿠키 실림) no-cors fetch·폼 POST → onControl 안 불림 — {"eo":{"nocors":"sent","login":"sent"},"new":[]}
PASS Origin 다른 POST(쿠키 맞음) → 403 — 403
INFO Origin 없는 POST(쿠키 맞음) 상태 — 비브라우저 도구 — 200
INFO Origin: null 인 /login POST 상태 — 403
PASS PIN 변경 → 열려 있던 발표자 휴대폰이 PIN 다시 물음 — 3100ms
PASS 새 PIN 으로 다시 들어옴
PASS 다시 켠 포트 같음 — 8765 → 8765
PASS 재시작 뒤 새로고침 없이 PIN 안 물음
PASS 재시작 뒤 새로 열어도 쿠키로 바로 발표자
PASS 5번째 틀림 → 잠금 문구 — 여러 번 틀렸습니다. 30초 뒤에 다시 넣어 주세요.
PASS 잠긴 동안 맞는 PIN 도 거절 — 여러 번 틀렸습니다. 30초 뒤에 다시 넣어 주세요.
PASS 잠금 중에도 이미 쿠키 있는 휴대폰은 계속 동작
INFO 잠금 중 같은 접속 주소의 다른 휴대폰(쿠키 없음)이 맞는 PIN — 여러 번 틀렸습니다. 30초 뒤에 다시 넣어 주세요.
PASS 30초 뒤 맞는 PIN 으로 들어감
INFO 같은 호스트의 다른 쿠키 값에 " 가 있을 때 /presenter — 발표자 페이지
INFO 다른 쿠키 값에 { } 가 있을 때 /presenter — 발표자 페이지
PASS JS pageerror 없음 — []
```
(마지막 `FATAL Error: no ack quit` 는 하네스가 종료 명령에 응답 파일을 안 쓰고 끝나서 난 스크립트 쪽 표시일 뿐, 하네스는 `All tests passed!` 로 끝났다.)

- PIN 변경 흐름: 서버가 발표자 SSE 를 닫음 → Chromium EventSource 가 기본 3초 뒤 다시 붙음 → 401 → `readyState 2` → `onerror` 의 `/state?p=1` → 401 → `checkPin` 이 `location.reload()` → 서버가 PIN 페이지를 준다. 3.1초는 이 3초 재연결 간격이다. 다시 읽은 PIN 페이지엔 JS 가 없어 reload 가 되풀이되지 않는다.
- 잠금은 접속 주소마다라 이 시험(모두 127.0.0.1)에서 **쿠키 없는 다른 휴대폰도 같이 잠겼다** — 터널(127.0.0.1 로 들어옴)에서 생길 일과 같다(새 낮음-3).

### 5. curl 로 본 경계 입력 (같은 하네스)

```
[Cookie: other=a b; ws_pin=4321]      -> 200
[Cookie: x=a,b; ws_pin=4321]          -> 200
[Cookie: x="q; ws_pin=4321]           -> 200
[Cookie: ws_pin=4321; ws_pin=0000]    -> 200
[Cookie: ws_pin=0000; ws_pin=4321]    -> 200
[Cookie: x=\\y; ws_pin=4321]          -> 200
POST /login body 'pin=%ZZ'            -> 000 (curl 5초 시간 초과, exit=28)
POST /login body 'pin=\xff\xfe'       -> 000 (curl 5초 시간 초과, exit=28)
GET /login                            -> 405
POST /login 'pin=+4321+'(앞뒤 공백)    -> 303
Host: evil.example:8765 로 GET /state -> 싱어 JSON 그대로
Host·Origin 둘 다 evil.example:8765 로 POST /login(틀린 PIN) -> 401 (Origin 검사 통과, PIN 검사로 거절)
POST /login 50MB 본문                 -> 401 (본문을 전부 메모리로 읽음)
그 뒤 GET /state                      -> 200
```
- 쿠키 파싱: 다른 쿠키 값이 깨져 있어도 예외 없이 `ws_pin` 을 찾았다(`try/catch` 는 안전망으로만 남음).
- `pin=%ZZ`·깨진 UTF-8 본문은 **응답이 닫히지 않는다** → 새 낮음-1.

### 6. PIN 바꾸기 창 (위젯 테스트, 같은 구조 복사)

`_askPresenterPin` 은 private 이라 같은 코드를 임시 테스트에 복사해 `MaterialApp` 위에서 열었다(macOS·Windows 대상 플랫폼 각각).

```
바꾸기 버튼 (macOS/Windows)   → A TextEditingController was used after being disposed.  + '_dependents.isEmpty': is not true.
Enter 로 제출 (macOS/Windows) → 같은 오류
Esc·취소 (macOS/Windows)     → 같은 오류
숫자 아닌 글자 '12a3' 입력     → '123' 만 남음(FilteringTextInputFormatter) — 정상
3자리로 바꾸기                → '숫자 4자리를 넣어 주세요.' — 정상
무작위로 정하기               → 4자리 숫자 — 정상
접근성: PIN 칸 Semantics      → label="" hint="" (이름 없음)
```
→ 새 중간-1, 낮음-6.

### 스크린샷 (`planning/mobile-keyless/screens/`, deviceScaleFactor 2)

| 파일 | 내용 |
|---|---|
| 2x-01-pin.png | PIN 없이 `/presenter` → PIN 입력 페이지 |
| 2x-02-pin-wrong.png | 틀린 PIN "PIN 이 맞지 않습니다." |
| 2x-03-pin-ok-presenter.png | 맞는 PIN 뒤 발표자 모드(썸네일 로드) |
| 2x-04-singer-no-pin.png | 다른 휴대폰 싱어창(PIN 없음) |
| 2x-05-pin-changed.png | PC 에서 PIN 을 바꾼 뒤 열려 있던 발표자 휴대폰이 다시 PIN 을 물음 |
| 2x-06-pin-locked.png | 5번 틀린 뒤 잠금 문구 |

## 새 발견 사항

### 중간

**중간-1. PIN 바꾸기 창을 닫을 때마다 디버그 빌드에서 "TextEditingController was used after being disposed"**
- 위치: `lib/src/features/praise/presentation/praise_home_page.dart:2207-2270`(`_askPresenterPin`), 특히 `:2269` `controller.dispose();`
- 재현: 같은 코드를 위젯 테스트로 열고 '바꾸기'·Enter·Esc·'취소' 어느 것으로 닫아도 `pumpAndSettle` 중 `A TextEditingController was used after being disposed`(TextField 의 `_AnimatedState.didUpdateWidget` → `addListener`) 와 뒤이은 `'_dependents.isEmpty': is not true` 가 난다(macOS·Windows 대상 모두). `showDialog` 의 Future 는 pop 순간 끝나지만 창은 닫히는 애니메이션 동안 아직 그려지고 있어서, 그 사이 TextField 가 다시 빌드되며 이미 dispose 한 컨트롤러를 쓴다.
- 영향: 디버그(개발) 실행에서 빨간 오류·assert. 릴리즈 빌드는 assert 가 빠져 증상이 없을 가능성이 높지만 **미확인**. 이 레포의 다른 입력창(`showGroupNameDialog` 등)은 StatefulWidget 의 `dispose` 에서 컨트롤러를 버려 이 문제가 없다 — 이 함수만 다르다.
- 제안: 창 내용을 작은 StatefulWidget 으로 빼서 그 `dispose` 에서 버리거나, `WidgetsBinding.instance.addPostFrameCallback` 대신 닫힘 애니메이션이 끝난 뒤(예: 라우트 `completed` 후) 버리기. 위젯 테스트로 '바꾸기'·Esc 닫기를 고정해 두기.

### 낮음

**낮음-1. `/login` 본문이 잘못된 퍼센트 인코딩·UTF-8 이면 응답을 닫지 않는다(연결이 매달림), 본문 크기 제한도 없다**
- 위치: `lib/src/features/praise/data/singer_web_server.dart:694-695`(`utf8.decoder.bind(req).join()`, `Uri.splitQueryString`), 바깥 catch `:656-659` 가 `res` 를 닫지 않음
- 재현: `curl -X POST --data-binary 'pin=%ZZ' http://<IP>:8765/login` → 응답 없음(5초 시간 초과). 깨진 UTF-8 도 같다. 50MB 본문은 전부 읽은 뒤 401.
- 영향: 일반 휴대폰 폼은 이런 본문을 안 보낸다. 망 안의 악의적 도구가 소켓·메모리를 붙잡는 정도. 실패 횟수에도 안 잡힌다(예외가 세기 전에 난다 — PIN 을 맞히는 데는 못 쓴다).
- 제안: `_login` 안에서 본문 읽기·풀기를 try 로 감싸 400 으로 닫기, 본문은 1KB 정도에서 자르기.

**낮음-2. Origin 이 없는 POST 는 받는다**
- 위치: `singer_web_server.dart:676`
- 판단: 현대 브라우저는 다른 출처로 보내는 POST(fetch·폼)에 늘 Origin 을 붙인다(이번 시험에서도 다른 포트 페이지의 요청은 모두 막힘, `Origin: null` 도 403). Origin 을 빼고 보낼 수 있는 것은 curl 같은 도구인데, 그런 도구는 Origin 을 마음대로 써 넣을 수도 있으므로 Origin 검사로 막을 대상이 아니다. 실제 보호는 PIN 쿠키다. 위험 낮음 — 기록만.
- 참고: Host 헤더는 검사하지 않아 DNS 리바인딩으로 싱어 `/state` 를 읽을 수 있지만 싱어 값은 원래 공개이고, 발표자 쪽은 쿠키가 IP 호스트에 묶여 있어 리바인딩 이름으로는 안 실린다(위 curl: Host·Origin 을 맞춰도 PIN 검사에서 401).

**낮음-3. 잠금이 접속 주소마다라 터널(127.0.0.1)로 오는 사람은 모두 한 묶음 — 남이 틀리면 진짜 발표자도 30초 못 들어온다**
- 위치: `singer_web_server.dart:690`(`who = remoteAddress`), CLAUDE.md 에도 "터널로 온 요청은 한 묶음"으로 적혀 있음
- 재현: 브라우저 시나리오에서 한 휴대폰이 5번 틀린 뒤 같은 주소의 다른 휴대폰(쿠키 없음)이 맞는 PIN 을 넣어도 잠금 문구. 이미 쿠키가 있는 휴대폰은 영향 없음(확인).
- 영향: 터널 주소를 아는 사람이 계속 틀려 주면 바깥 망 발표자는 새로 들어올 수 없다(이미 들어온 휴대폰은 괜찮다. 다만 터널 주소는 발표마다 바뀌고 쿠키도 호스트마다라 터널 발표자는 발표마다 새로 들어와야 한다 — 낮음-5). 반대로 대입 쪽에서는 터널 전체가 5번/30초로 묶여 더 안전하다.
- 제안: 받아들이거나, 터널 요청은 `CF-Connecting-IP` 헤더(Cloudflare 가 붙임 — 이 환경에서 미확인)로 나누기. 그 헤더는 같은 망에서 위조할 수 있으므로 127.0.0.1 에서 온 요청에만 믿어야 한다.

**낮음-4. 4자리 PIN 의 대입 한계(타이밍 공격은 해당 없음)**
- 위치: `singer_web_server.dart:121-122`(5번·30초), `:697`(`pin == presenterPin`)
- 계산: 한 주소당 30초에 5번 = 분당 10번 → 1만 개 중 평균 5,000번 ≈ 8.3시간, 한 시간 예배 동안 맞힐 확률 약 6%. 같은 와이파이에서 주소를 여러 개 쓰면(여러 기기·IP 바꾸기) 그만큼 빨라진다. 문자열 `==` 의 시간 차이는 네트워크 흔들림에 묻히고 공간이 1만 개뿐이라 의미 없다.
- 판단: "같은 와이파이의 장난 방지"로는 충분, "작정한 공격 방지"로는 부족. 사용자 결정 1.
- 덧붙임: 쿠키 값이 PIN 그 자체라 http(같은 망)에서 흘러가는 요청을 엿보면 PIN 이 보인다(PIN 입력 폼도 같은 http 라 어차피 같다). PIN 을 바꿨다 되돌리면 옛 쿠키가 다시 통한다. 모두 4자리 설계 안에서는 받아들일 만하다.

**낮음-5. 터널(바깥 망)로 여는 발표자는 발표를 다시 시작할 때마다 PIN 을 다시 넣어야 하는데 안내가 없다**
- 위치: 문구 `praise_home_page.dart:2090-2091`, `:2143`("한 번 넣은 휴대폰은 다음부터 묻지 않습니다")
- 근거(코드): 쿠키는 호스트마다 남는데 터널 주소(`*.trycloudflare.com`)는 발표마다 바뀐다. 같은 망 주소도 PC 의 IP 가 바뀌면 같다. 실제 cloudflared 로는 미확인(이 환경에 없음).
- 제안: "같은 와이파이 주소로 연 휴대폰은 다음부터 묻지 않습니다(바깥 망 주소는 열 때마다 묻습니다)".

**낮음-6. 접근성·자잘한 것**
- PC PIN 바꾸기 칸에 이름이 없다(Semantics label·hint 빈 값, `praise_home_page.dart:2231`). 화면 읽기 프로그램은 "편집 가능 텍스트"만 읽는다. `labelText: 'PIN 4자리'` 정도.
- 휴대폰 PIN 페이지의 `<input>` 에 `<label>`·`aria-label` 이 없다(`singer_web_server.dart:820`). 앞 `<p>` 설명만 있다. `aria-label="PIN 4자리"`.
- `_PresenterPinRow` 를 `_CopyTextButton` 앞에 넣으면서 `_CopyTextButton` 의 문서 주석("누르면 [text] 를 클립보드에…")이 `_PresenterPinRow` 위로 딸려 갔다(`praise_home_page.dart:18031-18032` 두 줄이 이어 붙음, `_CopyTextButton` 은 주석 없음).
- PIN 바꾸기 뒤 `await _presenterPinStore.save(pin)` 사이에 바깥 창을 닫으면 `setDialogState` 가 사라진 창에 불린다(`:2136-2138`). 저장이 빨라 사실상 안 일어나며, 일어나도 비동기 콜백 오류 로그 정도. 저장 실패(`save` 가 오류를 삼킴)도 사용자에게 안 알린다 — 다음 실행 때 옛 PIN 으로 돌아간다.
- 틀린 PIN 응답은 POST 결과 페이지라 휴대폰에서 새로고침하면 "양식 다시 제출" 확인이 뜬다(브라우저 동작, 미확인 — Chromium 데스크톱 흉내에서는 보지 않음).

### 확인했고 문제없던 항목

- **발표자 전용 값 누출 없음**: 싱어 쪽(`p` 없음) `/state` 키는 `current,next,page_number,total_pages,blackout` 뿐. `/pages`·`/img/page`·`/control`·`/events`·`/state` 의 `p=1` 은 PIN 쿠키 없으면 모두 401(검사가 `switch` 앞 한 곳이라 경로별 빠짐이 없다, `singer_web_server.dart:517-522`).
- `/img/current`·`/img/next` 는 PIN 없이 된다 — 싱어창이 원래 보는 현재·다음 그림이라 문제 아님. 썸네일(`/img/page/<n>`, 모든 페이지)은 `p=1` + PIN 이 있어야 한다.
- 쿠키: HttpOnly(JS 로 못 읽음), SameSite=Lax, 1년, Path=/. 썸네일 `<img>` 요청에도 저절로 실림(로드 확인).
- `/events?p=1` 401 → EventSource `readyState 2` → `onerror` 의 확인 fetch → reload → PIN 페이지(되풀이 없음). https(터널) 폴링 쪽은 `poll()` 이 `checkPin` 을 부른다(코드 확인, 실제 터널은 미확인).
- `_ensurePresenterPin` 은 서버를 켜는 두 경로(`_restartMobileWeb` `:1966`, `_showMobileSingerDialog` `:1990`) 모두 `start` 앞에 있다. `_singerWeb.start(` 호출은 이 두 곳뿐(grep). 자동 다시 켜기는 다이얼로그를 한 번 연 뒤에만 돌아 이미 PIN 이 들어 있다.
- PIN 이 비면 발표자 쪽 아무도 못 들어옴(단위 테스트). `PresenterPinStore.load` 는 오류를 삼키고 늘 4자리를 돌려준다.
- 다이얼로그 PIN 표시 갱신: 바꾼 뒤 `setDialogState(() {})` → `_PresenterPinRow(pin: _singerWeb.presenterPin)` 다시 그림(코드 확인, 실제 앱 화면은 미확인).
- 잠금: 5번째 틀림부터 잠금 문구, 잠긴 동안 맞는 PIN 도 거절, 30초 뒤 들어감, 잠금 중에도 쿠키 있는 휴대폰은 계속 동작.
- 서버 껐다 켜도 같은 포트·쿠키로 바로 발표자(새로고침 없이·새로 열어도).

## 사용자 결정 필요 사항

1. **4자리 PIN 의 강도**(낮음-3·4): 지금은 "같은 와이파이의 장난 방지" 수준(한 기기로 한 시간에 약 6%). 그대로 둘지, 6자리로 늘리거나 잠금을 점점 길게(30초 → 1분 → 5분) 할지. 터널에서는 남이 틀려 주면 진짜 발표자가 30초씩 못 들어오는 점도 같이 정해야 한다.
2. **PC 화면에 PIN 이 크게 보인다**(`_PresenterPinRow`): PC 모니터를 프로젝터에 "복제"로 띄우는 교회라면 휴대폰 화면 창을 여는 순간 PIN 이 관객에게 보인다. 가려 두고 '보기'를 눌러야 보이게 할지.
3. (지난번 미결) '끄기'를 안 눌렀으면 다음 발표 때 묻지 않고 다시 연다(지난 낮음-3). PIN 덕에 위험은 싱어창 가사 열람뿐.
4. (지난번 미결) 터널 주소는 발표마다 바뀐다 — 문구로 해결했지만 터널을 앱 실행 동안 살려 둘지(그러면 쿠키도 유지되어 PIN 도 다시 안 물음, 대신 그동안 인터넷에 열려 있음).

## 남은 미확인 항목

- 실제 iOS Safari·안드로이드 Chrome·카카오톡 인앱 브라우저: 쿠키 1년 유지(인앱 브라우저·개인 정보 보호 모드에서 쿠키가 지워지면 다시 묻는다), 폼 POST 의 Origin 값, `type="tel"` 숫자 자판, EventSource 401 처리(Safari 가 `readyState 2` 로 가는지).
- cloudflared 터널: 터널이 원래 Host(`*.trycloudflare.com`)를 그대로 넘기는지 — Origin 검사가 `Host` 와 비교하므로 Host 를 `127.0.0.1:<포트>` 로 바꿔 넘기면 **터널 쪽 모든 POST(로그인·조작)가 403** 이 된다. 이 환경에 cloudflared 가 없어 확인 못 했다. 다음 실제 기기 시험에서 꼭 볼 것.
- 실제 앱(`flutter run -d macos`/Windows)에서 휴대폰 화면 창의 PIN 줄·바꾸기 창 모양, 바꾼 뒤 표시 갱신 — `_PresenterPinRow`·`_askPresenterPin` 이 private 이고 `PraiseHomePage` 를 띄우지 못해 코드 리뷰 + 같은 구조 복사 위젯 테스트로만 판정.
- 중간-1 이 릴리즈 빌드에서 증상이 있는지.
- `presenter_pin.txt` 저장 실패(권한 등) 때의 실제 동작 — 단위 테스트는 정상 경로·깨진 파일만 본다.
