"""악보 가사 추출 self-check.

줄 찾기·하이픈 정리와 글자가 박힌 PDF 는 Tesseract 없이도 돌고,
그림 악보 OCR 검증만 Tesseract가 있을 때 돈다."""
import json
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


def test_finish_line_keeps_unread_slot():
    # 코드 하나짜리 줄도 코드 줄이다 (빈 자리로 남기면 단 줄 수가 하나 는다).
    assert ppt_tool._finish_line("G") == ppt_tool._CHORD_LINE
    assert ppt_tool._finish_line("G D Em C") == ppt_tool._CHORD_LINE
    # 글자가 두 자도 안 되는 잡음은 못 읽은 줄(자리 지킴)이다.
    assert ppt_tool._finish_line("~ 1") is None
    assert ppt_tool._finish_line("주님의 사랑") == ("주님의 사랑", False)


def test_kept_words():
    def words(items, confidences=None):
        return [word for _, word in ppt_tool._kept_words(items, confidences)]

    # 영어 줄의 외따로 선 | 는 대명사 I. l 은 확신도 80 이상일 때만 I, 아니면 기둥이라 버린다.
    assert words(["|", "love", "You"]) == ["I", "love", "You"]
    assert words(["l", "love", "You"], [95, 96, 97]) == ["I", "love", "You"]
    assert words(["Your", "love", "l", "is"]) == ["Your", "love", "is"]
    # 한글 줄의 l 은 기둥이다. 기둥이 여럿이어도 영어 줄로 치지 않는다.
    assert words(["주님", "l", "사랑"]) == ["주님", "사랑"]
    assert words(["l", "l", "l", "주님"]) == ["주님"]
    # 절 번호는 앞의 잡음이 빠진 뒤 맨 앞이면 남는다.
    assert words(["i", "1.", "주님"]) == ["1.", "주님"]


def test_lyric_line_boxes_keeps_tight_last_verse():
    """다음 오선에 한 줄 간격 안으로 붙은 마지막 줄: 촘촘하면 가사(빽빽한 찬송가), 성기면 코드 줄."""

    def boxes_with(last_ratio):
        ratios = [0.0] * 400
        for row in (100, 110, 120, 130, 140, 300, 310, 320, 330, 340):
            ratios[row] = 1.0
        # 1절·2절 가사, 마지막 줄은 앞 줄과 6px, 다음 오선과 10px(= 줄 간격) 떨어져 있다.
        for start, end, value in ((210, 232, 0.12), (240, 262, 0.12), (268, 290, last_ratio)):
            for row in range(start, end + 1):
                ratios[row] = value
        return lyric_line_boxes(find_staff_systems(ratios), ratios)

    assert boxes_with(0.12)[:3] == [(210, 232), (240, 262), (268, 290)]
    assert boxes_with(0.04)[:3] == [(210, 232), (240, 262)]


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
    # 구조 표시가 앞에 붙은 코드 줄, ♭·/ 를 뭉갠 코드 (콘티 PDF 에서 실제로 나온 것).
    assert is_chord_line("Inter Bb F Eb Gm F Eb")
    assert is_chord_line("Bo F Eo Bo FED")
    assert is_chord_line("C DIC Bm7 B/DA Em7 Am7 D7sus4 GsusA G GlB")
    assert not is_chord_line("Go and tell it")


def test_sheet_without_staff_sections():
    """오선 없는 가사·코드 악보: 제목·구조 표시·코드·연주 메모를 걷어 내고 구조 표시에서 절을 나눈다."""
    finish = ppt_tool._finish_line
    assert finish("<verse1>") == ppt_tool._SECTION_LINE
    assert finish("cbridge>") == ppt_tool._SECTION_LINE
    assert finish("A/C# D E F#m E A (verse로 갈땐 D/A)") == ppt_tool._CHORD_LINE
    assert finish("다시오실 그이름 (F# if keyup)") == ("다시오실 그이름", False)
    assert finish("주님 찬양해 (x2)") == ("주님 찬양해 (x2)", False)

    def row(text, y, h=0.02):
        return {"text": text, "confidence": 1.0, "x": 0.1, "y": y, "w": 0.5, "h": h}

    page = [row("기묘자", 0.02, 0.05), row("<verse1>", 0.1), row("한 아기가 났고", 0.15),
            row("A D E", 0.2), row("<verse2>", 0.3), row("알파와 오메가", 0.35)]
    lines = [ppt_tool._finish_line(line) for line in ppt_tool._native_page_lines(page)]
    job = {"systems": [[{"page_image": "p"}]]}
    systems = ppt_tool.resolve_sheet_lines(job, None, lambda _path: lines)
    assert order_lyric_lines(systems) == ["한아기가 났고", "", "알파와 오메가"], systems


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
    # 첫 음절이 흔한 낱말이어도 잇는다 (for-ever, to-gether).
    assert order_lyric_lines([[("sing for", True)], [("ever and ever", False)]]) == [
        "sing forever", "and ever",
    ]
    assert order_lyric_lines([[("all to", True)], [("gether now", False)]]) == [
        "all together", "now",
    ]
    # 흐려서 하이픈만 남고 뒷줄이 흔한 낱말로 시작하면 잇지 않는다.
    assert order_lyric_lines([[("and a gain", True)], [("for ever", False)]]) == [
        "and a gain", "for ever",
    ]
    # 못 읽은 줄(None)은 자리만 지킨다 — 2절 줄이 1절로 밀리지 않는다.
    v = lambda text: (text, False)  # noqa: E731
    assert order_lyric_lines([
        [v("1a"), v("2a")], [None, v("2b")], [v("1c"), v("2c")],
    ]) == ["1a", "1c", "", "2a", "2b", "2c"]
    # 이웃 단보다 줄이 하나 많은 단의 맨 끝 못 읽은 자리(뭉개진 코드 줄)는 덜어 낸다.
    assert order_lyric_lines([
        [v("1a"), v("2a"), None], [v("1b"), v("2b")],
    ]) == ["1a", "1b", "", "2a", "2b"]
    # 마지막 단만 빼고 모든 단 끝에 코드 줄 빈 자리가 있어도 덜어 낸다.
    assert order_lyric_lines([
        [v("1a"), v("2a"), None], [v("1b"), v("2b"), None], [v("1c"), v("2c")],
    ]) == ["1a", "1b", "1c", "", "2a", "2b", "2c"]
    # 한 줄짜리 후렴 단이 더 많아도 1·2절 단의 빈 자리는 지킨다.
    assert order_lyric_lines([
        [v("1a"), v("2a")], [None, v("2b")], [v("C1")], [v("C2")], [v("C3")],
    ]) == ["1a", "", "2a", "2b", "", "C1", "C2", "C3"]
    # 한 절을 통째로 못 읽어도 빈 줄이 겹치지 않는다.
    assert order_lyric_lines([[v("1a"), None], [v("1b"), None]]) == ["1a", "1b"]


def test_ends_with_word_break():
    assert ends_with_word_break("for me Lift -")
    assert ends_with_word_break("Lift-")
    # 한글 줄 끝 하이픈은 '음을 끌라'는 표시라 이어 붙이지 않는다.
    assert not ends_with_word_break("주 님 의 사 랑 -")
    assert not ends_with_word_break("for me")
    # 하이픈 문자 목록은 clean_lyric_line 과 같다 (긴 대시 포함).
    assert ends_with_word_break("Lift \u2014")
    assert clean_lyric_line("a\u00a0\u00a0b") == "a b"


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


def test_prepare_sheet_image_finds_faint_staff():
    """흐린 JPEG 처럼 옅게 번진 오선 단도 진한 단과 같이 찾는다 (실제 악보: 4단 중 2단을 놓쳤다)."""
    from PIL import Image, ImageDraw, ImageFilter

    image = Image.new("L", (600, 400), 255)
    draw = ImageDraw.Draw(image)
    for line in range(5):
        draw.line((30, 60 + line * 22, 570, 60 + line * 22), fill=0, width=2)
        draw.line((30, 260 + line * 22, 570, 260 + line * 22), fill=170, width=3)
    # 진한 글자 덩어리 — Otsu 값을 진한 쪽으로 끌어내린다.
    draw.rectangle((100, 180, 250, 200), fill=0)
    image = image.filter(ImageFilter.GaussianBlur(1))

    gray, staff_threshold, _ = prepare_sheet_image(image)
    systems = find_staff_systems(ppt_tool.row_dark_ratios(gray, staff_threshold))
    assert len(systems) == 2, systems


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


def test_native_ocr_two_stage():
    """앱의 OS 내장 OCR 경로: 줄 이미지 내보내기(1단계) → 읽은 결과로 마무리(2단계)."""
    import json

    with tempfile.TemporaryDirectory() as temp_dir:
        sheet_path = Path(temp_dir) / "sheet.png"
        _draw_sheet(sheet_path)
        out_dir = Path(temp_dir) / "lines"
        stage1 = ppt_tool.export_sheet_lines(str(sheet_path), str(out_dir))
        assert stage1["needs_ocr"] is True, stage1
        images = stage1["images"]
        # 첫 단 2줄(1·2절) + 나머지 단 1줄씩
        assert len(images) == 4, images
        assert all(Path(path).exists() for path in images)

        # OS OCR 흉내: 한 줄이 여러 덩어리로, 순서도 뒤섞여 온다.
        fake = {
            images[0]: [
                {"text": "사 랑 하 심 은", "confidence": 0.9, "x": 0.5, "y": 0.1, "w": 0.4, "h": 0.8},
                {"text": "1. 예 - 수", "confidence": 0.9, "x": 0.05, "y": 0.1, "w": 0.3, "h": 0.8},
                {"text": "♩♪", "confidence": 0.2, "x": 0.95, "y": 0.1, "w": 0.05, "h": 0.8},
            ],
            images[1]: [{"text": "2. 거룩하신 주님께", "confidence": 0.8, "x": 0.1}],
            images[2]: [{"text": "주 - 님 의 사 랑", "confidence": 1.0, "x": 0.1}],
            images[3]: [{"text": "G D Em C", "confidence": 0.9, "x": 0.1}],
        }
        ocr_path = Path(temp_dir) / "ocr.json"
        ocr_path.write_text(json.dumps(fake, ensure_ascii=False), encoding="utf-8")
        result = ppt_tool.finish_sheet_lines(stage1["job"], str(ocr_path))

    assert result["language"] == "native", result
    assert result["staff_count"] == 3, result
    # 1절 → 빈 줄 → 2절 → 빈 줄 → 한 줄짜리 단들. 코드 줄은 빠진다.
    assert result["lines"] == ["1. 예수사랑하심은", "2. 거룩하신 주님께", "주님의사랑"], result
    assert result["lyrics"] == "1. 예수사랑하심은\n\n2. 거룩하신 주님께\n\n주님의사랑", result


def test_native_page_without_staff():
    """오선이 없는 쪽(가사만 있는 그림)은 쪽 전체를 넘기고, 받은 줄을 위에서부터 한 줄씩 쓴다."""
    from PIL import Image, ImageDraw, ImageFont

    with tempfile.TemporaryDirectory() as temp_dir:
        path = Path(temp_dir) / "lyrics.png"
        image = Image.new("L", (600, 300), 255)
        ImageDraw.Draw(image).text(
            (40, 40), "주님의 사랑", font=ImageFont.truetype(str(FONT_PATH), 40), fill=0
        )
        image.save(path)
        stage1 = ppt_tool.export_sheet_lines(str(path), str(Path(temp_dir) / "out"))
        assert len(stage1["images"]) == 1, stage1
        job = json.loads(Path(stage1["job"]).read_text(encoding="utf-8"))
        assert "page_image" in job["systems"][0][0], job

        page = stage1["images"][0]
        fake = {page: [
            {"text": "나를 감싸네", "confidence": 0.9, "x": 0.1, "y": 0.5, "w": 0.5, "h": 0.1},
            {"text": "주님의", "confidence": 0.9, "x": 0.1, "y": 0.1, "w": 0.3, "h": 0.1},
            {"text": "사랑", "confidence": 0.9, "x": 0.5, "y": 0.11, "w": 0.2, "h": 0.1},
        ]}
        ocr_path = Path(temp_dir) / "ocr.json"
        ocr_path.write_text(json.dumps(fake, ensure_ascii=False), encoding="utf-8")
        result = ppt_tool.finish_sheet_lines(stage1["job"], str(ocr_path))

    # 같은 높이의 두 덩어리는 한 줄, 줄 사이에 빈 줄(절 나눔)이 끼지 않는다.
    assert result["lyrics"] == "주님의 사랑\n나를 감싸네", result


def test_erase_staff_symbols_with_four_detected_lines():
    """윗선이 흐려 4줄만 찾은 단에서도 오선 밑 가사를 지우지 않는다."""
    from PIL import Image, ImageDraw

    image = Image.new("L", (400, 200), 255)
    draw = ImageDraw.Draw(image)
    for line in range(1, 5):  # 윗선(0번)은 안 그린다
        draw.line((20, 20 + line * 10, 380, 20 + line * 10), fill=0, width=1)
    # 오선 한 칸 아래(옛 코드가 5번째 줄로 치던 자리)에 걸친 가사 획
    draw.rectangle((100, 66, 140, 80), fill=0)
    systems = find_staff_systems(ppt_tool.row_dark_ratios(image, 160))
    assert len(systems) == 1 and round(systems[0][2]) == 10, systems
    cleaned, _mask = erase_staff_symbols(image, 160, systems)
    assert cleaned.getpixel((120, 72)) == 0


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
    test_sheet_without_staff_sections()
    test_finish_line_keeps_unread_slot()
    test_kept_words()
    test_lyric_line_boxes_keeps_tight_last_verse()
    test_find_staff_systems()
    test_lyric_line_boxes_skips_notes_and_chords()
    test_order_lyric_lines()
    test_ends_with_word_break()
    test_otsu_threshold()
    test_prepare_sheet_image()
    test_prepare_sheet_image_finds_faint_staff()
    test_erase_staff_symbols_keeps_lyrics_under_low_notes()
    test_erase_staff_symbols_with_four_detected_lines()
    test_native_ocr_two_stage()
    test_native_page_without_staff()
    test_extract_pdf_with_text_layer()
    test_extract_sheet_music_lyrics()
    print("OK")
