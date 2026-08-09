# 외부 PPT 가져오기 (이미지 슬라이드) 기획

## 목표

로컬 `.ppt`/`.pptx` 파일을 골라서 **모든 페이지를 이미지로 변환**한 뒤, 예배 콘티에
하나의 항목으로 추가한다. 추가된 항목은 콘티 카드 / 슬라이드 순서 썸네일 / 발표 화면에서
동일하게 보이고, 순서 변경·개별 슬라이드 삭제·콘티 저장/불러오기·PPTX 내보내기가
기존 항목(찬양·말씀·빈 페이지)과 똑같이 동작한다.

가사 텍스트를 추출하는 기존 "가져오기"(폴더 → DB)와는 **완전히 별개 기능**이다.
이건 원본 디자인을 그대로 화면에 띄우는 용도다.

---

## 변환 방식 결정

| 후보 | 판단 |
|---|---|
| LibreOffice `--convert-to pdf` → PyMuPDF로 페이지별 PNG | **채택** |
| LibreOffice `--convert-to png` | Impress는 첫 슬라이드만 내보냄. 탈락 |
| `pdftoppm`(poppler) | 시스템 의존성 추가. 탈락 |
| Flutter `pdfx` 패키지로 PDF 직접 렌더 | Dart 플러그인 추가 + 렌더 캐시 직접 관리. PNG 미리 굽는 쪽이 짧다. 탈락 |

파이프라인: `원본 → (soffice --headless --convert-to pdf) → PDF → (PyMuPDF) → page-N.png`

- `.ppt`도 같은 경로로 처리된다 (soffice가 알아서 읽음). 별도 분기 불필요.
- 새 파이썬 의존성은 `pymupdf` **하나**. `python/requirements.txt`에 추가하면
  PyInstaller가 알아서 번들한다 (`scripts/build.sh` 수정 불필요).
- 렌더 해상도: 가로 1920px 기준 zoom 계산. 30장짜리 덱이 대략 10~20MB.

### 중요: LibreOffice가 필수가 된다

지금 LibreOffice는 `.ppt` 임포트에만 쓰이는 **선택** 의존성이다
(`ppt_tool.py:218 get_libreoffice_executable`). 이 기능은 `.pptx`에도 soffice가 필요하다.
없으면 기존 임포트처럼 `libreoffice_missing`을 돌려주고, UI에서
"LibreOffice를 설치해 주세요" 안내를 띄운다.

---

## 이미지 저장 위치

```
~/Library/Application Support/worship_slides/ppt_slides/<key>/001.png, 002.png, ...
(Windows: %LOCALAPPDATA%\worship_slides\ppt_slides\<key>\)
```

- `<key>` = sha1(원본 절대경로 + 파일크기 + mtime) — 기존
  `get_ppt_cache_key`(`ppt_tool.py:206`)와 같은 방식. 같은 파일 재선택 시 변환 스킵.
- 기존 `.ppt` 변환 캐시(`~/Library/Caches/...`)와 달리 **Caches가 아닌 Application Support**를 쓴다.
  콘티를 저장해 두고 몇 주 뒤 다시 열었을 때 OS가 캐시를 비워 이미지가 사라지면 안 되기 때문.
- 정리(cleanup)는 안 만든다. 필요해지면 그때.

---

## 변경 지점

### 1. `python/ppt_tool.py` — `render` 명령 추가

```
ppt_tool render <파일경로>
→ {"source_name": "...", "image_paths": ["/.../001.png", ...], "page_count": N}
→ 실패 시 {"error": "libreoffice_missing" | "..."}
```

- `get_libreoffice_executable()` 재사용.
- `--convert-to pdf --outdir <tmp>` 실행 → 나온 PDF를 `fitz.open()` →
  `page.get_pixmap(matrix=fitz.Matrix(z, z)).save(...)`.
- 캐시 디렉터리에 `.png`가 이미 페이지 수만큼 있으면 즉시 반환.
- `main()`에 `render` 분기 추가 (`ppt_tool.py:770`).

### 2. `python/requirements.txt`

```
pymupdf
```

### 3. `lib/.../domain/staging_item.dart` — `ImageStagingItem` 추가

```dart
class ImageStagingItem extends StagingItem {
  const ImageStagingItem({required this.sourceName, required this.imagePaths});
  final String sourceName;          // 표시용 파일명
  final List<String> imagePaths;    // 페이지 순서대로
  @override String get displayTitle => '[PPT] $sourceName';
  @override String get previewText => '${imagePaths.length}장';
}
```

`StagingItem`이 `sealed`이므로 **switch 문을 전부 컴파일 에러로 잡아준다.**
아래 목록은 그 에러가 나는 자리 전부다.

### 4. `lib/.../presentation/slide_page_data.dart`

`String? imagePath` 필드 + JSON 직렬화 추가. (발표 창은 별도 엔진이라 JSON으로만 넘어감)

### 5. `lib/.../presentation/slide_render_view.dart`

`build` 맨 앞에 분기 하나:

```dart
if (data.imagePath != null) {
  return Container(
    color: style.backgroundColor,
    child: Image.file(File(data.imagePath!), fit: BoxFit.contain),
  );
}
```

이 한 곳만 고치면 **발표 창 · 슬라이드 순서 썸네일 · 디자인 미리보기 세 곳이 전부 해결된다**
(셋 다 `SlideRenderView`를 공유. `praise_home_page.dart:4404`, `:5005`,
`presentation_window_app.dart:62`).

- `BoxFit.contain` — 16:9가 아닌 원본도 잘리지 않게. 남는 여백은 배경색.
- 디자인 설정(폰트/색/위치)은 이미지 슬라이드에 적용되지 않는다. 원본 그대로가 목적.

### 6. `lib/.../presentation/praise_home_page.dart`

| 위치 | 변경 |
|---|---|
| `_SlideInfo` (`:33`) | `String? imagePath` 필드 추가 |
| `_allSlides` (`:269`) | `ImageStagingItem` 분기: 페이지마다 `_SlideInfo(imagePath: ..., pageIndexInItem: j)`. 곡과 동일하게 뒤에 자동 여백 1장 |
| `_buildSlidePageData` (`:378`) | `imagePath: slide?.imagePath` 전달 |
| `_effectiveStagingItems` (`:201`) | 삭제된 페이지를 뺀 `imagePaths`로 재구성 (곡 로직과 동일) |
| `_editSlide` (`:467`) | 이미지 슬라이드는 텍스트 편집 불가 → 스낵바로 안내하고 반환 |
| `_PreviewBox` (`:4362`) | `ImageStagingItem` case 추가 (첫 장) |
| `_addPptImages()` 신규 | 파일 선택 → 변환 → 콘티 삽입 (아래) |
| `_StagingPanel` (`:916`) | `onImportPpt` 콜백 + 헤더 아이콘 버튼 추가 |

`_addPptImages()` 흐름:

```
FilePicker.pickFiles(type: custom, allowedExtensions: ['ppt','pptx'], allowMultiple: true)
  → 변환 중 다이얼로그 (파일 여러 개면 "3개 중 1번째")
  → PythonBridge.renderPptToImages(path)
  → 현재 선택된 콘티 항목 다음 위치에 삽입 (_addBlankItem(:711)과 동일한 삽입 규칙)
  → 실패 시 스낵바 + AppLogger.error
```

버튼은 콘티 패널 헤더의 "빈 페이지 추가" 옆에 배치.
아이콘 `Icons.slideshow_outlined`, 툴팁 **"PPT 슬라이드 가져오기"**.
(상단의 기존 "가져오기"는 폴더→DB 텍스트 임포트이므로 이름을 확실히 구분한다.)

### 7. `lib/.../data/python_bridge.dart`

```dart
Future<ImageStagingItem> renderPptToImages(String filePath)
```
`_runTool(['render', filePath])` 호출 후 JSON 파싱. `libreoffice_missing`이면
전용 예외를 던져 UI에서 설치 안내 문구로 바꾼다.

### 8. `lib/.../data/praise_database.dart` — 스키마 v9

```sql
ALTER TABLE worship_conti_items ADD COLUMN image_paths TEXT;   -- \n 조인
ALTER TABLE worship_conti_items ADD COLUMN image_source TEXT;
```
`version: 8` → `9`, `onUpgrade`에 `if (oldVersion < 9)` 블록, `onCreate` 테이블 정의에도 추가.

### 9. `lib/.../data/worship_conti_repository.dart`

- `saveConti`: `item_type: 'image'` 행 저장.
- `loadConti`: `'image'` 분기. **불러올 때 각 PNG의 존재 여부를 확인**하고,
  하나라도 없으면 그 항목은 건너뛰고 `missingCount`에 더한다
  (기존 곡 누락 처리와 같은 UX. 사용자에겐 "N개 항목을 찾지 못했습니다"로 표시).

### 10. PPTX 내보내기 — `ppt_tool.py` `export_presentation`

`type == "image"`인 항목은 페이지마다 슬라이드를 만들고
`slide.shapes.add_picture()`로 13.333×7.5in 안에 비율 유지해 중앙 배치.
배경은 기존 `_apply_slide_background`. 약 15줄.

이걸 빼면 내보낸 PPTX에서 해당 슬라이드가 조용히 사라지므로 같이 넣는다.
`python_bridge.dart`의 `exportPresentation` payload switch에도 `ImageStagingItem` case 추가.

---

## 안 하는 것

- 이미지 슬라이드에 텍스트 오버레이 / 디자인 설정 적용 — 원본 유지가 목적
- 캐시 자동 정리, 용량 관리
- 콘티 저장 시 이미지를 콘티별로 복사 (원본 캐시 경로를 그대로 참조. 원본 파일이
  바뀌면 키가 달라져 새로 굽고, 예전 이미지는 캐시에 남아 있으므로 콘티는 계속 열린다)
- PDF 파일 직접 가져오기 — 나중에 필요하면 `render` 명령에서 pdf 분기 3줄 추가로 끝난다

---

## 검증

`python/test_render.py` (assert 기반 self-check 하나):

```
tmp_sample/의 pptx 하나 → render → 반환된 image_paths가
(1) 전부 존재하고 (2) 개수가 python-pptx로 센 슬라이드 수와 같은지
```

LibreOffice가 없는 환경이면 skip. Dart 쪽은 기존대로 `flutter analyze`로
sealed switch 누락을 잡는다.

---

## 작업 순서

1. `ppt_tool.py` `render` + requirements + self-check — 여기서 변환이 실제로 되는지부터 확인
2. `ImageStagingItem` → `flutter analyze`로 고쳐야 할 switch 목록 확보
3. `SlidePageData` / `SlideRenderView` (화면 표시)
4. `python_bridge` + `_addPptImages` + 버튼 (가져오기 동작)
5. DB v9 + 콘티 저장/불러오기
6. PPTX 내보내기
