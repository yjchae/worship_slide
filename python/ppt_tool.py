import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.util import Inches, Pt

PPT_CONVERT_CHUNK_SIZE = 40
PPT_CONVERT_PARALLELISM = 3


def extract_text_from_shape(shape):
    if not hasattr(shape, "text_frame") or shape.text_frame is None:
        return ""
    lines = []
    for paragraph in shape.text_frame.paragraphs:
        text = "".join(run.text for run in paragraph.runs).strip()
        if text:
            lines.append(text)
    return "\n".join(lines)


def slide_lyrics(slide):
    blocks = []
    for shape in slide.shapes:
        text = extract_text_from_shape(shape)
        if text:
            blocks.append(text)
    return "\n".join(blocks).strip()


def normalize_title(path):
    return path.stem.strip()


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
    home = Path.home()
    return home / "Library" / "Caches" / "praise_lyrics_app" / "ppt_import_cache"


def get_ppt_cache_key(source_path):
    stat = source_path.stat()
    payload = f"{source_path.resolve()}::{stat.st_size}::{stat.st_mtime_ns}"
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()


def get_cached_pptx_path(source_path):
    cache_root = get_cache_root()
    cache_root.mkdir(parents=True, exist_ok=True)
    return cache_root / f"{get_ppt_cache_key(source_path)}.pptx"


def convert_ppt_group_to_pptx(source_paths, output_dir):
    subprocess.run(
        [
            "soffice",
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
                ensure_ascii=False,
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
        korean_pages = []
        english_pages = []

        for slide in prs.slides:
            page = slide_lyrics(slide)
            if not page:
                continue
            korean_page, english_page = split_bilingual_page(page)
            if korean_page:
                korean_pages.append(korean_page)
            else:
                korean_pages.append("")
            english_pages.append(english_page)

        if not any(page for page in korean_pages + english_pages):
            return {"status": "skipped", "path": str(file_path)}

        return {
            "status": "ok",
            "song": {
                "file_name": file_path.name,
                "title": normalize_title(file_path),
                "lyrics": "\n###\n".join(korean_pages),
                "english_lyrics": "\n###\n".join(english_pages),
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
            },
            ensure_ascii=False,
        )
    )


def parse_hex_color(hex_color):
    value = hex_color.replace("#", "")
    return RGBColor(int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16))


def add_song_slides(prs, song, style):
    bg_color = parse_hex_color(style["background_color"])
    text_color = parse_hex_color(style["text_color"])
    font_size = Pt(style["font_size"])
    position = style["text_position"]
    include_english_lyrics = style.get("include_english_lyrics", False)
    english_color = parse_hex_color(style["english_text_color"])
    korean_pages = [part.strip() for part in song["lyrics"].split("###")]
    english_pages = [part.strip() for part in song.get("english_lyrics", "").split("###")]
    page_count = max(len(korean_pages), len(english_pages))

    for index in range(page_count):
        page = korean_pages[index] if index < len(korean_pages) else ""
        english_page = english_pages[index] if index < len(english_pages) else ""
        if not page and not english_page:
            continue

        slide = prs.slides.add_slide(prs.slide_layouts[6])
        slide.background.fill.solid()
        slide.background.fill.fore_color.rgb = bg_color

        textbox = slide.shapes.add_textbox(Inches(0.7), Inches(0.6), Inches(11.9), Inches(5.4))
        frame = textbox.text_frame
        frame.clear()
        frame.word_wrap = True
        frame.vertical_anchor = {
            "top": MSO_ANCHOR.TOP,
            "middle": MSO_ANCHOR.MIDDLE,
            "bottom": MSO_ANCHOR.BOTTOM,
        }[position]

        paragraph = frame.paragraphs[0]
        paragraph.alignment = PP_ALIGN.CENTER
        run = paragraph.add_run()
        run.text = page
        run.font.size = font_size
        run.font.bold = True

        run.font.color.rgb = text_color

        if include_english_lyrics and english_page:
            english_paragraph = frame.add_paragraph()
            english_paragraph.alignment = PP_ALIGN.CENTER
            english_run = english_paragraph.add_run()
            english_run.text = english_page
            english_run.font.size = Pt(style["font_size"] * 0.8)
            english_run.font.bold = True
            english_run.font.color.rgb = english_color


def _add_blank_slide(prs, style):
    bg_color = parse_hex_color(style["background_color"])
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    slide.background.fill.solid()
    slide.background.fill.fore_color.rgb = bg_color


def export_presentation(payload_json):
    payload = json.loads(payload_json)
    output_path = Path(payload["output_path"])
    songs = payload["songs"]
    style = payload["style"]

    prs = Presentation()
    if len(prs.slides) == 0:
        prs.slides.add_slide(prs.slide_layouts[6])
        r_id = prs.slides._sldIdLst[0].rId
        prs.part.drop_rel(r_id)
        del prs.slides._sldIdLst[0]

    prs.slide_width = Inches(13.333)
    prs.slide_height = Inches(7.5)

    for index, song in enumerate(songs):
        add_song_slides(prs, song, style)
        if index < len(songs) - 1:
            _add_blank_slide(prs, style)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    prs.save(str(output_path))
    print(json.dumps({"output_path": str(output_path)}, ensure_ascii=False))


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

    raise SystemExit(f"unknown command: {command}")


if __name__ == "__main__":
    main()
