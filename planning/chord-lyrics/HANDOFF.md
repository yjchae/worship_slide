# 인수인계 — 코드 가사 (2026-11-07)

브랜치 `claude/chord-lyrics` · 기준 문서 `plan.md`(최종 명세) · 팀 작업 순서 `.claude/skills/feature-team/SKILL.md`

## 지금 상태
- 기획·기술 분석·목업·QA 검토: 끝 (`plan.md`, `tech-*.md`, `mockup.html`, `screens/`, `qa-review.md`)
- 백엔드 B0~B7: 끝 (도메인 `chord_lyrics.dart`, DB v20, saveChords, 동기화 `chords` 구역, 콘티·.wsconti, 누출 테스트)
- 프론트: F1~F7 구현 커밋됨 (가사 수정 창 코드 모드, 싱어 `chord_lines`·`key_label`, 휴대폰 코드 버튼, macOS 싱어 창 코드 줄,
  발표 보기 `ChordSheetView`·싱어 코드 스위치·조 묶음, 콘티 조 칩·배지, 콘티 한번에 넣기 조 칸)
  — 사용량 한도로 **테스트를 쓰던 중 멈춤**
- 검증(리눅스): `flutter analyze` 문제 없음 · `flutter test` 560 통과 / 1 실패
  (실패 `test/update_script_test.dart` 는 작업 전부터 root 환경에서만 나는 실패 — macOS 로컬에선 통과할 것으로 예상, 확인 필요)

## 남은 일
1. 프론트 테스트 마무리: `test/chord_sheet_test.dart` 보강 — ChordSheetView 배치 계산, 싱어 JSON 모양(`chord_lines`·`key_label`),
   `SlidePageData`·PPTX payload 에 코드 없음, Windows 에선 `chord_lines` 안 보냄
2. F8 문서: CLAUDE.md '코드 가사' 절에 화면 쪽(가사 수정 창 코드 모드, ChordSheetView, 싱어·휴대폰 코드, 조 UI) 추가
3. QA 재검증: `qa-review.md` ④ 체크리스트로 구현 검증 → 결과를 `qa-review.md` 에 덧붙이기
4. **macOS 에서 직접 확인** (리눅스에선 못 함): `flutter run -d macos` → 가사 수정 창에서 코드 넣기 → 콘티 담기 → 발표 시작 →
   싱어 창 '싱어 코드' 켜기 · 발표 보기 '코드 보기' · 조 −/+ · 휴대폰 코드 버튼. 관객 화면·PPTX 에 코드가 안 나오는지
5. PR 열기 → CI 로 Swift(macOS)·C++(Windows) 컴파일 확인

## 미확인
- 실제 곡 DB 에 대괄호(`[후렴]` 등) 든 가사가 몇 곡인지 (plan.md B0 SQL)
- realignChords 자동 저장 기준(변경 10% 이하)의 실제 곡 적합성
- 코드 줄이 낄 때 싱어 글자 축소 정도
- 옛 앱으로 내려갈 때 v20 DB 동작 (자동 백업 `worship_slides.db.v19.bak` 으로 되돌릴 수 있음)
