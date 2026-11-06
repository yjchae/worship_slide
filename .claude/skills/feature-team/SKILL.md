---
name: feature-team
description: 새 기능을 팀(팀장·기획자·프론트·백엔드·UI 설계자·QA)으로 기획·검증할 때 쓰는 작업 순서와 산출물 위치. "팀을 구성해서 기획", "기획자/개발자/QA 에게 맡겨" 같은 요청에 쓴다.
---

# 기능 팀 작업 순서

산출물은 모두 `planning/<기능-이름>/` 에 둔다 (기존 `planning/trilingual-display/` 형식).

| 단계 | 담당 | 산출물 |
|---|---|---|
| 1 | 팀장(메인 세션) | 요구사항·범위 정리, 팀원 지시 |
| 2 | 기획자 | `plan.md` — 목표·범위·사용자 흐름·결정할 것(추천안 포함)·단계별 일정 |
| 2 | 프론트 개발자 | `tech-frontend.md` — Dart/Flutter·macOS Swift·Windows C++·휴대폰 HTML 변경점, 파일·함수 단위 |
| 2 | 백엔드 개발자 | `tech-backend.md` — DB 스키마/마이그레이션·동기화·.wsconti·Python(ppt_tool) 변경점 |
| 3 | UI 설계자 | `mockup.html` + `screens/s*.png` (Playwright, deviceScaleFactor 2) |
| 4 | QA | `qa-review.md` — 기획·기술·화면 간 모순, 빠진 경로, 테스트 항목 |
| 5 | 팀장 | 결과 요약 → 사용자 확인 → 구현 → QA 재검증 |

규칙
- 2단계 세 명은 병렬, UI 는 기획 뒤, QA 는 마지막.
- 문서는 한국어, CLAUDE.md 의 용어(원본·보조·추가 보조, 싱어 화면, 발표 보기 등)를 그대로 쓴다.
- 확인 안 된 것은 "미확인"으로 적는다. 수치·버전을 지어내지 않는다.
- 사용자 확인 전에는 앱 코드를 고치지 않는다.
