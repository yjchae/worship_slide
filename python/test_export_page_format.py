"""페이지별 서식(page_styles) self-check: python3 python/test_export_page_format.py

LibreOffice 없이 도는 XML 단위 테스트. 페이지마다 다른 색·크기가 PPTX 에 반영되고
page_styles 가 없는 항목·null 페이지는 예전과 똑같은지 본다.
"""
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pptx import Presentation

from ppt_tool import export_presentation
from test_export_extra import _STYLE, body_paragraphs, run_info

_failures = []


def check(label, actual, expected):
    if actual == expected:
        print(f"  OK   {label}")
    else:
        print(f"  FAIL {label}: {actual!r} != {expected!r}")
        _failures.append(label)


def export(songs):
    out = Path(tempfile.mkdtemp()) / "out.pptx"
    export_presentation(json.dumps({
        "output_path": str(out), "style": _STYLE, "songs": songs,
    }))
    return Presentation(str(out))


def item(kind, lyrics, english="", extra="", **keys):
    return {"type": kind, "title": "t", "lyrics": lyrics, "english_lyrics": english,
            "extra_lyrics": extra, "background": None, **keys}


def test_song_pages():
    print("찬양 페이지별 서식")
    styles = [None, {"text_color": "#FF0000", "font_size": 60,
                     "english_text_color": "#00FF00", "english_font_size": 20}]
    prs = export([item("song", "1절\n\n후렴", "e1\n\ne2", page_styles=styles)])
    check("서식 없는 페이지 본문", run_info(body_paragraphs(prs.slides[0])[0]), ("1절", 40, "FFFFFF"))
    check("서식 없는 페이지 보조", run_info(body_paragraphs(prs.slides[0])[1]), ("e1", 32, "FFF176"))
    check("서식 있는 페이지 본문", run_info(body_paragraphs(prs.slides[1])[0]), ("후렴", 60, "FF0000"))
    check("서식 있는 페이지 보조", run_info(body_paragraphs(prs.slides[1])[1]), ("e2", 20, "00FF00"))


def test_bible_pages():
    print("성경 페이지별 서식(bible_* 키)")
    styles = [{"bible_text_color": "#0000FF", "bible_font_size": 50}, None]
    prs = export([item("bible", "a\n\nb", page_styles=styles)])
    first = body_paragraphs(prs.slides[0])[0]
    check("성경 첫 페이지", run_info(first)[1:], (50, "0000FF"))
    check("성경 둘째 페이지는 전역", run_info(body_paragraphs(prs.slides[1])[0])[1:], (30, "FFFFFF"))


def test_unchanged_without_styles():
    print("서식 없는 항목은 불변")
    plain = export([item("song", "한\n\n두", "e\n\nf")])
    nulls = export([item("song", "한\n\n두", "e\n\nf", page_styles=[None, None])])
    for i in range(2):
        check(f"{i + 1}쪽 같다",
              [run_info(p) for p in body_paragraphs(nulls.slides[i])],
              [run_info(p) for p in body_paragraphs(plain.slides[i])])


if __name__ == "__main__":
    test_song_pages()
    test_bible_pages()
    test_unchanged_without_styles()
    if _failures:
        print(f"\n{len(_failures)}개 실패")
        sys.exit(1)
    print("\n모두 통과")
