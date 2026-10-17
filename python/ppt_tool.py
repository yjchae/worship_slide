import concurrent.futures
import copy
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
import zipfile
from pathlib import Path

from lxml import etree
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.oxml.ns import qn
from pptx.oxml.xmlchemy import OxmlElement
from pptx.util import Inches, Pt

PPT_CONVERT_CHUNK_SIZE = 40
PPT_CONVERT_PARALLELISM = 3

_PAGE_SEP_RE = re.compile(r'\n[ \t]*\n')


def _encode_pages(pages):
    """페이지 목록 → \\n\\n 구분 저장 형식."""
    i = len(pages)
    while i > 0 and not pages[i - 1]:
        i -= 1
    return '\n\n'.join(pages[:i])


def _decode_pages(text):
    """\\n\\n 구분 저장 형식 → 페이지 목록."""
    if not text:
        return []
    text = text.replace('\r\n', '\n').replace('\r', '\n')
    pages = [p.strip() for p in _PAGE_SEP_RE.split(text)]
    while pages and not pages[-1]:
        pages.pop()
    return pages

_FONT_FILES = {
    "Pretendard":    ["Pretendard-Regular.ttf", "Pretendard-Bold.ttf"],
    "NanumGothic":   ["NanumGothic-Regular.ttf", "NanumGothic-Bold.ttf"],
    "NanumMyeongjo": ["NanumMyeongjo-Regular.ttf", "NanumMyeongjo-Bold.ttf"],
}


def _get_font_path(filename):
    if getattr(sys, "frozen", False):
        return os.path.join(sys._MEIPASS, "fonts", filename)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(script_dir, "..", "assets", "fonts", filename)


def _ensure_fonts_installed(font_family="Pretendard", font_files=()):
    """내보낸 PPTX 를 PowerPoint 에서 열 때 폰트가 있도록 사용자 폰트 폴더에 깐다.

    font_files: 앱에서 추가한 폰트(FontLibrary)의 [{path, weight}]. 없으면 번들 폰트.
    """
    import platform
    windows = platform.system() == "Windows"
    if windows:
        local_appdata = os.environ.get("LOCALAPPDATA", "")
        if not local_appdata:
            return
        fonts_dir = os.path.join(local_appdata, "Microsoft", "Windows", "Fonts")
    else:
        fonts_dir = os.path.expanduser("~/Library/Fonts")
    os.makedirs(fonts_dir, exist_ok=True)
    if font_files:
        sources = [f["path"] for f in font_files if f.get("path")]
    else:
        sources = [_get_font_path(n)
                   for n in _FONT_FILES.get(font_family, _FONT_FILES["Pretendard"])]
    for src in sources:
        dest = os.path.join(fonts_dir, os.path.basename(src))
        if os.path.exists(dest) or not os.path.exists(src):
            continue
        shutil.copy2(src, dest)
        if windows:
            _register_windows_font(dest)


def _register_windows_font(path):
    """사용자 폰트 폴더에 복사만 하면 Windows 는 폰트로 안 본다.
    레지스트리에 적어야 다음 로그인부터, AddFontResource 까지 해야 지금 바로 보인다.
    실패해도 내보내기는 계속한다 (PPTX 는 이미 폰트 이름만 담고 있다)."""
    try:
        import ctypes
        import winreg
        name = os.path.splitext(os.path.basename(path))[0] + " (TrueType)"
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r"Software\Microsoft\Windows NT\CurrentVersion\Fonts",
                            0, winreg.KEY_SET_VALUE) as key:
            winreg.SetValueEx(key, name, 0, winreg.REG_SZ, path)
        ctypes.windll.gdi32.AddFontResourceW(path)
        HWND_BROADCAST, WM_FONTCHANGE = 0xFFFF, 0x001D
        ctypes.windll.user32.SendMessageTimeoutW(
            HWND_BROADCAST, WM_FONTCHANGE, 0, 0, 0x0002, 1000, None)
    except Exception:
        pass


# 색 이름(prstClr)으로 쓴 흰색·검은색을 RGB 와 같은 값으로 본다.
_PRESET_COLORS = {"white": "FFFFFF", "black": "000000"}


def _paragraph_color(paragraph):
    """문단의 첫 글자 색. 직접 지정한 색이 없으면(상속) None."""
    from pptx.oxml.ns import qn

    for run in paragraph.runs:
        if not run.text.strip():
            continue
        rpr = run._r.find(qn("a:rPr"))
        fill = rpr.find(qn("a:solidFill")) if rpr is not None else None
        if fill is None or len(fill) == 0:
            return None
        color = fill[0]
        value = color.get("val")
        if color.tag == qn("a:prstClr"):
            value = _PRESET_COLORS.get(value, value)
        return f"{color.tag.rsplit('}', 1)[-1]}:{value}".replace("prstClr:", "srgbClr:")
    return None


def extract_lines_from_shape(shape):
    """shape 의 (줄, 색) 목록."""
    if not hasattr(shape, "text_frame") or shape.text_frame is None:
        return []
    lines = []
    for paragraph in shape.text_frame.paragraphs:
        text = "".join(run.text for run in paragraph.runs).strip()
        if text:
            lines.append((text, _paragraph_color(paragraph)))
    return lines


def extract_text_from_shape(shape):
    return "\n".join(text for text, _ in extract_lines_from_shape(shape))


def _find_title_texts(prs):
    """텍스트가 있는 슬라이드의 80% 이상에서 동일한 전체 텍스트로 반복되는
    텍스트박스의 내용을 반환한다. (위치가 아닌 shape 전체 텍스트의 완전 일치 기준)
    가사 shape는 슬라이드마다 다른 내용을 가지므로 걸러지지 않고,
    제목 shape만 동일 텍스트로 매 슬라이드에 반복되어 걸러진다."""
    text_count = {}
    content_slide_count = 0

    for slide in prs.slides:
        seen = set()
        slide_has_text = False
        for shape in slide.shapes:
            text = extract_text_from_shape(shape).strip()
            if not text:
                continue
            slide_has_text = True
            if text not in seen:
                seen.add(text)
                text_count[text] = text_count.get(text, 0) + 1
        if slide_has_text:
            content_slide_count += 1

    if content_slide_count < 2:
        return set()

    threshold = max(2, round(content_slide_count * 0.8))
    return {text for text, count in text_count.items() if count >= threshold}


def _shape_max_font_pt(shape):
    """명시적으로 설정된 최대 폰트 크기(pt)를 반환. 없으면 None."""
    if not hasattr(shape, "text_frame") or shape.text_frame is None:
        return None
    max_pt = None
    for paragraph in shape.text_frame.paragraphs:
        for run in paragraph.runs:
            if run.font.size is not None:
                pt = run.font.size.pt
                max_pt = pt if max_pt is None else max(max_pt, pt)
    return max_pt


def slide_lyrics(slide, title_texts=None):
    """슬라이드의 가사 (줄, 색) 목록."""
    shapes_info = []
    for shape in slide.shapes:
        lines = extract_lines_from_shape(shape)
        if not lines:
            continue
        # shape 전체 텍스트가 반복 제목과 완전히 일치하는 shape만 제외
        text = "\n".join(line for line, _ in lines)
        if title_texts and text.strip() in title_texts:
            continue
        shapes_info.append((lines, _shape_max_font_pt(shape)))

    # 보조 필터: 명시적 폰트 크기가 최댓값의 60% 미만인 박스도 제목/캡션으로 간주
    explicit_sizes = [size for _, size in shapes_info if size is not None]
    if len(shapes_info) > 1 and explicit_sizes:
        max_size = max(explicit_sizes)
        kept = [
            info for info in shapes_info
            if info[1] is None or info[1] >= max_size * 0.6
        ]
        shapes_info = kept or shapes_info

    return [line for lines, _ in shapes_info for line in lines]


def _main_lyrics_color(slides_lines):
    """원본 가사 색. 한글 줄에 가장 많이 쓴 색이고, 한글 줄이 없으면(영어 원곡)
    흰색, 흰 줄도 없으면 가장 많이 쓴 색. 줄이 하나도 없으면 _NO_MAIN_COLOR."""
    hangul_counts = {}
    all_counts = {}
    for lines in slides_lines:
        for text, color in lines:
            all_counts[color] = all_counts.get(color, 0) + 1
            if _HANGUL_RE.search(text):
                hangul_counts[color] = hangul_counts.get(color, 0) + 1
    if hangul_counts:
        return max(hangul_counts, key=hangul_counts.get)
    if _WHITE in all_counts:
        return _WHITE
    if all_counts:
        return max(all_counts, key=all_counts.get)
    return _NO_MAIN_COLOR


def normalize_title(path):
    # macOS HFS+는 파일명을 NFD로 저장하므로 NFC로 변환해야 한글이 정상 표시됨
    title = unicodedata.normalize('NFC', path.stem.strip())
    return re.sub(r'\s*\(\s*와이드 스크린\s*\)\s*', '', title, flags=re.IGNORECASE).strip()


def is_sub_line(line):
    """보조 언어 줄인가 — 한글이 없고 글자가 하나라도 있으면 그렇다.

    예전에는 라틴 문자 비율 60% 이상만 보조로 봤다. 그러면 일본어·중국어 가사가
    한국어 쪽에 섞여 버려서 다국어를 못 쓴다. "1. 2." 같은 숫자 줄은 alpha 가 없어
    예전처럼 한국어 쪽에 남는다.
    """
    stripped = line.strip()
    if not stripped:
        return False
    if any("\uac00" <= char <= "\ud7a3" for char in stripped):
        return False
    return any(char.isalpha() for char in stripped)


_WHITE = "srgbClr:FFFFFF"
# 원본 가사 색을 모를 때(줄이 없음, 문자열 입력) — 어떤 색과도 같지 않다.
_NO_MAIN_COLOR = object()


def split_bilingual_page(lines, main_color=_NO_MAIN_COLOR):
    """(줄, 색) 목록(또는 줄바꿈 문자열) → (본문, 보조 언어).

    PPT 는 번역 가사를 다른 색(주로 주황)으로 칠해 둔다. 그래서 한글이 없는 줄이라도
    원본 가사 색([main_color])과 같으면 원곡에 있는 영어(`How great is our God`, `(x2)`)로 보고
    원본 가사에 남긴다."""
    if isinstance(lines, str):
        lines = [(line, None) for line in lines.splitlines()]
    korean_lines = []
    sub_lines = []

    for line, color in lines:
        stripped = line.strip()
        if not stripped:
            continue
        if is_sub_line(stripped) and color != main_color:
            sub_lines.append(stripped)
        else:
            korean_lines.append(stripped)

    return "\n".join(korean_lines), "\n".join(sub_lines)


def get_cache_root():
    import platform
    if platform.system() == "Windows":
        local_appdata = os.environ.get("LOCALAPPDATA")
        if local_appdata:
            return Path(local_appdata) / "worship_slides" / "ppt_import_cache"
        return Path.home() / "AppData" / "Local" / "worship_slides" / "ppt_import_cache"
    return Path.home() / "Library" / "Caches" / "worship_slides" / "ppt_import_cache"


def get_ppt_cache_key(source_path):
    stat = source_path.stat()
    payload = f"{source_path.resolve()}::{stat.st_size}::{stat.st_mtime_ns}"
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()


def get_app_support_root():
    """Caches와 달리 OS가 임의로 비우지 않는 영역.
    콘티에 저장된 이미지 슬라이드가 나중에 사라지면 안 되므로 여기에 굽는다."""
    import platform
    if platform.system() == "Windows":
        local_appdata = os.environ.get("LOCALAPPDATA")
        base = Path(local_appdata) if local_appdata else Path.home() / "AppData" / "Local"
        return base / "worship_slides" / "ppt_slides"
    return Path.home() / "Library" / "Application Support" / "worship_slides" / "ppt_slides"


def get_cached_pptx_path(source_path):
    cache_root = get_cache_root()
    cache_root.mkdir(parents=True, exist_ok=True)
    return cache_root / f"{get_ppt_cache_key(source_path)}.pptx"


def get_libreoffice_executable():
    candidates = [
        shutil.which("soffice"),
        shutil.which("libreoffice"),
        "/Applications/LibreOffice.app/Contents/MacOS/soffice",
        "/Applications/LibreOffice.app/Contents/MacOS/LibreOffice",
        r"C:\Program Files\LibreOffice\program\soffice.exe",
        r"C:\Program Files (x86)\LibreOffice\program\soffice.exe",
    ]
    for candidate in candidates:
        if candidate and os.path.exists(candidate):
            return candidate
    return None


def convert_ppt_group_to_pptx(source_paths, output_dir):
    libreoffice = get_libreoffice_executable()
    if libreoffice is None:
        raise RuntimeError("LibreOffice 실행 파일을 찾지 못했습니다.")

    subprocess.run(
        [
            libreoffice,
            "--headless",
            "--convert-to",
            "pptx",
            "--outdir",
            str(output_dir),
            *[str(source_path) for source_path in source_paths],
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    converted_map = {}
    used_targets = set()
    for source_path in source_paths:
        stem_pattern = re.escape(source_path.stem)
        candidates = sorted(output_dir.glob(f"{source_path.stem}*.pptx"))
        matched = next(
            (
                candidate
                for candidate in candidates
                if candidate not in used_targets
                and re.fullmatch(rf"{stem_pattern}(?:_[0-9]+)?\.pptx", candidate.name, re.IGNORECASE)
            ),
            None,
        )
        if matched is not None:
            used_targets.add(matched)
            converted_map[source_path] = matched

    return converted_map


def chunked(items, chunk_size):
    for index in range(0, len(items), chunk_size):
        yield items[index : index + chunk_size]


def iter_presentation_files(root):
    def handle_walk_error(error):
        print(
            json.dumps(
                {
                    "warning": f"폴더를 읽지 못했습니다: {error.filename}",
                },
                ensure_ascii=True,
            ),
            file=sys.stderr,
        )

    for current_root, dir_names, file_names in os.walk(root, onerror=handle_walk_error):
        dir_names[:] = [name for name in dir_names if not name.startswith(".")]
        for file_name in sorted(file_names):
            suffix = Path(file_name).suffix.lower()
            if suffix not in {".ppt", ".pptx"}:
                continue
            yield Path(current_root) / file_name


def process_presentation_file(file_path, presentation_path):
    try:
        prs = Presentation(str(presentation_path))
        title_texts = _find_title_texts(prs)
        korean_pages = []
        english_pages = []
        slides_lines = [
            slide_lyrics(slide, title_texts=title_texts) for slide in prs.slides
        ]
        main_color = _main_lyrics_color(slides_lines)
        for page in slides_lines:
            if not page:
                korean_pages.append("")
                english_pages.append("")
                continue
            korean_page, english_page = split_bilingual_page(page, main_color)
            korean_pages.append(korean_page)
            english_pages.append(english_page)

        # 끝에 남은 빈 페이지 제거
        while korean_pages and not korean_pages[-1] and not english_pages[-1]:
            korean_pages.pop()
            english_pages.pop()

        if not any(page for page in korean_pages + english_pages):
            return {"status": "skipped", "path": str(file_path)}

        return {
            "status": "ok",
            "song": {
                "file_name": file_path.name,
                "title": normalize_title(file_path),
                "lyrics": _encode_pages(korean_pages),
                "english_lyrics": _encode_pages(english_pages),
            },
            "path": str(file_path),
        }
    except Exception as error:
        return {
            "status": "error",
            "error": {
                "file_name": file_path.name,
                "path": str(file_path),
                "error": str(error),
            },
        }


def _is_libreoffice_available():
    return get_libreoffice_executable() is not None


def prepare_presentation_sources(file_paths):
    prepared_sources = []
    errors = []
    temp_dirs = []
    ppt_groups = {}

    for file_path in file_paths:
        if file_path.suffix.lower() == ".ppt":
            cached_pptx = get_cached_pptx_path(file_path)
            if cached_pptx.exists():
                prepared_sources.append((file_path, cached_pptx))
            else:
                ppt_groups.setdefault(file_path.parent, []).append(file_path)
        else:
            prepared_sources.append((file_path, file_path))

    if ppt_groups and not _is_libreoffice_available():
        for file_path_list in ppt_groups.values():
            for file_path in file_path_list:
                errors.append(
                    {
                        "file_name": file_path.name,
                        "path": str(file_path),
                        "error": "libreoffice_missing",
                    }
                )
        ppt_groups = {}

    for index, directory in enumerate(sorted(ppt_groups, key=lambda item: str(item).casefold())):
        source_paths = sorted(ppt_groups[directory], key=lambda path: str(path).casefold())
        chunks = list(chunked(source_paths, PPT_CONVERT_CHUNK_SIZE))
        chunk_jobs = []
        for chunk_index, source_chunk in enumerate(chunks):
            output_dir = Path(
                tempfile.mkdtemp(prefix=f"praise_ppt_batch_{index}_{chunk_index}_")
            )
            temp_dirs.append(output_dir)
            chunk_jobs.append((source_chunk, output_dir))

        with concurrent.futures.ThreadPoolExecutor(
            max_workers=min(PPT_CONVERT_PARALLELISM, len(chunk_jobs))
        ) as executor:
            future_map = {
                executor.submit(convert_ppt_group_to_pptx, source_chunk, output_dir): (
                    source_chunk,
                    output_dir,
                )
                for source_chunk, output_dir in chunk_jobs
            }
            for future in concurrent.futures.as_completed(future_map):
                source_chunk, _ = future_map[future]
                try:
                    converted_map = future.result()
                    for source_path in source_chunk:
                        converted_path = converted_map.get(source_path)
                        if converted_path is None or not converted_path.exists():
                            errors.append(
                                {
                                    "file_name": source_path.name,
                                    "path": str(source_path),
                                    "error": f"PPT 변환 실패: {source_path}",
                                }
                            )
                            continue

                        cached_pptx = get_cached_pptx_path(source_path)
                        shutil.copy2(converted_path, cached_pptx)
                        prepared_sources.append((source_path, cached_pptx))
                except Exception as error:
                    for source_path in source_chunk:
                        errors.append(
                            {
                                "file_name": source_path.name,
                                "path": str(source_path),
                                "error": str(error),
                            }
                        )

    prepared_sources.sort(key=lambda item: str(item[0]).casefold())
    return prepared_sources, errors, temp_dirs


def get_import_worker_count(file_count):
    cpu_count = os.cpu_count() or 4
    return max(1, min(file_count, cpu_count, 8))


def import_folder(folder):
    root = Path(folder)
    if not root.exists():
        raise RuntimeError(f"폴더를 찾을 수 없습니다: {folder}")

    file_paths = list(iter_presentation_files(root))
    songs = []
    errors = []
    processed_count = len(file_paths)

    prepared_sources, preparation_errors, temp_dirs = prepare_presentation_sources(file_paths)
    errors.extend(preparation_errors)

    try:
        if prepared_sources:
            max_workers = get_import_worker_count(len(prepared_sources))
            with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
                futures = [
                    executor.submit(process_presentation_file, source_path, presentation_path)
                    for source_path, presentation_path in prepared_sources
                ]
                for future in concurrent.futures.as_completed(futures):
                    result = future.result()
                    if result["status"] == "ok":
                        songs.append(result["song"])
                    elif result["status"] == "error":
                        errors.append(result["error"])
    finally:
        for temp_dir in temp_dirs:
            shutil.rmtree(temp_dir, ignore_errors=True)

    songs.sort(key=lambda song: (song["title"].casefold(), song["file_name"].casefold()))
    errors.sort(key=lambda entry: entry["path"].casefold())

    print(
        json.dumps(
            {
                "songs": songs,
                "processed_count": processed_count,
                "imported_count": len(songs),
                "failed_count": len(errors),
                "errors": errors,
                "worker_count": get_import_worker_count(processed_count),
                "libreoffice_missing": any(
                    e["error"] == "libreoffice_missing" for e in errors
                ),
            },
            ensure_ascii=True,
        )
    )


# ---------------------------------------------------------------------------
# 외부 PPT 애니메이션 → 단계별 페이지
#
# LibreOffice가 PDF로 굽는 순간 애니메이션은 사라지고 "다 나타난 마지막 상태" 한 장만
# 남는다. 그래서 PDF로 넘기기 전에 pptx를 직접 뜯어, 클릭 한 번마다 화면에 보이는 상태를
# 슬라이드 한 장씩으로 복제해 둔다. 움직이는 효과 자체는 재현하지 못하지만
# "클릭할 때마다 하나씩 나타난다"는 순서는 그대로 살아난다.
# ---------------------------------------------------------------------------

_P_NS = "http://schemas.openxmlformats.org/presentationml/2006/main"
_A_NS = "http://schemas.openxmlformats.org/drawingml/2006/main"
_R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
_CT_NS = "http://schemas.openxmlformats.org/package/2006/content-types"
_PKG_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"

_SLIDE_CONTENT_TYPE = (
    "application/vnd.openxmlformats-officedocument.presentationml.slide+xml"
)
_SLIDE_REL_TYPE = f"{_R_NS}/slide"
_NOTES_REL_TYPE = f"{_R_NS}/notesSlide"

# 슬라이드 한 장이 수십 장으로 불어나면 발표도 캐시도 감당이 안 된다.
ANIM_MAX_STEPS_PER_SLIDE = 30
ANIM_MAX_TOTAL_PAGES = 600

_SLIDE_PART_RE = re.compile(r"ppt/slides/slide(\d+)\.xml$")


def _p(tag):
    return f"{{{_P_NS}}}{tag}"


def _a(tag):
    return f"{{{_A_NS}}}{tag}"


_SHAPE_TAGS = frozenset(
    _p(tag) for tag in ("sp", "pic", "graphicFrame", "grpSp", "cxnSp")
)


def _shape_id(element):
    """도형 XML → PowerPoint가 애니메이션 대상으로 지목하는 id(spid)."""
    # cNvPr은 항상 nvSpPr/nvPicPr/... 바로 아래에 있다. iter로 훑으면 그룹 안쪽
    # 자식 도형의 id까지 잡히므로 한 단계만 내려간다.
    marker = element.find(f"./*/{_p('cNvPr')}")
    return None if marker is None else marker.get("id")


def _iter_shapes(parent):
    """spTree 아래 도형을 그룹 안쪽까지 훑는다."""
    for element in parent:
        if element.tag in _SHAPE_TAGS:
            yield element
            if element.tag == _p("grpSp"):
                yield from _iter_shapes(element)


def _paragraph_count(shape):
    body = shape.find(_p("txBody"))
    return 0 if body is None else len(body.findall(_a("p")))


def _paragraph_range(shape_target):
    """<p:spTgt><p:txEl><p:pRg st=".." end=".."/> → 문단 번호들. 없으면 None(도형 통째)."""
    text_range = shape_target.find(f"{_p('txEl')}/{_p('pRg')}")
    if text_range is None:
        return None
    try:
        start = int(text_range.get("st", "0"))
        end = int(text_range.get("end", text_range.get("st", "0")))
    except ValueError:
        return None
    return tuple(range(start, max(start, end) + 1))


def _click_steps(slide_root):
    """메인 시퀀스를 클릭 단위로 끊는다 → [[(entr|exit, spid, 문단들|None), ...], ...]"""
    timing = slide_root.find(_p("timing"))
    if timing is None:
        return []

    main_sequence = next(
        (node for node in timing.iter(_p("cTn")) if node.get("nodeType") == "mainSeq"),
        None,
    )
    if main_sequence is None:
        return []

    children = main_sequence.find(_p("childTnLst"))
    if children is None:
        return []

    steps = []
    for click_group in children:
        effects = []
        for node in click_group.iter(_p("cTn")):
            preset = node.get("presetClass")
            if preset not in ("entr", "exit"):
                continue
            for target in node.iter(_p("spTgt")):
                spid = target.get("spid")
                if spid:
                    effects.append((preset, spid, _paragraph_range(target)))
        if effects:
            steps.append(effects)
    return steps


def _animation_frames(slide_root):
    """클릭 단계마다 '감춰야 할 것' 목록. 나눌 게 없으면 None.

    한 프레임은 (감출 도형 id 집합, {도형 id: 감출 문단 번호 집합}).
    """
    steps = _click_steps(slide_root)
    if not steps:
        return None

    shape_tree = slide_root.find(f"{_p('cSld')}/{_p('spTree')}")
    if shape_tree is None:
        return None

    shapes = {}
    for element in _iter_shapes(shape_tree):
        spid = _shape_id(element)
        if spid:
            shapes[spid] = element

    def hide(hidden_shapes, hidden_paragraphs, spid, paragraphs):
        if paragraphs is None:
            hidden_shapes.add(spid)
        else:
            limit = _paragraph_count(shapes[spid])
            hidden_paragraphs.setdefault(spid, set()).update(
                index for index in paragraphs if index < limit
            )

    # 시작 화면: 등장 애니메이션이 걸린 것들은 아직 안 보인다.
    hidden_shapes = set()
    hidden_paragraphs = {}
    for effects in steps:
        for preset, spid, paragraphs in effects:
            if preset == "entr" and spid in shapes:
                hide(hidden_shapes, hidden_paragraphs, spid, paragraphs)

    def snapshot():
        return (
            set(hidden_shapes),
            {spid: set(indexes) for spid, indexes in hidden_paragraphs.items() if indexes},
        )

    frames = [snapshot()]
    for effects in steps:
        for preset, spid, paragraphs in effects:
            if spid not in shapes:
                continue
            if preset == "entr":
                if paragraphs is None:
                    hidden_shapes.discard(spid)
                else:
                    hidden_paragraphs.get(spid, set()).difference_update(paragraphs)
            else:
                hide(hidden_shapes, hidden_paragraphs, spid, paragraphs)
        frames.append(snapshot())

    # 강조 효과처럼 화면이 그대로인 단계는 페이지를 늘릴 이유가 없다.
    unique = [frames[0]]
    for frame in frames[1:]:
        if frame != unique[-1]:
            unique.append(frame)

    if len(unique) < 2 or len(unique) > ANIM_MAX_STEPS_PER_SLIDE:
        return None
    return unique


def _blank_paragraphs(shape, indexes):
    """문단의 글자만 지운다. 문단 자체는 남겨야 나머지 줄이 위아래로 밀리지 않는다."""
    body = shape.find(_p("txBody"))
    if body is None:
        return
    paragraphs = body.findall(_a("p"))
    for index in indexes:
        if index >= len(paragraphs):
            continue
        paragraph = paragraphs[index]
        line_height_source = None
        for child in list(paragraph):
            if child.tag in (_a("r"), _a("br"), _a("fld")):
                if line_height_source is None:
                    run_properties = child.find(_a("rPr"))
                    if run_properties is not None:
                        line_height_source = copy.deepcopy(run_properties)
                paragraph.remove(child)
            elif child.tag == _a("endParaRPr"):
                if line_height_source is None:
                    line_height_source = copy.deepcopy(child)
                paragraph.remove(child)
        # 빈 문단의 줄 높이는 endParaRPr의 글자 크기를 따라간다.
        if line_height_source is not None:
            line_height_source.tag = _a("endParaRPr")
            paragraph.append(line_height_source)


def _apply_frame(slide_root, frame):
    hidden_shapes, hidden_paragraphs = frame
    shape_tree = slide_root.find(f"{_p('cSld')}/{_p('spTree')}")
    if shape_tree is None:
        return
    for element in list(_iter_shapes(shape_tree)):
        spid = _shape_id(element)
        if spid is None:
            continue
        if spid in hidden_shapes:
            parent = element.getparent()
            if parent is not None:
                parent.remove(element)
        elif spid in hidden_paragraphs:
            _blank_paragraphs(element, hidden_paragraphs[spid])


def _read_package(path):
    with zipfile.ZipFile(path) as archive:
        return {name: archive.read(name) for name in archive.namelist()}


def _write_package(parts, path):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in parts.items():
            archive.writestr(name, data)


def _parse_xml(data):
    return etree.fromstring(data)


def _serialize_xml(root):
    return etree.tostring(root, xml_declaration=True, encoding="UTF-8", standalone=True)


def _slide_parts_in_order(presentation_rels, slide_id_list):
    targets = {}
    for relationship in presentation_rels:
        if relationship.get("Type") != _SLIDE_REL_TYPE:
            continue
        target = (relationship.get("Target") or "").lstrip("/")
        if not target.startswith("ppt/"):
            target = f"ppt/{target}"
        targets[relationship.get("Id")] = target

    order = []
    for slide_id in slide_id_list:
        part_name = targets.get(slide_id.get(f"{{{_R_NS}}}id"))
        if part_name:
            order.append((slide_id, part_name))
    return order


def _next_relationship_id(used_ids):
    number = 1
    while f"rId{number}" in used_ids:
        number += 1
    relationship_id = f"rId{number}"
    used_ids.add(relationship_id)
    return relationship_id


def _copy_slide_rels(data):
    """복제 슬라이드용 관계 파일. 슬라이드 노트는 1:1이라 물려주면 안 된다."""
    root = _parse_xml(data)
    for relationship in list(root):
        if relationship.get("Type") == _NOTES_REL_TYPE:
            root.remove(relationship)
    return _serialize_xml(root)


def expand_animation_steps(source_pptx, output_pptx):
    """클릭 애니메이션이 걸린 슬라이드를 단계 수만큼 복제한 pptx를 만든다.

    만든 파일 경로를 돌려준다. 나눌 애니메이션이 없으면 None(원본 그대로 렌더하면 된다).
    """
    parts = _read_package(source_pptx)
    if "ppt/presentation.xml" not in parts or "ppt/_rels/presentation.xml.rels" not in parts:
        return None

    presentation = _parse_xml(parts["ppt/presentation.xml"])
    presentation_rels = _parse_xml(parts["ppt/_rels/presentation.xml.rels"])
    slide_id_list = presentation.find(_p("sldIdLst"))
    if slide_id_list is None:
        return None

    order = _slide_parts_in_order(presentation_rels, slide_id_list)
    plans = {}
    total_pages = 0
    for _, part_name in order:
        frames = _animation_frames(_parse_xml(parts[part_name])) if part_name in parts else None
        plans[part_name] = frames
        total_pages += len(frames) if frames else 1

    if not any(plans.values()) or total_pages > ANIM_MAX_TOTAL_PAGES:
        return None

    content_types = _parse_xml(parts["[Content_Types].xml"])
    used_numbers = {
        int(match.group(1))
        for name in parts
        if (match := _SLIDE_PART_RE.fullmatch(name))
    }
    used_relationship_ids = {relationship.get("Id") for relationship in presentation_rels}
    max_slide_id = max(
        (int(slide_id.get("id", "0")) for slide_id in slide_id_list), default=255
    )

    for slide_id, part_name in order:
        slide_root = _parse_xml(parts[part_name])
        # 타이밍 정보는 PDF 변환이 어차피 무시한다. 남겨 둘 이유가 없다.
        for timing in slide_root.findall(_p("timing")):
            slide_root.remove(timing)

        frames = plans[part_name]
        if not frames:
            parts[part_name] = _serialize_xml(slide_root)
            continue

        source_rels = parts.get(f"ppt/slides/_rels/{Path(part_name).name}.rels")
        # _apply_frame은 트리를 직접 깎으므로 단계마다 깨끗한 원본에서 다시 시작해야 한다.
        base_xml = _serialize_xml(slide_root)
        anchor = slide_id
        for index, frame in enumerate(frames):
            step_root = _parse_xml(base_xml)
            _apply_frame(step_root, frame)
            if index == 0:
                parts[part_name] = _serialize_xml(step_root)
                continue

            number = max(used_numbers) + 1
            used_numbers.add(number)
            step_part = f"ppt/slides/slide{number}.xml"
            parts[step_part] = _serialize_xml(step_root)
            if source_rels is not None:
                parts[f"ppt/slides/_rels/slide{number}.xml.rels"] = _copy_slide_rels(source_rels)

            override = etree.SubElement(content_types, f"{{{_CT_NS}}}Override")
            override.set("PartName", f"/{step_part}")
            override.set("ContentType", _SLIDE_CONTENT_TYPE)

            relationship_id = _next_relationship_id(used_relationship_ids)
            relationship = etree.SubElement(
                presentation_rels, f"{{{_PKG_REL_NS}}}Relationship"
            )
            relationship.set("Id", relationship_id)
            relationship.set("Type", _SLIDE_REL_TYPE)
            relationship.set("Target", f"slides/slide{number}.xml")

            max_slide_id += 1
            step_slide_id = etree.Element(_p("sldId"))
            step_slide_id.set("id", str(max_slide_id))
            step_slide_id.set(f"{{{_R_NS}}}id", relationship_id)
            anchor.addnext(step_slide_id)
            anchor = step_slide_id

    parts["ppt/presentation.xml"] = _serialize_xml(presentation)
    parts["ppt/_rels/presentation.xml.rels"] = _serialize_xml(presentation_rels)
    parts["[Content_Types].xml"] = _serialize_xml(content_types)
    _write_package(parts, output_pptx)
    return Path(output_pptx)


RENDER_IMAGE_WIDTH = 1920


def _convert_to_pdf(source_path, output_dir):
    libreoffice = get_libreoffice_executable()
    if libreoffice is None:
        raise RuntimeError("LibreOffice 실행 파일을 찾지 못했습니다.")

    subprocess.run(
        [
            libreoffice,
            "--headless",
            "--convert-to",
            "pdf",
            "--outdir",
            str(output_dir),
            str(source_path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    converted = sorted(output_dir.glob("*.pdf"))
    if not converted:
        raise RuntimeError(f"PDF 변환에 실패했습니다: {source_path.name}")
    return converted[0]


# 굽는 방식이 바뀌면 예전 캐시를 그대로 읽으면 안 되므로 키에 버전을 섞는다.
# (예전 폴더는 저장된 콘티가 참조하고 있을 수 있어 지우지 않고 그냥 둔다.)
RENDER_CACHE_VERSION = 2


def get_render_cache_key(source_path, expand_animation):
    stat = source_path.stat()
    payload = (
        f"{source_path.resolve()}::{stat.st_size}::{stat.st_mtime_ns}"
        f"::v{RENDER_CACHE_VERSION}::anim={int(bool(expand_animation))}"
    )
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()


def _prepare_render_source(source_path, temp_dir):
    """렌더에 넘길 파일을 고른다.

    애니메이션이 걸려 있으면 클릭 단계를 슬라이드로 펼친 pptx를 새로 만들어 그걸 넘기고,
    없거나 분석에 실패하면 원본을 그대로 넘긴다(기존 동작).
    """
    try:
        if source_path.suffix.lower() == ".pptx":
            pptx_path = source_path
        else:
            # .ppt는 XML을 열 수 없어서 먼저 pptx로 바꿔야 애니메이션을 볼 수 있다.
            convert_dir = temp_dir / "pptx"
            convert_dir.mkdir(parents=True, exist_ok=True)
            pptx_path = convert_ppt_group_to_pptx([source_path], convert_dir).get(source_path)
            if pptx_path is None:
                return source_path
        return expand_animation_steps(pptx_path, temp_dir / "animated.pptx") or source_path
    except Exception as error:
        print(
            json.dumps(
                {"warning": f"애니메이션 단계 분석을 건너뜁니다: {error}"},
                ensure_ascii=True,
            ),
            file=sys.stderr,
        )
        return source_path


def _render_result(source_name, image_paths, target_dir):
    animated = False
    meta_path = target_dir / "meta.json"
    if meta_path.exists():
        try:
            animated = bool(json.loads(meta_path.read_text(encoding="utf-8")).get("animated"))
        except (OSError, ValueError):
            animated = False
    return {
        "source_name": source_name,
        "image_paths": [str(path) for path in image_paths],
        "page_count": len(image_paths),
        "animated": animated,
    }


def render_presentation_images(file_path, expand_animation=True):
    """PPT/PPTX/PDF의 모든 페이지를 PNG로 굽고 경로 목록을 돌려준다.

    PPT/PPTX에 클릭 애니메이션이 걸려 있으면 클릭 단계마다 한 장씩 나눠 굽는다.
    PDF는 이미 PDF라서 LibreOffice 변환 단계를 건너뛴다(LibreOffice 없이도 동작).
    """
    source_path = Path(file_path)
    if not source_path.exists():
        raise RuntimeError(f"파일을 찾을 수 없습니다: {file_path}")

    is_pdf = source_path.suffix.lower() == ".pdf"
    expand_animation = expand_animation and not is_pdf

    source_name = unicodedata.normalize("NFC", source_path.name)
    target_dir = get_app_support_root() / get_render_cache_key(source_path, expand_animation)
    cached = sorted(target_dir.glob("*.png"))
    if cached:
        return _render_result(source_name, cached, target_dir)

    if not is_pdf and get_libreoffice_executable() is None:
        return {"error": "libreoffice_missing"}

    import pymupdf

    # 도중에 실패해도 반쪽짜리 캐시가 남지 않도록 임시 폴더에 굽고 마지막에 옮긴다.
    staging_dir = target_dir.with_name(f"{target_dir.name}.partial")
    shutil.rmtree(staging_dir, ignore_errors=True)
    staging_dir.mkdir(parents=True, exist_ok=True)
    temp_dir = Path(tempfile.mkdtemp(prefix="praise_ppt_render_"))
    try:
        if is_pdf:
            pdf_path = source_path
            animated = False
        else:
            render_source = (
                _prepare_render_source(source_path, temp_dir)
                if expand_animation
                else source_path
            )
            animated = render_source != source_path
            pdf_dir = temp_dir / "pdf"
            pdf_dir.mkdir(parents=True, exist_ok=True)
            pdf_path = _convert_to_pdf(render_source, pdf_dir)

        page_count = 0
        with pymupdf.open(str(pdf_path)) as document:
            for index, page in enumerate(document):
                zoom = RENDER_IMAGE_WIDTH / max(page.rect.width, 1)
                pixmap = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom))
                pixmap.save(str(staging_dir / f"{index + 1:04d}.png"))
                page_count += 1

        if page_count == 0:
            raise RuntimeError(f"페이지가 없습니다: {source_name}")

        (staging_dir / "meta.json").write_text(
            json.dumps({"animated": animated}), encoding="utf-8"
        )

        shutil.rmtree(target_dir, ignore_errors=True)
        target_dir.parent.mkdir(parents=True, exist_ok=True)
        os.replace(staging_dir, target_dir)
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)
        shutil.rmtree(staging_dir, ignore_errors=True)

    return _render_result(source_name, sorted(target_dir.glob("*.png")), target_dir)


def render_presentation(file_path, expand_animation=True):
    print(
        json.dumps(
            render_presentation_images(file_path, expand_animation=expand_animation),
            ensure_ascii=True,
        )
    )


def parse_hex_color(hex_color):
    value = hex_color.replace("#", "")
    return RGBColor(int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16))


_TITLE_BOX_HEIGHT = 0.55
_TITLE_BOX_PADDING = 0.2
_TITLE_BOX_WIDTH_CENTER = 10.0
_SLIDE_W = 13.333
_SLIDE_H = 7.5
_TITLE_BOX_WIDTH_SIDE = _SLIDE_W - (_TITLE_BOX_PADDING * 2)
_LYRICS_BOX_TOP = 0.6
_LYRICS_BOX_HEIGHT = 5.4
_LYRICS_BOX_WIDTH = _SLIDE_W * 0.9
_LYRICS_BOX_LEFT = (_SLIDE_W - _LYRICS_BOX_WIDTH) / 2
# 세로 미세 조정 허용 범위 (인치). Dart kMin/kMaxTextOffsetY 와 같아야 한다.
_TEXT_OFFSET_Y_MIN = -2.0
_TEXT_OFFSET_Y_MAX = 2.0
_TEXT_ALIGN_MAP = {
    "left": PP_ALIGN.LEFT,
    "center": PP_ALIGN.CENTER,
    "right": PP_ALIGN.RIGHT,
}
def _lyrics_text_layout(horizontal_position):
    text_align = _TEXT_ALIGN_MAP.get(horizontal_position, PP_ALIGN.CENTER)
    return _LYRICS_BOX_LEFT, _LYRICS_BOX_WIDTH, text_align


def _lyrics_box_vertical_layout(style, is_bible):
    """가사/본문 상자의 (top, height) 를 인치로 돌려준다.

    상자 크기는 고정이고, 미세 조정(``text_offset_y``)이 그 상자를 통째로
    위아래로 민다. 그래야 상단/중단/하단 어느 기준이든 밀어 준 만큼 똑같이
    움직인다. 미리보기(Dart)·발표 창(Swift/GDI)도 같은 식으로 계산한다.
    """
    top = _LYRICS_BOX_TOP + _lyrics_offset_y(style, is_bible)
    return top, _LYRICS_BOX_HEIGHT


def _lyrics_offset_y(style, is_bible):
    """본문 세로 미세 조정 값(인치, + = 아래로)."""
    return _clamp_offset_y(style.get(
        "bible_text_offset_y" if is_bible else "text_offset_y",
        0.0,
    ))


def _clamp_offset_y(value):
    """세로 미세 조정 값을 허용 범위로 자른다. 숫자가 아니면 0."""
    try:
        offset = float(value)
    except (TypeError, ValueError):
        return 0.0
    if offset != offset:  # NaN
        return 0.0
    return min(max(offset, _TEXT_OFFSET_Y_MIN), _TEXT_OFFSET_Y_MAX)


def _add_title_textbox(slide, song_title, style, is_bible=False, font_name="Pretendard"):
    title_font_size = Pt(style.get(
        "bible_title_font_size" if is_bible else "title_font_size",
        style.get("title_font_size", 14),
    ))
    title_color = parse_hex_color(style.get(
        "bible_title_text_color" if is_bible else "title_text_color",
        style.get("title_text_color", "#B3FFFFFF"),
    ))
    h_pos = style.get(
        "bible_title_horizontal_position" if is_bible else "title_horizontal_position",
        style.get("title_horizontal_position", "right"),
    )
    v_pos = style.get(
        "bible_title_vertical_position" if is_bible else "title_vertical_position",
        style.get("title_vertical_position", "bottom"),
    )

    if h_pos == "left":
        title_left = _TITLE_BOX_PADDING
        title_width = _TITLE_BOX_WIDTH_SIDE
        text_align = PP_ALIGN.LEFT
    elif h_pos == "center":
        title_left = (_SLIDE_W - _TITLE_BOX_WIDTH_CENTER) / 2
        title_width = _TITLE_BOX_WIDTH_CENTER
        text_align = PP_ALIGN.CENTER
    else:
        title_left = _SLIDE_W - _TITLE_BOX_PADDING - _TITLE_BOX_WIDTH_SIDE
        title_width = _TITLE_BOX_WIDTH_SIDE
        text_align = PP_ALIGN.RIGHT

    if v_pos == "top":
        title_top = _TITLE_BOX_PADDING
    elif v_pos == "middle":
        title_top = (_SLIDE_H - _TITLE_BOX_HEIGHT) / 2
    else:
        title_top = _SLIDE_H - _TITLE_BOX_PADDING - _TITLE_BOX_HEIGHT
    # 제목도 본문과 같다. 기준선에서 미세 조정만큼 더 민다.
    title_top += _clamp_offset_y(style.get(
        "bible_title_offset_y" if is_bible else "title_offset_y", 0.0
    ))

    box = slide.shapes.add_textbox(
        Inches(title_left), Inches(title_top),
        Inches(title_width), Inches(_TITLE_BOX_HEIGHT),
    )
    frame = box.text_frame
    frame.word_wrap = False
    para = frame.paragraphs[0]
    para.alignment = text_align
    run = para.add_run()
    run.text = _normalize_ppt_text(song_title)
    _set_run_font(run, font_name)
    run.font.size = title_font_size
    run.font.color.rgb = title_color


def _normalize_ppt_text(text):
    return unicodedata.normalize("NFC", text or "")


def _set_run_font(run, font_name="Pretendard"):
    run.font.name = font_name
    rpr = run._r.get_or_add_rPr()
    for tag in ("a:latin", "a:ea", "a:cs"):
        font = rpr.find(qn(tag))
        if font is None:
            font = OxmlElement(tag)
            rpr.append(font)
        font.set("typeface", font_name)


def _style_run(run, font_size, color, font_name):
    _set_run_font(run, font_name)
    run.font.size = font_size
    run.font.bold = True
    run.font.color.rgb = color


def _add_line_break(paragraph, font_size, color, font_name):
    """문단 안 줄바꿈(<a:br/>).

    <a:br> 에도 글꼴·크기를 넣는다. 비워 두면 줄 높이가 기본 18pt 로 잡혀서
    본문 줄 간격이 들쭉날쭉해진다.
    """
    br = paragraph._p.add_br()
    rpr = br.get_or_add_rPr()
    rpr.set("sz", str(int(round(font_size.pt * 100))))
    rpr.set("b", "1")
    # CT_TextCharacterProperties 는 fill 이 latin/ea/cs 보다 먼저 와야 한다.
    fill = OxmlElement("a:solidFill")
    srgb = OxmlElement("a:srgbClr")
    srgb.set("val", str(color))
    fill.append(srgb)
    rpr.append(fill)
    for tag in ("a:latin", "a:ea", "a:cs"):
        font = OxmlElement(tag)
        font.set("typeface", font_name)
        rpr.append(font)


def _add_text_run(paragraph, text, font_size, color, font_name="Pretendard"):
    """한 문단에 여러 줄을 넣는다.

    줄바꿈은 반드시 <a:br/> 로 넣는다. 한 run 의 <a:t> 안에 날 줄바꿈 문자를
    그대로 두면 OOXML 상 줄바꿈이 아니라서 뷰어마다 다르게 그려진다
    (LibreOffice 는 가운데 정렬을 무시하고 줄을 양쪽으로 벌려 버린다).
    """
    lines = _normalize_ppt_text(text).split("\n")
    for index, line in enumerate(lines):
        if index:
            _add_line_break(paragraph, font_size, color, font_name)
        run = paragraph.add_run()
        run.text = line
        _style_run(run, font_size, color, font_name)


def _format_bible_paragraph(paragraph, text_align, font_size):
    paragraph.alignment = text_align
    hanging_width = font_size.pt * 1.7
    paragraph.margin_left = Pt(hanging_width)
    paragraph.first_line_indent = Pt(-hanging_width)


def _add_bible_page_text(frame, page, text_align, font_size, text_color, font_name="Pretendard"):
    lines = [line.strip() for line in page.splitlines() if line.strip()]
    if not lines:
        return

    for index, line in enumerate(lines):
        paragraph = frame.paragraphs[0] if index == 0 else frame.add_paragraph()
        _format_bible_paragraph(paragraph, text_align, font_size)
        _add_text_run(paragraph, line, font_size, text_color, font_name)


def _resolve_background(style, background):
    """(배경 이미지 경로, 배경 색 hex) 결정.

    background 는 콘티 항목 하나에만 적용되는 오버라이드({"color", "image_path"}).
    None 이면 전역 style 의 배경을 그대로 쓴다. 오버라이드가 있으면 색·이미지를
    통째로 대체하므로, 이미지 없이 색만 담긴 오버라이드는 "이 항목만 단색"이 된다.
    """
    if background:
        return (
            background.get("image_path"),
            background.get("color") or style["background_color"],
        )
    return style.get("background_image_path"), style["background_color"]


def _style_for_item(style, background):
    """항목별 오버라이드에 실린 가사 세로 위치를 전역 style 위에 덮어쓴 style.

    헌금송은 "가사는 헌금 띠 위쪽"을 위해 그 항목만 가사 기준선(text_position)과
    미세 조정(text_offset_y)을 바꾼다. 찬양 가사에만 해당하고 성경 키는 건드리지 않는다.
    발표 창·미리보기(Dart)는 ExportStyle.withBackground 가 같은 일을 한다.
    """
    if not background:
        return style
    overrides = {
        key: background[key]
        for key in ("text_position", "text_offset_y")
        if background.get(key) is not None
    }
    if overrides.get("text_position") not in (None, "top", "middle", "bottom"):
        overrides.pop("text_position")
    return {**style, **overrides} if overrides else style


def _apply_slide_background(slide, style, background=None):
    bg_image_path, bg_color = _resolve_background(style, background)
    if bg_image_path and os.path.isfile(bg_image_path):
        try:
            _, rId = slide.part.get_or_add_image_part(bg_image_path)
            # p:bg 는 p:sld 가 아니라 p:cSld 의 첫 자식이다. 위치를 틀리면
            # PowerPoint 가 배경을 무시한다.
            c_sld = slide._element.find(qn('p:cSld'))
            bg = c_sld.find(qn('p:bg'))
            if bg is None:
                bg = OxmlElement('p:bg')
                c_sld.insert(0, bg)
            bg.clear()
            bgPr = OxmlElement('p:bgPr')
            bg.append(bgPr)
            blipFill = OxmlElement('a:blipFill')
            blip = OxmlElement('a:blip')
            blip.set(qn('r:embed'), rId)
            blipFill.append(blip)
            stretch = OxmlElement('a:stretch')
            stretch.append(OxmlElement('a:fillRect'))
            blipFill.append(stretch)
            bgPr.append(blipFill)
            # CT_BackgroundProperties 는 fill 뒤에 effect 가 와야 한다.
            bgPr.append(OxmlElement('a:effectLst'))
            return
        except Exception:
            pass
    # fallback: solid color
    slide.background.fill.solid()
    slide.background.fill.fore_color.rgb = parse_hex_color(bg_color)


def add_song_slides(prs, song, style, background=None):
    is_bible = song.get("type") == "bible"
    font_name = style.get("font_family", "Pretendard")
    text_color_key = "bible_text_color" if is_bible else "text_color"
    text_color = parse_hex_color(style.get(text_color_key, style["text_color"]))
    font_size = Pt(style.get(
        "bible_font_size" if is_bible else "font_size",
        style["font_size"],
    ))
    position = style.get(
        "bible_text_position" if is_bible else "text_position",
        style["text_position"],
    )
    include_english_lyrics = style.get("include_english_lyrics", False)
    english_color = parse_hex_color(style["english_text_color"])
    show_song_title = style.get(
        "show_bible_title" if is_bible else "show_song_title",
        style.get("show_song_title", False),
    )
    lyrics_text_align_str = style.get(
        "bible_text_align" if is_bible else "lyrics_text_align", "center"
    )
    lyrics_box_left, lyrics_box_width, lyrics_align = _lyrics_text_layout(
        lyrics_text_align_str
    )
    korean_pages = _decode_pages(song["lyrics"])
    english_pages = _decode_pages(song.get("english_lyrics", ""))
    page_count = max(len(korean_pages), len(english_pages))

    for index in range(page_count):
        page = korean_pages[index] if index < len(korean_pages) else ""
        english_page = english_pages[index] if index < len(english_pages) else ""
        if not page and not english_page:
            continue

        slide = prs.slides.add_slide(prs.slide_layouts[6])
        _apply_slide_background(slide, style, background)
        lyrics_box_top, lyrics_box_height = _lyrics_box_vertical_layout(
            style, is_bible
        )

        textbox = slide.shapes.add_textbox(
            Inches(lyrics_box_left), Inches(lyrics_box_top),
            Inches(lyrics_box_width), Inches(lyrics_box_height),
        )
        frame = textbox.text_frame
        frame.clear()
        frame.word_wrap = True
        frame.vertical_anchor = {
            "top": MSO_ANCHOR.TOP,
            "middle": MSO_ANCHOR.MIDDLE,
            "bottom": MSO_ANCHOR.BOTTOM,
        }[position]

        if is_bible:
            _add_bible_page_text(frame, page, lyrics_align, font_size, text_color, font_name)
        else:
            paragraph = frame.paragraphs[0]
            paragraph.alignment = lyrics_align
            _add_text_run(paragraph, page, font_size, text_color, font_name)

        if include_english_lyrics and english_page:
            english_paragraph = frame.add_paragraph()
            english_paragraph.alignment = lyrics_align
            _add_text_run(
                english_paragraph,
                english_page,
                Pt(style["font_size"] * 0.8),
                english_color,
                font_name,
            )

        if show_song_title:
            _add_title_textbox(slide, song.get("title", ""), style, is_bible=is_bible, font_name=font_name)


def add_image_slides(prs, item, style, background=None):
    """외부 PPT에서 구운 페이지 이미지를 슬라이드에 비율 유지해 중앙 배치."""
    for image_path in item.get("image_paths", []):
        if not os.path.isfile(image_path):
            continue
        slide = prs.slides.add_slide(prs.slide_layouts[6])
        _apply_slide_background(slide, style, background)
        picture = slide.shapes.add_picture(image_path, 0, 0)
        scale = min(
            _SLIDE_W / picture.width.inches,
            _SLIDE_H / picture.height.inches,
        )
        width = picture.width.inches * scale
        height = picture.height.inches * scale
        picture.width = Inches(width)
        picture.height = Inches(height)
        picture.left = Inches((_SLIDE_W - width) / 2)
        picture.top = Inches((_SLIDE_H - height) / 2)


def _add_blank_slide(prs, style, background=None):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    _apply_slide_background(slide, style, background)


def export_presentation(payload_json):
    payload = json.loads(payload_json)
    output_path = Path(payload["output_path"])
    if output_path.suffix.lower() != ".pptx":
        output_path = output_path.with_suffix(".pptx")
    songs = payload["songs"]
    style = payload["style"]
    _ensure_fonts_installed(style.get("font_family", "Pretendard"),
                            style.get("font_files") or ())

    prs = Presentation()
    if len(prs.slides) == 0:
        prs.slides.add_slide(prs.slide_layouts[6])
        r_id = prs.slides._sldIdLst[0].rId
        prs.part.drop_rel(r_id)
        del prs.slides._sldIdLst[0]

    prs.slide_width = Inches(13.333)
    prs.slide_height = Inches(7.5)

    for index, song in enumerate(songs):
        # 항목별 배경 오버라이드. 없으면 전역 배경.
        background = song.get("background")
        if song.get("type") == "blank":
            _add_blank_slide(prs, style, background)
        else:
            if song.get("type") == "image":
                add_image_slides(prs, song, style, background)
            else:
                add_song_slides(
                    prs, song, _style_for_item(style, background), background
                )
            is_last = index == len(songs) - 1
            # 다음이 직접 넣은 빈 페이지여도 여백은 따로 넣는다 — 빈 페이지를 추가하면
            # 실제로 한 장이 늘어나야 한다(발표 화면 _allSlides 와 같은 규칙).
            # no_spacer: 발표 화면에서 이 항목 뒤 여백을 지웠다(곡 중간 붙여 넣기 등).
            if not is_last and not song.get("no_spacer"):
                next_type = songs[index + 1].get("type")
                # 말씀 다음 말씀이면 빈 슬라이드 삽입 안 함
                if not (song.get("type") == "bible" and next_type == "bible"):
                    # 자동으로 끼우는 여백은 앞 항목의 배경을 따라간다
                    # (발표 화면의 _allSlides 도 앞 항목 uid 를 빌려 쓴다).
                    _add_blank_slide(prs, style, background)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    prs.save(str(output_path))
    print(json.dumps({"output_path": str(output_path)}, ensure_ascii=True))


# ── 악보 가사 추출 ────────────────────────────────────────────────────────
#
# 악보에서 "오선 아래"만 잘라 OCR 한다. 제목·작곡가(첫 단 위)와 코드 기호
# (다음 단 바로 위)는 좌표로 먼저 잘라 내는 편이, 다 읽은 뒤에 글자 모양으로
# 거르는 것보다 훨씬 정확하다.
# 자른 띠를 통째로 넘기지 않고 글 줄 하나씩 잘라 넘기는 이유 — 가사는 음표에
# 맞춰 띄엄띄엄 놓여서, 여러 줄 모드(psm 6)로 읽히면 한 줄을 두 줄로 쪼갠다.

OCR_DPI = 200
_SHEET_SUFFIXES = {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".pdf"}

# 오선 한 줄로 볼 가로 검은 비율. 한글 텍스트 줄은 0.35를 잘 넘지 않는다.
_STAFF_ROW_RATIO = 0.45
# 글자가 있다고 볼 가로 검은 비율. 가사 한 줄은 폭의 1%도 안 되는 일이 있다.
_TEXT_ROW_RATIO = 0.004
# 그림 악보는 오선 줄 간격이 이 크기(px)가 되게 맞춘 뒤 읽는다 (300dpi 인쇄 악보쯤).
_TARGET_STAFF_SPACING = 22
# 크기를 맞출 때 넘지 않을 픽셀 수 (약 4500x4500).
_MAX_SHEET_PIXELS = 20_000_000
# OCR 에 넘기는 가사 한 줄의 글자 높이(px). Tesseract 는 30~50px 글자를 가장 잘 읽는다.
_TARGET_LINE_HEIGHT = 48
# 줄마다 Tesseract 를 여럿 동시에 띄우므로 하나가 코어를 다 잡지 않게 한다.
_TESSERACT_ENV = {**os.environ, "OMP_THREAD_LIMIT": "1"}
# OS 내장 OCR 결과에서 버리는 글 덩어리 확신도(0~100). Windows 는 확신도를 안 줘서 늘 100 이다.
_NATIVE_MIN_CONFIDENCE = 30

# 음절을 잇는 하이픈·대시. 줄 끝 하이픈 검사(ends_with_word_break)도 같은 목록을 쓴다.
_HYPHEN_CHARS = "-\u2010\u2011\u2012\u2013\u2014\u2015\uff0d"
_LYRIC_HYPHEN_RE = re.compile(f"[ \\t\\u00a0]*[{_HYPHEN_CHARS}][ \\t\\u00a0]*")
_LYRIC_LETTER_RE = re.compile(r"[A-Za-z\uac00-\ud7a3]")
_HANGUL_RE = re.compile(r"[\uac00-\ud7a3]")
_CHORD_TOKEN_RE = re.compile(
    r"^[A-G][#b\u266f\u266d]?(m|M|maj|min|sus|dim|aug|add)?[0-9]*(/[A-G][#b]?)?$"
)
# OCR 이 뭉갠 코드: ♭ → o·S, / → I·l·1 (`Bo`, `DIC`, `GlB`). 줄의 대부분이 이렇게 생겼을 때만 코드로 본다.
_LOOSE_CHORD_TOKEN_RE = re.compile(
    r"^[A-G][#b\u266f\u266doS]?(m|M|maj|min|sus|dim|aug|add)?[0-9]*([/Il1][A-G][#b\u266f\u266d]?)?$"
)
# 곡 구조 표시 (`<verse1>`, `[Chorus]`, `Bridge 2:`, `후렴`). OCR 이 `<` 를 `c`·`〈` 로 읽기도 한다.
_SECTION_LABEL = (
    r"[\(\[<\u3008]?c?(?:intro|verse|pre-?chorus|chorus|bridge|inter(?:lude)?|outro|tag|"
    r"ending|coda|refrain|후렴|전주|간주|후주|브릿지|브리지)[0-9]?[a-z0-9]?[\)\]>\u3009]?:?"
)
_SECTION_LINE_RE = re.compile(f"^{_SECTION_LABEL}$", re.IGNORECASE)
_SECTION_PREFIX_RE = re.compile(f"^{_SECTION_LABEL}\\s+", re.IGNORECASE)
# 괄호 안 연주 메모 (`(verse로 갈땐 D/A)`, `(F# if keyup)`). 코드나 key 가 들어 있을 때만 지운다 — `(x2)` 는 남긴다.
# 코드는 낱말 전체가 코드여야 한다 — `(Amen)` 의 `Am` 에 걸리면 안 된다.
_NOTE_RE = re.compile(
    r"\([^()]*(?:\b[A-G][#b\u266f\u266d]?(?:m|maj|sus|dim|aug|add)?[0-9]*(?:/[A-G][#b]?)?(?![\w#])"
    r"|\b[Kk]ey)[^()]*\)"
)


def get_tesseract_executable():
    candidates = [
        shutil.which("tesseract"),
        "/opt/homebrew/bin/tesseract",
        "/usr/local/bin/tesseract",
        r"C:\Program Files\Tesseract-OCR\tesseract.exe",
        r"C:\Program Files (x86)\Tesseract-OCR\tesseract.exe",
    ]
    for candidate in candidates:
        if candidate and os.path.exists(candidate):
            return candidate
    return None


def get_tesseract_language(executable):
    """설치된 언어 데이터에 맞춰 -l 값을 고른다. 한국어가 없으면 영어만."""
    try:
        result = subprocess.run(
            [executable, "--list-langs"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return "eng"
    langs = {
        line.strip()
        for line in (result.stdout + "\n" + (result.stderr or "")).splitlines()
    }
    if "kor" in langs:
        return "kor+eng" if "eng" in langs else "kor"
    return "eng"


def row_dark_ratios(image, threshold=160):
    """행마다 '검은 픽셀 비율'을 돌려준다. 가로로 평균 내면 오선만 1에 가깝다."""
    from PIL import Image

    gray = image.convert("L")
    dark = gray.point(lambda value: 255 if value < threshold else 0)
    # 폭을 1로 줄이면 픽셀 하나가 그 행의 평균이 된다 (BOX = 단순 평균).
    column = dark.resize((1, gray.height), Image.BOX)
    # 폭이 1이라 tobytes() 가 행마다 한 바이트씩 준다 (getdata() 는 곧 없어진다).
    return [value / 255 for value in column.tobytes()]


def otsu_threshold(gray):
    """밝기 히스토그램을 두 무리(글자·바탕)로 가장 잘 가르는 값. 이 값보다 어두우면 글자."""
    histogram = gray.histogram()
    total = sum(histogram)
    weighted_total = sum(index * count for index, count in enumerate(histogram))
    best_variance, best = -1.0, 160
    dark_count, dark_weighted = 0, 0
    for value, count in enumerate(histogram):
        dark_count += count
        light_count = total - dark_count
        if dark_count == 0:
            continue
        if light_count == 0:
            break
        dark_weighted += value * count
        dark_mean = dark_weighted / dark_count
        light_mean = (weighted_total - dark_weighted) / light_count
        variance = dark_count * light_count * (dark_mean - light_mean) ** 2
        if variance > best_variance:
            best_variance, best = variance, value + 1
    return best


def flatten_background(gray):
    """그림자·누런 종이·회색 캡처 바탕을 흰색으로 펴고 대비를 끝까지 늘린다.

    바탕 밝기를 크게 흐린 '최댓값 지도'로 어림한 뒤 그 차이만 남긴다.
    폰으로 찍은 악보는 한쪽이 어두워서 고정 문턱(160)으로는 오선이 끊겨 보였다."""
    from PIL import Image, ImageChops, ImageFilter, ImageOps

    small = gray.resize(
        (max(gray.width // 16, 1), max(gray.height // 16, 1)), Image.BOX
    )
    background = (
        small.filter(ImageFilter.MaxFilter(5))
        .filter(ImageFilter.GaussianBlur(2))
        .resize(gray.size, Image.BILINEAR)
    )
    flat = ImageChops.invert(ImageChops.subtract(background, gray))
    return ImageOps.autocontrast(flat, cutoff=(0, 1))


def find_skew_angle(gray, threshold, max_angle=4.0, step=0.2):
    """오선이 가장 반듯하게 눕는 회전각(도). 기울어진 사진·스캔본용.

    오선이 수평이면 몇몇 행에 검은 픽셀이 몰려 '행 비율 제곱합'이 가장 커진다."""
    from PIL import Image

    scale = min(1.0, 1000 / max(gray.width, 1))
    small = gray.resize(
        (max(int(gray.width * scale), 1), max(int(gray.height * scale), 1)), Image.BOX
    )
    # 글자를 흰색(255)으로 둬야 돌릴 때 생기는 빈 모서리(0)가 글자로 안 잡힌다.
    ink = small.point(lambda value: 255 if value < threshold else 0)

    def score(angle):
        rotated = ink.rotate(angle, resample=Image.BILINEAR, expand=True, fillcolor=0)
        column = rotated.resize((1, rotated.height), Image.BOX)
        return sum((value / 255) ** 2 for value in column.tobytes())

    steps = int(max_angle / step)
    angles = [index * step for index in range(-steps, steps + 1)]
    scores = {angle: score(angle) for angle in angles}
    best = max(angles, key=lambda angle: scores[angle])
    # 반듯한 악보에서 흔들리지 않게, 0도보다 확실히 나을 때만 돌린다.
    return best if scores[best] > scores[0.0] * 1.02 else 0.0


def prepare_sheet_image(image):
    """OCR 할 그림 악보를 다듬는다 → (회색 이미지, 오선 문턱값, 글자 문턱값).

    바탕 펴기 → 기울기 바로잡기 → 오선 줄 간격이 _TARGET_STAFF_SPACING 이 되게 크기 맞추기.
    캡처한 작은 악보(줄 간격 7~8px)는 1·2절 가사 줄 사이 틈이 1~2px 뿐이라
    두 줄이 한 덩어리로 잡혀 아무것도 못 읽었다."""
    from PIL import Image

    gray = flatten_background(image.convert("L"))
    # 문턱값이 둘이다. 흐린 그림의 가는 오선은 옅은 회색이라 Otsu 값(넉넉함)으로 찾고,
    # 글 줄은 160 을 넘기지 않는 값으로 찾는다 — 흐리거나 JPEG 로 뭉개진 그림은 바탕 얼룩까지
    # 글자로 잡혀 1·2절 가사 줄 사이 틈이 사라진다. 오선은 행의 45% 를 넘어야 하므로 얼룩에 안 속는다.
    staff_threshold = otsu_threshold(gray)
    text_threshold = min(staff_threshold, 160)
    # 흐린 JPEG 는 오선 한 줄이 2~3행으로 번져 Otsu 값보다 옅어진다(실제 악보: 단 4개 중
    # 2개를 놓쳐 마지막 단 가사가 통째로 빠졌다). 더 너그러운 값이 단을 더 찾을 때만 그 값을 쓴다.
    loose_threshold = (staff_threshold + 255) // 2
    if len(find_staff_systems(row_dark_ratios(gray, loose_threshold))) > len(
        find_staff_systems(row_dark_ratios(gray, staff_threshold))
    ):
        staff_threshold = loose_threshold
    angle = find_skew_angle(gray, staff_threshold)
    if angle:
        gray = gray.rotate(angle, resample=Image.BICUBIC, expand=True, fillcolor=255)

    systems = find_staff_systems(row_dark_ratios(gray, staff_threshold))
    if systems:
        spacings = sorted(spacing for _top, _bottom, spacing in systems)
        factor = _TARGET_STAFF_SPACING / spacings[len(spacings) // 2]
        # 큰 사진을 키우면 뒤의 오선 지우기(파이썬 반복)와 메모리가 픽셀 수만큼 는다.
        # 이미 큰 사진은 키우지만 않는다 (줄이면 줄 간격이 더 좁아져 오히려 못 읽는다).
        cap = max(1.0, (_MAX_SHEET_PIXELS / (gray.width * gray.height)) ** 0.5)
        factor = min(factor, 4.0, cap)
        if not 0.85 <= factor <= 1.15:
            gray = gray.resize(
                (max(int(gray.width * factor), 1), max(int(gray.height * factor), 1)),
                Image.LANCZOS,
            )
    return gray, staff_threshold, text_threshold


def find_staff_systems(ratios, min_ratio=_STAFF_ROW_RATIO):
    """가로 검은 비율 목록 → 오선 한 단마다 (윗선, 아랫선, 줄 간격)."""
    rows = [index for index, ratio in enumerate(ratios) if ratio >= min_ratio]
    if not rows:
        return []

    # 오선 한 줄은 두께가 1~3px 이라 연속된 행이 여러 개 나온다. 하나로 묶는다.
    lines = [[rows[0]]]
    for row in rows[1:]:
        if row - lines[-1][-1] <= 2:
            lines[-1].append(row)
        else:
            lines.append([row])
    centers = [sum(line) / len(line) for line in lines]
    if len(centers) < 4:
        return []

    gaps = sorted(later - earlier for earlier, later in zip(centers, centers[1:]))
    # 한 단 안의 간격이 4개, 단 사이 간격이 1개라 중앙값은 늘 '줄 간격'이다.
    spacing = gaps[len(gaps) // 2]
    if spacing <= 0:
        return []

    groups = [[centers[0]]]
    for previous, current in zip(centers, centers[1:]):
        if current - previous <= spacing * 2.5:
            groups[-1].append(current)
        else:
            groups.append([current])

    return [
        (group[0], group[-1], (group[-1] - group[0]) / (len(group) - 1))
        for group in groups
        # 한 줄쯤 흐려서 안 잡혀도 단으로 인정한다 (원래 5줄).
        if len(group) >= 4
    ]


def text_row_groups(ratios, top, bottom, max_blank_gap=2, min_height=3):
    """[top, bottom) 안에서 글자가 있는 행 덩어리를 찾는다. 한 덩어리 = 글 한 줄."""
    groups = []
    start = None
    end = 0
    blank = 0
    for row in range(max(top, 0), min(bottom, len(ratios))):
        if ratios[row] >= _TEXT_ROW_RATIO:
            start = row if start is None else start
            end = row
            blank = 0
        elif start is not None:
            blank += 1
            if blank > max_blank_gap:
                groups.append((start, end))
                start = None
    if start is not None:
        groups.append((start, end))
    return [(top_row, end_row) for top_row, end_row in groups if end_row - top_row >= min_height]


def lyric_line_boxes_by_system(systems, ratios):
    """오선 단 목록 → 단마다 [오선 아래 가사 한 줄씩의 (위, 아래)].

    단 하나 아래의 줄들은 위에서부터 1절, 2절 ... 이다."""
    height = len(ratios)
    sparse_limit = _sparse_row_limit(systems, ratios)
    result = []
    for index, (_, bottom, spacing) in enumerate(systems):
        top = int(bottom + spacing * 0.3)
        next_top = systems[index + 1][0] if index + 1 < len(systems) else None
        band_bottom = (
            int(next_top - spacing * 0.2)
            if next_top is not None
            else int(min(height, bottom + spacing * 8))
        )
        # 줄 간격의 절반도 안 되는 얇은 덩어리는 글자가 아니다 (음표 꼬리 끝, 붙임줄).
        # 먼저 걸러야 한다 — 가사와 코드 사이에 끼면 아래 '어느 단에 더 붙었나' 비교가 틀린다.
        groups = [
            (start, end)
            for start, end in text_row_groups(ratios, top, band_bottom)
            if end - start + 1 >= spacing * 0.5
        ]
        # 위쪽(가사 줄·오선)보다 아래 단에 더 붙어 있으면 그 단의 것이다
        # (코드 기호, 오선 위로 삐져나온 음표). 둘 다 붙을 수 있어 끝에서부터 걷어 낸다.
        while next_top is not None and groups:
            last_start, last_end = groups[-1]
            above = last_start - (groups[-2][1] if len(groups) > 1 else bottom)
            # 다음 단 윗선에 한 줄 간격 안으로 붙고 글자가 성긴 덩어리는 거리와 상관없이 그 단의
            # 코드 줄이다 (가사와 코드 사이가 코드와 오선 사이보다 좁은 악보가 있다).
            # 성긴지도 보는 이유 — 코드 없이 3~4절을 빽빽하게 찍은 찬송가는 마지막 절이 다음
            # 오선에 바짝 붙는다. 가사 줄은 글자가 촘촘해 코드 줄보다 검은 비율이 두 배쯤 높다.
            # 띠에 한 줄뿐이면 건드리지 않는다 ('A - - men' 처럼 성긴 가사 한 줄일 수 있다).
            attached = (
                len(groups) > 1
                and next_top - last_end <= spacing
                and _mean_ratio(ratios, last_start, last_end) < sparse_limit
            )
            if not attached and next_top - last_end >= above:
                break
            groups.pop()
        # 띠 첫 행부터 검으면 오선에 붙은 덧줄 음표다. 그 아래 줄이 가사다.
        if len(groups) > 1 and groups[0][0] == top:
            groups.pop(0)
        result.append(groups)

    # 가사 줄보다 확 얇은 덩어리(붙임줄 ‿, 맨 아래 저작권 문구, 지우고 남은 음표 조각)는 버린다.
    # 소문자뿐인 짧은 영어 줄(`for ever`)도 한글 줄 높이의 60% 쯤이라, 40% 미만은 무조건,
    # 60% 미만은 오선 바로 밑(한 줄 간격 안 = 음표 조각 자리)에서 시작하고 아래에 줄이 더 있을 때만 버린다.
    heights = sorted(end - start + 1 for groups in result for start, end in groups)
    if heights:
        median = heights[len(heights) // 2]

        def is_fragment(groups, index, staff_bottom, spacing):
            start, end = groups[index]
            if end - start + 1 < median * 0.4:
                return True
            return (
                index == 0
                and len(groups) > 1
                and end - start + 1 < median * 0.6
                and start - staff_bottom < spacing
            )

        result = [
            [
                group
                for index, group in enumerate(groups)
                if not is_fragment(groups, index, systems[system_index][1], systems[system_index][2])
            ]
            for system_index, groups in enumerate(result)
        ]
    return result


def _mean_ratio(ratios, start, end):
    return sum(ratios[start:end + 1]) / max(end - start + 1, 1)


def _sparse_row_limit(systems, ratios):
    """이보다 검은 비율이 낮은 글 줄은 성기다(코드 줄). 쪽의 글 줄 밀도 상위 25% 값의 65%.

    가운데값이 아니라 상위 25% 를 기준으로 삼는 이유 — 한 줄짜리 단이 많은 악보는
    글 줄의 절반이 코드 줄이라 가운데값이 코드 줄 밀도로 내려앉는다."""
    densities = []
    for index, (_, bottom, spacing) in enumerate(systems[:-1]):
        for start, end in text_row_groups(
            ratios, int(bottom + spacing * 0.3), int(systems[index + 1][0] - spacing * 0.2)
        ):
            if end - start + 1 >= spacing * 0.5:
                densities.append(_mean_ratio(ratios, start, end))
    if not densities:
        return 0.0
    densities.sort()
    return densities[(len(densities) * 3) // 4] * 0.65


def lyric_line_boxes(systems, ratios):
    """오선 단 목록 → 오선 아래 가사 한 줄씩의 (위, 아래) 목록."""
    return [box for boxes in lyric_line_boxes_by_system(systems, ratios) for box in boxes]


def _is_single_syllable(token):
    return len(token) == 1 and _HANGUL_RE.match(token) is not None


def join_single_syllables(text):
    """음표마다 떨어뜨려 놓은 한 글자 토막을 붙인다 (`주 의 인 자` → `주의인자`).

    악보는 음표 하나에 음절 하나를 놓느라 띄어 쓴 것이라, 단어 사이가 아니다.
    한글끼리만 붙인다 — 영어 가사의 `I am a boy` 까지 붙으면 안 된다."""
    tokens = text.split()
    if not tokens:
        return text
    parts = [tokens[0]]
    for previous, current in zip(tokens, tokens[1:]):
        both_hangul = _HANGUL_RE.search(previous) and _HANGUL_RE.search(current)
        if both_hangul and (
            _is_single_syllable(previous) or _is_single_syllable(current)
        ):
            parts[-1] += current
        else:
            parts.append(current)
    return " ".join(parts)


def clean_lyric_line(line):
    """OCR 한 줄 → 가사 한 줄. 음절을 잇는 하이픈은 양옆 공백까지 지운다."""
    text = unicodedata.normalize("NFC", line)
    text = text.replace("|", " ")  # 마디선을 글자로 읽은 것
    text = _LYRIC_HYPHEN_RE.sub("", text)
    text = re.sub("[ \t\u00a0]+", " ", text).strip()
    return join_single_syllables(text)


def is_lyric_line(text):
    """글자가 두 자 미만이면 음표·숫자를 잘못 읽은 것으로 보고 버린다."""
    return len(_LYRIC_LETTER_RE.findall(text)) >= 2


def is_chord_line(text):
    """C G7 Am/E 처럼 코드 기호만 있는 줄. 띠에 섞여 들어온 코드행을 버린다.

    OCR 은 코드 사이 띄어쓰기를 자주 잃고(`CG’DmCFCG’C`) 마디 번호·위첨자를 섞으므로,
    낱말 검사에 더해 '영문자 대부분이 코드 뿌리음(A~G 대문자)·m' 인지도 본다.
    영어 가사는 소문자가 대부분이고 한글 가사는 영문자가 없어 걸리지 않는다."""
    text = _SECTION_PREFIX_RE.sub("", text)
    tokens = text.split()
    if tokens and all(_CHORD_TOKEN_RE.match(token) for token in tokens):
        return True
    if _HANGUL_RE.search(text):
        return False
    if len(tokens) >= 3 and sum(
        1 for token in tokens if _LOOSE_CHORD_TOKEN_RE.match(token)
    ) >= len(tokens) * 0.6:
        return True
    letters = re.findall("[A-Za-z]", text)
    roots = sum(1 for letter in letters if letter in "ABCDEFG")
    chordish = roots + sum(1 for letter in letters if letter in "mb")
    return roots >= 3 and chordish >= len(letters) * 0.75


def ends_with_word_break(raw_line):
    """영어 낱말이 단 끝에서 하이픈으로 끊겼는지 (`Lift -` ↵ `ing`).

    한글 줄 끝 하이픈은 '음을 끌라'는 표시라 다음 줄과 붙이면 안 된다."""
    match = re.search(
        f"[A-Za-z][ \\t\\u00a0]*[{_HYPHEN_CHARS}]+[ \\t\\u00a0]*$", raw_line
    )
    return match is not None


def _line_reach(spacing):
    """가사 줄 위아래로 함께 보는 높이. 줄을 지나는 음표 기둥을 알아볼 만큼."""
    return max(int(spacing * 2), 6)


def _lyric_line_image(gray, threshold, top, bottom, spacing, binarize=True):
    """가사 한 줄을 OCR 에 넘길 이미지로 자른다.

    - 줄 위아래에서 들어온 획(음표 기둥이 가사 사이로 내려온 것 등)은 지운다.
      Tesseract 가 기둥을 l·1·| 로 읽거나, 한 줄을 통째로 숫자로 읽는 원인이었다
    - 오선 폭 전체가 아니라 글자가 있는 곳만 남기고 흰 여백을 두른다
    - 글 줄 높이를 _TARGET_LINE_HEIGHT 로 맞춘 뒤 흑백으로 굳힌다 (binarize=False 면 회색 그대로.
      OS 내장 OCR 은 사진 같은 그림에 맞춰져 있어 굳히고 굵힌 글자가 오히려 낯설다)"""
    from PIL import Image

    reach = _line_reach(spacing)
    window_top = max(top - reach, 0)
    window_bottom = min(bottom + 1 + reach, gray.height)
    window = gray.crop((0, window_top, gray.width, window_bottom))
    ink = window.point(lambda value: 255 if value < threshold else 0)
    pixels = ink.load()
    width, height = ink.size

    # 글 줄에서 한 줄 간격쯤 떨어진 행에 걸친 덩어리는 글자가 아니라 바깥에서 들어온 획이다.
    # 바로 옆 행은 f·l 윗부분, g·y 아랫부분, 'ㅎ' 꼭지처럼 글자 일부일 수 있다
    # (글 줄 경계는 검은 비율로 잡아서, 솟은 글자 몇 개만 있는 행은 경계 밖으로 빠진다).
    seed_gap = max(int(spacing), 4)
    margin = max(int(spacing * 0.5), 3)
    seed_rows = [
        row
        for row in (top - window_top - seed_gap, bottom - window_top + seed_gap)
        if 0 <= row < height
    ]
    band_top = top - window_top - margin
    band_bottom = bottom - window_top + margin
    stem_width = max(int(spacing * 0.4), 3)
    removed = []
    for seed_row in seed_rows:
        for seed_x in range(width):
            if pixels[seed_x, seed_row] != 255:
                continue
            component = []
            stack = [(seed_x, seed_row)]
            pixels[seed_x, seed_row] = 0
            while stack:
                x, y = stack.pop()
                component.append((x, y))
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                    if 0 <= nx < width and 0 <= ny < height and pixels[nx, ny] == 255:
                        pixels[nx, ny] = 0
                        stack.append((nx, ny))
            in_band = [x for x, y in component if band_top <= y < band_bottom]
            # 글 줄 안에서 기둥처럼 가늘면 통째로 지운다. 넓으면 흐린 그림에서 음표가 글자에
            # 붙어 버린 것이라 글자를 살리고 바깥 부분만 지운다 (어차피 잘려 나간다).
            if not in_band or max(in_band) - min(in_band) < stem_width:
                removed.extend(component)

    keep_top = max(top - window_top - margin + 1, 0)
    keep_bottom = min(bottom - window_top + margin, height)
    cleaned = window.copy()
    if removed:
        cleaned_pixels = cleaned.load()
        # 획 가장자리의 옅은 테두리(안티에일리어싱)까지 한 칸 더 지운다.
        for x, y in removed:
            for nx in (x - 1, x, x + 1):
                if 0 <= nx < width:
                    cleaned_pixels[nx, y] = 255
    cleaned = cleaned.crop((0, keep_top, width, keep_bottom))

    bbox = cleaned.point(lambda value: 255 if value < threshold else 0).getbbox()
    if bbox is None:
        return None
    pad = max(int(spacing), 4)
    cleaned = cleaned.crop(
        (max(bbox[0] - pad, 0), 0, min(bbox[2] + pad, cleaned.width), cleaned.height)
    )

    cleaned = _squeeze_gaps(cleaned, threshold, max_gap=int((bottom - top + 1) * 0.6))

    factor = _TARGET_LINE_HEIGHT / max(bottom - top + 1, 1)
    factor = max(0.5, min(factor, 4.0))
    if abs(factor - 1) > 0.1:
        cleaned = cleaned.resize(
            (max(int(cleaned.width * factor), 1), max(int(cleaned.height * factor), 1)),
            Image.LANCZOS,
        )
    if binarize:
        cleaned = _binarize_line(cleaned, threshold)
    border = 12
    framed = Image.new("L", (cleaned.width + border * 2, cleaned.height + border * 2), 255)
    framed.paste(cleaned, (border, border))
    return framed


def _binarize_line(image, threshold):
    """Tesseract 용으로 흑백으로 굳히고 획을 굵힌다."""
    from PIL import ImageFilter

    binary = image.point(lambda value: 0 if value < threshold else 255)
    # 획을 1px 씩 굵힌다. 손글씨풍 가사 글꼴은 획이 가늘어 '라'·'나' 를 통째로 빠뜨렸다
    # (실제 악보 사진에서 줄 평균 72% → 75%, 인쇄체 시험 악보는 그대로).
    return binary.filter(ImageFilter.MinFilter(3))


def _squeeze_gaps(image, threshold, max_gap):
    """글자 사이 빈 칸이 max_gap 보다 넓으면 max_gap 으로 줄인다.

    가사는 음표 자리에 맞춰 띄엄띄엄 놓여서 낱말 사이가 글자 몇 개만큼 빈다.
    Tesseract 는 그런 큰 틈 뒤의 낱말을 확신도 0 으로 읽거나 숫자 잡음을 지어낸다."""
    from PIL import Image

    if max_gap < 2:
        return image
    ink = image.point(lambda value: 255 if value < threshold else 0)
    columns = ink.resize((image.width, 1), Image.BOX).tobytes()
    keep = []
    blank = 0
    for x, value in enumerate(columns):
        blank = blank + 1 if value == 0 else 0
        if blank <= max_gap:
            keep.append(x)
    if len(keep) == image.width:
        return image
    squeezed = Image.new("L", (len(keep), image.height), 255)
    # 이어진 열 묶음째로 붙여 넣는다 (열 하나씩은 느리다).
    start = 0
    for index in range(1, len(keep) + 1):
        if index == len(keep) or keep[index] != keep[index - 1] + 1:
            strip = image.crop((keep[start], 0, keep[index - 1] + 1, image.height))
            squeezed.paste(strip, (start, 0))
            start = index
    return squeezed


def _run_tesseract(executable, image_path, language, psm):
    result = subprocess.run(
        [executable, str(image_path), "stdout", "-l", language, "--psm", psm],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=_TESSERACT_ENV,
    )
    return result.stdout or "" if result.returncode == 0 else ""


def _run_tesseract_words(executable, image_path, language, psm):
    """한 줄 OCR → [(낱말, 확신도 0~100)]. 확신도로 언어 후보를 고르고 잡음을 거른다."""
    result = subprocess.run(
        [executable, str(image_path), "stdout", "-l", language, "--psm", psm, "tsv"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=_TESSERACT_ENV,
    )
    if result.returncode != 0:
        return []
    words = []
    for row in (result.stdout or "").splitlines()[1:]:
        columns = row.split("\t")
        if len(columns) < 12 or columns[0] != "5":
            continue
        text = columns[11].strip()
        try:
            confidence = float(columns[10])
        except ValueError:
            continue
        if text and confidence >= 0:
            words.append((unicodedata.normalize("NFC", text), confidence))
    return words


def _words_score(words):
    """글자 수로 가중한 평균 확신도. 버려질 토막(음표를 읽은 숫자·기호)은 확신도 0 으로 친다.

    무엇을 버릴지는 실제 출력(_kept_words)과 같은 기준으로 가른다."""
    kept = {
        index
        for index, _ in _kept_words([text for text, _ in words], [conf for _, conf in words])
    }
    weighted = 0.0
    total = 0
    for index, (text, conf) in enumerate(words):
        letters = len(_LYRIC_LETTER_RE.findall(text))
        if index not in kept:
            total += max(letters, len(text))
        elif letters:
            weighted += letters * conf
            total += letters
    return weighted / total if total else 0.0


def _keep_word(text, index):
    """음표·기둥을 잘못 읽은 토막을 버린다. 하이픈과 맨 앞 절 번호(`1.`)는 남긴다."""
    if _LYRIC_LETTER_RE.search(text):
        # 음표 기둥을 l·i·j 로 읽은 것. 'I'·'a' 는 진짜 낱말이라 남긴다. OS OCR 은 줄 단위
        # 확신도만 주거나(Vision) 아예 안 줘서(Windows) 확신도로는 가를 수 없다.
        return text not in ("l", "i", "j", "J")
    if _LYRIC_HYPHEN_RE.fullmatch(text):
        return True
    return index == 0 and re.fullmatch(r"\d{1,2}[.)]", text) is not None


def _kept_words(words, confidences=None):
    """[낱말] → [(원래 순번, 가사로 남길 낱말)].

    영어 줄의 외따로 선 세로 막대는 대명사 I 다. 소문자 l 은 보통 음표 기둥이라 버리되,
    Tesseract 가 확신하고(80 이상) 읽은 l 은 산세리프 글꼴의 I 로 본다.
    confidences 는 낱말마다의 확신도(0~100). OS OCR 은 낱말별 확신도가 없어 None 이다."""
    stems = {"|", "l", "i", "j", "J"}
    joined = " ".join(word for word in words if word not in stems)
    latin_line = len(re.findall("[A-Za-z]", joined)) > len(_HANGUL_RE.findall(joined))
    kept = []
    for index, word in enumerate(words):
        confident = confidences is not None and confidences[index] >= 80
        if latin_line and (word == "|" or (word == "l" and confident)):
            kept.append((index, "I"))
        elif _keep_word(word, len(kept)):
            kept.append((index, word))
    return kept


def _ocr_lyric_line(executable, image_path, languages):
    """가사 한 줄을 언어마다 따로 읽어 확신도가 가장 높은 결과를 고른다.

    kor+eng 를 한 번에 쓰면 한 줄 안에서 음절마다 언어를 오가며 읽어서,
    한글 줄을 통째로 영문 잡음으로 읽거나('뽑의노래로' → 'ol Layae') 영어 줄 속
    음절을 한글로 읽었다. 가사 한 줄은 거의 늘 한 언어라 언어별로 읽어 비교한다."""
    candidates = [
        _run_tesseract_words(executable, image_path, language, "7")
        for language in languages
    ]
    words = max(candidates, key=_words_score)
    kept = _kept_words([text for text, _ in words], [conf for _, conf in words])
    return " ".join(word for _, word in kept)


def _pdf_page_words(page, scale):
    """PDF에 박힌 낱말을 (x, 세로 중심, 글자)로. 좌표는 구운 이미지 픽셀 기준."""
    return [
        (x0 * scale, (y0 + y1) / 2 * scale, word)
        for x0, y0, _x1, y1, word, *_ in page.get_text("words")
    ]


# _finish_line 결과: 코드 줄이라 아예 빼야 하는 줄.
_CHORD_LINE = "chord"
_SECTION_LINE = "section"
# 단 목록 사이에 끼워 절을 끊는 표시 (order_lyric_lines). 오선 없는 쪽의 `<verse2>` 자리.
_SECTION_BREAK = [_SECTION_LINE]


def _is_lyric(line):
    """_finish_line 결과가 실제 가사 줄((가사, 이어짐))인지."""
    return isinstance(line, tuple)


def _finish_line(raw):
    """OCR/PDF 원문 한 줄 → (가사 한 줄, 다음 단에 낱말이 이어지는지).

    코드 줄이면 _CHORD_LINE, 곡 구조 표시(`<verse1>`)면 _SECTION_LINE,
    읽지 못한 줄(글자가 두 자도 안 됨)이면 None.
    둘을 가르는 이유 — 코드 줄은 띠에 잘못 섞여 들어온 줄이라 빼면 되지만, 못 읽은 줄은
    진짜 가사 줄 자리라 자리를 비워 둬야 1·2절 순서가 밀리지 않는다 (order_lyric_lines)."""
    text = clean_lyric_line(_NOTE_RE.sub(" ", raw))
    if _SECTION_LINE_RE.match(text.replace(" ", "")):
        return _SECTION_LINE
    # 코드 판별이 먼저다 — 코드 하나짜리 줄('G')도 글자가 두 자 미만이라 못 읽은 줄이 될 뻔한다.
    if is_chord_line(text):
        return _CHORD_LINE
    if not is_lyric_line(text):
        return None
    return text, ends_with_word_break(raw)


def _words_to_system_lines(words, boxes):
    lines = []
    for top, bottom in boxes:
        inside = sorted(
            (word for word in words if top <= word[1] <= bottom),
            key=lambda word: word[0],
        )
        if inside:
            line = _finish_line(" ".join(word[2] for word in inside))
            if _is_lyric(line):
                lines.append(line)
    return lines


def _words_to_lyric_lines(words, boxes):
    """글자가 박힌 PDF는 OCR 없이 띠 안의 낱말을 x 순서로 이어 붙인다."""
    return [text for text, _ in _words_to_system_lines(words, boxes)]


def order_lyric_lines(system_lines):
    """단마다 [(1절 줄), (2절 줄), ...] → 절 순서로 편 가사 줄. 빈 문자열 = 절 사이 빈 줄.

    None 은 못 읽은 줄 자리다. 줄 수 셈에는 넣고(그래야 한 줄을 놓친 단도 같은 구간에
    들고 2절 줄이 1절로 밀리지 않는다) 결과에서는 뺀다.

    악보는 한 단 아래에 1·2절을 겹쳐 적어서, 위에서 아래로 읽으면 1절과 2절이
    한 줄씩 엇갈려 나온다. 줄 수가 같은 단이 이어진 구간마다 1절을 끝까지,
    빈 줄, 2절을 끝까지 ... 순서로 편다. 한 줄짜리 단(후렴)은 그대로 둔다."""
    system_lines = _trim_unread_lines(system_lines)
    runs = []
    new_run = False
    for lines in system_lines:
        if lines == _SECTION_BREAK:
            new_run = True
            continue
        if not any(lines):
            continue
        if runs and not new_run and len(runs[-1][0]) == len(lines):
            runs[-1].append(lines)
        else:
            runs.append([lines])
        new_run = False

    verses_out = []
    for run in runs:
        for verse in range(len(run[0])):
            verses_out.append([lines[verse] for lines in run])

    result = []
    for verse in verses_out:
        merged = _join_broken_words(verse)
        if not merged:
            continue  # 줄을 하나도 못 읽은 절
        if result:
            result.append("")
        result.extend(merged)
    return result


# 단 끝 하이픈 뒤에 와도 끊긴 낱말의 뒷부분으로 보지 않는 흔한 낱말 (_join_broken_words).
# 둘째 음절로도 흔한 것(on: up-on, to: un-to, a: hal-le-lu-ia, in, er)은 넣지 않는다.
_COMMON_ENGLISH_WORDS = frozenset(
    "and for from he her him his me my our she that the thee their them they this "
    "thy we who will with you your".split()
)


def _trim_unread_lines(system_lines):
    """맨 끝 줄을 못 읽은 단이 그것만 빼면 이웃 단과 줄 수가 같아질 때, 그 자리를 덜어 낸다.

    띠 맨 끝에 섞여 든 다음 단 코드 줄은 뭉개져(`4DmMCFCG`) 코드로도 가사로도 안 읽혀
    빈 자리가 된다. 그 단만 줄이 하나 많아 1·2절 구간이 끊긴다.
    맨 끝 자리만, 이웃 단(앞·뒤) 줄 수에 맞출 때만 덜어 낸다 — 진짜 가사 줄을 놓친 자리나
    한 줄짜리 후렴 단이 많은 곡의 1·2절 단은 그대로 둔다.
    이웃 줄 수는 이웃의 맨 끝 빈 자리를 뺀 값이다 — 코드 줄은 마지막 단만 빼고 모든 띠
    끝에 섞여 들기 쉬워서, 이웃도 똑같이 하나씩 많다."""

    def core(lines):
        return len(lines) - 1 if len(lines) > 1 and lines[-1] is None else len(lines)

    trimmed = []
    for index, lines in enumerate(system_lines):
        neighbors = {
            core(system_lines[other])
            for other in (index - 1, index + 1)
            if 0 <= other < len(system_lines) and any(system_lines[other])
            and system_lines[other] != _SECTION_BREAK
        }
        lines = list(lines)
        if (
            len(lines) > 1
            and lines[-1] is None
            and len(lines) not in neighbors
            and len(lines) - 1 in neighbors
        ):
            lines.pop()
        trimmed.append(lines)
    return trimmed


def _join_broken_words(lines):
    """`Lift -` ↵ `ing up my` 처럼 단 끝에서 끊긴 영어 낱말을 앞 줄에 붙인다."""
    lines = [line for line in lines if line]
    if not lines:
        return []
    texts = [text for text, _ in lines]
    for index, (_, broken) in enumerate(lines[:-1]):
        following = texts[index + 1].split(" ", 1)
        # 흐린 그림은 낱말은 못 읽고 하이픈만 남기기도 한다(`and a-gain -` ↵ `for ever`).
        # 뒷줄 첫 토막이 그 자체로 흔한 낱말이면 끊긴 낱말의 뒷부분이 아니다.
        # (하이픈 앞 토막은 보지 않는다 — for-ever, to-geth-er, a-men 처럼 흔한 낱말이 첫 음절이다.)
        if (
            broken
            and following[0]
            and re.match("[a-z]", following[0])
            and following[0].lower() not in _COMMON_ENGLISH_WORDS
        ):
            texts[index] += following[0]
            texts[index + 1] = following[1] if len(following) > 1 else ""
    return [text for text in texts if text]


def _load_sheet_pages(source_path, work_dir):
    """악보 한 쪽마다 (오선을 찾을 이미지, 낱말 목록).

    낱말 목록이 비어 있으면 글자가 안 박힌 쪽이라 OCR로 읽어야 한다.
    그림 파일과 스캔한 PDF가 여기 해당한다."""
    from PIL import Image

    if source_path.suffix.lower() != ".pdf":
        image = Image.open(source_path)
        if image.mode in ("RGBA", "LA", "P"):
            # 투명 배경(캡처·붙여넣은 그림)은 흰 바탕에 얹는다. 그대로 회색으로
            # 바꾸면 투명한 곳이 검게 되어 오선·글자를 못 찾는다.
            image = image.convert("RGBA")
            flat = Image.new("RGB", image.size, "white")
            flat.paste(image, mask=image.getchannel("A"))
            image.close()
            image = flat
        return [(image, [])]

    import pymupdf

    pages = []
    with pymupdf.open(str(source_path)) as document:
        for index, page in enumerate(document):
            page_path = work_dir / f"page_{index:03d}.png"
            page.get_pixmap(dpi=OCR_DPI).save(str(page_path))
            # PDF 좌표는 72dpi 기준이라 구운 이미지 배율로 맞춘다.
            pages.append(
                (Image.open(page_path), _pdf_page_words(page, OCR_DPI / 72))
            )
    return pages


def erase_staff_symbols(gray, threshold, systems):
    """오선과 거기 이어진 모든 획(음표 머리·기둥·꼬리·붙임줄·마디선)을 흰색으로 지운다.

    오선 다섯 줄은 마디선으로 이어져 있고 음표는 기둥으로 오선에 닿으므로, 오선에서
    번져 나가면 한 단의 악보 기호가 한 덩어리로 지워지고 가사·코드 글자만 남는다.
    낮은 음표가 오선 아래로 길게 내려온 악보는 음표와 가사 첫 줄이 한 글 줄로 붙어
    잡히고, 그 줄을 '덧줄 음표'로 보고 통째로 버려서 가사가 사라졌다."""
    from PIL import Image

    width, height = gray.size
    ink = bytearray(gray.point(lambda value: 1 if value < threshold else 0).tobytes())
    stack = []
    for top, bottom, spacing in systems:
        # 한 줄이 흐려 4줄만 찾은 단도 있다. 찾은 줄 수만큼만 — 5줄로 치면 마지막 씨앗이
        # 오선 밑 가사 자리에 떨어져 가사를 지운다.
        for line in range(int(round((bottom - top) / spacing)) + 1):
            center = int(round(top + line * spacing))
            for row in range(max(center - 1, 0), min(center + 2, height)):
                offset = row * width
                stack.extend(offset + x for x in range(width) if ink[offset + x])

    erased = bytearray(width * height)
    while stack:
        index = stack.pop()
        if not ink[index]:
            continue
        ink[index] = 0
        erased[index] = 255
        x = index % width
        if x > 0 and ink[index - 1]:
            stack.append(index - 1)
        if x < width - 1 and ink[index + 1]:
            stack.append(index + 1)
        if index >= width and ink[index - width]:
            stack.append(index - width)
        if index + width < width * height and ink[index + width]:
            stack.append(index + width)

    mask = Image.frombytes("L", (width, height), bytes(erased))
    # 획 가장자리의 옅은 테두리(안티에일리어싱·JPEG 번짐)까지 한 칸 더 지운다.
    from PIL import ImageFilter

    mask = mask.filter(ImageFilter.MaxFilter(3))
    cleaned = gray.copy()
    cleaned.paste(255, mask=mask)
    return cleaned, mask


def restore_lyric_band(original, cleaned, mask, top, bottom, margin):
    """지운 악보 기호 가운데 가사 줄 높이 안에 든 것은 되살린다 (기둥만 빼고).

    음표 머리가 글자에 닿아 있으면 글자까지 같이 지워진다('함께' → '께').
    줄 높이를 거의 다 꿰뚫는 세로 기둥만 지운 채로 두고 나머지는 원래대로 돌린다."""
    from PIL import Image, ImageChops

    band = (0, max(top - margin, 0), original.width, min(bottom + margin + 1, original.height))
    band_height = band[3] - band[1]
    if band_height <= 0:
        return cleaned
    band_mask = mask.crop(band)
    # 열마다 지운 비율 → 80% 넘게 꿰뚫린 열(기둥)만 255.
    columns = band_mask.resize((band_mask.width, 1), Image.BOX)
    keep_erased = columns.point(lambda value: 255 if value >= 204 else 0).resize(
        band_mask.size, Image.NEAREST
    )
    restore = ImageChops.subtract(band_mask, keep_erased)
    if restore.getbbox() is None:
        return cleaned
    result = cleaned.copy()
    result.paste(original.crop(band), band[:2], mask=restore)
    return result


# 단 목록의 줄 항목. 셋 중 하나다.
#   {"text": ..., "continues": ...}  PDF 에 박힌 글자로 이미 다 읽은 줄
#   {"image": 경로}                    OCR 로 읽을 가사 한 줄 이미지
#   {"page_image": 경로}               오선을 못 찾은 쪽 전체 (여러 줄)
# 그림을 다듬고 줄을 자르는 일(레이아웃)과 글자를 읽는 일(OCR)을 나눠 둔 이유 —
# 글자 읽기는 Tesseract 로도, 앱이 OS 내장 OCR(macOS Vision, Windows.Media.Ocr)로도 한다.

# OS OCR 에 넘기는 이미지의 긴 변 상한. Windows.Media.Ocr 는 OcrEngine.MaxImageDimension
# (보통 수천 px)보다 큰 그림을 못 읽는다.
_NATIVE_OCR_MAX_SIDE = 2500


def _fit_within(image, max_side):
    """긴 변이 max_side 를 넘으면 비율을 지켜 줄인다."""
    from PIL import Image

    if not max_side or max(image.size) <= max_side:
        return image
    factor = max_side / max(image.size)
    return image.resize(
        (max(int(image.width * factor), 1), max(int(image.height * factor), 1)),
        Image.LANCZOS,
    )


def _native_line_image(image):
    """OS OCR 용 줄 이미지: 절반으로 줄이고 흰 여백을 두른다.

    Vision 은 글자가 띄엄띄엄 놓인 큰 줄 이미지(글자 높이 48px, 여백 없음)를 통째로 못 찾고
    빈 결과를 자주 낸다(콘티 PDF 한 쪽에서 12줄 중 8줄). 이렇게 하면 다 읽었다."""
    from PIL import Image, ImageOps

    image = image.resize((max(image.width // 2, 1), max(image.height // 2, 1)), Image.LANCZOS)
    return ImageOps.expand(image, border=image.height, fill=255)


def _layout_image_page(image, work_dir, page_index, native=False):
    """그림 한 쪽 → (단마다의 줄 항목 목록, 찾은 오선 단 수). 줄 이미지는 work_dir 에 저장한다.

    native=True 면 OS 내장 OCR 용으로 만든다 — 회색 그대로, 긴 변은 _NATIVE_OCR_MAX_SIDE 이하."""
    max_side = _NATIVE_OCR_MAX_SIDE if native else None
    original, staff_threshold, threshold = prepare_sheet_image(image)
    systems = find_staff_systems(row_dark_ratios(original, staff_threshold))
    if not systems:
        # 오선을 못 찾으면 쪽 전체를 한 번에 읽는다 (가사만 있는 스캔 등).
        path = work_dir / f"p{page_index:03d}_page.png"
        _fit_within(original, max_side).save(path)
        return [[{"page_image": str(path)}]], 0

    gray, mask = erase_staff_symbols(original, staff_threshold, systems)
    ratios = row_dark_ratios(gray, threshold)
    layout = []
    for system_index, boxes in enumerate(lyric_line_boxes_by_system(systems, ratios)):
        spacing = systems[system_index][2]
        items = []
        for box_index, (top, bottom) in enumerate(boxes):
            # 줄 주변만 잘라서 다룬다 (줄마다 쪽 전체를 복사하지 않게).
            reach = _line_reach(spacing)
            window = (0, max(top - reach, 0), gray.width, min(bottom + 1 + reach, gray.height))
            offset = window[1]
            source = restore_lyric_band(
                original.crop(window), gray.crop(window), mask.crop(window),
                top - offset, bottom - offset, max(int(spacing * 0.3), 2),
            )
            line_image = _lyric_line_image(
                source, threshold, top - offset, bottom - offset, spacing,
                binarize=not native,
            )
            if line_image is None:
                continue
            path = work_dir / f"p{page_index:03d}_s{system_index:02d}_l{box_index:02d}.png"
            if native:
                line_image = _native_line_image(line_image)
            _fit_within(line_image, max_side).save(path)
            items.append({"image": str(path)})
        layout.append(items)
    return layout, len(systems)


def _layout_text_page(image, words):
    """글자가 박힌 PDF 한 쪽 → (단마다의 줄 항목 목록, 찾은 오선 단 수). OCR 이 필요 없다.

    줄 위치는 그림과 똑같이 오선에 이어진 음표를 지운 뒤 찾는다 (음표가 가사에 붙는 문제는 같다)."""
    gray = image.convert("L")
    ratios = row_dark_ratios(gray)
    systems = find_staff_systems(ratios)
    if systems:
        ratios = row_dark_ratios(erase_staff_symbols(gray, 160, systems)[0])
    by_system = lyric_line_boxes_by_system(systems, ratios)
    if not any(by_system):
        # 오선을 못 찾으면 쪽 전체의 글 줄을 그대로 쓴다.
        by_system = [text_row_groups(ratios, 0, len(ratios))]
    layout = [
        [{"text": text, "continues": continues}
         for text, continues in _words_to_system_lines(words, boxes)]
        for boxes in by_system
    ]
    return layout, len(systems)


def layout_sheet(source_path, work_dir, native=False):
    """악보 파일 → 단 목록과 요약 정보. 줄 이미지는 work_dir 에 남는다 (지우는 건 부른 쪽)."""
    pages = _load_sheet_pages(source_path, work_dir)
    layout = []
    staff_count = 0
    try:
        for page_index, (image, words) in enumerate(pages):
            if words:
                page_layout, page_staffs = _layout_text_page(image, words)
            else:
                page_layout, page_staffs = _layout_image_page(
                    image, work_dir, page_index, native
                )
            layout.extend(page_layout)
            staff_count += page_staffs
    finally:
        for image, _words in pages:
            image.close()
    return {
        "source_name": unicodedata.normalize("NFC", source_path.name),
        "systems": layout,
        "page_count": len(pages),
        "staff_count": staff_count,
        # True 면 PDF에 박힌 글자를 그대로 읽은 것 (OCR 오인식이 없다).
        "text_layer": any(bool(words) for _image, words in pages),
    }


def ocr_image_paths(job):
    """OCR 로 읽어야 하는 이미지 경로 목록 (단 순서대로)."""
    return [
        item.get("image") or item["page_image"]
        for items in job["systems"]
        for item in items
        if "image" in item or "page_image" in item
    ]


def resolve_sheet_lines(job, read_line, read_page):
    """줄 항목을 실제 가사 줄로 바꾼다 → 단마다의 [(가사 줄, 이어짐)].

    read_line(경로) → _finish_line 결과, read_page(경로) → _finish_line 결과 목록.
    못 읽은 줄은 None 으로 자리를 남기고 코드 줄은 뺀다 (_finish_line 참고).
    쪽 전체에서 읽은 줄은 한 줄씩 따로 단으로 둔다 — 한 단에 넣으면 절 정리가
    줄마다 다른 절로 보고 사이사이 빈 줄을 넣는다."""
    systems = []
    for items in job["systems"]:
        if items and "page_image" in items[0]:
            for line in read_page(items[0]["page_image"]):
                if line == _SECTION_LINE:
                    systems.append(list(_SECTION_BREAK))
                elif _is_lyric(line):
                    systems.append([line])
            continue
        lines = []
        for item in items:
            line = (
                (item["text"], item["continues"]) if "text" in item
                else read_line(item["image"])
            )
            if line not in (_CHORD_LINE, _SECTION_LINE):
                lines.append(line)
        systems.append(lines)
    return systems


def _sheet_result(job, systems, language):
    ordered = order_lyric_lines(systems)
    return {
        "source_name": job["source_name"],
        # 빈 줄 = 절이 바뀌는 곳 (앱에서는 페이지 나눔이 된다).
        "lyrics": "\n".join(ordered),
        "lines": [line for line in ordered if line],
        "page_count": job["page_count"],
        "staff_count": job["staff_count"],
        "language": language,
        "text_layer": job["text_layer"],
    }


def _read_with_tesseract(job, executable, languages):
    """줄 이미지를 Tesseract 로 읽는다. 줄마다 따로 띄우므로 스레드 풀로 동시에 돌린다."""
    workers = max(1, min(8, os.cpu_count() or 1))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            path: pool.submit(_ocr_lyric_line, executable, Path(path), languages)
            for items in job["systems"]
            for item in items
            if "image" in item
            for path in [item["image"]]
        }

        def read_line(path):
            return _finish_line(futures[path].result())

        def read_page(path):
            text = _run_tesseract(executable, path, "+".join(languages), "6")
            return [_finish_line(line) for line in text.splitlines()]

        return resolve_sheet_lines(job, read_line, read_page)


def extract_sheet_music_lyrics(file_path):
    """악보 이미지(PDF 포함)에서 오선 아래 가사만 뽑아 낸다 (Tesseract 로 읽는다)."""
    source_path = Path(file_path)
    if not source_path.exists():
        raise RuntimeError(f"파일을 찾을 수 없습니다: {file_path}")

    work_dir = Path(tempfile.mkdtemp(prefix="praise_sheet_ocr_"))
    try:
        job = layout_sheet(source_path, work_dir)
        # 글자가 박힌 PDF는 OCR 없이 읽는다. 그림·스캔본만 Tesseract가 필요하다.
        if not ocr_image_paths(job):
            return _sheet_result(job, resolve_sheet_lines(job, None, None), "")
        executable = get_tesseract_executable()
        if executable is None:
            return {"error": "tesseract_missing"}
        language = get_tesseract_language(executable)
        # 줄마다 언어별로 따로 읽어 비교한다 (kor+eng → kor, eng).
        systems = _read_with_tesseract(job, executable, language.split("+"))
        return _sheet_result(job, systems, language)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


def export_sheet_lines(file_path, out_dir):
    """앱이 OS 내장 OCR 로 읽을 수 있게 줄 이미지만 만들어 둔다 (1단계).

    OCR 이 필요 없으면(글자가 박힌 PDF) 바로 최종 결과를 돌려준다. 아니면
    {"needs_ocr": true, "job": job.json 경로, "images": [...]} — 앱이 이미지를 읽어
    `sheet-finish <job.json> <결과.json>` 으로 넘긴다."""
    source_path = Path(file_path)
    if not source_path.exists():
        raise RuntimeError(f"파일을 찾을 수 없습니다: {file_path}")
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    job = layout_sheet(source_path, out_dir, native=True)
    images = ocr_image_paths(job)
    if not images:
        return _sheet_result(job, resolve_sheet_lines(job, None, None), "")
    job_path = out_dir / "job.json"
    job_path.write_text(json.dumps(job, ensure_ascii=False), encoding="utf-8")
    return {"needs_ocr": True, "job": str(job_path), "images": images}


def _native_line_text(observations):
    """OS OCR 이 한 줄 이미지에서 찾은 글 덩어리들 → 원문 한 줄.

    음표 자리 때문에 벌어진 가사는 한 줄이 여러 덩어리로 나뉘어 오므로 x 순서로 잇는다.
    확신도가 낮은 덩어리, 음표·기둥을 읽은 토막은 버린다."""
    words = []
    for observation in sorted(observations, key=lambda item: item.get("x", 0.0)):
        if float(observation.get("confidence", 1.0)) * 100 < _NATIVE_MIN_CONFIDENCE:
            continue
        words.extend(unicodedata.normalize("NFC", observation.get("text", "")).split())
    return " ".join(word for _, word in _kept_words(words))


def _native_page_lines(observations):
    """쪽 전체 OCR 결과 → 위에서 아래 순서의 원문 줄 목록. 세로로 겹치는 덩어리는 한 줄이다."""
    rows = []
    for observation in sorted(observations, key=lambda item: item.get("y", 0.0)):
        top = observation.get("y", 0.0)
        bottom = top + observation.get("h", 0.0)
        if rows:
            row_top, row_bottom, members = rows[-1]
            overlap = min(bottom, row_bottom) - max(top, row_top)
            if overlap > min(bottom - top, row_bottom - row_top) * 0.5:
                rows[-1] = (min(top, row_top), max(bottom, row_bottom), members + [observation])
                continue
        rows.append((top, bottom, [observation]))
    # 맨 윗줄이 다른 줄보다 확 크면 곡 제목이다 (오선 없는 가사·코드 악보).
    # 줄 높이는 덩어리 중 가장 큰 것 — 겹쳐 묶은 범위는 덩어리가 살짝 어긋나기만 해도 커진다.
    heights = [max(item.get("h", 0.0) for item in members) for _top, _bottom, members in rows]
    if len(rows) >= 3 and heights[0] > sorted(heights)[len(heights) // 2] * 1.5:
        rows = rows[1:]
    return [_native_line_text(members) for _top, _bottom, members in rows]


def finish_sheet_lines(job_path, ocr_path):
    """앱이 OS 내장 OCR 로 읽은 결과로 가사를 마무리한다 (2단계).

    ocr_path JSON = {이미지 경로: [{text, confidence(0~1), x, y, w, h(0~1, 위가 0)}]}."""
    job = json.loads(Path(job_path).read_text(encoding="utf-8"))
    results = json.loads(Path(ocr_path).read_text(encoding="utf-8"))

    def read_line(path):
        return _finish_line(_native_line_text(results.get(path) or []))

    def read_page(path):
        return [_finish_line(line) for line in _native_page_lines(results.get(path) or [])]

    return _sheet_result(job, resolve_sheet_lines(job, read_line, read_page), "native")


def extract_sheet_music(file_path, out_dir=None):
    """`sheet <파일|--clipboard> [--ocr-lines <폴더>]`. 폴더를 주면 1단계(줄 이미지)만 한다."""
    if file_path == "--clipboard":
        result = extract_clipboard_sheet_music(out_dir)
    elif out_dir:
        result = export_sheet_lines(file_path, out_dir)
    else:
        result = extract_sheet_music_lyrics(file_path)
    print(json.dumps(result, ensure_ascii=True))


def extract_clipboard_sheet_music(out_dir=None):
    """클립보드의 그림(캡처·복사한 이미지)이나 복사한 파일을 악보로 읽는다."""
    from PIL import Image, ImageGrab

    def extract(path):
        return export_sheet_lines(path, out_dir) if out_dir else extract_sheet_music_lyrics(path)

    try:
        clip = ImageGrab.grabclipboard()
    except Exception:  # 클립보드 형식에 따라 OS 쪽에서 실패하기도 한다
        clip = None
    # Finder/탐색기에서 파일을 복사하면 경로 목록이 온다.
    if isinstance(clip, list):
        paths = [path for path in clip if Path(path).suffix.lower() in _SHEET_SUFFIXES]
        if not paths:
            return {"error": "clipboard_empty"}
        return extract(paths[0])
    if not isinstance(clip, Image.Image):
        return {"error": "clipboard_empty"}

    work_dir = Path(tempfile.mkdtemp(prefix="praise_sheet_clip_"))
    try:
        image_path = work_dir / "클립보드.png"
        clip.save(image_path)
        return extract(str(image_path))
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: ppt_tool.py [import|export|render|sheet|sheet-finish] [payload]")

    command = sys.argv[1]
    payload = sys.argv[2]

    if command == "import":
        import_folder(payload)
        return

    if command == "export":
        export_presentation(payload)
        return

    if command == "render":
        # --no-animation: 애니메이션을 펼치지 않고 슬라이드당 한 장만 굽는다.
        render_presentation(payload, expand_animation="--no-animation" not in sys.argv[3:])
        return

    if command == "sheet":
        # --ocr-lines <폴더>: 줄 이미지만 만들고 앱의 OS 내장 OCR 결과를 기다린다.
        options = sys.argv[3:]
        out_dir = None
        if "--ocr-lines" in options and options.index("--ocr-lines") + 1 < len(options):
            out_dir = options[options.index("--ocr-lines") + 1]
        extract_sheet_music(payload, out_dir)
        return

    if command == "sheet-finish":
        if len(sys.argv) < 4:
            raise SystemExit("usage: ppt_tool.py sheet-finish <job.json> <ocr.json>")
        print(json.dumps(finish_sheet_lines(payload, sys.argv[3]), ensure_ascii=True))
        return

    raise SystemExit(f"unknown command: {command}")


if __name__ == "__main__":
    main()
