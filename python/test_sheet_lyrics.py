"""악보 가사 추출 self-check.

줄 찾기·하이픈 정리와 글자가 박힌 PDF 는 Tesseract 없이도 돌고,
그림 악보 OCR 검증만 Tesseract가 있을 때 돈다."""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import ppt_tool
from ppt_tool import (
    clean_lyric_line,
    erase_staff_symbols,
    lyric_line_boxes_by_system,
    restore_lyric_band,
    ends_with_word_break,
    find_skew_angle,
    order_lyric_lines,
    otsu_threshold,
    prepare_sheet_image,
    join_single_syllables,
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
# PDF는 72dpi 포인트 좌표라 그림보다 촘촘하다.
PDF_STAFF_TOPS = [140, 340, 540]
PDF_STAFF_SPACING = 8
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
    assert clean_lyric_line("주 님 의 사 랑 -") == "주님의사랑"
    assert clean_lyric_line("A – ma – zing") == "Amazing"
    # 마디선을 글자로 읽은 것은 공백으로
    assert clean_lyric_line("주님 | 사랑") == "주님 사랑"


def test_join_single_syllables():
    # 음표마다 떨어뜨려 놓은 한 글자 토막은 붙인다.
    assert join_single_syllables("주 의 인 자 하 심 이") == "주의인자하심이"
    assert join_single_syllables("주 님의 사랑") == "주님의 사랑"
    # 절 번호는 한글이 아니라 안 붙는다.
    assert join_single_syllables("1. 나 를 따 르 리 니") == "1. 나를따르리니"
    # 두 글자 이상끼리는 그대로 (단어 사이 띄어쓰기)
    assert join_single_syllables("거룩하신 주님께") == "거룩하신 주님께"
    # 영어는 건드리지 않는다.
    assert join_single_syllables("I am a boy") == "I am a boy"
    assert join_single_syllables("주 의 love") == "주의 love"


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
    # 띄어쓰기를 잃고 마디 번호·위첨자가 섞인 OCR 결과도 코드 줄이다.
    assert is_chord_line("9.CG’DmCFCG’C")
    assert is_chord_line("u.4DmMCFCG’C")
    assert not is_chord_line("God Bless America")
    assert not is_chord_line("Every morning I will sing")


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


def test_order_lyric_lines():
    # 한 단 아래 1·2절이 겹쳐 있으면 1절을 끝까지, 빈 줄, 2절을 끝까지 편다.
    systems = [
        [("주님의 사랑", False), ("거룩한 이름", False)],
        [("나를 감싸네", False), ("높이 부르며", False)],
    ]
    assert order_lyric_lines(systems) == [
        "주님의 사랑", "나를 감싸네", "", "거룩한 이름", "높이 부르며",
    ]
    # 한 줄짜리 단만 있으면 그대로, 빈 단은 건너뛴다.
    assert order_lyric_lines([[("가", False)], [], [("나", False)]]) == ["가", "나"]
    # 단 끝에서 하이픈으로 끊긴 영어 낱말은 앞 줄에 붙인다.
    broken = [[("for me Lift", True)], [("ing up my hands", False)]]
    assert order_lyric_lines(broken) == ["for me Lifting", "up my hands"]


def test_ends_with_word_break():
    assert ends_with_word_break("for me Lift -")
    assert ends_with_word_break("Lift-")
    # 한글 줄 끝 하이픈은 '음을 끌라'는 표시라 이어 붙이지 않는다.
    assert not ends_with_word_break("주 님 의 사 랑 -")
    assert not ends_with_word_break("for me")


def test_prepare_sheet_image():
    """그림자 진 회색 바탕 + 기울어진 작은 캡처도 오선을 반듯하게, 표준 크기로 편다."""
    from PIL import Image, ImageDraw

    image = Image.new("L", (600, 300), 255)
    draw = ImageDraw.Draw(image)
    for line in range(5):
        y = 100 + line * 8
        draw.line((30, y, 570, y), fill=0, width=1)
    # 왼쪽이 어두운 그림자 + 회색 종이
    from PIL import ImageChops

    shade = Image.linear_gradient("L").rotate(90).resize(image.size)
    shaded = ImageChops.multiply(image, shade.point(lambda value: 140 + value * 115 // 255))
    tilted = shaded.rotate(2.0, resample=Image.BICUBIC, expand=True, fillcolor=150)

    gray, staff_threshold, text_threshold = prepare_sheet_image(tilted)
    assert text_threshold <= 160 and text_threshold <= staff_threshold
    systems = find_staff_systems(ppt_tool.row_dark_ratios(gray, staff_threshold))
    assert len(systems) == 1, systems
    # 줄 간격 8px → 표준(22px) 쯤으로 커진다.
    assert abs(systems[0][2] - ppt_tool._TARGET_STAFF_SPACING) < 3, systems
    assert abs(find_skew_angle(gray, staff_threshold)) < 0.5


def test_erase_staff_symbols_keeps_lyrics_under_low_notes():
    """오선 아래로 길게 내려온 음표가 가사 첫 줄에 붙어도 가사 줄을 잃지 않는다.

    예전엔 음표+가사 첫 줄이 한 덩어리로 잡혀 '덧줄 음표'로 통째로 버려졌다."""
    from PIL import Image, ImageDraw, ImageFont

    spacing = 22
    image = Image.new("L", (900, 420), 255)
    draw = ImageDraw.Draw(image)
    font = ImageFont.truetype(str(FONT_PATH), 50)
    for line in range(5):
        y = 60 + line * spacing
        draw.line((40, y, 860, y), fill=0, width=2)
    staff_bottom = 60 + 4 * spacing
    # 기둥이 오선에서 내려와 가사 바로 위까지 닿은 음표들 (덧줄 음표 자리)
    for x in range(120, 800, 90):
        draw.line((x, staff_bottom - spacing, x, staff_bottom + 60), fill=0, width=3)
        draw.ellipse((x - 14, staff_bottom + 50, x + 2, staff_bottom + 64), fill=0)
    draw.text((80, staff_bottom + 56), "주 님 의 사 랑", font=font, fill=0)
    draw.text((80, staff_bottom + 120), "거 룩 한 이 름", font=font, fill=0)

    systems = find_staff_systems(ppt_tool.row_dark_ratios(image, 160))
    assert len(systems) == 1, systems
    cleaned, mask = erase_staff_symbols(image, 160, systems)
    boxes = lyric_line_boxes_by_system(systems, ppt_tool.row_dark_ratios(cleaned, 160))[0]
    assert len(boxes) == 2, boxes
    # 가사 높이 안의 글자는 되살리고, 줄을 꿰뚫는 기둥은 지운 채로 둔다.
    restored = restore_lyric_band(image, cleaned, mask, *boxes[0], 4)
    assert restored.crop((0, boxes[0][0], 900, boxes[0][1])).getextrema()[0] < 100


def test_otsu_threshold():
    from PIL import Image

    image = Image.new("L", (100, 100), 240)
    image.paste(30, (0, 0, 100, 20))
    assert 30 < otsu_threshold(image) <= 240


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


def _draw_pdf_sheet(path):
    """같은 악보를 글자가 박힌 PDF로. 좌표 단위는 72dpi 포인트."""
    import pymupdf

    document = pymupdf.open()
    page = document.new_page(width=600, height=740)
    font = str(FONT_PATH)
    page.insert_text((240, 60), "믿음의 노래", fontfile=font, fontname="NG", fontsize=18)
    for index, top in enumerate(PDF_STAFF_TOPS):
        for line in range(5):
            y = top + line * PDF_STAFF_SPACING
            page.draw_line((40, y), (560, y), width=0.8)
        page.insert_text(
            (45, top - 10), "G   D   Em   C", fontfile=font, fontname="NG", fontsize=9
        )
        for verse, text in enumerate(SHEET_LYRICS[index]):
            y = top + 4 * PDF_STAFF_SPACING + 18 + verse * 22
            page.insert_text((45, y), text, fontfile=font, fontname="NG", fontsize=11)
    document.save(path)
    document.close()


def test_lyric_line_boxes_skips_notes_and_chords():
    # 오선 바로 아래 덧줄 음표 / 가사 / 다음 단 코드 / 다음 단 위로 삐진 음표
    ratios = [0.0] * 400
    for row in (100, 110, 120, 130, 140, 300, 310, 320, 330, 340):
        ratios[row] = 1.0
    for start, end in ((142, 150), (165, 180), (260, 275), (285, 295)):
        for row in range(start, end):
            ratios[row] = 0.02
    boxes = lyric_line_boxes(find_staff_systems(ratios), ratios)
    assert boxes == [(165, 179)], boxes


def test_extract_pdf_with_text_layer():
    """글자가 박힌 PDF는 Tesseract 없이, 오인식 없이 읽는다."""
    original = ppt_tool.get_tesseract_executable
    ppt_tool.get_tesseract_executable = lambda: None
    try:
        with tempfile.TemporaryDirectory() as temp_dir:
            pdf_path = Path(temp_dir) / "sheet.pdf"
            _draw_pdf_sheet(pdf_path)
            result = ppt_tool.extract_sheet_music_lyrics(str(pdf_path))
    finally:
        ppt_tool.get_tesseract_executable = original

    assert result.get("error") is None, result
    assert result["text_layer"] is True, result
    assert result["staff_count"] == 3, result
    lines = result["lines"]
    # 하이픈도 한 글자 토막도 붙는다. 2절도 같이 나온다.
    assert lines[0] == "1. 예수사랑하심은", lines
    assert lines[1] == "2. 거룩하신 주님께", lines
    assert lines[2] == "주님의사랑", lines
    assert lines[3] == "할렐루야 아멘", lines
    # 오선 위(제목·코드)는 들어오면 안 된다.
    assert not any("믿음" in line or "Em" in line for line in lines), lines


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
    test_join_single_syllables()
    test_is_lyric_line()
    test_is_chord_line()
    test_find_staff_systems()
    test_lyric_line_boxes_skips_notes_and_chords()
    test_order_lyric_lines()
    test_ends_with_word_break()
    test_otsu_threshold()
    test_prepare_sheet_image()
    test_erase_staff_symbols_keeps_lyrics_under_low_notes()
    test_extract_pdf_with_text_layer()
    test_extract_sheet_music_lyrics()
    print("OK")
