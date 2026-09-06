"""세로 미세 조정 self-check: python3 python/test_export_position.py

LibreOffice 없이 도는 단위 테스트. 상단/중단/하단 세 고정값만으로는 못 맞추는
높이를 미세 조정(인치, + = 아래로)으로 밀 수 있는지 본다.
본문은 `text_offset_y`/`bible_text_offset_y`, 제목은 `title_offset_y`/
`bible_title_offset_y` 를 쓴다.

규칙: 본문 상자는 크기가 고정이고 미세 조정이 그 상자를 통째로 위아래로 민다.
그래야 상단/중단/하단 어느 기준을 골라도 밀어 준 만큼 똑같이 움직인다.
제목도 같은 규칙이다.

예전에는 "본문 상단 여백"(text_box_top)이 상자의 위쪽만 끌어내려 높이까지 같이
줄였다. 상자 아래쪽이 항상 6.0인치에 붙어 있어서 하단 기준에서는 아무 효과가
없었고 중단 기준에서는 절반만 움직였다. 미세 조정이 그 범위를 모두 덮으므로
제거했고, 예전 키가 남아 있어도 무시한다(설정 파일은 ExportStyleStore 가 옮긴다).
"""
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pptx import Presentation
from pptx.util import Inches

from ppt_tool import (
    _TEXT_OFFSET_Y_MAX,
    _TEXT_OFFSET_Y_MIN,
    _lyrics_box_vertical_layout,
    export_presentation,
)

_STYLE = {
    "font_size": 40,
    "bible_font_size": 30,
    "background_color": "#1B1B1B",
    "text_color": "#FFFFFF",
    "bible_text_color": "#FFF8E1",
    "text_position": "middle",
    "bible_text_position": "middle",
    "lyrics_text_align": "center",
    "bible_text_align": "center",
    "include_english_lyrics": False,
    "english_text_color": "#FFF176",
    "show_song_title": False,
    "show_bible_title": False,
    "title_font_size": 14,
    "bible_title_font_size": 14,
    "title_text_color": "#FFFFFF",
    "bible_title_text_color": "#FFFFFF",
    "title_horizontal_position": "right",
    "title_vertical_position": "bottom",
    "bible_title_horizontal_position": "right",
    "bible_title_vertical_position": "bottom",
    "font_family": "Pretendard",
    "background_image_path": None,
}

_failures = []


def check(label, actual, expected):
    if actual == expected:
        print(f"  OK   {label}")
    else:
        print(f"  FAIL {label}: {actual!r} != {expected!r}")
        _failures.append(label)


def close(label, actual, expected, tol=1e-6):
    if abs(actual - expected) <= tol:
        print(f"  OK   {label}")
    else:
        print(f"  FAIL {label}: {actual!r} != {expected!r}")
        _failures.append(label)


def body_box(slide):
    """가사 텍스트 상자. 본문 상자를 먼저 만들므로 첫 도형이 본문이다."""
    for shape in slide.shapes:
        if shape.has_text_frame:
            return shape
    raise AssertionError("본문 상자가 없다")


def title_box(slide):
    """제목 텍스트 상자. 본문 다음에 붙으므로 두 번째 도형이다."""
    boxes = [s for s in slide.shapes if s.has_text_frame]
    if len(boxes) < 2:
        raise AssertionError("제목 상자가 없다")
    return boxes[1]


def export(songs, style=None):
    tmp = tempfile.mkdtemp()
    out = Path(tmp) / "out.pptx"
    export_presentation(json.dumps({
        "output_path": str(out),
        "style": style or _STYLE,
        "songs": songs,
    }))
    return Presentation(str(out))


def test_layout_shifts_box_only():
    print("_lyrics_box_vertical_layout")
    base_top, base_height = _lyrics_box_vertical_layout(_STYLE, False)
    close("기본 위치", base_top, 0.6)
    close("기본 높이", base_height, 5.4)

    down_top, down_height = _lyrics_box_vertical_layout(
        dict(_STYLE, text_offset_y=0.75), False
    )
    close("아래로 0.75", down_top, base_top + 0.75)
    close("높이는 그대로", down_height, base_height)

    up_top, up_height = _lyrics_box_vertical_layout(
        dict(_STYLE, text_offset_y=-0.4), False
    )
    close("위로 0.4", up_top, base_top - 0.4)
    close("높이는 그대로 (위)", up_height, base_height)


def test_legacy_top_margin_ignored():
    print("없어진 상단 여백")
    # 예전 payload 가 그대로 와도 위치가 흔들리면 안 된다.
    top, height = _lyrics_box_vertical_layout(
        dict(_STYLE, text_box_top=2.2, bible_text_box_top=2.2), False
    )
    close("text_box_top 은 무시", top, 0.6)
    close("높이도 고정", height, 5.4)

    # 미세 조정만 듣는다.
    moved, _ = _lyrics_box_vertical_layout(
        dict(_STYLE, text_box_top=2.2, text_offset_y=0.5), False
    )
    close("미세 조정만 적용", moved, 1.1)


def test_bible_uses_own_offset():
    print("찬양/성경 각각")
    style = dict(_STYLE, text_offset_y=0.5, bible_text_offset_y=-0.5)
    song_top, _ = _lyrics_box_vertical_layout(style, False)
    bible_top, _ = _lyrics_box_vertical_layout(style, True)
    close("가사는 아래로", song_top, 1.1)
    close("성경은 위로", bible_top, 0.1)


def test_offset_is_clamped():
    print("범위 밖 값")
    too_low, _ = _lyrics_box_vertical_layout(
        dict(_STYLE, text_offset_y=-99), False
    )
    too_high, _ = _lyrics_box_vertical_layout(
        dict(_STYLE, text_offset_y=99), False
    )
    close("최소로 잘림", too_low, 0.6 + _TEXT_OFFSET_Y_MIN)
    close("최대로 잘림", too_high, 0.6 + _TEXT_OFFSET_Y_MAX)

    junk, _ = _lyrics_box_vertical_layout(
        dict(_STYLE, text_offset_y="위로"), False
    )
    close("숫자가 아니면 0", junk, 0.6)

    nan, _ = _lyrics_box_vertical_layout(
        dict(_STYLE, text_offset_y=float("nan")), False
    )
    close("NaN 이면 0", nan, 0.6)


def test_export_moves_textbox():
    print("export (실제 상자 위치)")
    song = {
        "type": "song", "title": "찬양",
        "lyrics": "첫째 줄\n둘째 줄",
        "english_lyrics": "",
        "background": None,
    }
    base = body_box(export([song]).slides[0])
    moved = body_box(
        export([song], style=dict(_STYLE, text_offset_y=0.3)).slides[0]
    )
    # Inches() 변환에서 EMU 1 정도는 어긋난다 (0.3in = 274320 EMU)
    close("상자가 0.3인치 내려간다", moved.top - base.top, Inches(0.3), tol=2)
    check("상자 높이는 그대로", moved.height, base.height)
    check("가로는 그대로", (moved.left, moved.width), (base.left, base.width))


def test_title_offset():
    print("제목 미세 조정")
    song = {
        "type": "song", "title": "찬양",
        "lyrics": "한 줄",
        "english_lyrics": "",
        "background": None,
    }
    # 하단(기본) 기준: 7.5 - 0.2 - 0.55 = 6.75인치
    titled = dict(_STYLE, show_song_title=True)
    base = title_box(export([song], style=titled).slides[0])
    check("기준 위치", base.top, Inches(6.75))

    up = title_box(
        export([song], style=dict(titled, title_offset_y=-0.4)).slides[0]
    )
    close("제목이 0.4인치 올라간다", up.top - base.top, -Inches(0.4), tol=2)
    check("제목 높이는 그대로", up.height, base.height)

    # 상단 기준에서도 같은 만큼 움직인다 (0.2 + 0.4 = 0.6인치)
    top_anchor = title_box(export([song], style=dict(
        titled, title_vertical_position="top", title_offset_y=0.4
    )).slides[0])
    close("상단 기준도 같은 만큼", top_anchor.top, Inches(0.6), tol=2)

    # 본문 미세 조정과 서로 간섭하지 않는다
    both = export([song], style=dict(
        titled, text_offset_y=0.5, title_offset_y=-0.5
    )).slides[0]
    close("본문은 아래로", body_box(both).top, Inches(1.1), tol=2)
    close("제목은 위로", title_box(both).top, Inches(6.25), tol=2)


def test_bible_title_offset():
    print("성경 제목은 자기 값을 쓴다")
    verse = {
        "type": "bible", "title": "롬 8:28",
        "lyrics": "우리가 알거니와",
        "english_lyrics": "",
        "background": None,
    }
    style = dict(
        _STYLE,
        show_bible_title=True,
        title_offset_y=0.9,       # 찬양 제목 값 — 성경은 따라가면 안 된다
        bible_title_offset_y=-0.3,
    )
    box = title_box(export([verse], style=style).slides[0])
    close("성경 제목 값만 적용", box.top, Inches(6.75 - 0.3), tol=2)


def test_export_without_key():
    print("export (하위 호환)")
    legacy = dict(_STYLE)
    legacy.pop("text_offset_y", None)
    prs = export([{
        "type": "song", "title": "찬양",
        "lyrics": "한 줄",
        "english_lyrics": "",
        "background": None,
    }], style=legacy)
    check("키가 없으면 기본 위치", body_box(prs.slides[0]).top, Inches(0.6))

    legacy_titled = dict(legacy, show_song_title=True)
    legacy_titled.pop("title_offset_y", None)
    titled = export([{
        "type": "song", "title": "찬양",
        "lyrics": "한 줄",
        "english_lyrics": "",
        "background": None,
    }], style=legacy_titled)
    check("제목도 마찬가지", title_box(titled.slides[0]).top, Inches(6.75))


if __name__ == "__main__":
    test_layout_shifts_box_only()
    test_legacy_top_margin_ignored()
    test_bible_uses_own_offset()
    test_offset_is_clamped()
    test_export_moves_textbox()
    test_title_offset()
    test_bible_title_offset()
    test_export_without_key()
    if _failures:
        print(f"\n{len(_failures)}개 실패: {_failures}")
        raise SystemExit(1)
    print("\n모두 통과")
