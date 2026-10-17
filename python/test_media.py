"""PPT 안 동영상 꺼내기 self-check: python3 python/test_media.py

LibreOffice 없이 도는 XML 단위 테스트. python-pptx 로 동영상을 넣은 pptx 를 만들어
extract_slide_videos 가 페이지 번호·자리(rect)를 맞게 적고, 애니메이션 단계로 복제된
슬라이드가 동영상 파일 하나를 같이 쓰는지 확인한다.
"""
import io
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PIL import Image
from pptx import Presentation
from pptx.util import Emu

from ppt_tool import extract_slide_videos


def _poster():
    buffer = io.BytesIO()
    Image.new("RGB", (16, 9), "gray").save(buffer, "PNG")
    buffer.seek(0)
    return buffer


def main():
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        movie = work / "clip.mp4"
        movie.write_bytes(b"\x00\x00\x00\x18ftypmp42 fake")
        legacy = work / "old.wmv"
        legacy.write_bytes(b"wmv")

        prs = Presentation()
        width, height = prs.slide_width, prs.slide_height
        blank = prs.slide_layouts[6]
        prs.slides.add_slide(blank)  # 1: 동영상 없음
        slide = prs.slides.add_slide(blank)  # 2: 오른쪽 아래 1/4
        slide.shapes.add_movie(
            str(movie), Emu(width // 2), Emu(height // 2), Emu(width // 2), Emu(height // 2),
            poster_frame_image=_poster(), mime_type="video/mp4",
        )
        hidden = prs.slides.add_slide(blank)  # 숨김: PDF 에 없으므로 번호에서 빠져야 한다
        hidden._element.set("show", "0")
        slide = prs.slides.add_slide(blank)  # 3: 재생 못 하는 형식 → 포스터만
        slide.shapes.add_movie(
            str(legacy), 0, 0, width, height, poster_frame_image=_poster(), mime_type="video/x-ms-wmv",
        )
        slide = prs.slides.add_slide(blank)  # 4: 2번과 같은 파일, 화면 전체
        slide.shapes.add_movie(
            str(movie), 0, 0, width, height, poster_frame_image=_poster(), mime_type="video/mp4",
        )
        source = work / "deck.pptx"
        prs.save(source)

        out = work / "out"
        out.mkdir()
        assert extract_slide_videos(source, out, 4, work) == 2
        assert not (out / "0001.media.json").exists()
        assert not (out / "0003.media.json").exists()
        second = json.loads((out / "0002.media.json").read_text(encoding="utf-8"))
        fourth = json.loads((out / "0004.media.json").read_text(encoding="utf-8"))
        assert second["rect"] == [0.5, 0.5, 0.5, 0.5], second
        assert fourth["rect"] == [0.0, 0.0, 1.0, 1.0], fourth
        # python-pptx 는 같은 파일을 한 번만 담으므로 두 페이지가 같은 동영상을 가리킨다.
        assert second["file"] == fourth["file"] and second["file"].endswith(".mp4")
        assert (out / second["file"]).read_bytes() == movie.read_bytes()

        # 페이지 수가 PDF 와 다르면(변환이 슬라이드를 빼먹음 등) 엉뚱한 페이지에 붙이지 않는다.
        other = work / "other"
        other.mkdir()
        assert extract_slide_videos(source, other, 5, work) == 0
        assert not list(other.iterdir())

        print("ok: 동영상 2개 페이지(숨긴 슬라이드 건너뜀, wmv 제외, 같은 파일 공유)")


if __name__ == "__main__":
    main()
