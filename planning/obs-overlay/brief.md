# 팀장 지시서 — OBS 브라우저 소스용 찬양·말씀 자막

## 사용자 요청 (원문 요지)
- 지금 발표 중인 찬양·말씀 화면을 **OBS 의 '브라우저' 입력 소스**로 추가할 수 있게 한다.
- 관객 화면과 **내용은 같지만** OBS 에 얹는 별도 화면이다. 위치·크기는 OBS 안에서 조절한다.
- 지금 방식: OBS 화면 하단에 영역을 잡고, PPT 를 특정 배경색으로 띄워 크로마키로 빼서 표시한다.
  → 자막 싱크 맞추기 어렵고, 결국 OBS 에서 찬양·말씀을 한 번 더 작업해야 하는 번거로움.
- 목표: 앱에서 페이지를 넘기면 OBS 자막도 **바로 같이** 넘어가고, 배경은 **투명**(크로마키 불필요).

## 팀장이 정한 방향(초안 — 기획자가 다듬고 결정할 것 표에 올린다)
- 앱 안 HTTP 서버가 `http://127.0.0.1:<고정 포트>/obs?k=<고정 키>` 페이지를 준다. OBS 브라우저 소스에 이 주소를 넣는다.
  OBS 브라우저 소스(CEF)는 페이지 바탕이 투명하면 투명으로 합성한다(body background 투명) — 사실 여부는 기획서에 '미확인/사용자 확인' 으로 적는다.
- 페이지 갱신은 SSE(같은 PC 라 터널 문제 없음). 기존 `SingerWebServer`(lib/src/features/praise/data/singer_web_server.dart) 와 **따로 둘지 합칠지** 결정 필요:
  - 싱어 서버는 휴대폰 버튼으로만 켜지고, 켤 때마다 토큰·포트가 바뀌고, 발표 종료 시 꺼진다 → OBS 는 한 번 설정해 두고 계속 써야 하므로 **고정 포트·고정 키·앱 켜 있는 동안 상시** 가 필요.
- 내용: 가사(원본·보조·추가 보조)·성경 본문(+참조 제목). PPT 그림 페이지·편집 페이지(구운 PNG)·빈 페이지·미디어는? 블랙아웃은 OBS 자막도 감추나? 결정 필요.
- 디자인: OBS 는 방송 화면 위 자막이라 관객 화면 디자인(배경·위치)을 그대로 쓰면 맞지 않다. 'OBS 자막 디자인'(글꼴·크기·색·외곽선·그림자·반투명 띠·정렬·줄 수) 을 따로 두는 안 vs 관객 디자인 글자 설정을 따르는 안.
  캔버스는 1920x1080 투명 페이지로 두고 아래쪽에 자막을 그리는 안(OBS 에서 크롭·이동) vs 자막 크기에 맞춘 띠 페이지(OBS 에서 소스 크기 지정) — 추천안 포함.
- 페이드 전환(선택), 다음 페이지 미리 로드 없음(텍스트라 즉시).
- 설정 UI: 앱 바 '발표 시작' 옆 모니터 버튼 근처 또는 리본 '공통' 탭에 'OBS 자막' — 주소 복사·켜기/끄기·디자인·미리보기.
- 발표 전(발표 보기 탭에서 페이지 고르기만 할 때)에도 OBS 로 나갈지? 기본은 발표 중에만.

## 참고할 기존 코드·문서
- CLAUDE.md (반드시 먼저 읽기 — 용어: 원본·보조·추가 보조, 관객 화면, 싱어 화면, 발표 보기, 통역 화면(B))
- lib/src/features/praise/presentation/slide_page_data.dart (관객 화면 한 페이지 JSON, forB 참고)
- lib/src/features/praise/data/singer_web_server.dart (HTTP·SSE·토큰·포트 선택, singerPageHtml)
- lib/src/features/praise/presentation/praise_home_page.dart 의 `_sendCurrentSlide`(2494행 부근)·`_sendSingerView`(2317행 부근)
- lib/src/features/praise/domain/export_style.dart, data/export_style_store.dart, data/b_screen_store.dart(설정 json 저장 패턴), data/atomic_file.dart
- 기존 기획서 형식: planning/trilingual-display/plan.md

## 산출물 위치: planning/obs-overlay/
## 규칙: 한국어, 확인 안 된 것은 '미확인', 수치·버전 지어내지 않기. 앱 코드는 고치지 않는다(문서만).
