"""PPTX 슬라이드 → 슬라이드 편집 페이지 요소(page_elements) — `ppt_tool layout <pptx> <out_dir>`.

받을 수 있는 것(글 상자·자리표시자 글·사각형·둥근 사각형·타원·선·화살표·png/jpg 그림, 그것만 든 그룹)은
요소 JSON 으로 내고, 나머지(표·차트·SmartArt·회전·그라데이션·다른 모양·효과 그림 …)는 슬라이드에 남긴 채
"요소로 바꾼 것을 지운 사본"을 기존 굽기 경로로 구워 슬라이드마다 배경 PNG 로 쓴다(두 번 굽기).
요소 JSON 키는 lib/src/features/praise/domain/page_element.dart, 글 서식은 page_rich_text.dart 와 같다.
출력 계약: planning/ppt-style-editor/shapes-contract.md
"""
import colorsys
import io
import json
import os
import struct
import sys
import tempfile
import uuid
from pathlib import Path

from lxml import etree
from pptx import Presentation

_A = "{http://schemas.openxmlformats.org/drawingml/2006/main}"
_P = "{http://schemas.openxmlformats.org/presentationml/2006/main}"
_R = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
_RT_THEME = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme"

CANVAS_W, CANVAS_H = 1920, 1080
CANVAS_ASPECT = CANVAS_W / CANVAS_H
BASE_PT = 540  # 앱 글자 크기 기준: 슬라이드 높이 = 540pt
EMU_PER_PT = 12700
MIN_FONT, MAX_FONT = 8, 300  # PageTextElement.minFontSize·maxFontSize
MAX_STROKE = 40  # PageShapeElement.maxStrokeWidth
DEFAULT_INSETS = (91440, 45720, 91440, 45720)  # l, t, r, b (EMU) — PPT 기본
_SHAPES = {"rect": "rect", "roundRect": "round_rect", "ellipse": "ellipse"}
_LINE_GEOMS = {"line", "straightConnector1"}
_IMAGE_EXTS = {"png": "png", "jpg": "jpg", "jpeg": "jpg"}
_ALIGN = {"l": "left", "ctr": "center", "r": "right"}
_VALIGN = {"ctr": "middle", "b": "bottom"}
_GRAPHIC_KINDS = {"table": "table", "chart": "chart", "diagram": "smartart", "ole": "ole"}
_PRESET_COLORS = {
    "black": "000000", "white": "FFFFFF", "red": "FF0000", "green": "008000", "blue": "0000FF",
    "yellow": "FFFF00", "gray": "808080", "grey": "808080", "orange": "FFA500", "purple": "800080",
    "cyan": "00FFFF", "magenta": "FF00FF", "darkGray": "A9A9A9", "lightGray": "D3D3D3", "navy": "000080",
}
# 앱에 늘 있는 글꼴(pubspec 3종 + assets/fonts/free). 글꼴을 더하면 여기도.
APP_FONTS = {
    "Pretendard", "NanumGothic", "NanumMyeongjo", "Black Han Sans", "Do Hyeon", "Gothic A1",
    "IBM Plex Sans KR", "Jua", "Nanum Pen Script",
}


def _local(tag):
    return tag.split("}")[-1] if isinstance(tag, str) else ""


def _int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


# ── 색 ────────────────────────────────────────────────────────────────

class _Theme:
    def __init__(self, master):
        theme = etree.fromstring(master.part.part_related_by(_RT_THEME).blob)
        self.colors = {}
        scheme = theme.find(f".//{_A}clrScheme")
        for slot in scheme if scheme is not None else ():
            child = slot[0] if len(slot) else None
            if child is not None:
                value = child.get("lastClr") if _local(child.tag) == "sysClr" else child.get("val")
                if value:
                    self.colors[_local(slot.tag)] = value.upper()
        self.fonts = {}
        for key, tag in (("mj", "majorFont"), ("mn", "minorFont")):
            node = theme.find(f".//{_A}{tag}")
            if node is None:
                continue
            latin = node.find(f"{_A}latin")
            ea = node.find(f"{_A}ea")
            hang = next((f.get("typeface") for f in node.findall(f"{_A}font") if f.get("script") == "Hang"), None)
            self.fonts[key] = {
                "lt": latin.get("typeface") if latin is not None else "",
                # ea 가 비면 PowerPoint 는 언어별 글꼴(Hang)을 쓴다.
                "ea": (ea.get("typeface") if ea is not None else "") or hang or "",
            }
        fmt = theme.find(f".//{_A}fmtScheme")
        def styles(tag):
            node = fmt.find(f"{_A}{tag}") if fmt is not None else None
            return list(node) if node is not None else []
        self.fill_styles = styles("fillStyleLst")
        self.bg_fill_styles = styles("bgFillStyleLst")
        self.line_styles = styles("lnStyleLst")


def _hls_apply(rgb, fn):
    h, l, s = colorsys.rgb_to_hls(*rgb)
    h, l, s = fn(h, l, s)
    return colorsys.hls_to_rgb(h, min(max(l, 0), 1), min(max(s, 0), 1))


class _Colors:
    """schemeClr 를 이 슬라이드의 색 대응(clrMap)·테마로 푼다."""

    def __init__(self, theme, clr_map):
        self.theme = theme
        self.map = clr_map

    def resolve(self, node, ph=None):
        """색 요소(srgbClr 등) → ('#RRGGBB', alpha) 또는 None."""
        kind = _local(node.tag)
        alpha = 1.0
        if kind == "srgbClr":
            hex_ = node.get("val")
        elif kind == "sysClr":
            hex_ = node.get("lastClr") or ("000000" if node.get("val") == "windowText" else "FFFFFF")
        elif kind == "prstClr":
            hex_ = _PRESET_COLORS.get(node.get("val"))
        elif kind == "schemeClr":
            val = node.get("val")
            if val == "phClr":
                if ph is None:
                    return None
                hex_, alpha = ph[0][1:], ph[1]
            else:
                hex_ = self.theme.colors.get(self.map.get(val, val))
        elif kind == "scrgbClr":
            def srgb(v):
                c = _int(v) / 100000
                return c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055
            hex_ = "".join(f"{round(min(max(srgb(node.get(k)), 0), 1) * 255):02X}" for k in "rgb")
        elif kind == "hslClr":
            r, g, b = colorsys.hls_to_rgb(_int(node.get("hue")) / 21600000, _int(node.get("lum")) / 100000, _int(node.get("sat")) / 100000)
            hex_ = "".join(f"{round(c * 255):02X}" for c in (r, g, b))
        else:
            return None
        if not hex_ or len(hex_) != 6:
            return None
        rgb = tuple(int(hex_[i:i + 2], 16) / 255 for i in (0, 2, 4))
        for mod in node:
            m, v = _local(mod.tag), _int(mod.get("val"), 100000) / 100000
            if m == "lumMod":
                rgb = _hls_apply(rgb, lambda h, l, s: (h, l * v, s))
            elif m == "lumOff":
                rgb = _hls_apply(rgb, lambda h, l, s: (h, l + v, s))
            elif m == "satMod":
                rgb = _hls_apply(rgb, lambda h, l, s: (h, l, s * v))
            elif m == "shade":
                rgb = tuple(c * v for c in rgb)
            elif m == "tint":
                rgb = tuple(c + (1 - c) * (1 - v) for c in rgb)
            elif m == "alpha":
                alpha = v
            elif m == "alphaMod":
                alpha *= v
            # ponytail: hueOff·gamma 등 드문 변형은 무시 — 색이 조금 다를 수 있다.
        return "#" + "".join(f"{round(min(max(c, 0), 1) * 255):02X}" for c in rgb), min(max(alpha, 0), 1)

    def first(self, parent, ph=None):
        """parent 안 첫 색 요소를 푼다."""
        if parent is None:
            return None
        for child in parent:
            if _local(child.tag).endswith("Clr"):
                return self.resolve(child, ph)
        return None


# ── 글 상속 ───────────────────────────────────────────────────────────

def _ph_info(el):
    ph = el.find(f"./{_P}nvSpPr/{_P}nvPr/{_P}ph")
    if ph is None:
        ph = el.find(f"./*/{_P}nvPr/{_P}ph")
    if ph is None:
        return None
    return ph.get("type") or "obj", ph.get("idx") or "0"


_MASTER_PH = {"ctrTitle": "title", "title": "title", "dt": "dt", "ftr": "ftr", "sldNum": "sldNum"}


def _find_ph(tree_root, ph_type, idx, by_idx):
    for el in tree_root.iter(f"{_P}sp"):
        info = _ph_info(el)
        if info is None:
            continue
        if by_idx and info[1] == idx and idx != "0":
            return el
        if not by_idx or idx == "0":
            want = _MASTER_PH.get(ph_type, "body")
            if _MASTER_PH.get(info[0], "body") == want:
                return el
    return None


class _Slide:
    """한 슬라이드를 풀 때 필요한 것(테마·색 대응·레이아웃·마스터·기본 글 스타일)."""

    def __init__(self, prs, slide, theme_cache):
        layout = slide.slide_layout
        master = layout.slide_master
        key = id(master)
        if key not in theme_cache:
            theme_cache[key] = _Theme(master)
        self.theme = theme_cache[key]
        base_map = master._element.find(f"{_P}clrMap")
        clr_map = dict(base_map.attrib) if base_map is not None else {"bg1": "lt1", "tx1": "dk1", "bg2": "lt2", "tx2": "dk2"}
        for owner in (layout._element, slide._element):
            override = owner.find(f"{_P}clrMapOvr/{_A}overrideClrMapping")
            if override is not None:
                clr_map = dict(override.attrib)
        self.colors = _Colors(self.theme, clr_map)
        self.slide = slide
        self.layout_root = layout._element
        self.master_root = master._element
        self.default_text = prs.part._element.find(f"{_P}defaultTextStyle")
        self.tx_styles = master._element.find(f"{_P}txStyles")

    def placeholder_chain(self, el):
        """자리표시자면 (레이아웃 것, 마스터 것). 아니면 (None, None)."""
        info = _ph_info(el)
        if info is None:
            return None, None
        layout_ph = _find_ph(self.layout_root, info[0], info[1], by_idx=True)
        master_type = _ph_info(layout_ph)[0] if layout_ph is not None else info[0]
        return layout_ph, _find_ph(self.master_root, master_type, "0", by_idx=False)

    def level_styles(self, el, level):
        """글 서식을 찾을 lvlNpPr 들(가까운 것부터) + 도형 style fontRef."""
        tag = f"{_A}lvl{level + 1}pPr"
        out = []
        def add(owner):
            if owner is None:
                return
            node = owner.find(f"{_P}txBody/{_A}lstStyle/{tag}")
            if node is not None:
                out.append(node)
        add(el)
        layout_ph, master_ph = self.placeholder_chain(el)
        info = _ph_info(el)
        if info is not None:
            add(layout_ph)
            add(master_ph)
            if self.tx_styles is not None:
                kind = _MASTER_PH.get(info[0], "body")
                style = {"title": "titleStyle", "body": "bodyStyle"}.get(kind, "otherStyle")
                node = self.tx_styles.find(f"{_P}{style}/{tag}")
                if node is not None:
                    out.append(node)
        else:
            if self.default_text is not None:
                node = self.default_text.find(tag)
                if node is not None:
                    out.append(node)
            if self.tx_styles is not None:
                node = self.tx_styles.find(f"{_P}otherStyle/{tag}")
                if node is not None:
                    out.append(node)
        return out

    def body_pr(self, el):
        """bodyPr 들(가까운 것부터, 자리표시자는 레이아웃·마스터까지)."""
        out = [el.find(f"{_P}txBody/{_A}bodyPr")]
        out += [ph.find(f"{_P}txBody/{_A}bodyPr") for ph in self.placeholder_chain(el) if ph is not None]
        return [b for b in out if b is not None]

    def xfrm(self, el):
        """도형 자리(EMU, 자기 좌표계). 자리표시자는 레이아웃·마스터에서 물려받는다."""
        for owner in (el, *self.placeholder_chain(el)):
            if owner is None:
                continue
            x = owner.find(f"{_P}spPr/{_A}xfrm")
            if x is None:
                x = owner.find(f"{_P}grpSpPr/{_A}xfrm")
            if x is None:
                x = owner.find(f"{_P}xfrm")
            if x is not None and x.find(f"{_A}off") is not None and x.find(f"{_A}ext") is not None:
                return x
        return None

    def font(self, typeface):
        if typeface and typeface.startswith("+"):
            # +mj-lt, +mn-ea … (cs 는 latin 으로)
            group, _, script = typeface[1:].partition("-")
            fonts = self.theme.fonts.get(group, {})
            return fonts.get("ea" if script == "ea" else "lt") or fonts.get("lt") or None
        return typeface or None


def _first_attr(nodes, attr):
    for n in nodes:
        if n is not None and n.get(attr) is not None:
            return n.get(attr)
    return None


def _is_east_asian(text):
    return any(
        0xAC00 <= o <= 0xD7A3 or 0x1100 <= o <= 0x11FF or 0x3130 <= o <= 0x318F
        or 0x3040 <= o <= 0x30FF or 0x4E00 <= o <= 0x9FFF
        for o in map(ord, text)
    )


def _has_text_effect(rpr):
    if rpr is None:
        return False
    effect = rpr.find(f"{_A}effectLst")
    ln = rpr.find(f"{_A}ln")
    return (
        (effect is not None and len(effect) > 0)
        or (ln is not None and ln.find(f"{_A}noFill") is None and len(ln) > 0)
        or rpr.find(f"{_A}gradFill") is not None
        or rpr.find(f"{_A}highlight") is not None
    )


def _read_text(ctx, el, font_scale, size_scale):
    """도형 글 → (줄 목록 [(spans, list)], 첫 문단 정렬, 효과 있음). span = (글, 서식 dict)."""
    body = el.find(f"{_P}txBody")
    if body is None:
        return [], "left", False
    style_ref = el.find(f"{_P}style/{_A}fontRef")
    lines, align, effect = [], None, False
    for para in body.findall(f"{_A}p"):
        ppr = para.find(f"{_A}pPr")
        level = min(_int(ppr.get("lvl") if ppr is not None else 0), 8)
        levels = ctx.level_styles(el, level)
        pnodes = [ppr, *levels]
        defs = [lv.find(f"{_A}defRPr") for lv in levels]
        bullet = None
        for node in pnodes:
            if node is None:
                continue
            kinds = {_local(c.tag) for c in node}
            if "buNone" in kinds:
                break
            if "buAutoNum" in kinds:
                bullet = "ordered"
                break
            if kinds & {"buChar", "buBlip"}:
                bullet = "bullet"
                break
        segments = [[]]
        for item in para:
            kind = _local(item.tag)
            if kind == "br":
                segments.append([])
                continue
            if kind not in ("r", "fld"):
                continue
            text = "".join(t.text or "" for t in item.findall(f"{_A}t"))
            if not text:
                continue
            rpr = item.find(f"{_A}rPr")
            nodes = [rpr, *defs]
            effect = effect or _has_text_effect(rpr)
            size = _int(_first_attr(nodes, "sz"), 1800) / 100 * font_scale * size_scale
            color = None
            for n in nodes:
                if n is None:
                    continue
                fill = n.find(f"{_A}solidFill")
                if fill is not None:
                    color = ctx.colors.first(fill)
                    break
                if n.find(f"{_A}gradFill") is not None:
                    stop = n.find(f"{_A}gradFill/{_A}gsLst/{_A}gs")
                    color = ctx.colors.first(stop)
                    break
            if color is None and style_ref is not None:
                color = ctx.colors.first(style_ref)
            # 한글이 든 run 은 ea 글꼴(상속 끝까지 찾은 뒤에야 latin), 아니면 latin.
            face_tag = "ea" if _is_east_asian(text) else "latin"
            face = next((
                ctx.font(node.get("typeface"))
                for tag in dict.fromkeys((face_tag, "latin"))
                for n in nodes if n is not None
                for node in [n.find(f"{_A}{tag}")]
                if node is not None and ctx.font(node.get("typeface"))
            ), None)
            if face is None:
                ref = style_ref.get("idx") if style_ref is not None else "minor"
                face = ctx.font(f"+{'mj' if ref == 'major' else 'mn'}-{'ea' if face_tag == 'ea' else 'lt'}")
            underline = _first_attr(nodes, "u")
            strike = _first_attr(nodes, "strike")
            segments[-1].append((text, {
                "size": size,
                "color": (color or ctx.colors.resolve(etree.Element(f"{_A}schemeClr", val="tx1")) or ("#000000", 1))[0],
                "bold": _first_attr(nodes, "b") in ("1", "true"),
                "italic": _first_attr(nodes, "i") in ("1", "true"),
                "underline": underline not in (None, "none"),
                "strike": strike not in (None, "noStrike"),
                "font": face or "",
            }))
        has_text = any(t.strip() for seg in segments for t, _ in seg)
        if align is None and has_text:
            align = _ALIGN.get(_first_attr(pnodes, "algn"), "left")
        for i, seg in enumerate(segments):
            # 줄바꿈(<a:br>)으로 이어진 줄은 첫 줄만 목록 기호.
            lines.append((seg, bullet if (i == 0 and has_text) else None))
    return lines, align or "left", effect


def _fmt_size(value):
    return f"{value:.1f}".rstrip("0").rstrip(".")


def _most_common(values):
    counts = {}
    for value, weight in values:
        counts[value] = counts.get(value, 0) + weight
    return max(counts, key=counts.get) if counts else None


def _text_fields(lines, align):
    """줄 목록 → PageTextElement 글 칸(text·font_size·color·bold·align·font_family·rich)."""
    runs = [(text, a) for spans, _ in lines for text, a in spans]
    weighted = lambda key: _most_common((a[key], len(t)) for t, a in runs)
    clamp = lambda v: min(max(v, MIN_FONT), MAX_FONT)
    box = {
        "size": round(clamp(weighted("size") or 40), 1),
        "color": weighted("color") or "#FFFFFF",
        "bold": bool(weighted("bold")),
        "font": weighted("font") or "Pretendard",
    }
    ops = []
    def add(text, attrs):
        # page_rich_text.dart pageRichOps 와 같게: 같은 서식 덩어리는 합친다.
        if ops and ops[-1].get("attributes", {}) == attrs:
            ops[-1]["insert"] += text
        else:
            ops.append({"insert": text, **({"attributes": attrs} if attrs else {})})
    for spans, bullet in lines:
        for text, a in spans:
            attrs = {}
            if a["bold"] != box["bold"]:
                attrs["bold"] = a["bold"]
            for key in ("italic", "underline", "strike"):
                if a[key]:
                    attrs[key] = True
            if a["color"] != box["color"]:
                attrs["color"] = a["color"]
            if round(clamp(a["size"]), 1) != box["size"]:
                attrs["size"] = _fmt_size(clamp(a["size"]))
            if a["font"] and a["font"] != box["font"]:
                attrs["font"] = a["font"]
            add(text, attrs)
        add("\n", {"list": bullet} if bullet else {})
    fields = {
        "text": "\n".join("".join(t for t, _ in spans) for spans, _ in lines),
        "font_size": box["size"],
        "color": box["color"],
        "bold": box["bold"],
        "align": align,
        "font_family": box["font"],
    }
    if any("attributes" in op for op in ops):
        fields["rich"] = json.dumps(ops, ensure_ascii=False, separators=(",", ":"))
    return fields


# ── 자리·좌표 ─────────────────────────────────────────────────────────

class _Frame:
    """슬라이드 EMU → 16:9 캔버스 0~1. 16:9 가 아니면 가운데에 놓는다(4:3 은 양옆, 더 넓으면 위아래 여백)."""

    def __init__(self, width, height):
        if width / height <= CANVAS_ASPECT:
            self.canvas_w, self.canvas_h = height * CANVAS_ASPECT, height
        else:
            self.canvas_w, self.canvas_h = width, width / CANVAS_ASPECT
        self.off_x = (self.canvas_w - width) / 2
        self.off_y = (self.canvas_h - height) / 2
        self.size_scale = BASE_PT / (self.canvas_h / EMU_PER_PT)  # pt → 540pt 기준

    def rect(self, x, y, w, h):
        return [
            round((x + self.off_x) / self.canvas_w, 5),
            round((y + self.off_y) / self.canvas_h, 5),
            round(w / self.canvas_w, 5),
            round(h / self.canvas_h, 5),
        ]


def _apply(tf, x, y, w, h):
    ax, bx, ay, by = tf
    return ax * x + bx, ay * y + by, ax * w, ay * h


def _child_transform(tf, xfrm):
    off, ext = xfrm.find(f"{_A}off"), xfrm.find(f"{_A}ext")
    ch_off, ch_ext = xfrm.find(f"{_A}chOff"), xfrm.find(f"{_A}chExt")
    sx = _int(ext.get("cx")) / _int(ch_ext.get("cx"), 1) if ch_ext is not None and _int(ch_ext.get("cx")) else 1
    sy = _int(ext.get("cy")) / _int(ch_ext.get("cy"), 1) if ch_ext is not None and _int(ch_ext.get("cy")) else 1
    cx0 = _int(ch_off.get("x")) if ch_off is not None else _int(off.get("x"))
    cy0 = _int(ch_off.get("y")) if ch_off is not None else _int(off.get("y"))
    ax, bx, ay, by = tf
    return (
        ax * sx, ax * (_int(off.get("x")) - cx0 * sx) + bx,
        ay * sy, ay * (_int(off.get("y")) - cy0 * sy) + by,
    )


def _xywh(xfrm):
    off, ext = xfrm.find(f"{_A}off"), xfrm.find(f"{_A}ext")
    return _int(off.get("x")), _int(off.get("y")), _int(ext.get("cx")), _int(ext.get("cy"))


def _bbox(xfrm, tf):
    """회전까지 넣은 슬라이드 EMU 바깥 상자 (x0, y0, x1, y1)."""
    x, y, w, h = _apply(tf, *_xywh(xfrm))
    rot = _int(xfrm.get("rot")) / 60000
    if rot % 180:
        import math
        r = math.radians(rot)
        bw = abs(w * math.cos(r)) + abs(h * math.sin(r))
        bh = abs(w * math.sin(r)) + abs(h * math.cos(r))
        cx, cy = x + w / 2, y + h / 2
        return cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2
    return x, y, x + w, y + h


def _overlaps(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


# ── 요소 바꾸기 ───────────────────────────────────────────────────────

class _Drop(Exception):
    """이 도형은 요소로 못 바꾼다(배경 그림에 남긴다). args[0] = 까닭."""


def _new_id():
    return uuid.uuid4().hex[:16]


def _resolve_fill(ctx, el):
    """채우기 → None(없음) 또는 (색, 알파). 단색이 아니면 _Drop."""
    sppr = el.find(f"{_P}spPr")
    for child in sppr if sppr is not None else ():
        kind = _local(child.tag)
        if kind == "noFill":
            return None
        if kind == "solidFill":
            return ctx.colors.first(child)
        if kind in ("gradFill", "pattFill", "blipFill", "grpFill"):
            raise _Drop("fill")
    ref = el.find(f"{_P}style/{_A}fillRef")
    idx = _int(ref.get("idx")) if ref is not None else 0
    if idx == 0:
        return None
    styles = ctx.theme.bg_fill_styles if idx >= 1001 else ctx.theme.fill_styles
    pos = (idx - 1001 if idx >= 1001 else idx - 1)
    style = styles[pos] if 0 <= pos < len(styles) else None
    if style is None or _local(style.tag) == "noFill":
        return None
    if _local(style.tag) != "solidFill":
        raise _Drop("fill")
    return ctx.colors.first(style, ph=ctx.colors.first(ref))


def _resolve_line(ctx, el, size_scale):
    """선 → None(없음) 또는 (색, 두께 pt 540 기준, 끝 모양 (head, tail)). 단색 실선이 아니면 _Drop."""
    ln = el.find(f"{_P}spPr/{_A}ln")
    ref = el.find(f"{_P}style/{_A}lnRef")
    idx = _int(ref.get("idx")) if ref is not None else 0
    style = ctx.theme.line_styles[idx - 1] if 0 < idx <= len(ctx.theme.line_styles) else None
    nodes = [n for n in (ln, style) if n is not None]
    color = None
    for n in nodes:
        kinds = {_local(c.tag): c for c in n}
        if "noFill" in kinds:
            return None
        if "solidFill" in kinds:
            color = ctx.colors.first(kinds["solidFill"], ph=ctx.colors.first(ref) if n is style else None)
            break
        if kinds.keys() & {"gradFill", "pattFill"}:
            raise _Drop("line")
    if color is None:
        return None
    dash = None
    for n in nodes:
        d = n.find(f"{_A}prstDash")
        if d is not None or n.find(f"{_A}custDash") is not None:
            dash = d.get("val") if d is not None else "custom"
            break
    if dash not in (None, "solid"):
        raise _Drop("line")
    width = _int(_first_attr(nodes, "w"), 9525) / EMU_PER_PT * size_scale
    def end(tag):
        node = ln.find(f"{_A}{tag}") if ln is not None else None
        return node is not None and node.get("type") not in (None, "none")
    return color, round(min(width, MAX_STROKE), 2), (end("headEnd"), end("tailEnd"))


def _shape_effect(el):
    effect = el.find(f"{_P}spPr/{_A}effectLst")
    return effect is not None and len(effect) > 0


def _convert_sp(ctx, frame, el, tf, connector=False):
    """sp·cxnSp → (요소 목록, 효과 빠짐 여부). 못 바꾸면 _Drop."""
    xfrm = ctx.xfrm(el)
    if xfrm is None:
        raise _Drop("geometry")
    if _int(xfrm.get("rot")) % 21600000:
        raise _Drop("rotated")
    geom = el.find(f"{_P}spPr/{_A}prstGeom")
    prst = geom.get("prst") if geom is not None else None
    if prst is None and el.find(f"{_P}spPr/{_A}custGeom") is not None:
        prst = "custom"
    if prst is None and _ph_info(el) is not None:
        prst = "rect"  # 자리표시자는 모양을 레이아웃에서 물려받는다 — 사실상 사각형
    x, y, w, h = _apply(tf, *_xywh(xfrm))
    flip_h, flip_v = xfrm.get("flipH") == "1", xfrm.get("flipV") == "1"

    if connector or prst in _LINE_GEOMS:
        if prst not in _LINE_GEOMS:
            raise _Drop("geometry")
        line = _resolve_line(ctx, el, frame.size_scale)
        if line is None:
            return [], False
        color, width, (head, tail) = line
        if head and tail:
            raise _Drop("line")
        if head:  # 앱 화살표 머리는 끝점 — 시작점에 머리가 있으면 방향을 뒤집는다
            flip_h, flip_v = not flip_h, not flip_v
        return [_shape_json(frame, x, y, w, h, "arrow" if head or tail else "line", None, color, width,
                            flip_h=flip_h, flip_v=flip_v)], _shape_effect(el)

    body_prs = ctx.body_pr(el)
    if _first_attr(body_prs, "vert") not in (None, "horz"):
        raise _Drop("vertical_text")
    autofit = next((c for b in body_prs for c in b if _local(c.tag) in ("normAutofit", "spAutoFit", "noAutofit")), None)
    font_scale = _int(autofit.get("fontScale"), 100000) / 100000 if autofit is not None and _local(autofit.tag) == "normAutofit" else 1
    lines, align, text_effect = _read_text(ctx, el, font_scale, frame.size_scale)
    has_text = any(t.strip() for spans, _ in lines for t, _ in spans)
    fill = _resolve_fill(ctx, el)
    line = _resolve_line(ctx, el, frame.size_scale)
    effect = _shape_effect(el) or text_effect
    valign = _VALIGN.get(_first_attr(body_prs, "anchor"), "top")

    if fill is None and line is None:
        if not has_text:
            return [], False  # 안 보이는 도형·빈 자리표시자
        insets = [_int(_first_attr(body_prs, k), d) for k, d in zip(("lIns", "tIns", "rIns", "bIns"), DEFAULT_INSETS)]
        ix, iy = insets[0] * tf[0], insets[1] * tf[2]
        tx, ty = x + ix, y + iy
        tw = max(w - ix - insets[2] * tf[0], 1)
        th = max(h - iy - insets[3] * tf[2], 1)
        if _first_attr(body_prs, "wrap") == "none":
            # 줄바꿈 없는 상자는 PowerPoint 글꼴 폭에 꼭 맞게 잡혀 있다 — 앱 글꼴이 조금만 넓어도 줄이 바뀌니 넓혀 둔다.
            # ponytail: 30% 고정 여유, 실제 글 폭을 재려면 글꼴 측정이 필요하다.
            grow = tw * 0.3
            tx -= {"left": 0, "center": grow / 2, "right": grow}[align]
            tw += grow
        element = {"type": "text", "id": _new_id(), "rect": frame.rect(tx, ty, tw, th), **_text_fields(lines, align)}
        if valign != "top":
            element["valign"] = valign
        return [element], effect

    if prst not in _SHAPES:
        raise _Drop("geometry")
    radius = 0.1667
    if prst == "roundRect":
        gd = el.find(f"{_P}spPr/{_A}prstGeom/{_A}avLst/{_A}gd")
        if gd is not None and (gd.get("fmla") or "").startswith("val "):
            radius = min(max(_int(gd.get("fmla")[4:]) / 100000, 0), 0.5)
    return [_shape_json(frame, x, y, w, h, _SHAPES[prst], fill, line[0] if line else None,
                        line[1] if line else 0, radius=radius, valign=valign,
                        text=_text_fields(lines, align) if has_text else None)], effect


def _shape_json(frame, x, y, w, h, kind, fill, stroke, stroke_width, flip_h=False, flip_v=False,
                radius=0.1667, valign="middle", text=None):
    """PageShapeElement.toJson 과 같은 키·순서."""
    text = text or {"text": "", "font_size": 40, "color": "#000000", "bold": False, "align": "center", "font_family": "Pretendard"}
    return {
        "type": "shape",
        "id": _new_id(),
        "rect": frame.rect(x, y, w, h),
        "shape": kind,
        "fill": fill[0] if fill else None,
        "fill_alpha": round(fill[1], 3) if fill else 1,
        "stroke": stroke[0] if stroke else None,
        "stroke_width": stroke_width,
        "radius": round(radius, 4),
        "flip_h": flip_h,
        "flip_v": flip_v,
        **text,
        "valign": valign,
    }


def _convert_pic(ctx, frame, el, tf, out_dir, name):
    """그림 → 그림 요소(파일은 out_dir 로 꺼낸다)."""
    from PIL import Image, ImageOps

    nv = el.find(f"{_P}nvPicPr/{_P}nvPr")
    if nv is not None and (
        nv.find(f"{_A}videoFile") is not None or nv.find(f"{_A}audioFile") is not None
        or any(_local(c.tag) == "media" for c in nv.iter())
    ):
        raise _Drop("media")
    xfrm = ctx.xfrm(el)
    if xfrm is None:
        return [], False
    if _int(xfrm.get("rot")) % 21600000:
        raise _Drop("rotated")
    geom = el.find(f"{_P}spPr/{_A}prstGeom")
    if geom is not None and geom.get("prst") != "rect":
        raise _Drop("geometry")
    blip = el.find(f"{_P}blipFill/{_A}blip")
    rid = blip.get(f"{_R}embed") if blip is not None else None
    if not rid:
        if blip is None:
            return [], False  # 빈 그림 자리표시자
        raise _Drop("picture_format")
    for child in blip:
        # 투명도·흑백·색 바꾸기 같은 그림 효과(extLst 의 예술 효과 포함)는 앱이 못 그린다.
        if _local(child.tag) != "extLst" or any(_local(n.tag) == "imgProps" for n in child.iter()):
            raise _Drop("picture_effect")
    part = ctx.slide.part.related_part(rid)
    ext = _IMAGE_EXTS.get(str(part.partname).rsplit(".", 1)[-1].lower())
    if ext is None:
        raise _Drop("picture_format")
    src = el.find(f"{_P}blipFill/{_A}srcRect")
    crop = [_int(src.get(k)) / 100000 if src is not None else 0 for k in ("l", "t", "r", "b")]
    if any(c < 0 for c in crop) or crop[0] + crop[2] >= 1 or crop[1] + crop[3] >= 1:
        raise _Drop("picture_crop")
    flip_h, flip_v = xfrm.get("flipH") == "1", xfrm.get("flipV") == "1"
    path = Path(out_dir) / f"{name}.{ext}"
    if any(crop) or flip_h or flip_v:
        with Image.open(io.BytesIO(part.blob)) as image:
            image.load()
            iw, ih = image.size
            image = image.crop((round(crop[0] * iw), round(crop[1] * ih), round(iw * (1 - crop[2])), round(ih * (1 - crop[3]))))
            if flip_h:
                image = ImageOps.mirror(image)
            if flip_v:
                image = ImageOps.flip(image)
            if ext == "jpg":
                image.convert("RGB").save(path, quality=95)
            else:
                image.save(path)
    else:
        path.write_bytes(part.blob)
    x, y, w, h = _apply(tf, *_xywh(xfrm))
    ln = el.find(f"{_P}spPr/{_A}ln")
    border = ln is not None and ln.find(f"{_A}noFill") is None and len(ln) > 0
    return [{"type": "image", "id": _new_id(), "rect": frame.rect(x, y, w, h), "path": str(path)}], border or _shape_effect(el)


def _convert(ctx, frame, el, tf, out_dir, name):
    """맨 위 도형 하나(그룹이면 자식 전부) → (요소 목록, 효과 빠짐 수). 못 바꾸면 _Drop."""
    kind = _local(el.tag)
    if kind == "sp":
        elements, effect = _convert_sp(ctx, frame, el, tf)
        return elements, int(effect)
    if kind == "cxnSp":
        elements, effect = _convert_sp(ctx, frame, el, tf, connector=True)
        return elements, int(effect)
    if kind == "pic":
        elements, effect = _convert_pic(ctx, frame, el, tf, out_dir, name)
        return elements, int(effect)
    if kind == "graphicFrame":
        data = el.find(f".//{_A}graphicData")
        uri = (data.get("uri") or "") if data is not None else ""
        raise _Drop(next((v for k, v in _GRAPHIC_KINDS.items() if uri.endswith(k) or f"/{k}" in uri), "other"))
    if kind == "grpSp":
        xfrm = el.find(f"{_P}grpSpPr/{_A}xfrm")
        if xfrm is None or xfrm.find(f"{_A}off") is None:
            raise _Drop("group")
        if _int(xfrm.get("rot")) % 21600000 or xfrm.get("flipH") == "1" or xfrm.get("flipV") == "1":
            raise _Drop("rotated")
        child_tf = _child_transform(tf, xfrm)
        out, effects = [], 0
        for i, child in enumerate(c for c in el if _local(c.tag) in ("sp", "cxnSp", "pic", "graphicFrame", "grpSp")):
            try:
                elements, effect = _convert(ctx, frame, child, child_tf, out_dir, f"{name}_{i + 1}")
            except _Drop:
                raise _Drop("group")
            out += elements
            effects += effect
        return out, effects
    raise _Drop("other")  # AlternateContent·contentPart 등


def _item_bbox(ctx, el, tf=(1, 0, 1, 0)):
    xfrm = ctx.xfrm(el) if _local(el.tag) != "grpSp" else el.find(f"{_P}grpSpPr/{_A}xfrm")
    if xfrm is None or xfrm.find(f"{_A}off") is None or xfrm.find(f"{_A}ext") is None:
        return (float("-inf"),) * 2 + (float("inf"),) * 2  # 모르면 다 덮는다고 본다
    return _bbox(xfrm, tf)


def _slide_title(slide):
    for shape in slide.placeholders:
        if _ph_info(shape._element) and _ph_info(shape._element)[0] in ("title", "ctrTitle") and shape.has_text_frame:
            text = shape.text_frame.text.strip()
            if text:
                return text.splitlines()[0].strip()
    return None


def convert_slide(prs, slide, index, frame, out_dir, theme_cache):
    """슬라이드 하나 → (결과 dict, 사본에서 지울 도형 목록)."""
    ctx = _Slide(prs, slide, theme_cache)
    tree = slide._element.find(f"{_P}cSld/{_P}spTree")
    items = [c for c in tree if _local(c.tag) not in ("nvGrpSpPr", "grpSpPr", "extLst")]
    results = []  # (el, elements | None, reason, effects)
    for n, el in enumerate(items):
        try:
            elements, effects = _convert(ctx, frame, el, (1, 0, 1, 0), out_dir, f"s{index:03d}_{n + 1}")
            results.append([el, elements, None, effects])
        except _Drop as drop:
            results.append([el, None, drop.args[0], 0])
        except Exception as error:  # 이상한 도형 하나 때문에 가져오기 전체가 죽지 않게
            print(json.dumps({"warning": f"슬라이드 {index} 도형을 그림으로 둡니다: {error}"}, ensure_ascii=True), file=sys.stderr)
            results.append([el, None, "other", 0])
    # 그림으로 남는 도형이 위에서 덮는 그림·도형은 같이 그림으로 둔다 — 요소는 늘 배경 그림 위에 그려져
    # 겹침 순서가 뒤집히니까(사진 위 말풍선). 글 상자는 고칠 수 있는 게 목적이라 그대로 요소로 둔다.
    covers = []
    for r in reversed(results):
        el, elements, reason, _ = r
        if reason is not None:
            covers.append(_item_bbox(ctx, el))
        elif (
            elements
            and any(e["type"] != "text" for e in elements)
            and any(_overlaps(_item_bbox(ctx, el), c) for c in covers)
        ):
            for e in elements:
                if e["type"] == "image":
                    Path(e["path"]).unlink(missing_ok=True)
            r[1], r[2] = None, "covered"
            covers.append(_item_bbox(ctx, el))
    dropped = {}
    for _, _, reason, _ in results:
        if reason:
            dropped[reason] = dropped.get(reason, 0) + 1
    return {
        "index": index,
        "hidden": False,
        "title": _slide_title(slide),
        "background_png": None,
        "elements": [e for r in results if r[1] for e in r[1]],
        "dropped": dropped,
        "effects_lost": sum(r[3] for r in results if r[2] is None),
    }, [r[0] for r in results if r[2] is None]


# ── 글꼴 ──────────────────────────────────────────────────────────────

def _font_dirs():
    home = Path.home()
    if sys.platform == "win32":
        windir = Path(os.environ.get("WINDIR", r"C:\Windows"))
        local = os.environ.get("LOCALAPPDATA")
        return [windir / "Fonts"] + ([Path(local) / "Microsoft" / "Windows" / "Fonts"] if local else [])
    if sys.platform == "darwin":
        from glob import glob
        return [Path(p) for p in (
            "/System/Library/Fonts", "/Library/Fonts", str(home / "Library" / "Fonts"),
            *glob("/System/Library/AssetsV2/com_apple_MobileAsset_Font*"),
        )]
    return [Path("/usr/share/fonts"), Path("/usr/local/share/fonts"), home / ".fonts", home / ".local/share/fonts"]


def _font_names(data):
    """TTF/OTF/TTC 바이트 → family 이름들(name ID 1·4·16, 모든 언어)."""
    offsets = [0]
    if data[:4] == b"ttcf":
        count = struct.unpack(">I", data[8:12])[0]
        offsets = list(struct.unpack(f">{count}I", data[12:12 + 4 * count]))
    names = set()
    for base in offsets:
        num = struct.unpack(">H", data[base + 4:base + 6])[0]
        for i in range(num):
            rec = base + 12 + 16 * i
            if data[rec:rec + 4] != b"name":
                continue
            table = struct.unpack(">I", data[rec + 8:rec + 12])[0]
            _, count, strings = struct.unpack(">HHH", data[table:table + 6])
            for j in range(count):
                platform, enc, _, name_id, length, off = struct.unpack(">6H", data[table + 6 + 12 * j:table + 18 + 12 * j])
                if name_id not in (1, 4, 16):
                    continue
                raw = data[table + strings + off:table + strings + off + length]
                if platform in (0, 3):
                    names.add(raw.decode("utf-16-be", "ignore"))
                elif platform == 1 and enc == 0:
                    names.add(raw.decode("mac_roman", "ignore"))
    return names


def installed_fonts():
    """이 PC 에 깔린 글꼴 이름(한글·영문 이름 모두)."""
    names = set(APP_FONTS)
    for folder in _font_dirs():
        if not folder.is_dir():
            continue
        for root, _, files in os.walk(folder):
            for file in files:
                if file.lower().endswith((".ttf", ".otf", ".ttc")):
                    try:
                        names |= _font_names(Path(root, file).read_bytes())
                    except (OSError, struct.error, ValueError):
                        pass
    return {n.strip() for n in names if n.strip()}


def _used_fonts(slides):
    used = set()
    for s in slides:
        for e in s["elements"]:
            if "font_family" in e and e.get("text"):
                used.add(e["font_family"])
            for op in json.loads(e.get("rich") or "[]"):
                font = op.get("attributes", {}).get("font")
                if font:
                    used.add(font)
    return used


# ── 두 번 굽기 ────────────────────────────────────────────────────────

def _bake_backgrounds(prs, slides, removals, out_dir, to_pdf):
    """요소로 바꾼 도형을 지운 사본을 구워 slides[i]['background_png'] 를 채운다."""
    import pymupdf
    from PIL import Image

    for slide in prs.slides:
        root = slide._element
        root.attrib.pop("show", None)  # 숨긴 장도 굽는다 — 쪽 번호 = 슬라이드 번호로 맞추려고
        timing = root.find(f"{_P}timing")
        if timing is not None:
            root.remove(timing)  # 지운 도형을 가리키는 애니메이션이 남지 않게
    for el in removals:
        parent = el.getparent()
        if parent is not None:
            parent.remove(el)
    with tempfile.TemporaryDirectory(prefix="praise_ppt_layout_") as temp:
        stripped = Path(temp) / "layout.pptx"
        prs.save(str(stripped))
        pdf_dir = Path(temp) / "pdf"
        pdf_dir.mkdir()
        pdf_path = to_pdf(stripped, pdf_dir)
        pymupdf.TOOLS.mupdf_display_errors(False)
        pymupdf.TOOLS.mupdf_display_warnings(False)
        with pymupdf.open(str(pdf_path)) as document:
            if document.page_count != len(slides):
                raise RuntimeError(f"구운 쪽 수({document.page_count})가 슬라이드 수({len(slides)})와 다릅니다")
            for page, info in zip(document, slides):
                if info["hidden"]:
                    continue
                zoom = min(CANVAS_W / max(page.rect.width, 1), CANVAS_H / max(page.rect.height, 1))
                pixmap = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom))
                image = Image.frombytes("RGB", (pixmap.width, pixmap.height), pixmap.samples)
                if image.size != (CANVAS_W, CANVAS_H):
                    canvas = Image.new("RGB", (CANVAS_W, CANVAS_H), "black")
                    canvas.paste(image, ((CANVAS_W - image.width) // 2, (CANVAS_H - image.height) // 2))
                    image = canvas
                path = Path(out_dir) / f"bg_{info['index']:03d}.png"
                image.save(path)
                info["background_png"] = str(path)


def layout_presentation(pptx_path, out_dir, to_pdf=None, source_name=None):
    """pptx → 결과 dict. to_pdf(pptx, 폴더) → pdf 경로를 주면 배경 그림까지 굽는다(None 이면 굽지 않음 — 테스트용)."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    prs = Presentation(str(pptx_path))
    width, height = prs.slide_width, prs.slide_height
    frame = _Frame(width, height)
    theme_cache, slides, removals = {}, [], []
    for index, slide in enumerate(prs.slides, start=1):
        if slide._element.get("show") in ("0", "false"):
            slides.append({
                "index": index, "hidden": True, "title": _slide_title(slide), "background_png": None,
                "elements": [], "dropped": {}, "effects_lost": 0,
            })
            continue
        info, remove = convert_slide(prs, slide, index, frame, out_dir, theme_cache)
        slides.append(info)
        removals += remove
    if to_pdf is not None:
        _bake_backgrounds(prs, slides, removals, out_dir, to_pdf)
    used = _used_fonts(slides)
    installed = installed_fonts() if used else set()
    return {
        "source_name": source_name or Path(pptx_path).name,
        "slide_size": {"width": width, "height": height},
        "aspect": round(width / height, 4),
        "letterboxed": abs(width / height - CANVAS_ASPECT) > 0.01,
        "slides": slides,
        "fonts": sorted(used),
        "fonts_missing": sorted(used - installed),
    }
