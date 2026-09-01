# CLAUDE.md — Worship Slides

## 프로젝트 개요

Flutter 데스크탑 앱(macOS/Windows) + Python 백엔드로 구성된 예배 슬라이드 도구.

1. PPT/PPTX 폴더를 가져와 가사를 SQLite에 저장한다
2. 성경(JSON)을 가져와 절 단위로 검색한다
3. 곡·성경·외부 PPT 이미지·빈 페이지를 "콘티"로 조립한다
4. 조립한 콘티를 보조 모니터에 **직접 발표**하거나, PPTX로 **내보낸다**

## 주요 명령어

```bash
flutter pub get
flutter run -d macos          # 실행
flutter build macos           # 빌드
flutter analyze
flutter test                  # test/widget_test.dart (페이지 파싱·슬라이드 렌더 단위 테스트)
python3 python/test_render.py # render 명령 self-check (LibreOffice 없으면 skip)

# 배포용 전체 빌드 (PyInstaller + Flutter 릴리즈 + dist/ 구성)
./scripts/build.sh    # macOS
./scripts/build.ps1   # Windows
```

**중요**: 앱은 `python/ppt_tool/ppt_tool`(PyInstaller 산출물)만 호출한다. 이 폴더는 git에 없으므로
클론 직후·`ppt_tool.py` 수정 시마다 위 빌드 스크립트를 한 번 돌려야 임포트·내보내기·발표가 동작한다.
(빌드 스크립트가 `.venv` 생성 + `python/requirements.txt` 설치까지 알아서 한다.)

## 아키텍처

### Flutter (Dart)

```
lib/
  main.dart                          -- sqflite FFI 초기화 후 WorshipSlidesApp 실행
  src/app.dart                       -- MaterialApp (seed #1B6B5C, 배경 #F4F1EA)
  src/features/praise/
    data/
      praise_database.dart           -- SQLite 스키마 + 마이그레이션 (현재 version 10)
      praise_repository.dart         -- 곡 CRUD (searchSongs, replaceAllSongs, deleteSongsByIds ...)
      worship_conti_repository.dart  -- 콘티 저장/불러오기 (곡 가사 스냅샷까지 함께 보관)
      python_bridge.dart             -- Process.run으로 ppt_tool 실행 (import / render / export)
      export_style_store.dart        -- 스타일을 Application Support/export_style.json에 저장
      app_logger.dart                -- Application Support/logs/app.log (앱 내 "로그 보기"용)
    domain/
      praise_song.dart               -- PraiseSong; 페이지 구분자는 빈 줄(\n\n)
      export_style.dart              -- ExportStyle (가사/성경 각각의 색·크기·정렬·제목 표시 등)
      staging_item.dart              -- sealed StagingItem: Song / Bible / Image / Blank
      worship_conti.dart             -- 콘티 모델
    presentation/
      praise_home_page.dart          -- 단일 화면(5,700줄). 검색·성경·디자인·콘티·발표 제어 전부 여기
      slide_page_data.dart           -- 발표 창에 보낼 한 페이지의 JSON 표현
      slide_render_view.dart         -- 미리보기/썸네일용 Flutter 슬라이드 렌더러
  src/features/bible/
    data/bible_repository.dart       -- 역본·책·장·절 조회, JSON 임포트
    domain/bible_verse.dart
  src/features/update/update_service.dart -- GitHub Releases(yjchae/make_ppt-releases) 확인·다운로드
```

### 발표 창 (네이티브)

발표 화면은 Flutter가 아니라 **네이티브 창**이다. MethodChannel 3개로 제어한다.

- `worship_slides/presentation` — Dart → 네이티브: open / updatePage / toggleBlackout / close
- `worship_slides/presentation_main` — 네이티브 → Dart: `presentationClosed`
- `worship_slides/save_panel` — 저장 위치 선택 (macOS NSSavePanel)

| 플랫폼 | 구현 | 렌더링 |
|--------|------|--------|
| macOS  | `macos/Runner/MainFlutterWindow.swift` (`PresentationWindowController`) | WKWebView + 생성한 HTML/CSS |
| Windows| `windows/runner/presentation_channel.cpp` | GDI `DrawTextW` + GDI+ 이미지 |

보조 모니터가 있으면 그 화면에 borderless 전체화면(`level = .screenSaver`)으로, 없으면 1280x720 창으로 띄운다.

### Python (`python/ppt_tool.py`, 약 900줄)

Flutter가 서브프로세스로 호출하고 stdout의 JSON을 읽는다.

- `import <폴더>` — `.ppt`/`.pptx` 재귀 탐색 → 한/영 가사 분리 → `{songs, processed_count, errors, libreoffice_missing}`
- `render <파일>` — 외부 PPT/PDF 전 페이지를 PNG로 (soffice → PDF → PyMuPDF → 페이지별 PNG).
  `.pdf`는 soffice 변환을 건너뛰므로 LibreOffice 없이도 된다
- `export <JSON payload>` — 콘티 + 스타일로 새 PPTX 생성 (곡/성경/이미지/빈 페이지 슬라이드)

## 중요 설계 결정

- **Python 실행 방식**: PyInstaller 실행 파일만 탐색·호출한다 (`.py`를 직접 실행하지 않는다).
  탐색 경로는 CWD·실행 파일 위치·`$PWD`의 모든 상위 폴더 아래 `python/[ppt_tool/]ppt_tool`
- **onefile이 아니라 onedir**: onefile은 호출마다 아카이브를 임시폴더에 풀고 macOS가 매번 검사해서
  **실행 1회당 약 10초**가 든다. onedir는 0.12초
- **가사 페이지 구분자**: 빈 줄(`\n\n`). 예전 `###` 구분자는 DB version 6 마이그레이션에서 일괄 변환됨.
  선행 빈 줄은 "빈 페이지"로 보존된다 (`praise_song.dart` 참고)
- **한/영 분리 기준** (`is_english_line`): 라틴 문자 비율 ≥ 60%면 영어 줄
- **DB 위치**: 실행 파일 옆 (`worship_slides.db`). macOS는 `.app`에서 3단계 위. 앱 폴더를 통째로 옮겨도 데이터가 따라온다
- **DB 갱신** (`replaceAllSongs`): 전체 삭제 후 재삽입 (증분 갱신 아님)
- **콘티 저장 시 가사 스냅샷**: 곡 id만이 아니라 당시 가사(`song_lyrics`)까지 저장한다.
  나중에 곡을 지우거나 다시 임포트해도 저장한 콘티가 깨지지 않는다
- **PPT 렌더 캐시 위치**: `~/Library/Application Support/worship_slides/ppt_slides/<해시>/`.
  Caches가 아닌 이유 — 저장한 콘티가 나중에 이미지 유실로 깨지면 안 되기 때문.
  (`.ppt`→`.pptx` 변환 캐시는 유실돼도 되므로 `~/Library/Caches/worship_slides/ppt_import_cache/`)
- **폰트**: 앱은 번들 폰트(Pretendard/NanumGothic/NanumMyeongjo)를 쓰지만, 내보낸 PPTX를 PowerPoint에서
  열 때 필요하므로 `_ensure_fonts_installed`가 사용자 폰트 폴더에 복사한다.
  단, PyInstaller에는 **Pretendard만** 번들되어 있다
- **좌표계 일치**: 미리보기·발표 창·PPTX가 같게 보여야 한다. 기준은 슬라이드 높이 7.5인치 = 540pt,
  `fontScale = 높이 / 540`. Swift HTML은 `calc(N / 540 * 100vh)`로 맞춘다

## 발표 모드 단축키

`praise_home_page.dart` `_handleKeyEvent` — →/↓/Space 다음, ←/↑ 이전, 숫자+Enter 해당 슬라이드로 점프, ESC 발표 종료.

## 배포

- `scripts/build.sh` / `build.ps1` → `dist/worship_slides/` (앱 + `python/ppt_tool/`)
- macOS 배포본에는 Gatekeeper 해제용 `Unlock Worship Slides.command`와 안내 txt가 함께 들어간다 (서명 없음)
- `v*` 태그를 푸시하면 `.github/workflows`가 macOS/Windows zip을 만들어 Release에 올린다
- 앱은 시작 시 `yjchae/make_ppt-releases`의 최신 릴리즈를 확인해 업데이트 배너를 띄운다.
  **릴리즈 태그와 `pubspec.yaml`의 version이 같아야 한다**

## 의존성

- Dart: `file_picker`, `sqflite_common_ffi`, `path`, `path_provider`, `package_info_plus`, `http`
- Python: `python-pptx`, `pymupdf`, `pyinstaller`
- 시스템: LibreOffice(`soffice`) — `.ppt` 임포트와 PPT 이미지 렌더에 필요 (없으면 해당 기능만 비활성)

## 기타

- `make_ppt_guide.py`, `make_user_guide.py` — 사용자 가이드 pptx/docx 생성 스크립트 (앱과 무관)
- `AGENTS.md` — 이 파일을 가리키는 포인터
