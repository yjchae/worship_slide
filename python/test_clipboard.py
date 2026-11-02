"""편집 페이지 클립보드 그림 self-check: python3 python/test_clipboard.py

실제 클립보드 대신 grab 함수를 바꿔 넣어 `clipboard` 명령의 세 갈래(그림 → PNG 저장,
복사한 파일 → 그 경로, 없음 → clipboard_empty)와 CMYK 변환을 확인한다.
"""
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PIL import Image

from ppt_tool import clipboard_image


def main():
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "sub" / "clip.png"

        result = clipboard_image(out, grab=lambda: Image.new("RGBA", (40, 20), "red"))
        assert result == {"path": str(out)}, result
        with Image.open(out) as saved:
            assert saved.format == "PNG" and saved.size == (40, 20), saved

        out.unlink()
        result = clipboard_image(out, grab=lambda: Image.new("CMYK", (8, 8)))
        assert result == {"path": str(out)} and out.exists(), result

        files = ["/a/doc.pdf", "/a/cat.JPG", "/a/dog.png"]
        assert clipboard_image(out, grab=lambda: files) == {"path": "/a/cat.JPG"}
        assert clipboard_image(out, grab=lambda: ["/a/doc.pdf"]) == {"error": "clipboard_empty"}
        assert clipboard_image(out, grab=lambda: None) == {"error": "clipboard_empty"}
        assert clipboard_image(out, grab=lambda: "text") == {"error": "clipboard_empty"}

        def broken():
            raise OSError("no clipboard")

        assert clipboard_image(out, grab=broken) == {"error": "clipboard_empty"}
    print("clipboard: 통과")


if __name__ == "__main__":
    main()
