# CLAUDE.md — Worship Slides

## 프로젝트 개요

Flutter 데스크탑 앱 + Python 백엔드로 구성된 예배 슬라이드 관리 도구.
PPT/PPTX 폴더를 가져와 SQLite에 저장하고, 선택한 곡을 새 PPTX로 내보낸다.

## 주요 명령어

```bash
# 패키지 설치
flutter pub get

# 실행 (macOS)
flutter run -d macos

# 빌드 (macOS)
flutter build macos

# 분석
flutter analyze

# 테스트
flutter test

# Python 의존성 (최초 1회)
python3 -m venv .venv && source .venv/bin/activate && pip install python-pptx
```

## 아키텍처

### Flutter (Dart)

```
lib/src/features/praise/
  data/
    praise_database.dart    -- SQLite 스키마, 테이블 생성
    praise_repository.dart  -- 곡 CRUD (searchSongs, replaceAllSongs, deleteSongsByIds, clearAllSongs)
    python_bridge.dart      -- Process.run()으로 ppt_tool.py 호출; .venv/bin/python 자동 탐색
    export_style_store.dart -- 스타일 설정을 로컬 파일에 JSON으로 저장
  domain/
    praise_song.dart        -- PraiseSong 모델; pages/englishPages는 "###" 구분자로 분리
    export_style.dart       -- ExportStyle 모델 (fontSize, backgroundColor, textColor 등)
  presentation/
    praise_home_page.dart   -- 단일 StatefulWidget; 임포트·검색·디자인·내보내기 모두 여기
```

### Python (ppt_tool.py)

CLI 도구. Flutter에서 서브프로세스로 호출하며 stdout에 JSON을 출력한다.

- `import <폴더>` — `.ppt`/`.pptx` 재귀 탐색 → 한/영 가사 분리 → JSON 출력
- `export <JSON>` — 스타일 적용하여 새 PPTX 생성
- `.ppt` 파일은 LibreOffice(`soffice --headless`)로 변환 후 처리; 결과는 `~/Library/Caches/worship_slides/ppt_import_cache/`에 캐시
- 병렬 처리: `concurrent.futures.ThreadPoolExecutor`, 최대 8 워커

## 중요 설계 결정

- **Python 탐색 순서** (`python_bridge.dart`): 스크립트 인접 `.venv` → 실행 파일 경로 상위 `.venv` → `python3`
- **가사 페이지 구분자**: `"###"` — DB 저장 시 단일 문자열로 직렬화
- **한/영 분리 기준** (`is_english_line`): 라틴 문자 비율 ≥ 60% 이면 영어 줄로 판단
- **스타일 미리보기**: `_PreviewBox`에서 선택된 첫 번째 곡의 첫 페이지를 실시간 렌더링
- **DB 초기화** (`replaceAllSongs`): 기존 데이터 전체 삭제 후 재삽입 (증분 갱신 아님)

## 파일 레이아웃

```
make_ppt/
├── lib/                  # Flutter/Dart 소스
├── python/ppt_tool.py    # Python CLI
├── .venv/                # Python 가상환경 (git 제외)
├── tmp_sample/           # 샘플 PPT 파일 (git 제외)
├── pubspec.yaml          # Flutter 의존성
└── CLAUDE.md             # 이 파일
```

## 의존성

### Dart
- `file_picker` — 폴더/파일 다이얼로그
- `sqflite_common_ffi` — 데스크탑 SQLite
- `path`, `path_provider` — 파일 경로

### Python
- `python-pptx` — PPT 파일 읽기/쓰기

### 시스템
- LibreOffice (`soffice`) — `.ppt` → `.pptx` 변환 (선택적)
