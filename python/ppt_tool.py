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


def _ensure_fonts_installed(font_family="Pretendard"):
    import platform
    system = platform.system()
    if system == "Windows":
        local_appdata = os.environ.get("LOCALAPPDATA", "")
        if not local_appdata:
            return
        fonts_dir = os.path.join(local_appdata, "Microsoft", "Windows", "Fonts")
    else:
        fonts_dir = os.path.expanduser("~/Library/Fonts")
    os.makedirs(fonts_dir, exist_ok=True)
    for filename in _FONT_FILES.get(font_family, _FONT_FILES["Pretendard"]):
        dest = os.path.join(fonts_dir, filename)
        if not os.path.exists(dest):
            src = _get_font_path(filename)
            if os.path.exists(src):
                shutil.copy2(src, dest)


def extract_text_from_shape(shape):
    if not hasattr(shape, "text_frame") or shape.text_frame is None:
        return ""
    lines = []
    for paragraph in shape.text_frame.paragraphs:
        text = "".join(run.text for run in paragraph.runs).strip()
        if text:
            lines.append(text)
    return "\n".join(lines)


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
    shapes_info = []
    for shape in slide.shapes:
        text = extract_text_from_shape(shape)
        if not text:
            continue
        # shape 전체 텍스트가 반복 제목과 완전히 일치하는 shape만 제외
        if title_texts and text.strip() in title_texts:
            continue
        shapes_info.append((text, _shape_max_font_pt(shape)))

    if not shapes_info:
        return ""
    if len(shapes_info) == 1:
        return shapes_info[0][0]

    # 보조 필터: 명시적 폰트 크기가 최댓값의 60% 미만인 박스도 제목/캡션으로 간주
    explicit_sizes = [size for _, size in shapes_info if size is not None]
    if explicit_sizes:
        max_size = max(explicit_sizes)
        kept = [
            text for text, size in shapes_info
            if size is None or size >= max_size * 0.6
        ]
        if kept:
            return "\n".join(kept).strip()

    return "\n".join(text for text, _ in shapes_info).strip()


def normalize_title(path):
    # macOS HFS+는 파일명을 NFD로 저장하므로 NFC로 변환해야 한글이 정상 표시됨
    title = unicodedata.normalize('NFC', path.stem.strip())
    return re.sub(r'\s*\(\s*와이드 스크린\s*\)\s*', '', title, flags=re.IGNORECASE).strip()


def is_english_line(line):
    stripped = line.strip()
    if not stripped:
        return False
    if any("\uac00" <= char <= "\ud7a3" for char in stripped):
        return False

    alpha_count = sum(char.isalpha() for char in stripped)
    latin_count = sum(("A" <= char <= "Z") or ("a" <= char <= "z") for char in stripped)
    if latin_count == 0:
        return False
    return latin_count / max(alpha_count, 1) >= 0.6


def split_bilingual_page(text):
    korean_lines = []
    english_lines = []

    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if is_english_line(stripped):
            english_lines.append(stripped)
        else:
            korean_lines.append(stripped)

    return "\n".join(korean_lines), "\n".join(english_lines)


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
        for slide in prs.slides:
            page = slide_lyrics(slide, title_texts=title_texts)
            if not page:
                korean_pages.append("")
                english_pages.append("")
                continue
            korean_page, english_page = split_bilingual_page(page)
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
_LYRICS_BOX_BOTTOM = _SLIDE_H - _LYRICS_BOX_TOP - _LYRICS_BOX_HEIGHT
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

    상단 여백(``text_box_top``)은 상자의 높이를 정하고, 미세 조정
    (``text_offset_y``)은 그 상자를 통째로 위아래로 민다(높이는 그대로).
    그래야 상단/중단/하단 어느 기준이든 밀어 준 만큼 똑같이 움직인다.
    미리보기(Dart)·발표 창(Swift/GDI)도 같은 식으로 계산한다.
    """
    top = float(style.get(
        "bible_text_box_top" if is_bible else "text_box_top",
        _LYRICS_BOX_TOP,
    ))
    top = min(max(top, 0.3), _SLIDE_H - _LYRICS_BOX_BOTTOM - 1.0)
    height = _SLIDE_H - top - _LYRICS_BOX_BOTTOM
    return top + _lyrics_offset_y(style, is_bible), height


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
    _ensure_fonts_installed(style.get("font_family", "Pretendard"))

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
                add_song_slides(prs, song, style, background)
            is_last = index == len(songs) - 1
            next_is_blank = not is_last and songs[index + 1].get("type") == "blank"
            if not is_last and not next_is_blank:
                next_type = songs[index + 1].get("type")
                # 말씀 다음 말씀이면 빈 슬라이드 삽입 안 함
                if not (song.get("type") == "bible" and next_type == "bible"):
                    # 자동으로 끼우는 여백은 앞 항목의 배경을 따라간다
                    # (발표 화면의 _allSlides 도 앞 항목 uid 를 빌려 쓴다).
                    _add_blank_slide(prs, style, background)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    prs.save(str(output_path))
    print(json.dumps({"output_path": str(output_path)}, ensure_ascii=True))


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: ppt_tool.py [import|export] [payload]")

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

    raise SystemExit(f"unknown command: {command}")


if __name__ == "__main__":
    main()
