"""layout 명령(PPTX → 편집 페이지 요소) self-check: python3 python/test_pptx_layout.py

python-pptx 로 견본을 만들어 받음·떨어뜨림 분류, 좌표·글자 크기 환산, 상속(마스터 제목 크기·테마 색),
Delta 서식, 그룹 풀기, 그림 자르기, 4:3 여백, 숨긴 슬라이드, 애니메이션 클릭 단계(appear·steps·anim_lost)를 확인한다.
두 번 굽기(배경 PNG, 애니메이션 배경 도형 잘라 내기)는 LibreOffice·PowerPoint 가 없으면 skip.
"""
import io
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lxml import etree
from PIL import Image
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_CONNECTOR, MSO_SHAPE
from pptx.oxml.ns import qn
from pptx.util import Emu, Inches, Pt

import ppt_tool
import pptx_layout
from test_animation import _NS_DECL, _timing

A = "{http://schemas.openxmlformats.org/drawingml/2006/main}"
# Dart PageTextElement/PageShapeElement/PageImageElement.toJson 의 키
TEXT_KEYS = {"type", "id", "rect", "text", "font_size", "color", "bold", "align", "font_family"}
SHAPE_KEYS = TEXT_KEYS | {"shape", "fill", "fill_alpha", "stroke", "stroke_width", "radius", "flip_h", "flip_v", "valign"}
IMAGE_KEYS = {"type", "id", "rect", "path"}


def close(a, b, tol=0.002):
    return abs(a - b) <= tol


def solid_bg(slide, hex_):
    slide.background.fill.solid()
    slide.background.fill.fore_color.rgb = RGBColor.from_string(hex_)


def textbox(slide, x, y, w, h, text, size=None):
    box = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    box.text_frame.text = text
    if size:
        box.text_frame.paragraphs[0].runs[0].font.size = Pt(size)
    return box


def solid_shape(slide, kind, x, y, w, h, hex_):
    shape = getattr(slide, "shapes", slide).add_shape(kind, Inches(x), Inches(y), Inches(w), Inches(h))
    shape.fill.solid()
    shape.fill.fore_color.rgb = RGBColor.from_string(hex_)
    shape.line.fill.background()
    return shape


def make_main(path, picture):
    """13.333x7.5in 16:9 견본."""
    prs = Presentation()
    prs.slide_width, prs.slide_height = Inches(13.333), Inches(7.5)
    blank = prs.slide_layouts[6]

    # 1: 제목 자리표시자(크기는 마스터 titleStyle 44pt 를 물려받음) + 서식 글 상자 + normAutofit
    s1 = prs.slides.add_slide(prs.slide_layouts[5])
    solid_bg(s1, "102030")
    s1.shapes.title.text = "제목"
    box = textbox(s1, 1, 2, 6, 2, "굵은")
    tf = box.text_frame
    tf.word_wrap = True
    run = tf.paragraphs[0].runs[0]
    run.font.size, run.font.bold, run.font.color.rgb = Pt(30), True, RGBColor(0xFF, 0x00, 0x00)
    r2 = tf.paragraphs[0].add_run()
    r2.text, r2.font.size, r2.font.italic = "기울임", Pt(20), True
    r2.font.color.rgb = RGBColor(0xFF, 0x00, 0x00)
    p2 = tf.add_paragraph()
    p2.text = "글머리"
    p2.runs[0].font.size, p2.runs[0].font.bold = Pt(30), True
    p2.runs[0].font.color.rgb = RGBColor(0xFF, 0x00, 0x00)
    etree.SubElement(p2._p.get_or_add_pPr(), qn("a:buChar"), char="•")
    fit = textbox(s1, 7, 2, 4, 2, "줄여 맞춤", size=40)
    body_pr = fit.text_frame._txBody.find(qn("a:bodyPr"))
    for child in list(body_pr):
        body_pr.remove(child)  # add_textbox 의 spAutoFit 대신
    etree.SubElement(body_pr, qn("a:normAutofit"), fontScale="62500")
    fit.text_frame.paragraphs[0].alignment = 2  # 가운데
    body_pr.set("anchor", "ctr")

    # 2: 도형 5종 + 테마 색(accent1 lumMod 75%) + 그라데이션(p:style fillRef 3) + 회전 + 표
    s2 = prs.slides.add_slide(blank)
    solid_bg(s2, "203040")
    rect = solid_shape(s2, MSO_SHAPE.RECTANGLE, 1, 1, 2, 1, "FF0000")
    rect.text_frame.text = "안"
    solid_shape(s2, MSO_SHAPE.ROUNDED_RECTANGLE, 4, 1, 2, 1, "00FF00")
    ellipse = s2.shapes.add_shape(MSO_SHAPE.OVAL, Inches(7), Inches(1), Inches(2), Inches(1))
    ellipse.fill.background()
    ellipse.line.color.rgb = RGBColor(0, 0, 255)
    ellipse.line.width = Pt(2)
    theme = solid_shape(s2, MSO_SHAPE.RECTANGLE, 10, 1, 2, 1, "000000")
    srgb = theme._element.spPr.find(qn("a:solidFill"))
    srgb.clear()
    scheme = etree.SubElement(srgb, qn("a:schemeClr"), val="accent1")
    etree.SubElement(scheme, qn("a:lumMod"), val="75000")
    line = s2.shapes.add_connector(MSO_CONNECTOR.STRAIGHT, Inches(1), Inches(4), Inches(5), Inches(4))
    line.line.color.rgb = RGBColor(0xFF, 0xFF, 0xFF)
    line.line.width = Pt(3)
    arrow = s2.shapes.add_connector(MSO_CONNECTOR.STRAIGHT, Inches(6), Inches(5), Inches(3), Inches(3))
    arrow.line.color.rgb = RGBColor(0xFF, 0xFF, 0xFF)
    etree.SubElement(arrow.line._get_or_add_ln(), qn("a:tailEnd"), type="triangle")
    s2.shapes.add_shape(MSO_SHAPE.RECTANGLE, Inches(1), Inches(6), Inches(1), Inches(1))  # 기본 style = 그라데이션
    rotated = solid_shape(s2, MSO_SHAPE.RECTANGLE, 8, 5, 2, 1, "FFFF00")
    rotated.rotation = 30
    s2.shapes.add_table(2, 2, Inches(10), Inches(5), Inches(2), Inches(1))

    # 3: 그룹 — 받을 수 있는 그룹(자식 좌표 2배)·회전 도형이 든 그룹, 잘라 낸 그림, 덮인 그림
    s3 = prs.slides.add_slide(blank)
    solid_bg(s3, "304050")
    group = s3.shapes.add_group_shape()
    solid_shape(group.shapes, MSO_SHAPE.RECTANGLE, 0, 0, 1, 1, "FF00FF")
    solid_shape(group.shapes, MSO_SHAPE.RECTANGLE, 1, 1, 1, 1, "00FFFF")
    xfrm = group._element.grpSpPr.find(qn("a:xfrm"))
    xfrm.find(qn("a:off")).set("x", str(Inches(2)))
    xfrm.find(qn("a:off")).set("y", str(Inches(2)))
    xfrm.find(qn("a:ext")).set("cx", str(Inches(4)))
    xfrm.find(qn("a:ext")).set("cy", str(Inches(4)))
    bad = s3.shapes.add_group_shape()
    solid_shape(bad.shapes, MSO_SHAPE.RECTANGLE, 8, 0.5, 1, 1, "FFFFFF")
    solid_shape(bad.shapes, MSO_SHAPE.RECTANGLE, 10, 0.5, 1, 1, "FFFFFF").rotation = 45
    pic = s3.shapes.add_picture(str(picture), Inches(8), Inches(3), Inches(2), Inches(2))
    pic.crop_left = 0.5
    s3.shapes.add_picture(str(picture), Inches(1), Inches(6), Inches(2), Inches(1))
    solid_shape(s3, MSO_SHAPE.RECTANGLE, 2, 6.2, 1, 0.5, "123456").rotation = 10  # 위 그림을 덮는다

    # 4: 숨긴 슬라이드, 5: 빈 제목 자리표시자뿐
    s4 = prs.slides.add_slide(blank)
    solid_bg(s4, "405060")
    textbox(s4, 1, 1, 3, 1, "숨김")
    s4._element.set("show", "0")
    s5 = prs.slides.add_slide(prs.slide_layouts[5])
    solid_bg(s5, "506070")
    prs.save(str(path))


def make_sized(path, width, height, size):
    prs = Presentation()
    prs.slide_width, prs.slide_height = width, height
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    solid_bg(slide, "336699")
    box = slide.shapes.add_textbox(0, 0, width, Inches(1))
    box.text_frame.text = "가"
    box.text_frame.word_wrap = True
    box.text_frame.paragraphs[0].runs[0].font.size = Pt(size)
    body_pr = box.text_frame._txBody.find(qn("a:bodyPr"))
    for key in ("lIns", "tIns", "rIns", "bIns"):
        body_pr.set(key, "0")
    solid_shape(slide, MSO_SHAPE.RECTANGLE, 0, 2, 1, 1, "FF0000")
    prs.save(str(path))


def effect(spid, node_type="clickEffect", preset="entr", paragraph=None):
    """메인 시퀀스 효과 하나. 클릭 묶음 = effect 들을 이은 글."""
    target = f'<p:txEl><p:pRg st="{paragraph}" end="{paragraph}"/></p:txEl>' if paragraph is not None else ""
    return (
        f'<p:par><p:cTn id="{900 + int(spid)}" presetID="1" presetClass="{preset}" fill="hold" nodeType="{node_type}">'
        f'<p:childTnLst><p:set><p:cBhvr><p:cTn id="{950 + int(spid)}" dur="1" fill="hold"/>'
        f'<p:tgtEl><p:spTgt spid="{spid}">{target}</p:spTgt></p:tgtEl>'
        f'<p:attrNameLst><p:attrName>style.visibility</p:attrName></p:attrNameLst></p:cBhvr>'
        f'<p:to><p:strVal val="visible"/></p:to></p:set></p:childTnLst></p:cTn></p:par>'
    )


def animate(slide, clicks):
    slide._element.append(etree.fromstring(_timing(clicks)))


def make_anim(path):
    """애니메이션 견본. 1: 클릭·이전과 함께·클릭 2: 첫 묶음 이전과 함께 3: 첫 묶음 이전 다음 뿐
    4: 문단·사라짐·그룹 자식·그룹째 5: 31단계 6: 회전(배경) 도형 둘 — 하나 겹침 없음, 둘은 서로 겹치고 단계가 다름."""
    prs = Presentation()
    prs.slide_width, prs.slide_height = Inches(13.333), Inches(7.5)
    blank = prs.slide_layouts[6]
    def new(color):
        slide = prs.slides.add_slide(blank)
        solid_bg(slide, color)
        return slide

    s1 = new("101010")
    a, b, c = (textbox(s1, 1, y, 4, 1, t).shape_id for y, t in ((1, "가"), (2, "나"), (3, "다")))
    animate(s1, [effect(a) + effect(b, "withEffect"), effect(c)])

    s2 = new("101010")
    a, b = (textbox(s2, 1, y, 4, 1, t).shape_id for y, t in ((1, "가"), (2, "나")))
    animate(s2, [effect(a, "withEffect"), effect(b)])

    s3 = new("101010")
    a = textbox(s3, 1, 1, 4, 1, "가").shape_id
    animate(s3, [effect(a, "afterEffect")])

    s4 = new("101010")
    para = textbox(s4, 1, 1, 4, 2, "첫 줄")
    para.text_frame.add_paragraph().text = "둘째 줄"
    gone = textbox(s4, 6, 1, 4, 1, "사라짐").shape_id
    child_group = s4.shapes.add_group_shape()
    child = solid_shape(child_group.shapes, MSO_SHAPE.RECTANGLE, 1, 4, 1, 1, "FF0000").shape_id
    whole = s4.shapes.add_group_shape()
    solid_shape(whole.shapes, MSO_SHAPE.RECTANGLE, 6, 4, 1, 1, "00FF00")
    solid_shape(whole.shapes, MSO_SHAPE.RECTANGLE, 8, 4, 1, 1, "0000FF")
    animate(s4, [effect(para.shape_id, paragraph=1), effect(gone, preset="exit"), effect(child), effect(whole.shape_id)])

    s5 = new("101010")
    ids = [textbox(s5, 0.4 * (i % 30), 0.5 + 3 * (i // 30), 0.4, 1, str(i)).shape_id for i in range(31)]
    animate(s5, [effect(i) for i in ids])

    s6 = new("202020")
    text = textbox(s6, 1, 6, 4, 1, "글").shape_id
    lone = solid_shape(s6, MSO_SHAPE.RECTANGLE, 2, 2, 2, 2, "FF0000")
    lone.rotation = 45
    left = solid_shape(s6, MSO_SHAPE.RECTANGLE, 8, 2, 2, 2, "00FF00")
    right = solid_shape(s6, MSO_SHAPE.RECTANGLE, 9, 2, 2, 2, "0000FF")
    left.rotation = right.rotation = 10
    animate(s6, [effect(text), effect(lone.shape_id), effect(left.shape_id), effect(right.shape_id)])
    prs.save(str(path))


def check_anim(result):
    s1, s2, s3, s4, s5, s6 = result["slides"]
    assert [e.get("appear") for e in s1["elements"]] == [1, 1, 2] and s1["steps"] == 3, s1
    assert [e.get("appear") for e in s2["elements"]] == [None, 1] and s2["steps"] == 2, s2
    assert [e.get("appear") for e in s3["elements"]] == [None] and s3["steps"] == 1 and "anim_lost" not in s3, s3
    # 문단 단위 = 상자째 그 단계, 사라짐·그룹 자식은 처음부터, 그룹째는 자식 모두 같은 단계. 빈 단계(사라짐)는 다시 매김.
    assert [e.get("appear") for e in s4["elements"]] == [1, None, None, 2, 2] and s4["steps"] == 3, s4["elements"]
    assert s4["anim_lost"] == {"paragraph": 1, "exit": 1, "group_child": 1}, s4["anim_lost"]
    assert all("appear" not in e for e in s5["elements"]) and s5["steps"] == 1 and s5["anim_lost"] == {"too_many": 31}, s5
    assert s6["anim_lost"] == {"overlap": 2}, s6
    return s6


def check_anim_baked(s6):
    """배경 도형 애니메이션: 배경(B 판)엔 없고, 같은 자리 그림 요소가 appear 와 함께 맨 앞. 겹친 둘은 배경에 그대로."""
    first = s6["elements"][0]
    assert first["type"] == "image" and first["appear"] == 2, s6["elements"]
    assert [e.get("appear") for e in s6["elements"]] == [2, 1] and s6["steps"] == 3, s6["elements"]
    x, y, w, h = first["rect"]
    with Image.open(first["path"]) as crop:  # 45° 정사각형 바깥 상자 — 가운데는 빨강
        assert abs(crop.width - w * 1920) <= 1 and crop.getpixel((crop.width // 2, crop.height // 2))[:3][0] > 200
    assert close(x + w / 2, 3 / 13.333, 0.003) and close(y + h / 2, 3 / 7.5, 0.003), first["rect"]
    with Image.open(s6["background_png"]) as bg:
        def px(x_in, y_in):
            return bg.getpixel((round(x_in / 13.333 * 1920), round(y_in / 7.5 * 1080)))[:3]
        assert all(abs(v - 0x20) <= 6 for v in px(3, 3)), "애니메이션 배경 도형이 B 판에 남았다"
        assert px(8.5, 3)[1] > 200, "겹친 도형은 처음부터 보이게 배경에 남아야 한다"


def by(slide, **want):
    return [e for e in slide["elements"] if all(e.get(k) == v for k, v in want.items())]


def check_main(result, tmp):
    slides = result["slides"]
    assert [s["index"] for s in slides] == [1, 2, 3, 4, 5]
    assert result["letterboxed"] is False and result["aspect"] == round(Inches(13.333) / Inches(7.5), 4)
    for s in slides:
        assert s["steps"] == 1 and "anim_lost" not in s, s  # 애니메이션 없는 슬라이드는 steps 만 더해진다
        for e in s["elements"]:
            keys = {"text": TEXT_KEYS, "shape": SHAPE_KEYS, "image": IMAGE_KEYS}[e["type"]]
            assert keys <= set(e) <= keys | {"rich", "valign"}, (e["type"], set(e) ^ keys)

    s1 = slides[0]
    title = by(s1, text="제목")[0]
    assert title["font_size"] == 44, title  # 마스터 titleStyle 4400 × 540/540
    styled = [e for e in s1["elements"] if e["text"].startswith("굵은")][0]
    assert styled["text"] == "굵은기울임\n글머리"
    assert styled["font_size"] == 30 and styled["bold"] is True and styled["color"] == "#FF0000"
    ops = json.loads(styled["rich"])
    assert ops == [
        {"insert": "굵은"},
        {"insert": "기울임", "attributes": {"bold": False, "italic": True, "size": "20"}},
        {"insert": "\n글머리"},
        {"insert": "\n", "attributes": {"list": "bullet"}},
    ], ops
    x, y, w, h = styled["rect"]  # 기본 안쪽 여백(좌우 0.1in·위아래 0.05in)을 뺀 자리
    assert close(x, 1.1 / 13.333) and close(y, 2.05 / 7.5) and close(w, 5.8 / 13.333) and close(h, 1.9 / 7.5), styled["rect"]
    fit = by(s1, text="줄여 맞춤")[0]
    assert fit["font_size"] == 25 and fit["align"] == "center" and fit["valign"] == "middle", fit
    # 줄바꿈 없는 상자(wrap=none)는 가운데를 두고 30% 넓힌다: 안쪽 3.8in → 4.94in
    assert close(fit["rect"][0], (7.1 - 0.57) / 13.333) and close(fit["rect"][2], 4.94 / 13.333), fit["rect"]

    s2 = slides[1]
    rect = by(s2, shape="rect", fill="#FF0000")[0]
    assert rect["text"] == "안" and rect["stroke"] is None and rect["valign"] == "middle"
    assert close(rect["rect"][0], 1 / 13.333) and close(rect["rect"][2], 2 / 13.333)
    assert by(s2, shape="round_rect", fill="#00FF00")
    ellipse = by(s2, shape="ellipse")[0]
    assert ellipse["fill"] is None and ellipse["stroke"] == "#0000FF" and ellipse["stroke_width"] == 2
    theme = by(s2, shape="rect")[1]
    assert theme["fill"] == "#376092", theme["fill"]  # 기본 테마 accent1 4F81BD 의 밝기 75% (PowerPoint "강조 1, 25% 더 어둡게")
    line = by(s2, shape="line")[0]
    assert line["stroke"] == "#FFFFFF" and line["stroke_width"] == 3 and line["rect"][3] == 0
    arrow = by(s2, shape="arrow")[0]
    assert arrow["flip_h"] and arrow["flip_v"], arrow  # (6,5) → (3,3): 끝점이 왼쪽 위
    assert s2["dropped"] == {"fill": 1, "rotated": 1, "table": 1}, s2["dropped"]

    s3 = slides[2]
    group = [e for e in s3["elements"] if e["type"] == "shape"]
    assert [g["fill"] for g in group] == ["#FF00FF", "#00FFFF"]
    # 그룹 자식 좌표계 (0,0)-(2,2)in 이 슬라이드 (2,2)-(6,6)in 으로 → 자식은 2배
    assert close(group[0]["rect"][0], 2 / 13.333) and close(group[0]["rect"][2], 2 / 13.333)
    assert close(group[1]["rect"][0], 4 / 13.333) and close(group[1]["rect"][1], 4 / 7.5)
    images = [e for e in s3["elements"] if e["type"] == "image"]
    assert len(images) == 1, images  # 덮인 그림은 배경으로
    with Image.open(images[0]["path"]) as cropped:
        assert cropped.size == (50, 50) and cropped.getpixel((25, 25))[:3] == (0, 0, 255)
    assert s3["dropped"] == {"group": 1, "rotated": 1, "covered": 1}, s3["dropped"]

    assert slides[3]["hidden"] is True and slides[3]["elements"] == [] and slides[3]["background_png"] is None
    assert slides[4]["elements"] == []  # 빈 자리표시자는 버린다
    # 한글 run 은 테마 ea 글꼴 — 기본 테마는 ea 가 비어 있어 언어별 글꼴(Hang)을 쓴다
    assert result["fonts"] == ["맑은 고딕"], result["fonts"]


def check_baked(result):
    """배경 PNG: 슬라이드마다 자기 배경색(숨긴 장이 끼어도 밀리지 않음), 요소로 바꾼 도형은 지워졌다."""
    slides = result["slides"]
    colors = {1: (0x10, 0x20, 0x30), 2: (0x20, 0x30, 0x40), 3: (0x30, 0x40, 0x50), 5: (0x50, 0x60, 0x70)}
    def px(path, x_in, y_in):
        with Image.open(path) as image:
            assert image.size == (1920, 1080)
            return image.getpixel((round(x_in / 13.333 * 1920), round(y_in / 7.5 * 1080)))[:3]
    def near(a, b):
        return all(abs(i - j) <= 6 for i, j in zip(a, b))
    for index, color in colors.items():
        assert near(px(slides[index - 1]["background_png"], 0.2, 0.2), color), (index, px(slides[index - 1]["background_png"], 0.2, 0.2))
    bg2 = slides[1]["background_png"]
    assert near(px(bg2, 2, 1.5), colors[2]), "요소로 바꾼 빨간 사각형이 배경에 남았다"
    assert near(px(bg2, 9, 5.5), (0xFF, 0xFF, 0x00)), "회전 도형은 배경에 남아야 한다"


def check_sizes(tmp, bake):
    # 4:3 (10x7.5in): 양옆을 비워 가운데로. 30pt → 30 × 540/540
    path = tmp / "4x3.pptx"
    make_sized(path, Inches(10), Inches(7.5), 30)
    r = pptx_layout.layout_presentation(path, tmp / "out43", bake)
    assert r["letterboxed"] is True
    text = r["slides"][0]["elements"][0]
    assert close(text["rect"][0], 0.125) and close(text["rect"][2], 0.75) and text["font_size"] == 30, text
    rect = r["slides"][0]["elements"][1]
    assert close(rect["rect"][0], 0.125) and close(rect["rect"][2], 0.075) and close(rect["rect"][1], 2 / 7.5)
    if bake:
        with Image.open(r["slides"][0]["background_png"]) as image:
            assert image.getpixel((5, 540))[:3] == (0, 0, 0)  # 왼쪽 여백
            assert all(abs(a - b) <= 6 for a, b in zip(image.getpixel((300, 900))[:3], (0x33, 0x66, 0x99)))
    # 10x5.625in 16:9: 30pt → 30 × 540/405 = 40
    path = tmp / "small.pptx"
    make_sized(path, Inches(10), Emu(5143500), 30)
    r = pptx_layout.layout_presentation(path, tmp / "out_small")
    text = r["slides"][0]["elements"][0]
    assert r["letterboxed"] is False and text["font_size"] == 40 and close(text["rect"][2], 1.0), text


def check_font_names():
    """name 테이블 읽기: 앱 내장 글꼴 파일에서 family 이름이 나온다."""
    font = Path(__file__).resolve().parent.parent / "assets" / "fonts" / "Pretendard-Regular.ttf"
    if font.exists():
        assert "Pretendard" in pptx_layout._font_names(font.read_bytes())


def check_progress(sample, tmp):
    """진행 줄: stderr 에 슬라이드마다 {"progress":"read","n","total"}, stdout 은 비어 있다(결과 JSON 자리)."""
    import contextlib
    err, out = io.StringIO(), io.StringIO()
    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
        pptx_layout.layout_presentation(sample, tmp / "out_progress")
    lines = [json.loads(line) for line in err.getvalue().splitlines() if line.startswith('{"progress"')]
    reads = [line for line in lines if line["progress"] == "read"]
    assert [(r["n"], r["total"]) for r in reads] == [(n, 5) for n in range(1, 6)], lines
    assert out.getvalue() == ""


_TREE_SCRIPT = """
import signal, subprocess, sys
sys.path.insert(0, sys.argv[1])
import ppt_tool
signal.signal(signal.SIGTERM, ppt_tool._cancel_on_sigterm)
child = [sys.executable, "-c",
         "import subprocess, sys, time; p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']);"
         "print(p.pid, flush=True); time.sleep(60)"]
try:
    ppt_tool._run_child(child, timeout=30)
except ppt_tool.Cancelled:
    sys.exit(130)
"""


def check_sigterm_kills_tree(tmp):
    """SIGTERM → Cancelled → 자식·손자(soffice → soffice.bin 흉내)까지 죽고 130 으로 나간다. POSIX 만."""
    import signal
    import subprocess
    import time
    if os.name != "posix":
        return
    script = tmp / "tree.py"
    script.write_text(_TREE_SCRIPT, encoding="utf-8")
    runner = subprocess.Popen([sys.executable, str(script), os.path.dirname(os.path.abspath(__file__))])
    # 손자 pid 는 자식의 stdout 으로 나오는데 _run_child 가 가져가니 ps 로 찾는다.
    grandchild = None
    for _ in range(100):
        time.sleep(0.1)
        ps = subprocess.run(["ps", "-ax", "-o", "pid=,ppid=,command="], capture_output=True, text=True).stdout
        rows = [line.split(None, 2) for line in ps.splitlines()]
        kids = {int(r[0]) for r in rows if int(r[1]) == runner.pid}
        grand = [int(r[0]) for r in rows if int(r[1]) in kids and "time.sleep(60)" in r[2]]
        if grand:
            grandchild = grand[0]
            break
    assert grandchild, "손자 프로세스가 안 떴다"
    runner.send_signal(signal.SIGTERM)
    assert runner.wait(timeout=10) == 130
    for _ in range(50):
        try:
            os.kill(grandchild, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)
    raise AssertionError("손자 프로세스가 남았다")


def main():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        picture = tmp / "pic.png"
        image = Image.new("RGB", (100, 50), (255, 0, 0))
        image.paste((0, 0, 255), (50, 0, 100, 50))
        image.save(picture)
        sample = tmp / "main.pptx"
        make_main(sample, picture)
        can_bake = ppt_tool.get_libreoffice_executable() is not None or ppt_tool.powerpoint_available()
        bake = ppt_tool._convert_to_pdf if can_bake else None
        result = pptx_layout.layout_presentation(sample, tmp / "out", bake)
        check_main(result, tmp)
        check_sizes(tmp, bake)
        check_font_names()
        check_progress(sample, tmp)
        check_sigterm_kills_tree(tmp)
        anim = tmp / "anim.pptx"
        make_anim(anim)
        s6 = check_anim(pptx_layout.layout_presentation(anim, tmp / "out_anim_plain"))
        # 굽지 않으면 배경 도형 애니메이션은 잘라 낼 수 없다 — 글 상자(1번째 클릭)만 남는다
        assert [e.get("appear") for e in s6["elements"]] == [1] and s6["steps"] == 2, s6["elements"]
        if bake:
            check_anim_baked(check_anim(pptx_layout.layout_presentation(anim, tmp / "out_anim", bake)))
            check_baked(result)
            via_command = ppt_tool.layout_presentation(sample, tmp / "out_cmd")
            assert "error" not in via_command and len(via_command["slides"]) == 5
            print("ok (두 번 굽기 포함)")
        else:
            print("ok (skip: LibreOffice·PowerPoint 없음 — 두 번 굽기 안 함)")


if __name__ == "__main__":
    main()
