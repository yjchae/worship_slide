# Worship Slides

예배 슬라이드를 한 곳에서 준비하고 바로 띄우는 데스크탑 앱 (macOS · Windows).

찬양 PPT 폴더를 통째로 가져와 가사를 DB에 모아두고, 곡·성경 구절·외부 PPT를 섞어 콘티를 만든 뒤,
보조 모니터에 바로 발표하거나 PPTX 파일로 내보냅니다.

## 주요 기능

- **폴더 일괄 가져오기** — 지정 폴더의 `.ppt` / `.pptx`를 재귀 탐색해 가사를 추출하고 SQLite에 저장
- **한/영 가사 자동 분리** — 한 슬라이드에 한국어·영어가 섞여 있어도 구분해서 저장
- **검색** — 제목·가사 대상으로 실시간 검색 (검색 범위 선택 가능)
- **성경** — 성경 JSON을 역본별로 가져와 `요 3:16` 같은 참조로 찾아 콘티에 추가
- **콘티 구성** — 곡 / 성경 / 외부 PPT(페이지 이미지) / 빈 페이지를 드래그로 순서 조정, 슬라이드 단위 수정·삭제
- **콘티 저장·불러오기** — 저장 시점의 가사를 함께 보관해서 원본이 바뀌어도 콘티가 깨지지 않음
- **발표 모드** — 보조 모니터 전체화면으로 송출. 키보드로 이동, 화면 끄기(블랙아웃) 지원
- **디자인** — 배경색/배경 이미지, 글자색·크기·정렬·위치, 곡 제목 표시 등을 가사와 성경에 따로 설정, 실시간 미리보기
- **PPTX 내보내기** — 구성한 콘티를 그대로 새 PPTX 파일로 생성
- **자동 업데이트 확인** — 새 릴리즈가 있으면 앱 안에서 알림·다운로드

### 발표 모드 단축키

| 키 | 동작 |
|----|------|
| → · ↓ · Space | 다음 슬라이드 |
| ← · ↑ | 이전 슬라이드 |
| 숫자 + Enter | 해당 번호 슬라이드로 이동 |
| ESC | 발표 종료 |

## 기술 스택

| 영역 | 기술 |
|------|------|
| UI | Flutter Desktop (macOS · Windows) |
| 데이터베이스 | SQLite (`sqflite_common_ffi`) |
| PPT 읽기/쓰기 | Python 3 + `python-pptx` (PyInstaller로 빌드해 서브프로세스 호출) |
| PPT → 이미지 | LibreOffice(`soffice`) → PDF → PyMuPDF → PNG |
| 발표 창 | macOS: WKWebView / Windows: GDI (네이티브 창, MethodChannel로 제어) |

## 사전 요구사항

1. **Flutter SDK** (Dart SDK ^3.11)
2. **Python 3**
3. **LibreOffice** — `.ppt`(구형) 가져오기와 외부 PPT를 이미지로 넣을 때만 필요 (선택)

## 개발 환경 준비

```bash
flutter pub get

# Python 도구 빌드 — 이 단계를 건너뛰면 가져오기/내보내기/발표가 동작하지 않습니다.
# .venv 생성과 의존성 설치까지 스크립트가 처리합니다.
./scripts/build.sh      # macOS
.\scripts\build.ps1     # Windows (PowerShell)

flutter run -d macos    # 또는 flutter run -d windows
```

`python/ppt_tool.py`를 수정하면 위 빌드 스크립트를 다시 실행해야 반영됩니다.

## 배포 빌드

`scripts/build.sh` / `scripts/build.ps1`는 Python 도구와 Flutter 릴리즈 앱을 빌드하고
실행에 필요한 파일을 `dist/worship_slides/`에 모읍니다.

- macOS: `dist/worship_slides/Worship Slides.app` — 코드 서명이 없어 Gatekeeper가 막으므로,
  같은 폴더의 `Unlock Worship Slides.command`를 우클릭 → 열기로 한 번 실행한 뒤 앱을 실행합니다.
- Windows: `dist\worship_slides\worship_slides.exe`

## 릴리즈

`v*` 태그를 푸시하면 GitHub Actions가 Windows/macOS 빌드를 만들어
`worship_slides-windows-<tag>.zip` / `worship_slides-macos-<tag>.zip`을 Release에 업로드합니다.
태그는 `pubspec.yaml`의 `version`과 맞춰야 앱의 업데이트 확인이 올바르게 동작합니다.

```bash
git tag v1.1.9
git push origin v1.1.9
```

## 테스트

```bash
flutter test                    # 페이지 파싱 · 슬라이드 렌더링
python3 python/test_render.py   # PPT → 이미지 변환 (LibreOffice 없으면 skip)
```

## 데이터 저장 위치

| 데이터 | 위치 |
|--------|------|
| 곡 · 성경 · 콘티 DB | 실행 파일 옆 `worship_slides.db` (앱 폴더째 옮기면 함께 이동) |
| 디자인 설정 | Application Support `/worship_slides/export_style.json` |
| 오류 로그 | Application Support `/worship_slides/logs/app.log` (앱 안에서 확인 가능) |
| 외부 PPT 페이지 이미지 | Application Support `/worship_slides/ppt_slides/` |
| `.ppt` 변환 캐시 | Caches `/worship_slides/ppt_import_cache/` |

## 프로젝트 구조

```
worship_slides/
├── lib/                    # Flutter/Dart 소스 (자세한 구조는 CLAUDE.md)
├── python/ppt_tool.py      # CLI: import <폴더> | render <파일> | export <JSON>
├── macos/, windows/        # 네이티브 발표 창 구현
├── assets/fonts/           # Pretendard · NanumGothic · NanumMyeongjo
├── scripts/build.sh|ps1    # 배포 빌드
├── test/                   # Flutter 테스트
└── CLAUDE.md               # 아키텍처 · 설계 결정 상세
```
