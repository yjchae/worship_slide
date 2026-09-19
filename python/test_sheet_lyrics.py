"""악보 가사 추출 self-check.

줄 찾기·하이픈 정리는 Tesseract 없이도 돌고,
실제 OCR 검증은 Tesseract가 있을 때만 돈다."""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from ppt_tool import (
    clean_lyric_line,
    extract_sheet_music_lyrics,
    find_staff_systems,
    get_tesseract_executable,
    is_chord_line,
    is_lyric_line,
    lyric_line_boxes,
    text_row_groups,
)

FONT_PATH = Path(__file__).parent.parent / "assets" / "fonts" / "NanumGothic-Regular.ttf"

STAFF_TOPS = [200, 500, 800]
STAFF_SPACING = 12
# 첫 단은 2절까지, 나머지 단은 한 줄.
SHEET_LYRICS = [
    ["1. 예 - 수 사 랑 하 심 은", "2. 거룩하신 주님께"],
    ["주 - 님 의 사 랑"],
    ["할렐루야 아멘"],
]


def test_clean_lyric_line():
    # 하이픈은 양옆 공백까지 지워 음절을 붙인다.
    assert clean_lyric_line("할 - 렐 - 루 - 야") == "할렐루야"
    assert clean_lyric_line("할-렐루야") == "할렐루야"
    assert clean_lyric_line("주 님 의 사 랑 -") == "주 님 의 사 랑"
    assert clean_lyric_line("A – ma – zing") == "Amazing"
    # 마디선을 글자로 읽은 것은 공백으로
    assert clean_lyric_line("주님 | 사랑") == "주님 사랑"


def test_is_lyric_line():
    assert is_lyric_line("주의 은혜")
    assert is_lyric_line("Amazing")
    # 음표·마디번호를 잘못 읽은 줄
    assert not is_lyric_line("1 2 3 4")
    assert not is_lyric_line(". , ' \"")
    assert not is_lyric_line("J")


def test_is_chord_line():
    assert is_chord_line("G D Em C")
    assert is_chord_line("Am/E F#m7")
    assert not is_chord_line("거룩하신 주님께")
    assert not is_chord_line("Am I not yours")


def test_find_staff_systems():
    # 오선 두 단(줄 간격 10)을 가로 검은 비율로 흉내 낸다.
    ratios = [0.0] * 400
    for top in (100, 250):
        for index in range(5):
            ratios[top + index * 10] = 0.9
    # 첫 단 아래 가사 두 줄, 다음 단 바로 위 코드 한 줄.
    for row in list(range(160, 175)) + list(range(180, 195)):
        ratios[row] = 0.3
    for row in range(232, 244):
        ratios[row] = 0.05

    systems = find_staff_systems(ratios)
    assert len(systems) == 2, systems
    assert systems[0][:2] == (100, 140), systems[0]
    assert systems[0][2] == 10, systems[0]

    # 글 줄 세 개를 다 찾되, 아래 단에 붙은 코드 줄만 가사에서 빠진다.
    assert text_row_groups(ratios, 143, 248) == [(160, 174), (180, 194), (232, 243)]
    assert lyric_line_boxes(systems, ratios) == [(160, 174), (180, 194)]


def _draw_sheet(path):
    """오선 3단 + 단마다 오선 아래 가사, 위쪽엔 제목·코드가 있는 악보를 그린다."""
    from PIL import Image, ImageDraw, ImageFont

    image = Image.new("L", (900, 1100), 255)
    draw = ImageDraw.Draw(image)
    title_font = ImageFont.truetype(str(FONT_PATH), 40)
    lyric_font = ImageFont.truetype(str(FONT_PATH), 30)
    chord_font = ImageFont.truetype(str(FONT_PATH), 26)

    draw.text((300, 60), "믿음의 노래", font=title_font, fill=0)
    for index, top in enumerate(STAFF_TOPS):
        for line in range(5):
            y = top + line * STAFF_SPACING
            draw.line((60, y, 840, y), fill=0, width=2)
        draw.text((70, top - 40), "G   D   Em   C", font=chord_font, fill=0)
        for verse, text in enumerate(SHEET_LYRICS[index]):
            y = top + 4 * STAFF_SPACING + 14 + verse * 44
            draw.text((70, y), text, font=lyric_font, fill=0)
    image.save(path)


def test_extract_sheet_music_lyrics():
    if get_tesseract_executable() is None:
        print("SKIP: Tesseract 없음")
        return

    with tempfile.TemporaryDirectory() as temp_dir:
        sheet_path = Path(temp_dir) / "sheet.png"
        _draw_sheet(sheet_path)
        result = extract_sheet_music_lyrics(str(sheet_path))

    assert result.get("error") is None, result
    assert result["staff_count"] == 3, result
    text = result["lyrics"]
    # 음절 사이 띄어쓰기는 Tesseract가 붙이기도 해서 빼고 비교한다.
    compact = text.replace(" ", "")
    # 하이픈은 지워지고 앞뒤 음절이 붙는다. 2절도 같이 나온다.
    assert "예수사랑하심은" in compact, text
    assert "거룩하신주님께" in compact, text
    assert "주님의사랑" in compact, text
    assert "할렐루야아멘" in compact, text
    # 오선 위(제목·코드)는 들어오면 안 된다.
    assert "믿음의노래" not in compact, text
    assert "Em" not in text, text


if __name__ == "__main__":
    test_clean_lyric_line()
    test_is_lyric_line()
    test_is_chord_line()
    test_find_staff_systems()
    test_extract_sheet_music_lyrics()
    print("OK")
