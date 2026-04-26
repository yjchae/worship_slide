# 찬양 가사 관리자 (Praise Lyrics Manager)

PPT/PPTX 형식으로 보관된 찬양 파일을 한 곳에서 관리하고, 원하는 곡만 골라 새 PPTX로 내보내는 데스크탑 앱입니다.

## 주요 기능

- **폴더 일괄 가져오기** — 지정 폴더 내 `.ppt` / `.pptx` 파일을 재귀 탐색하여 가사를 추출, SQLite DB에 저장
- **한/영 가사 분리** — 슬라이드에 한국어·영어가 섞여 있어도 자동으로 구분
- **검색** — 제목 또는 가사 내용으로 실시간 검색
- **PPTX 내보내기** — 선택한 곡들을 스타일(배경색·글자색·글자 크기·위치·영어 포함 여부)에 맞춰 새 PPTX로 생성
- **스타일 미리보기** — 내보내기 전 슬라이드 디자인을 앱 내에서 미리 확인

## 기술 스택

| 영역 | 기술 |
|------|------|
| UI | Flutter (Desktop — macOS · Windows · Linux) |
| 데이터베이스 | SQLite (`sqflite_common_ffi`) |
| PPT 처리 | Python 3 + `python-pptx` |
| PPT→PPTX 변환 | LibreOffice (`soffice --headless`) |

## 사전 요구사항

1. **Flutter SDK** ≥ 3.11
2. **Python 3** (`.venv` 권장)
3. **python-pptx** 패키지
4. **LibreOffice** — `.ppt`(구형) 파일 변환 시 필요

```bash
# Python 의존성 설치
cd <프로젝트 루트>
python3 -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install python-pptx
```

## 실행 방법

```bash
# Flutter 패키지 설치
flutter pub get

# macOS 데스크탑 실행
flutter run -d macos

# Windows
flutter run -d windows

# Linux
flutter run -d linux
```

## 프로젝트 구조

```
make_ppt/
├── lib/
│   ├── main.dart                          # 앱 진입점, SQLite FFI 초기화
│   └── src/
│       ├── app.dart                       # MaterialApp 설정
│       └── features/praise/
│           ├── data/
│           │   ├── praise_database.dart   # DB 스키마 / 마이그레이션
│           │   ├── praise_repository.dart # 곡 CRUD
│           │   ├── python_bridge.dart     # Flutter → Python 프로세스 호출
│           │   └── export_style_store.dart # 스타일 설정 영속화
│           ├── domain/
│           │   ├── praise_song.dart       # 곡 모델
│           │   └── export_style.dart      # 내보내기 스타일 모델
│           └── presentation/
│               └── praise_home_page.dart  # 단일 화면 UI
├── python/
│   └── ppt_tool.py                        # CLI: import <폴더> | export <JSON>
├── .venv/                                 # Python 가상환경 (git 제외)
└── pubspec.yaml
```

## Python 도구 (ppt_tool.py)

Flutter 앱은 `python_bridge.dart`를 통해 `ppt_tool.py`를 서브프로세스로 실행합니다.

```bash
# 폴더 임포트 (stdout: JSON)
python python/ppt_tool.py import /path/to/ppt/folder

# PPTX 내보내기 (stdout: JSON)
python python/ppt_tool.py export '{"output_path":"...","songs":[...],"style":{...}}'
```

`.ppt` 파일은 LibreOffice로 `.pptx`로 먼저 변환 후 처리하며, 변환 결과는 `~/Library/Caches/praise_lyrics_app/ppt_import_cache/`에 캐시됩니다.
