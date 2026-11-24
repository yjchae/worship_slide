# QA 검토 — PowerPoint 방식 슬라이드 편집 (기획 문서 단계)

검토: QA · 2026-11-24 · 대상: plan.md · tech-frontend.md · tech-backend.md · design.md · mockup.html · screens/s1~s6.png
앱 코드는 고치지 않았다. 실행한 것: `flutter test test/page_editor_test.dart test/page_image_test.dart test/page_rich_text_test.dart test/page_template_test.dart test/page_to_free_test.dart` → 43개 모두 통과(기준선).
'코드 확인' = 이 레포 소스를 읽어 확인. '미확인' = 실행·실측 못 함.

## 판정: 반려 (차단 3 · 주요 9 · 경미 6) — 문서끼리 결정이 엇갈려 이대로는 개발 착수 불가

---

## 1. 문서 간 모순 + 추천 통일안

| # | 주제 | plan | backend | frontend | design | 추천 통일안 |
|---|---|---|---|---|---|---|
| M1 | **도형 JSON 키** | `shape`(모양) · `fill` · `fill_alpha` · `stroke` · `stroke_width` · `radius` · `flip_h/v` · `valign` | `shape` · `fill`(`#AARRGGBB` 허용) · `line_color` · `line_width` · `rotation` · `valign` | `kind` · `fill` · `stroke` · `stroke_width` · `flip_h/v` · **`v_align`** | 투명도 슬라이더 있음 | 한 벌로 고정: `type:"shape"`, **`shape`**(모양), `fill`, **`fill_alpha`**(0~1, 색은 6자리 유지 — 기존 `colorToHex` 규칙), `stroke`, `stroke_width`, `flip_h`, `flip_v`, **`valign`**(밑줄 없음, plan·backend 다수). `radius`·`rotation` 은 이번엔 넣지 않음(아래 M8). 저장 형식은 되돌리기 어려우므로(plan 결정 11) **개발 전에 이 표 하나를 plan 에 박는다** |
| M2 | 모양 종류 | 5종 | triangle·right_arrow 등 "앱이 그릴 줄 아는 것" | 5종 enum | 5종 | 5종(rect·round_rect·ellipse·line·arrow). backend 의 triangle 등은 3단계에서 배경 그림 |
| M3 | 모르는/틀린 값 | "기본값으로" | 모르는 `shape` → rect | "틀린 값 버림" | — | 모르는 `shape` → rect(요소 보존), 숫자 틀림 → clamp, 필수(rect) 없음 → 요소 버림 |
| M4 | 두께 범위 | 0~40 pt | 0~50 | 0.25~20 | pt ▾ | 0~20(0 = 테두리 없음과 같게 다룰지도 정함). 4곳 다 같은 상수 |
| M5 | **편집 중 되돌리기 단위** | 편집 시작~끝 = 한 묶음(수용 기준 "⌘Z 한 번에 통째로") | — | 창 되돌리기로 덮고 **1초 멈춤마다 묶음 끊기** | 결정 2 추천 **B: Quill 안 글자 단위**, 끝난 뒤 창 되돌리기 | 셋이 다 다르다. 추천: design B(편집 중엔 Quill 자체 undo, 편집을 끝내면 그 묶음이 창 기록 1건). 단 그러면 frontend 1-5 의 `customActions` 덮기·1초 타이머는 빼고, plan 수용 기준 문구를 "편집을 끝낸 뒤 ⌘Z 한 번 = 그 편집 통째" 로 고친다. 편집 중 ⌘⇧Z 처리(Quill 은 ⌘Y 만)도 명시 |
| M6 | **오른쪽 패널** | 폭 320(지금 코드 :967), 글 상자 = 위치·크기 숫자(없애도 됨, 결정 4) | — | 폭 **260**, 글/도형 = 넘침 경고+안내, 숫자 언급 없음 | 폭 **300**, 글/도형 = X·Y·폭·높이 숫자(1920×1080), 그림 = 설정+위치 | 폭 300 하나로. 내용 = design(숫자 칸) + frontend 의 넘침 경고 한 줄. 숫자 칸은 새 입력 4개라 1단계 작업량에 넣을지 사용자 결정 |
| M7 | **가져오기 결과 창 시점** | 결과 창 → 콘티 끝에 담긴다(담은 뒤 알림으로 읽힘) | — | 편집 창 아래 메시지 줄에 경고 한 줄 | 결정 3 추천 **A: 담기 전**, '담지 않기'/'콘티에 담기' (s6 캡처도 이것) | design A. plan 6번 흐름을 "결과 창(담기 전) → '콘티에 담기'" 로 고친다. frontend 의 '편집 창 메시지 줄'은 결과 창과 별개로 둘지 결정 |
| M8 | 회전 | 회전 요소 → 배경 그림, 회전 손잡이는 다음 단계 | 모든 요소 공통 `rotation` 칸 제안 | 모델에 회전 없음, 회전 글 → 회전 없이+경고 또는 그림 | s6 '회전한 도형 → 배경 그림' | plan·design 대로 **회전 = 배경 그림**, `rotation` 칸 안 만듦 |
| M9 | **Python 명령 이름·출력** | `layout <pptx> <작업 폴더>` → `{slides:[{index, hidden, aspect_ok, background_png, elements, dropped:{picture_as_background, effects_lost, fonts_missing}}]}` | `shapes <pptx> <out_dir>` → `{slide_width, slide_height, slides:[{index, background:{color,image}, elements, dropped:[{kind,name}]}], warnings}` + `missing_fonts` | `warnings:[{kind,count}]` 요청 | 수용 기준이 "`layout` 출력의 합" | 이름은 `layout`(design 수용 기준과 맞음). 출력은 plan 모양을 기본으로 하되 결과 창 '어느 장인지 보기'·'12, 13번째 장' 표시(s6)에 장 번호가 필요하므로 `dropped` 는 슬라이드마다 개수 + 전체 `skipped:{aspect:[번호], hidden:[번호]}`. backend·frontend 문서를 이 모양으로 고친다 |
| M10 | **배경 그림 만드는 방법(두 번 굽기)** | 요소로 바꾼 도형을 지운 사본을 render 로 구워 `background_png` — 표·차트·마스터 그림·그라데이션이 다 여기에 | 두 번 굽기 없음. 배경 = XML 의 색·그림만, 못 옮기는 것은 1차 **버림**(가), 2차 원본 렌더에서 잘라 쓰기(다) | 표 등은 렌더 PNG 에서 잘라 그림 요소, 안 되면 빼고 경고 | s6 "페이지 배경 그림에 들어갔습니다" | 근본이 다르다. plan(두 번 굽기)이 결과 창 문구·수용 기준("표·차트가 배경 그림에 있다")과 맞으므로 plan 채택. 그러면 backend 2-5 '마스터 비-placeholder 도형을 요소로'·2-6 (가)(다)는 폐기, LibreOffice/PowerPoint 필수 의존성이 됨(backend "pptx 는 둘 다 없어도 됨" 폐기) |
| M11 | **`_renderVersion`** | 안 올림(`page_rich_text` 그대로) + 수용 기준 "옛 페이지를 그대로 완료하면 같은 PNG 경로" | 2 로 올림 | 2 로 올림(굽기 렌더러를 줄 단위 `PageTextBlock` 으로 교체) | — | frontend 안을 받으면 plan 의 수용 기준(같은 캐시 키)과 정면 충돌. 추천: **1단계는 렌더러 그대로, `_renderVersion` 1 유지**(plan) — 편집 중 목록 줄 차이는 감수. 줄 단위 렌더러 교체는 별도 작업으로 떼고 그때 2 로 올리며 위 수용 기준을 지운다. 사용자 결정 필요 |
| M12 | **4:3 슬라이드** | 편집 페이지로 안 만들고 '16:9 가 아님 N장' | **레터박스**로 가운데 맞춤(`test_shapes.py` 도 레터박스 기대) | backend 규칙 따름 | s6 '만들지 않았습니다' | plan·design(건너뛰기). backend 2-2 레터박스 공식·테스트 항목을 "aspect_ok=false 로 표시" 로 바꾼다. 경계(16:10 등 허용 오차)를 숫자로 정한다 — 미정 |
| M13 | **숨긴 슬라이드** | 결정 8 추천 A 건너뛰기, 출력에 `hidden` | 언급 없음 | 언급 없음 | 결과 창 '숨긴 슬라이드 n장 건너뜀' | A + 결과 창 알림. 단 두 번 굽기에서 장 번호 어긋남 위험(R-B2) |
| M14 | **`PageUnknownElement`** | "막는 장치 만들지 않는다", 수용 기준 = 옛 코드로 읽으면 도형만 빠짐 | **이번 판에 넣자**(모르는 type 을 날 맵 그대로 보존) | 언급 없음 | — | 넣는다(backend). 옛 앱은 못 고치지만 **이번 판 이후** 새 요소(표 등)가 사라지지 않는다. plan '기존 데이터 호환'에 추가. 편집 창 요소 수·순서 버튼·`_confirm` 에서 이 요소가 섞여도 순서 보존 테스트 필요 |
| M15 | 기존 type 에 더한 칸(`valign` 등)의 옛 앱 소실 | "valign 무시되어 위 맞춤" | 옛 앱 `toJson` 이 모르는 칸을 버린다(저장 시 소실) | — | — | backend 가 맞다(옛 `toJson` 은 아는 칸만 씀 — 코드 확인 `page_element.dart`). plan 호환 표에 "옛 앱으로 콘티 **저장**만 해도 도형·valign 이 JSON 에서 사라진다(PNG 는 남음)"를 추가 |
| M16 | 문단 정렬 | 결정 7 추천 A(첫 문단 정렬) — 그런데 같은 문서 '떨어뜨리는 것'(:113)엔 "문단마다 정렬 다른 글 상자 → 배경 그림" | 첫 문단(또는 가장 많은 쪽) + warnings | **줄 속성 `align` 지원**(사실상 C, `normalizeRich`) | 리본 정렬은 '상자 단위' | plan 안에서도 모순. 추천: 1~3단계는 A(상자 단위), frontend 1-3-2 줄 align 은 다음 단계. 단 Quill 에 상자 align 을 넣어야 편집 중 가운데 정렬이 보이므로 `_loadQuill` 주입 + `_quillRich` 제거(normalizeRich)는 1단계에 필요 — 저장엔 align 이 안 남게 |
| M17 | 글 효과·그라데이션 도형 | 결정 6 A(효과 버리고 글은 요소), 그라데이션 도형 → 배경 그림 | 그라데이션 → 첫 정지점 단색, 워드아트·그라데이션 글자 → 버림 목록 | 그라데이션 → 단색+경고 | — | plan 대로(그라데이션 도형 = 배경 그림). backend 2-5 '첫 정지점 색' 삭제 |
| M18 | 그룹 | 자식 모두 받을 수 있으면 평평하게, 아니면 그룹째 배경 그림 | 늘 평평하게 + 그룹 회전 계산 | 늘 평평하게 | — | plan. 회전 그룹은 배경 그림이라 회전 계산 불필요 |
| M19 | 투명도 | `fill_alpha` + 수용 기준 0~100% | `#AARRGGBB` | "투명도는 받지 않는다" | 슬라이더 0~100% | plan(`fill_alpha`). frontend 3-1 고침 |
| M20 | 단계 번호 | 1=편집 2=도형 3=가져오기, 내보내기 B 는 다음 | 1=도형 2=가져오기 **3=내보내기 B** 4=가져오기 2차, "B 를 2단계에" 추천 | 1~6 작업 순서 | — | plan 번호로 통일, 내보내기 B 는 범위 밖(plan 결정 10) — backend 3·4절을 '다음 단계' 로 표시 |
| M21 | 둥근 사각형 반경 | `radius` 칸(기본 0.1667) | 조정값 뺌 | 0.1667 고정 | — | 고정(칸 없음). 가져올 때 `adj` 차이는 감수 |
| M22 | 확인 버튼 이름 | '완료' | — | — | '확인'(s2) | 지금 코드는 **'확인'**(page_editor_dialog.dart:1892). 문서를 '확인'으로 |
| M23 | 여러 개 고르기·범위 끌기·맞춤 | 1·2단계 범위 | — | **설계 없음**(`_selectedIds`·범위 사각형·맞춤 계산 미기술) | s5 있음 | frontend 문서에 추가 필요(누락, 2절 참고) |
| M24 | 상자 선택 + 글자 키 | 결정 3 추천 A(편집 시작 + 끝에 덧붙임) | — | 키 표에 없음(Enter 만) | Enter·F2 만 | A 로 정하면 frontend 키 표에 추가, 한글 IME 첫 글자 조합이 덧붙여지는지 사람 확인 |
| M25 | 기준선 테스트 수 | — | — | 41개 | — | page_to_free_test 포함 43개(이번 실행). 문서 갱신만 |

---

## 2. 빠진 경로 (코드 확인)

| 경로 | 지금 코드 | 빠진 점 | 등급 |
|---|---|---|---|
| `page_to_free.dart:92` `freePageElements` | 글 높이를 `pageTextSpan(body, 1)` 로 잰다. `test/page_to_free_test.dart` 있음 | plan 은 이 파일을 언급 안 함. frontend 안(렌더러 교체)이면 측정이 바뀌어 '편집 페이지로 바꾸기' 상자 자리가 달라진다. 기획 테스트 목록에 page_to_free_test 추가 필요 | 주요 |
| `praise_home_page.dart:9117~9134` 콘티 목록 둘째 줄 | 글은 `PageTextElement` 만, 없으면 `'그림 ${whereType<PageImageElement>().length}장'` | 도형만 있는 페이지 → '그림 0장'. 도형 안 글은 미리보기에 안 나옴. plan 미언급(frontend 3-2 에만 "팀장 확인 필요") | 주요 |
| `page_template_dialog.dart:297~300` 틀 목록 | 그림 수 = 전체 − 글 | 도형이 '그림'으로 세어짐. plan '틀은 같은 규칙'만 있음 | 경미 |
| `_restoreFreePages`(praise_home_page.dart:3797~) | PNG 없으면 요소로 다시 굽기 | ① 가져온 페이지의 `background_png`(page_images) 가 없으면 배경 없이 구워지는지 확인 없음 ② 없는 글꼴 페이지는 대체 글꼴로 조용히 구워짐(알림 경로 없음) ③ 옛 앱에서 도형 소실(M15) | 주요 |
| 항목 배경 다이얼로그(praise_home_page.dart:4860) | 편집 페이지면 `withPageElementsOf` 로 요소 붙여 다시 굽기 | 가져온 페이지의 '가져온 배경'(모음 밖 경로)이 이 다이얼로그 갤러리에서 어떻게 보이는지 — plan 은 편집 창만 "확인 필요". 여기서 색을 바꾸면 가져온 배경 그림이 사라짐 | 주요 |
| `_convertPageToFreePage`·`_editFreePage`(:2615~2720) | 같은 `PageEditorDialog` | 리본·캔버스 편집이 이 길(발표 보기 연필)에서도 같은지, 발표 중 편집 창 키(←/→)가 발표로 새지 않는지 테스트 항목 없음 | 경미 |
| `.wsconti` 가져오기·저장 `saveConti` | `SlideBackground.encode` 로 객체에서 다시 씀(worship_conti_repository.dart:240), 불러올 때 decode(:387, :414) | `PageUnknownElement` 를 안 넣으면 이번 판 이후 새 요소도 저장 한 번에 사라짐. 가져온 페이지의 그림 요소·배경 그림은 `_backgroundPathSlots`(:770) 가 실어 나름 — 그대로 됨(코드 확인) | 주요(M14 결정에 달림) |
| 3단계 메뉴의 LibreOffice 자동 설치 뒤 '하던 일 다시 하기' | 폴더 가져오기·PPT 이미지 넣기만 다시 함 | 새 가져오기도 설치 뒤 재시도 길에 넣어야 함(plan 은 '설치 안내 띄움'까지만) | 경미 |
| 가져오기 진행 '취소' | design 에만 있음 | Python 프로세스 죽이기·작업 폴더 치우기·page_images 에 복사한 파일 처리 미기술 | 주요 |
| 가져오기 되돌리기 | 없음 | 21장을 담았다가 잘못이면 하나씩 지워야 함. `_trackedEdit`/⌘Z 에 넣을지 미기술. 발표 중 가져오기 허용 여부도 없음 | 경미 |
| 두 번 굽기 캐시 | `get_ppt_cache_key`(ppt_tool.py:311) = 경로+크기+mtime | 지운 사본은 매번 새 임시 파일 → `ppt_slides/<해시>/` 에 가져올 때마다 새 폴더, 지우지 않는 규칙이라 계속 쌓인다. 배경은 page_images 로 복사한다면 렌더 폴더는 지워도 되는지 정해야 함 | 주요 |
| 싱어·휴대폰 썸네일·통역(B)·관객·PPTX | 모두 구운 PNG(`imagePaths`)만 봄. `exportPayload` 는 `page_elements` 를 싣지만 Python `add_image_slides` 는 무시 | 변경 없음 — 맞다(코드 확인). 다만 PPTX 내보내기 payload 에 도형 JSON 이 실려도 Python 이 안 깨지는지 1회 확인(미확인, 무시할 것으로 보임) | — |
| 편집 창 다중 선택 + 그림 '원래 비율로'·붙여 넣기(⌘V) | 단일 선택 전제 | `_selectedId` → `_selectedIds` 로 바꿀 때 영향 받는 함수 목록이 어느 문서에도 없음 | 주요 |
| 선 요소 rect 높이 0 | `clampRect`·`_parseRect`(w·h > 0) 가 막음 | frontend 만 다룸. plan JSON 정의·backend 출력(가로선 높이 0)에도 반영 필요, 안 하면 가져온 선이 `fromJson` 에서 버려짐 | **차단** |
| CLAUDE.md · `python/test_*.py` 목록 · PyInstaller 재빌드 안내 | — | 새 명령·새 파일 추가 시 갱신 항목 | 경미 |

---

## 3. 등급별 위험

### 차단
- **B1 도형 JSON 키 미합의(M1)**: 세 문서가 각각 `kind`/`shape`, `stroke`/`line_color`, `valign`/`v_align` 을 쓴다. 백엔드 출력과 프론트 `fromJson` 이 어긋나면 가져온 도형이 조용히 다 버려진다(모르는 type·필수 칸 없음 → null). 저장 형식은 한 번 퍼지면 못 바꾼다.
- **B2 두 번 굽기 장 번호 대응(M10·M13)**: `render` 는 숨긴 슬라이드 처리 코드가 없다(ppt_tool.py 에 `show="0"` 처리 없음, 코드 확인). LibreOffice·PowerPoint 가 PDF 에서 숨긴 장을 빼면 `background_png` 가 한 장씩 밀려 **다른 슬라이드의 배경이 붙는다**(빼는지는 미확인 — CLAUDE.md 도 PowerPoint 쪽 미확인으로 적음). 애니메이션 펼치기를 끄는 것(`--no-animation`)도 필수. 장 수가 다르면 가져오기를 막는 검사가 필요.
- **B3 선·화살표 높이 0(2절)**: 지금 `clampRect`·`_parseRect` 로는 가로선 자체를 저장·읽기 못 한다.

### 주요
- M5 되돌리기 단위 미정 — 수용 기준이 서로 반대라 테스트를 쓸 수 없다.
- M11 `_renderVersion` — 올리면 plan 수용 기준 "같은 PNG 경로"가 깨지고, 안 올리면 frontend 렌더러 교체가 캐시된 옛 PNG 와 섞인다.
- Quill 편집 ↔ `Text.rich` 굽기 줄바꿈 불일치(plan 위험 1) — 실험 전 미확인. 목록 줄은 거의 확실히 다르다(frontend 1-3 표, 소스 확인).
- 편집 중 끌기(글자 고르기) vs 테두리 띠 옮기기, 더블클릭 지연과 원클릭 고르기 충돌 — 위젯 테스트로 고정해야 함.
- 한글 IME(macOS·Windows) 조합 중 Esc·방향키·캐럿·후보 창 위치 — 미확인, 사람 확인 필수. Windows 는 CI 컴파일만.
- 옛 앱 저장만으로 도형·valign 소실(M15) — 여러 PC 교회에서 실제로 생긴다.
- 상속 해석(마스터·레이아웃·테마 색·lumMod) — 실제 교회 PPTX 견본 없음(레포엔 python-pptx 단순 샘플·4:3 `tmp_sample` 뿐).
- 없는 글꼴: Flutter 데스크톱이 시스템 글꼴을 이름으로 찾는지 미확인. frontend 는 "FontLibrary 에 없으면 상자 글꼴로" — 그러면 '맑은 고딕'이 있는 PC 에서도 대체될 수 있음. 결과 창 '없는 글꼴' 판정 기준이 PC 마다 다름.
- 두 번 굽기 캐시 폴더 누적(2절).

### 경미
- 패널 폭 320/300/260, 버튼 이름 '완료'/'확인', 기준선 테스트 수 등 문서 수치 불일치.
- `page_editor_dialog.dart` 1,939줄 — 리본 분리 권고(plan 이미 적음).
- 틀 목록·콘티 목록의 요소 개수 문구.
- 3단계 중 요소 수십 개 페이지에서 글자마다 전체 setState 성능 — 미확인.
- design 결정 5(배분 맞춤) 범위 밖 — 기록만.

---

## 4. 단계별 테스트 항목

### 1단계 — 캔버스 안 편집·리본·여러 개 고르기
자동(위젯·단위)
- [ ] 더블클릭 → 편집 상태(QuillEditor 가 캔버스 안에 생김), 오른쪽 패널에 QuillEditor 없음
- [ ] 리본 '글 상자' → 바로 편집 상태(포커스·캐럿)
- [ ] 편집 중 Delete·Backspace·방향키·⌘A·⌘D·⌘[ ] → 요소 수·순서·rect 그대로
- [ ] ESC 1회 = 편집 끝·고른 채, 2회 = 고르기 해제, 3회 = 창 닫기 흐름이 지금과 같음
- [ ] Enter·F2 → 편집 시작, 캐럿 글 끝
- [ ] 리본 버튼 누름이 편집을 끝내지 않음(포커스 유지)
- [ ] 상자만 고름 + 굵게/색/크기 → 상자 기본값 바뀌고 Delta 에서 그 속성 직접 지정 사라짐, 기울임 등 다른 속성 유지, 기록 1건
- [ ] 편집 중 글자 일부 + 굵게 → 그 글자만
- [ ] 섞인 크기·글꼴·색 → 리본 빈칸(design 수용 기준)
- [ ] 되돌리기 단위(M5 결정 후 그 규칙으로)
- [ ] Shift/⌘·Ctrl+클릭 3개 → 함께 끌기·Delete·⌘Z 1회 복원, 손잡이는 1개 고를 때만
- [ ] 아무것도 안 고름 → 줄 2 전부 `onPressed: null` + 안내문, 캔버스 위쪽 y 고정
- [ ] 모든 아이콘 버튼 `find.byTooltip`
- [ ] `_loadQuill`→`_quillRich` 왕복으로 상자 align 이 rich 에 안 남음(서식 없으면 rich == null)
- [ ] 옛 편집 페이지를 열어 아무것도 안 바꾸고 '확인' → 같은 PNG 경로(M11 결정이 '안 올림'일 때)
- [ ] 기존 page_editor·page_image·page_rich_text·page_template·**page_to_free** 테스트 통과
사람 확인
- [ ] 줄바꿈 일치 실험: 24·40·96pt × Pretendard·NanumMyeongjo × 한/영 3줄 이상 — 편집 중/아닐 때/구운 PNG
- [ ] macOS·Windows 한글 IME: 조합 중 캐럿·후보 창 위치·Esc·방향키, 축소 캔버스 캐럿 보임
- [ ] 편집 중 드래그 = 글자 고르기, 테두리 띠 = 옮기기(트랙패드·마우스 둘 다)
- [ ] 발표 보기 연필(`_editFreePage`)·'편집 페이지로 바꾸기'·틀 편집 모드에서도 같음

### 2단계 — 도형
자동
- [ ] shape JSON 왕복(합의한 키), 모르는 `shape` → rect, 틀린 숫자 clamp, rect 없음 → 버림
- [ ] 선 높이 0 저장·읽기, `lineFromPoints`/`linePoints` 4방향
- [ ] 옛 JSON(valign 없음) → top, 도형 JSON 을 옛 `listFromJson` 규칙으로 읽으면 예외 없이 도형만 빠짐
- [ ] `PageUnknownElement`(채택 시): 모르는 type 날 맵이 저장·`.wsconti`·틀 왕복 뒤 그대로
- [ ] 화면 밖 굽기 픽셀: 채우기 색·투명도·테두리·선 끝
- [ ] 콘티 저장→불러오기, `.wsconti` 내보내기→가져오기 뒤 도형·글·서식 같음
- [ ] 콘티 목록 둘째 줄·틀 목록 개수 문구에 도형 반영, `pageAutoName`·넘침에 도형 글 포함
- [ ] 범위 끌기 고르기, 맞춤(하나 = 슬라이드 기준, 여럿 = 범위 기준), 도형 메뉴 ↓·Enter
- [ ] 선·화살표 고르면 채우기·세로 맞춤·글자 묶음 비활성, 테두리 없음이면 두께 비활성
사람 확인
- [ ] 캔버스와 구운 PNG 의 도형 모양·두께 육안 비교, 가는 선(1pt) 고르기 쉬운지
- [ ] 옛 앱(지금 배포본)으로 같은 콘티 열기·발표·저장 시 동작이 호환 표와 같은지

### 3단계 — PPTX 가져오기
자동(`python/test_pptx_layout.py`, LibreOffice 없으면 두 번 굽기만 skip)
- [ ] 16:9 두 크기(13.333×7.5, 10×5.625) rect 1% 안, 글자 pt × 540 / 높이 ±0.5
- [ ] 4:3 → `aspect_ok=false`, 요소 안 만듦(M12 결정대로)
- [ ] 숨긴 슬라이드 → `hidden`, 건너뜀, **나머지 장의 background_png 번호가 원본 슬라이드와 맞음**(B2)
- [ ] placeholder 제목 크기 = 마스터 titleStyle, schemeClr+lumMod 색, fillRef 채우기
- [ ] 표·차트·회전·그라데이션 → elements 에 없고 dropped 개수, 그룹(받을 수 있음/없음) 둘 다
- [ ] 가로선 출력이 높이 0 으로 나오고 Dart `fromJson` 이 받음(B3)
- [ ] normAutofit fontScale 곱, 빈 placeholder 제외, 그림 srcRect 자르기
- [ ] 출력 JSON 이 Dart `PageElement.listFromJson` 으로 요소 수 그대로 읽힘(교차 테스트 — 두 문서 키 어긋남 잡기)
Dart 자동
- [ ] 결과 창: 각 줄 개수 = 출력 합, 0 인 줄 숨김, '담지 않기' → 콘티 그대로, 편집 0장 → '닫기'만
- [ ] 담기 → 파일 이름 그룹(`uniqueGroupName`), 항목 태그 '편집', sourcePath null('원본 열어 수정' 없음)
- [ ] 기존 '외부 PPT 이미지' 가져오기 결과 불변
사람 확인
- [ ] 실제 교회 PPTX 10개 이상(맑은 고딕·테마 색·사진 배경·표) — 원본과 나란히 비교
- [ ] Windows PowerPoint COM 경로·macOS PowerPoint 샌드박스 허용 창에서 두 번 굽기
- [ ] 없는 글꼴 표시가 실제로 없는 PC 에서만 뜨는지
- [ ] 가져오기 취소 뒤 남는 파일·콘티 상태
- [ ] 가져오기 여러 번 뒤 `ppt_slides/` 폴더 증가량

## 실행한 확인
- `flutter test test/page_editor_test.dart test/page_image_test.dart test/page_rich_text_test.dart test/page_template_test.dart test/page_to_free_test.dart` → All tests passed (43)
- 코드 대조: `page_canvas.dart:118` `_renderVersion = 1`, `page_element.dart:97` 모르는 type → null, `page_editor_dialog.dart:1892` 버튼 '확인', `page_to_free.dart:92` `pageTextSpan` 측정, `praise_home_page.dart:9117~9134` 그림 수 문구, `worship_conti_repository.dart:240` 저장 시 객체에서 재인코딩, `:770` 경로 칸, `ppt_tool.py` 숨긴 슬라이드 처리 없음(grep)
- 화면: screens/s2.png(편집 중·패널 X/Y/폭/높이), s6.png(담기 전 결과 창·16:9 아님 건너뜀·숨긴 슬라이드) 열람. 나머지 캡처는 design.md 서술로 대신함
