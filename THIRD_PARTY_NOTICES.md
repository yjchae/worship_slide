# 사용한 오픈소스 · 외부 구성 요소

Worship Slides 가 사용하거나 배포본에 포함하는 외부 소프트웨어·글꼴·서비스 목록입니다.
각 구성 요소의 저작권은 해당 저작자에게 있으며, 아래 라이선스를 따릅니다.

## 배포본에 포함되는 것

### Flutter / Dart 패키지

| 이름 | 용도 | 라이선스 |
|------|------|----------|
| [Flutter](https://github.com/flutter/flutter) · Dart SDK | 앱 UI 프레임워크 | BSD-3-Clause |
| [file_picker](https://pub.dev/packages/file_picker) | 파일·폴더 고르기 | MIT |
| [sqflite_common_ffi](https://pub.dev/packages/sqflite_common_ffi) | SQLite 접근 (데스크톱) | BSD-2-Clause |
| [sqlite3](https://pub.dev/packages/sqlite3) (sqflite_common_ffi 의존) | SQLite 바인딩 | MIT |
| [SQLite](https://www.sqlite.org/) | 데이터베이스 엔진 | Public Domain |
| [path](https://pub.dev/packages/path) | 경로 처리 | BSD-3-Clause |
| [path_provider](https://pub.dev/packages/path_provider) | 앱 데이터 폴더 찾기 | BSD-3-Clause |
| [package_info_plus](https://pub.dev/packages/package_info_plus) | 앱 버전 읽기 | BSD-3-Clause |
| [http](https://pub.dev/packages/http) | 업데이트 확인·구글 드라이브 요청 | BSD-3-Clause |
| [qr_flutter](https://pub.dev/packages/qr_flutter) · [qr](https://pub.dev/packages/qr) | 휴대폰 접속 QR 코드 | BSD-3-Clause |
| [cupertino_icons](https://pub.dev/packages/cupertino_icons) | 아이콘 | MIT |

전이 의존성까지 포함한 Dart 패키지 라이선스 전문은 Flutter 가 앱에 함께 묶습니다(`LicenseRegistry`).

### Python 도구 (`python/ppt_tool`, PyInstaller 로 묶음)

| 이름 | 용도 | 라이선스 |
|------|------|----------|
| [python-pptx](https://github.com/scanny/python-pptx) | PPT 가사 읽기·PPTX 만들기 | MIT |
| [lxml](https://lxml.de/) (python-pptx 의존) | XML 처리 | BSD-3-Clause |
| [XlsxWriter](https://github.com/jmcnamara/XlsxWriter) (python-pptx 의존) | python-pptx 내부 사용 | BSD-2-Clause |
| [PyMuPDF](https://github.com/pymupdf/PyMuPDF) (MuPDF) | PDF → PNG, PDF 글자 읽기 | **AGPL-3.0** (또는 Artifex 상용 라이선스) |
| [Pillow](https://github.com/python-pillow/Pillow) | 악보 이미지 처리·클립보드 그림 | MIT-CMU (HPND) |
| [PyInstaller](https://github.com/pyinstaller/pyinstaller) | 실행 파일로 묶기 | GPL-2.0 + 부트로더 예외 (묶인 앱에는 제약 없음) |
| [Python](https://www.python.org/) 런타임 | — | PSF License |

> PyMuPDF 는 AGPL-3.0 입니다. 이 앱은 소스 코드 전체를 공개 저장소로 배포하므로 AGPL 의 소스 공개 조건을 따릅니다.

> PPT 에 심은 글꼴(MicroType Express 압축)은 W3C Member Submission [MTX](https://www.w3.org/Submission/MTX/) 명세를 보고 직접 구현한 코드(`python/eot_font.py`)로 풉니다. 별도 라이브러리는 쓰지 않습니다.

### Windows 네이티브

| 이름 | 용도 | 라이선스 |
|------|------|----------|
| [Microsoft.Web.WebView2](https://www.nuget.org/packages/Microsoft.Web.WebView2) SDK (정적 로더) | 동영상·유튜브·배경 영상 재생 레이어 | BSD-3-Clause (Microsoft) |

### 글꼴

| 글꼴 | 저작자 | 라이선스 |
|------|--------|----------|
| [Pretendard](https://github.com/orioncactus/pretendard) | Kil Hyung-jin | SIL OFL 1.1 |
| [나눔고딕 · 나눔명조](https://hangeul.naver.com/font) | NAVER | SIL OFL 1.1 |
| [나눔손글씨 펜](https://fonts.google.com/specimen/Nanum+Pen+Script) | NAVER (NHN) | SIL OFL 1.1 |
| [Black Han Sans](https://fonts.google.com/specimen/Black+Han+Sans) | Zess Type | SIL OFL 1.1 |
| [Do Hyeon](https://fonts.google.com/specimen/Do+Hyeon) | Woowa Brothers | SIL OFL 1.1 |
| [Jua](https://fonts.google.com/specimen/Jua) | Woowa Brothers | SIL OFL 1.1 |
| [Gothic A1](https://fonts.google.com/specimen/Gothic+A1) | HanYang I&C | SIL OFL 1.1 |
| [IBM Plex Sans KR](https://github.com/IBM/plex) | IBM | SIL OFL 1.1 |

`assets/fonts/free/` 글꼴의 라이선스 전문은 같은 폴더의 `OFL-*.txt` 에 있습니다.

## 배포본에 포함하지 않는 것 (사용자 PC 에 따로 설치)

| 이름 | 용도 | 라이선스 |
|------|------|----------|
| [LibreOffice](https://www.libreoffice.org/) | `.ppt` 변환, PPT → PDF | MPL-2.0 |
| [Tesseract OCR](https://github.com/tesseract-ocr/tesseract) (+ tessdata) | 악보 가사 OCR (대체 경로) | Apache-2.0 |
| [cloudflared](https://github.com/cloudflare/cloudflared) | 휴대폰 화면 바깥 망 임시 터널 | Apache-2.0 |
| [Microsoft Edge WebView2 런타임](https://developer.microsoft.com/microsoft-edge/webview2/) | Windows 미디어 재생 | Microsoft 소프트웨어 라이선스 |
| [Homebrew](https://brew.sh/) · [winget](https://github.com/microsoft/winget-cli) | 선택 프로그램 자동 설치 | BSD-2-Clause · MIT |

## OS 기능 · 외부 서비스

- **Apple Vision**(`VNRecognizeTextRequest`), **WebKit**(WKWebView), **AVFoundation** — macOS 내장
- **Windows.Media.Ocr**, **GDI / GDI+**, 탐색기 썸네일(`IShellItemImageFactory`) — Windows 내장
- **Google Drive API v3** — 찬양·콘티 동기화 ([Google API 서비스 약관](https://developers.google.com/terms))
- **YouTube IFrame Player API** — 유튜브 페이지 재생 ([YouTube API 서비스 약관](https://developers.google.com/youtube/terms/api-services-terms-of-service))
- **Cloudflare Quick Tunnel** (`trycloudflare.com`) — 휴대폰 바깥 망 주소
- **GitHub Releases API** — 업데이트 확인
