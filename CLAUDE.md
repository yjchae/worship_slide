# CLAUDE.md — Worship Slides

## 프로젝트 개요

Flutter 데스크탑 앱(macOS/Windows) + Python 백엔드로 구성된 예배 슬라이드 도구.

1. PPT/PPTX 폴더를 가져와 가사를 SQLite에 저장한다 (악보 이미지에서 OCR로 뽑아낼 수도 있다)
2. 성경(JSON)을 가져와 절 단위로 검색한다
3. 곡·성경·외부 PPT 이미지·빈 페이지를 "콘티"로 조립한다
4. 조립한 콘티를 보조 모니터에 **직접 발표**하거나, PPTX로 **내보낸다**

## 주요 명령어

```bash
flutter pub get
flutter run -d macos          # 실행
flutter build macos           # 빌드
flutter analyze
flutter test                  # test/ (페이지 파싱·슬라이드 렌더·헌금송 배경 굽기 등 단위 테스트)
python3 python/test_render.py    # render 명령 self-check (LibreOffice 없으면 skip)
python3 python/test_animation.py # 애니메이션 단계 펼치기 self-check (LibreOffice 불필요)
python3 python/test_export_background.py # 항목별 배경 오버라이드 self-check (LibreOffice 불필요)
python3 python/test_export_text.py       # 가사 줄바꿈 self-check (LibreOffice 불필요)
python3 python/test_export_position.py   # 본문·제목 세로 미세 조정 self-check (LibreOffice 불필요)
python3 python/test_split_language.py    # 한/보조 언어 줄 나누기 self-check (LibreOffice 불필요)
python3 python/test_sheet_lyrics.py      # 악보 가사 추출 self-check (Tesseract 없으면 OCR 부분만 skip)

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
      praise_database.dart           -- SQLite 스키마 + 마이그레이션 (현재 version 12)
      praise_repository.dart         -- 곡 CRUD (searchSongs, replaceAllSongs, deleteSongsByIds ...)
      worship_conti_repository.dart  -- 콘티 저장/불러오기 (곡 가사 스냅샷까지 함께 보관)
      python_bridge.dart             -- Process.run으로 ppt_tool 실행 (import / render / export)
      export_style_store.dart        -- 스타일을 Application Support/export_style.json에 저장
      offering_design_store.dart     -- 헌금송 기본 디자인 → offering_design.json
      offering_background_composer.dart -- 헌금송 디자인을 배경 PNG 한 장으로 굽는다
      app_logger.dart                -- Application Support/logs/app.log (앱 내 "로그 보기"용)
    domain/
      praise_song.dart               -- PraiseSong; 페이지 구분자는 빈 줄(\n\n)
      export_style.dart              -- ExportStyle (가사/성경 각각의 색·크기·정렬·제목 표시 등)
      slide_background.dart          -- SlideBackground (콘티 항목 하나만 배경을 다르게)
      offering_design.dart           -- OfferingDesign (헌금송 배경·계좌·색·크기·띠 높낮이)
      staging_item.dart              -- sealed StagingItem: Song / Bible / Image / Blank
      worship_conti.dart             -- 콘티 모델
    presentation/
      praise_home_page.dart          -- 단일 화면(5,700줄). 검색·성경·디자인·콘티·발표 제어 전부 여기
      slide_page_data.dart           -- 발표 창에 보낼 한 페이지의 JSON 표현
      slide_render_view.dart         -- 미리보기/썸네일용 Flutter 슬라이드 렌더러
      offering_dialog.dart           -- 헌금송 디자인 등록 / 항목에 적용(높낮이) 다이얼로그
      offering_overlay_painter.dart  -- 헌금송 띠(라인 + 헌금 + 계좌) painter. 미리보기·PNG 공용
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
- `render <파일> [--no-animation]` — 외부 PPT/PDF 전 페이지를 PNG로
  (애니메이션 펼치기 → soffice → PDF → PyMuPDF → 페이지별 PNG).
  `.pdf`는 soffice 변환을 건너뛰므로 LibreOffice 없이도 된다
- `export <JSON payload>` — 콘티 + 스타일로 새 PPTX 생성 (곡/성경/이미지/빈 페이지 슬라이드)
- `sheet <파일>` — 악보(이미지·PDF)에서 오선 아래 가사만 →
  `{source_name, lyrics, lines, page_count, staff_count, text_layer}`
  (OCR 이 필요한데 Tesseract 가 없으면 `{"error": "tesseract_missing"}`)

## 중요 설계 결정

- **Python 실행 방식**: PyInstaller 실행 파일만 탐색·호출한다 (`.py`를 직접 실행하지 않는다).
  탐색 경로는 CWD·실행 파일 위치·`$PWD`의 모든 상위 폴더 아래 `python/[ppt_tool/]ppt_tool`
- **onefile이 아니라 onedir**: onefile은 호출마다 아카이브를 임시폴더에 풀고 macOS가 매번 검사해서
  **실행 1회당 약 10초**가 든다. onedir는 0.12초
- **가사 페이지 구분자**: 빈 줄(`\n\n`). 예전 `###` 구분자는 DB version 6 마이그레이션에서 일괄 변환됨.
  선행 빈 줄은 "빈 페이지"로 보존된다 (`praise_song.dart` 참고)
- **한/보조 언어 분리 기준** (`is_sub_line`): 한글이 없고 글자(alpha)가 있으면 보조 언어 줄.
  예전엔 라틴 비율 ≥ 60% 였는데 그러면 일본어·중국어가 한국어 쪽에 섞였다.
  숫자·기호만 있는 줄은 alpha 가 없어 예전처럼 본문 쪽에 남는다
- **DB 위치**: 실행 파일 옆 (`worship_slides.db`). macOS는 `.app`에서 3단계 위. 앱 폴더를 통째로 옮겨도 데이터가 따라온다
- **DB 갱신** (`replaceAllSongs`): 전체 삭제 후 재삽입 (증분 갱신 아님)
- **콘티 저장 시 가사 스냅샷**: 곡 id만이 아니라 당시 가사(`song_lyrics`)까지 저장한다.
  나중에 곡을 지우거나 다시 임포트해도 저장한 콘티가 깨지지 않는다
- **다국어 (보조 언어)**: 렌더러 네 곳(미리보기·macOS·Windows·PPTX)은 원래부터 본문 아래
  `english_text` 한 줄을 그린다. 그래서 다국어는 **그 칸에 무엇을 넣을지**만 정하는 기능이고
  렌더링 코드는 하나도 안 건드렸다.
  - **찬양**: `praise_songs.english_lyrics` 가 기본 언어('영어')를 그대로 맡고, 그 밖의 언어만
    `song_translations(song_title, language, lyrics)` 에 둔다. 키가 곡 id 가 아니라 **제목**인
    이유 — `replaceAllSongs` 가 전체 삭제 후 재삽입이라 id 가 임포트마다 바뀐다
  - **곡을 콘티에 담는 순간** 선택 언어 가사를 `englishLyrics` 슬롯에 확정해 넣는다
    (`_withSubLyrics`). 가사 스냅샷과 같은 방식이라 슬라이드·미리보기·내보내기·발표·콘티 저장은
    다국어를 전혀 모른다. 언어를 바꾸면 `_reapplySubLanguage` 가 담긴 곡들만 다시 입힌다
  - **폴더 임포트 때 언어를 묻는다.** '영어'가 아니면 곡을 새로 만들지 않고 **제목 기준으로
    가사만** 붙인다 — 같은 곡의 한글 가사가 파일마다 미묘하게 달라 중복 곡이 생기는 걸 막는다
  - **성경**: `ExportStyle.bibleSubVersion` 에 역본 하나를 전역으로 고르면 절을 콘티에 담을 때
    그 역본 본문을 `BibleStagingItem.subText` 에 함께 담는다 (DB `worship_conti_items.bible_sub_text`).
    역본마다 책 이름이 다르므로(창세기/Genesis) `mapBookName` 이 이름 → 정경 순서 index 순으로
    짝을 찾는다. 권 수가 다르면 포기하고 보조 본문 없이 담는다
  - `subLanguage`·`bibleSubVersion` 은 `ExportStyle` 에 얹혀 `export_style.json` 에 저장된다.
    렌더러는 둘 다 읽지 않는다 (담을 때 이미 결정되어 있다)
- **항목별 배경 오버라이드**: "헌금송만 다른 배경"처럼 콘티 일부만 배경을 다르게 하는 기능.
  전역 `ExportStyle` 은 그대로 두고, 항목 uid → `SlideBackground`(색 + 이미지 경로) 맵
  (`_itemBackgrounds`)을 따로 들고 다닌다. 메모(`_slideNotes`)와 같은 방식이라 `StagingItem`
  4형제를 건드리지 않는다.
  - 적용은 `ExportStyle.withBackground()` 한 곳. 오버라이드가 있으면 배경 **색과 이미지를
    통째로** 대체하므로, 색만 담긴 오버라이드는 "전역 배경 이미지 위가 아니라 단색"이 된다
  - 발표 창(네이티브)은 페이지마다 style JSON을 통째로 받으므로 자동으로 따라온다.
    macOS 는 WKWebView CSS(`background-size:cover`), Windows 는 GDI+ 로 같은 cover 규칙을
    직접 그린다(`PaintBackgroundImage`). 확대(zoom)도 양쪽 다 배경까지 같이 따라간다
  - **배경 이미지는 PNG/JPG 만** 고르게 막아 뒀다. 미리보기(Flutter)·Windows 발표 창(GDI+)·
    PPTX 세 군데가 모두 확실히 읽는 형식이 이 둘이다 (GDI+ 는 WebP·HEIC 를 못 읽는다)
  - 항목이 만드는 모든 페이지 + 뒤에 자동으로 붙는 여백까지 같은 배경을 쓴다
    (Dart `_allSlides` 는 앞 항목의 uid 를, Python `export_presentation` 은 앞 항목의
    background 를 그대로 빌려 쓴다)
  - 저장은 `worship_conti_items.background` 한 칸(JSON, DB version 11)
- **헌금송**: 찬양을 "배경 이미지 + 노란 '헌금' · '은행 계좌' 두 줄 + 위아래 라인" 위에 띄우는 기능.
  **항목별 배경 오버라이드 위에 얹었다** — 띠까지 그린 그림을 1920x1080 PNG 한 장으로 구워
  (`OfferingBackgroundComposer`) 그 항목의 `SlideBackground.imagePath` 로 건다. 그래서 렌더러 네 곳은
  헌금송을 전혀 모르고, 가사는 평소처럼 그 위에 그려진다.
  - 기본 디자인(배경·은행·계좌·색·크기)은 `OfferingDesign` → `offering_design.json`.
    디자인 패널 "헌금송 디자인 등록"에서 고친다
  - 콘티 항목(찬양·빈 페이지)의 헌금송 버튼 → `OfferingDialog`. **띠 높낮이(`bandCenterY`, 인치)는
    곡마다 다르다** — 가사가 긴 곡은 띠를 위/아래로 비킨다. 여기서 바꾼 배경·계좌 등은 기본값에도
    반영하지만 높낮이는 그 항목에만 남긴다
  - 미리보기와 PNG 굽기가 같은 `OfferingOverlayPainter` 를 쓴다. 미리보기에서 맞춘 위치가 곧 실제 위치
  - `SlideBackground.offering` 에 구운 디자인(높낮이 포함)을 함께 저장한다(DB `background` JSON 한 칸,
    마이그레이션 없음). 다시 열어 높낮이만 고치거나, 콘티를 불러왔는데 PNG 가 없으면 다시 굽는 데 쓴다
  - PNG 는 `Application Support/offering_backgrounds/offering_<해시>.png`. 키 = 디자인 JSON + 배경
    원본의 수정 시각·크기. 그리는 방식이 바뀌면 `_renderVersion` 을 올린다. 예전 파일은 지우지 않는다
  - "항목 배경" 다이얼로그에서 색·이미지를 손으로 바꾸면 헌금송 정보는 떨어져 나간다(일반 배경이 된다)
- **외부 PPT 애니메이션**: LibreOffice가 PDF로 굽는 순간 애니메이션은 사라지고 "다 나타난 마지막
  상태" 한 장만 남는다. 그래서 PDF로 넘기기 전에 pptx의 `<p:timing>`(메인 시퀀스)을 읽어
  **클릭 한 번 = 페이지 한 장**으로 슬라이드를 복제해 둔다 (`expand_animation_steps`).
  움직이는 효과 자체는 재현하지 못하지만 "클릭할 때마다 하나씩 나타난다"는 순서는 살아난다.
  도형 단위(`spTgt`)와 문단 단위(`txEl/pRg`, 가사 한 줄씩 등장) 둘 다 지원하고 사라짐(`exit`)도 따라간다.
  - 문단을 감출 때는 글자만 지우고 빈 문단은 남긴다. 문단째 지우면 나머지 줄이 위아래로 밀린다
  - 슬라이드당 30단계 / 파일당 600페이지를 넘으면 펼치기를 포기하고 원본대로 한 장씩 굽는다
  - 결과는 `image_paths`가 길어지는 것뿐이라 Dart·발표 창·내보내기·콘티 저장은 손댈 게 없다
  - `.ppt`는 XML을 못 여니 pptx로 먼저 바꾼 뒤에 본다. 다만 **LibreOffice가 `.ppt`를 저장할 때
    애니메이션을 버리는 것은 확인됐고, 진짜 PowerPoint가 만든 `.ppt`를 읽을 때 타이밍이
    남는지는 미확인**이다. 안 남으면 그냥 예전처럼 한 장씩 구워진다
- **악보 가사 추출**: 오선을 좌표로 먼저 찾아 "오선 아래"만 OCR 에 넘긴다. 제목·작곡가(첫 단 위)와
  코드 기호(다음 단 바로 위)를 글자 모양으로 거르는 것보다 훨씬 정확하다.
  - 오선 찾기는 이미지 처리 라이브러리 없이 **행별 검은 비율**(Pillow `resize((1, h), BOX)` = 가로 평균)
    하나로 한다. 가로로 평균 내면 오선만 1에 가깝고 글자 줄은 0.35를 잘 안 넘는다.
    줄 간격은 모든 선 간격의 **중앙값** — 한 단 안의 간격이 4개, 단 사이 간격이 1개라 늘 줄 간격이 된다
  - **띠를 통째로 넘기지 않고 글 줄 하나씩** 잘라 `--psm 7`(한 줄 모드)로 넘긴다. 가사는 음표에 맞춰
    띄엄띄엄 놓여서 여러 줄 모드(`--psm 6`)는 한 줄을 두 줄로 쪼갠다
  - **코드 기호 거르기**: 오선 사이 글 줄 중 마지막 줄이 위쪽(가사·오선)보다 **아래 단에 더 붙어 있으면**
    그 단의 코드다. 거리 비교라 악보마다 다른 여백에 영향을 안 받는다. `is_chord_line`(C, G7, Am/E 만
    있는 줄)이 2차 그물
  - **하이픈은 양옆 공백까지 지워 붙인다** (`할 - 렐 - 루 - 야` → `할렐루야`). 음절을 잇는 기호라
    공백을 남기면 안 된다
  - **한 글자 토막도 붙인다** (`주 의 인 자` → `주의인자`, `join_single_syllables`). 악보는 음표 하나에
    음절 하나를 놓느라 띄어 쓴 것이라 단어 사이가 아니다. 단, **양쪽이 다 한글일 때만** 붙인다 —
    영어 가사의 `I am a boy` 까지 붙으면 안 되고, 절 번호(`1.`)도 한글이 아니라 떨어져 남는다
  - **글자가 박힌 PDF(악보 프로그램 출력본)는 OCR 을 아예 안 탄다.** PyMuPDF 로 낱말과 좌표를
    꺼내 같은 띠 안의 낱말을 x 순서로 잇는다(`_words_to_lyric_lines`). 오인식이 없고 Tesseract 도
    필요 없다. 오선 찾기는 그대로 구운 이미지로 하므로 **PDF 좌표(72dpi)를 이미지 배율로 맞춰야
    한다**(`OCR_DPI / 72`). 낱말이 하나도 없는 쪽(그림·스캔본)만 OCR 로 넘어간다 →
    그래서 `tesseract_missing` 판정은 파일을 연 **뒤에** 한다
  - Tesseract 는 LibreOffice 와 같은 **선택 시스템 의존성**이다. 없으면 그 기능만 막고 설치 안내를 띄운다
    (`TesseractMissingException` → `_showTesseractDialog`). `kor` 언어 데이터가 없으면 `eng` 로만 읽는다
  - 읽어 온 가사는 `_SheetLyricsDialog` 에서 고친 뒤 **곡 편집 다이얼로그로 넘어간다**. 그래서
    `_openSongEditor` 는 `song == null` 이 아니라 **`edited.id == null`** 로 새 곡 여부를 가린다
    (악보 초안은 song 은 있고 id 만 없다)
- **PPT 렌더 캐시 위치**: `~/Library/Application Support/worship_slides/ppt_slides/<해시>/`.
  Caches가 아닌 이유 — 저장한 콘티가 나중에 이미지 유실로 깨지면 안 되기 때문.
  (`.ppt`→`.pptx` 변환 캐시는 유실돼도 되므로 `~/Library/Caches/worship_slides/ppt_import_cache/`)
  굽는 방식이 바뀌면 `RENDER_CACHE_VERSION`을 올린다. 키가 달라져 다시 굽지만, 예전 폴더는
  저장된 콘티가 참조하고 있을 수 있으므로 지우지 않는다
- **폰트**: 앱은 번들 폰트(Pretendard/NanumGothic/NanumMyeongjo)를 쓰지만, 내보낸 PPTX를 PowerPoint에서
  열 때 필요하므로 `_ensure_fonts_installed`가 사용자 폰트 폴더에 복사한다.
  단, PyInstaller에는 **Pretendard만** 번들되어 있다
- **PPTX 배경 XML 위치**: `p:bg` 는 `p:sld` 가 아니라 **`p:cSld` 의 첫 자식**이다.
  자리를 틀리면 PowerPoint 가 배경을 조용히 무시한다 (`_apply_slide_background` 참고)
- **가사 줄바꿈은 `<a:br/>`**: 한 run 의 `<a:t>` 안에 날 줄바꿈 문자를 넣으면 OOXML 상
  줄바꿈이 아니라서 뷰어마다 다르게 그려진다 (LibreOffice 는 가운데 정렬을 무시하고
  줄을 양쪽으로 벌린다). `_add_text_run` 이 줄마다 run 을 만들고 사이에 `<a:br/>` 를 넣는다.
  `<a:br>` 에도 크기·굵기·글꼴을 넣어야 줄 높이가 본문과 같아진다.
  성경 본문은 내어쓰기 때문에 원래 줄마다 문단을 만들므로 이 경로를 타지 않는다
- **좌표계 일치**: 미리보기·발표 창·PPTX가 같게 보여야 한다. 기준은 슬라이드 높이 7.5인치 = 540pt,
  `fontScale = 높이 / 540`. Swift HTML은 `calc(N / 540 * 100vh)`로 맞춘다
- **세로 위치 = 기준선 + 미세 조정**: 상단/중단/하단(`text_position`, `title_vertical_position`)은
  세 칸짜리 고정값이라 그 사이 높이를 못 맞춘다. 그래서 미세 조정 값(인치, + = 아래, ±2.0,
  0.05 단위)을 따로 둔다. 본문은 `text_offset_y`/`bible_text_offset_y`,
  제목은 `title_offset_y`/`bible_title_offset_y` 네 개가 서로 독립이다.
  - **본문 상자는 크기가 고정(0.6인치 위, 5.4인치 높이)이고 미세 조정이 그 상자를 통째로 민다.**
    높이를 건드리지 않으므로 상단/중단/하단 어느 기준을 골라도 밀어 준 만큼 똑같이 움직인다
  - **예전 "본문 상단 여백"(`text_box_top`)은 제거됐다.** 상자의 위쪽만 끌어내려 높이까지
    같이 줄이던 값이라 기준마다 효과가 달랐다 — 상자 아래쪽이 늘 6.0인치에 붙어 있어서
    **하단 기준에서는 아무 효과가 없었고, 중단 기준에서는 절반만** 움직였다. 낼 수 있던 위치
    (상단 0.3~2.2 / 중단 중심 3.15~4.10)는 모두 미세 조정 범위 안에 들어온다.
    예전 `export_style.json` 은 `migrateLegacyTopMargin()`(`export_style.dart`)이 기준선별로
    환산해 미세 조정 값에 더한다 — 상단은 그대로, 중단은 절반, 하단은 0. 콘티는 스타일을
    저장하지 않으므로 옮길 게 없다
  - 제목은 상자 높이가 0.55인치로 고정이라 기준선에 그냥 더하면 된다
    (`slide_render_view.dart`의 `titleTop`, `ppt_tool.py`의 `_add_title_textbox`,
    `presentation_channel.cpp`의 `ty`). macOS 는 제목을 `top`/`bottom` 퍼센트로
    붙이므로 `calc(1.5% ± Nvh)`로 넣는다 — **아래로 미는 값은 `top` 에는 더하고
    `bottom` 에서는 뺀다**. 가운데+중단은 `translateX`/`translateY` 가 서로를 덮으므로
    `translate()` 하나로 합쳐 쓴다
  - 계산하는 곳이 네 군데다. 하나만 고치면 미리보기와 실제 화면이 어긋난다 —
    `slide_render_view.dart`(미리보기), `MainFlutterWindow.swift`(macOS 발표),
    `presentation_channel.cpp`(Windows 발표), `ppt_tool.py`의
    `_lyrics_box_vertical_layout`·`_add_title_textbox`(PPTX).
    허용 범위(±2.0)도 네 곳이 같아야 한다
  - 키가 없는 예전 설정·콘티는 0으로 읽혀 기존 동작 그대로다

## 발표 모드 단축키

`praise_home_page.dart` `_handleKeyEvent` — →/↓/Space 다음, ←/↑ 이전, 숫자+Enter 해당 슬라이드로 점프, ESC 발표 종료.

## 배포

- `scripts/build.sh` / `build.ps1` → `dist/worship_slides/` (앱 + `python/ppt_tool/`)
- macOS 배포본에는 Gatekeeper 해제용 `Unlock Worship Slides.command`와 안내 txt가 함께 들어간다 (서명 없음)
- `v*` 태그를 푸시하면 `.github/workflows`가 macOS/Windows zip을 만들어 Release에 올린다
- **PR 을 열면 같은 워크플로가 자동으로 돈다**(문서만 바뀐 PR 은 제외). Swift·C++ 발표 창 코드는
  여기서만 실제로 컴파일되므로 네이티브 쪽 사실상 유일한 검증 수단이다. 브랜치를 직접 빌드해
  받고 싶으면 Actions → Build Release → Run workflow 로 그 브랜치를 골라 아티팩트를 받는다
  (`ppt_tool` PyInstaller 빌드까지 CI 가 하므로 로컬 재빌드가 필요 없다)
- **배포 zip 은 `worship_slides/` 폴더를 최상위에 포함해야 한다.** 앱 내장 업데이터
  (`update_service.dart`)가 압축을 푼 뒤 그 폴더를 찾아 설치 폴더에 덮어쓴다. 폴더가 없으면
  아무것도 복사하지 못하고 조용히 재시작만 한다. Windows 는 `Compress-Archive -Path dist/worship_slides`
  (뒤에 `\*` 를 붙이면 내용물만 담긴다), macOS 는 `ditto --keepParent`
- 업데이트는 폴더를 지우지 않고 **덮어쓰기**다. 실행 파일 옆 `worship_slides.db` 가 살아남아야 하기 때문.
  수동으로 새 빌드를 받아 갈아끼울 때도 폴더째 교체하지 말고 덮어써야 곡·콘티가 유지된다
- 앱은 시작 시 `yjchae/make_ppt-releases`의 최신 릴리즈를 확인해 업데이트 배너를 띄운다.
  **릴리즈 태그와 `pubspec.yaml`의 version이 같아야 한다**

## 의존성

- Dart: `file_picker`, `sqflite_common_ffi`, `path`, `path_provider`, `package_info_plus`, `http`
- Python: `python-pptx`, `pymupdf`, `pyinstaller`, `pillow`(악보 오선 찾기)
- 시스템: LibreOffice(`soffice`) — `.ppt` 임포트와 PPT 이미지 렌더에 필요 (없으면 해당 기능만 비활성)
- 시스템: Tesseract OCR — 악보 가사 추출에 필요. 한국어는 `kor` 언어 데이터까지 (없으면 해당 기능만 비활성)

## 기타

- `make_ppt_guide.py`, `make_user_guide.py` — 사용자 가이드 pptx/docx 생성 스크립트 (앱과 무관)
- `AGENTS.md` — 이 파일을 가리키는 포인터
