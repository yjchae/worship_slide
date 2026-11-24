# QA 3단계 1회차 — PPTX → 편집 페이지 가져오기

## 판정: 반려 (차단 0 · 주요 2 · 경미 6)

## 수용 기준 (plan.md 3단계 + decisions + shapes-contract + design s6)
- [x] 16:9 PPTX → 슬라이드 수만큼 편집 페이지(ImageStagingItem + page_elements), 파일 이름 그룹으로 콘티 끝 — 코드 확인(`praise_home_page.dart:5130-5260`), `test/ppt_layout_import_test.dart` 통과. 단 결함 1(페이지 사이 자동 여백) 때문에 발표 순서는 기준 미달
- [x] 위치 1%·글자 크기 ±0.5(13.333x7.5 / 10x5.625 / 4:3) — `python/test_pptx_layout.py`(두 번 굽기 포함) 통과
- [x] 마스터 상속(제목 자리표시자 크기·색·글꼴) — self-check 통과. 실제 PowerPoint 화면과의 눈 비교는 하지 않음
- [x] 표·회전·그라데이션 등은 배경 그림, 결과 창에 개수 — 견본 4개에서 `dropped` 까닭이 모두 계약 목록 안, 결과 창 합계 = Σdropped(위젯 테스트)
- [x] 4:3 — 결정 4(여백 두고 편집 페이지로 만듦)대로. 견본 D: letterboxed true, 배경 PNG 1920x1080 양옆 검정 확인
- [x] 없는 글꼴 — 결과 창 '없는 글꼴' 줄, 편집 창 글꼴 칸은 기존 '(없는 글꼴)' 표시(`style_fields.dart:326`)
- [x] 가져온 페이지 sourcePath null(원본 열어 수정 없음) — `ImageStagingItem(sourceName, imagePaths)` 만
- [x] 기존 'PPT · PDF 가져오기' 경로 변경 없음 — `render`·`_addPptImages` diff 없음, test_render·test_animation·test_media 통과
- [x] 숨긴 슬라이드 건너뛰기(결정 8) — 굽기 사본에서 show 를 풀어 쪽 수를 맞춤(`pptx_layout.py:938`). 숨긴 장 섞인 .pptx·.ppt 를 실제 LibreOffice 로 구워 index·hidden·배경 대응 확인
- [x] LibreOffice·PowerPoint 둘 다 없음 → `{"error":"libreoffice_missing"}` → 설치 안내창 → 설치 뒤 같은 파일 다시(`:5176-5184`)
- [x] PyInstaller 번들에 `pptx_layout` 포함 — build.sh 와 같은 옵션으로 스크래치에 빌드, xref 에 pptx_layout 있음, 번들 실행 파일로 견본 layout 성공
- [ ] 견본 정보가 공개 레포에 없음 — 결함 2

## 결함
1. [주요] 가져온 편집 페이지마다 뒤에 자동 여백(빈 장)이 붙는다
   - 재현: 20장 PPTX 를 '콘티에 담기' → 발표 보기/PPTX 내보내기
   - 기대 / 실제: PPT 처럼 20장이 이어짐(끝에만 여백) / 장마다 별도 ImageStagingItem 이고 `_noSpacerUids` 에 안 넣어서 `_allSlides`(`praise_home_page.dart:1285`)·PPTX export(`ppt_tool.py:2076`)가 장 사이마다 여백을 끼운다(39장). 여백은 그 장의 배경 PNG(글 뺀 배경)를 써서 '글 없는 원본 장'처럼 보인다
   - 위치: `praise_home_page.dart:5240-5256` (`_trackedEdit` 안 루프)
   - 수정안: 같은 edit 안에서 마지막 페이지를 뺀 uid 를 `_noSpacerUids.addAll(...)` (끝 여백은 기존 PPT 항목처럼 남김). 위젯/순수 테스트 하나로 고정
2. [주요] 테스트에 실제 견본 파일 이름(개인 이름 포함)이 들어 있음 — 공개 레포 유출
   - 위치: `test/ppt_layout_import_test.dart:138` (`source_name` 값)
   - 수정안: '아주 긴 강의 파일 이름 (설교자)/x.pptx' 같은 가짜 이름으로. planning/ 문서는 grep 결과 견본 이름·글 내용 없음(`samples-analysis.md` 는 통계만)
3. [경미] 취소가 ppt_tool 을 멈추지 않는다 — 창만 닫고 프로세스는 끝까지 돈다(`:5151-5160`). 계약(shapes-contract '취소는 프로세스를 죽이고')과 다르고, 취소 직후 다시 가져오면 LibreOffice/PowerPoint 가 겹쳐 돈다. 앱을 그사이 끄면 `ws_ppt_layout_*` 가 임시 폴더에 남는다. 수정안: `Process.start` + kill 을 받는 `layout` 변형
4. [경미] 진행 창에 '(슬라이드 n / N)' 이 없다(design s6 로딩 문구) — `:5150`. 한 번의 프로세스라 n 을 못 받으므로 문구를 design 쪽에서 고치거나 stderr 진행 줄을 더해야 함
5. [경미] 복사·굽기 실패가 조용하다 — `library.register` 실패(`:5207`) 시 그 장은 검정 배경/그림 빠짐으로 담기고 로그만 남는다. 모든 장 굽기 실패(made 비어 있음)면 이미 복사한 page_images 사본이 남는다. 수정안: 실패 수를 완료 스낵바에 함께 알림(굽기 실패처럼), made 비면 사본 지우기
6. [경미] .ppt + PowerPoint 만 있는 PC: pptx 변환이 LibreOffice 전용이라 `libreoffice_missing` → 안내 문구 'PowerPoint 나 LibreOffice 가 있어야'(`:5180`)가 PowerPoint 가 있는 사람에게 헷갈린다. .ppt 면 'LibreOffice 가 필요' 로
7. [경미] `uniqueGroupName` 에 `trimRight` 추가(`conti_tree.dart:657`)는 공용 함수 동작 변경(그룹 만들기·이름 바꾸기·붙이기에도 적용 — 개선이지만 이번 범위 밖)이고, 테스트 주석 `test/ppt_layout_import_test.dart:134` '공백을 다듬지 않는다(기존 동작)' 는 이제 틀림
8. [경미·환경] 이 Mac 에서 PowerPoint 변환이 매번 -9074(한 번은 AppleEvent 시간 초과)로 실패하고 LibreOffice 로 구워졌다. 기존 render 경로와 같은 문제로 보이며 3단계 코드 결함은 아님 — PowerPoint 쪽 굽기 품질은 이번에 확인 못 함

## 실행한 확인
- `flutter analyze` — No issues found
- `flutter test` 전체 — 815개 통과
- `.venv/bin/python3 python/test_pptx_layout.py` — ok (두 번 굽기 포함)
- 기존 `python/test_*.py` 12개 — 모두 통과
- 견본 4개 `ppt_tool.py layout` (스크래치 폴더, 각 3~7초): 계약 검사 스크립트로 키 집합·dropped 까닭·rect 범위·id 16hex·font_size 8~300·색 #RRGGBB·shape/align/valign 값·그림/배경 경로 존재·배경 1920x1080·rich 의 글 = text — 위반 0. 요소 합 59/74/82/51, rich 12/11/16/22
- 견본 출력 JSON 을 스크래치의 flutter test 로 `PptLayout.fromJson` → `pptLayoutPages` → `PageElement.listFromJson`·`pageRichLinesFromOps` 로 읽음 — 요소 수 그대로, rich 줄 글 = text, clampRect 로 옮겨진 요소 2개(4:3 견본)
- 오류 경로: 없는 파일·깨진 파일 → 종료 코드 1(앱은 '열지 못했습니다' 스낵바), LibreOffice·PowerPoint 없음(함수 바꿔치기) → libreoffice_missing, .ppt 입력(LibreOffice 변환) 성공, Python 임시 폴더 남지 않음
- PyInstaller(build.sh 옵션, 스크래치 dist) 빌드 → 번들로 견본 layout 성공
- 작업 폴더 정리: 코드 확인 — 실패·LibreOffice 없음·취소·담지 않기·굽기 완료(finally) 모두 `dropWork`. 발표 중 넣기·되돌리기는 `_trackedEdit`(보던 슬라이드 키 유지, `_VoiceUndo` 가 배경·그룹·여백 포함) — 코드만 읽고 판단
- 같은 파일 두 번: 작업 폴더·register 이름(시각 접두)이 매번 새로, 그룹 이름 ' (2)' — 코드·단위 테스트로 확인
