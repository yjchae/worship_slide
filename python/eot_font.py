"""PPT 에 심은 글꼴(ppt/fonts/*.fntdata = EOT, 대개 MicroType Express 압축)을 TrueType 으로 되살린다.

LibreOffice 는 이 글꼴을 못 읽어 대체 글꼴로 그리고, 심은 글꼴에 '미리 보기/인쇄만 허용'이 섞여 있으면
macOS PowerPoint 는 문서를 잠가 PDF 로 저장하지 않는다. 그래서 렌더 때만 TTF 로 풀어 LibreOffice 에 넘긴다.

구현은 W3C MTX 명세(https://www.w3.org/Submission/MTX/)를 그대로 옮겼다. 'hdmx'·'VDMX'(힌팅 결과 캐시)는
되살리지 않고 뺀다 — 없어도 글꼴은 똑같이 그려진다.
"""

import struct

_TTEMBED_TTCOMPRESSED = 0x4
_TTEMBED_XORENCRYPTDATA = 0x10000000


def eot_fs_type(data):
    """EOT 머리의 fsType (OS/2 의 글꼴 포함 권한). 0x2 = 포함 금지, 0x4 = 미리 보기/인쇄만."""
    return struct.unpack_from("<H", data, 32)[0]


def eot_to_ttf(data):
    eot_size, font_data_size, _version, flags = struct.unpack_from("<IIII", data, 0)
    if struct.unpack_from("<H", data, 34)[0] != 0x504C:
        raise ValueError("EOT 가 아닙니다")
    font = data[eot_size - font_data_size:eot_size]
    if flags & _TTEMBED_XORENCRYPTDATA:
        font = bytes(b ^ 0x50 for b in font)
    if flags & _TTEMBED_TTCOMPRESSED:
        font = _mtx_to_ttf(font)
    return font


# ---------------------------------------------------------------- LZCOMP (명세 3장·부록 C)

class _BitReader:
    def __init__(self, data):
        self.data = data
        self.pos = 0
        self.bit = 0

    def read_bit(self):
        byte = self.data[self.pos]  # 끝을 넘으면 IndexError = 깨진 파일
        value = (byte >> (7 - self.bit)) & 1
        self.bit += 1
        if self.bit == 8:
            self.bit = 0
            self.pos += 1
        return value

    def read_value(self, bits):
        value = 0
        for _ in range(bits):
            value = (value << 1) | self.read_bit()
        return value


class _AdaptiveHuffman:
    """명세 AHUFF.C. 노드 i 의 부모는 up[i], 1 이 뿌리, 잎은 code >= 0."""

    def __init__(self, bits, size):
        self.bits = bits
        n = 2 * size
        self.up = [i // 2 for i in range(n)]
        self.left = [2 * i for i in range(n)]
        self.right = [2 * i + 1 for i in range(n)]
        self.code = [-1] * size + list(range(size))
        self.weight = [1] * n
        self.symbol_index = [size + i for i in range(size)]
        for i in range(size - 1, 0, -1):
            self.weight[i] = self.weight[2 * i] + self.weight[2 * i + 1]
        bit_count2 = 0
        if 256 < size < 512:
            bit_count2 = (size - 256 - 1).bit_length() + 1
        if bit_count2:
            self._update(self.symbol_index[256])
            self._update(self.symbol_index[257])
            for _ in range(12):
                self._update(self.symbol_index[size - 3])  # DUP2
            for _ in range(6):
                self._update(self.symbol_index[size - 2])  # DUP4
        else:
            for _ in range(2):
                for i in range(size):
                    self._update(self.symbol_index[i])

    def _swap(self, a, b):
        up, left, right, code, weight = self.up, self.left, self.right, self.code, self.weight
        upa, upb = up[a], up[b]
        left[a], left[b] = left[b], left[a]
        right[a], right[b] = right[b], right[a]
        code[a], code[b] = code[b], code[a]
        weight[a], weight[b] = weight[b], weight[a]
        for node in (a, b):
            if code[node] < 0:
                up[left[node]] = node
                up[right[node]] = node
            else:
                self.symbol_index[code[node]] = node
        up[a], up[b] = upa, upb

    def _update(self, a):
        weight, up = self.weight, self.up
        while a != 1:
            w = weight[a]
            b = a - 1
            if weight[b] == w:
                while weight[b] == w:
                    b -= 1
                b += 1
                if b > 1:
                    self._swap(a, b)
                    a = b
            weight[a] = w + 1
            a = up[a]
        weight[a] += 1

    def read(self):
        a = 1
        code, left, right, bits = self.code, self.left, self.right, self.bits
        while True:
            a = right[a] if bits.read_bit() else left[a]
            if code[a] >= 0:
                break
        symbol = code[a]
        self._update(a)  # 노드를 맞바꾸므로 기호는 먼저 꺼내 둔다
        return symbol


_PRELOAD = bytes(
    [v for k in range(32) for j in range(96) for v in (k, j)]
    + [j for j in range(256) for _ in range(4)]
)


def _lzcomp_decompress(data):
    bits = _BitReader(data)
    run_length = bits.read_bit()
    dist = _AdaptiveHuffman(bits, 8)
    length_coder = _AdaptiveHuffman(bits, 8)
    out_len = bits.read_value(24)
    ranges = 1
    while 1 + (1 << (3 * ranges)) - 1 < out_len:
        ranges += 1
    dup2 = 256 + 8 * ranges
    symbols = _AdaptiveHuffman(bits, dup2 + 3)

    buf = bytearray(_PRELOAD)
    start = len(buf)
    while len(buf) - start < out_len:
        symbol = symbols.read()
        if symbol < 256:
            buf.append(symbol)
        elif symbol >= dup2:
            buf.append(buf[-2 * (symbol - dup2 + 1)])
        else:
            value = symbol - 256
            dist_ranges = value // 8 + 1
            value %= 8
            length = 0
            while True:
                length = (length << 2) | (value & 3)
                if not value & 4:
                    break
                value = length_coder.read()
            length += 2
            distance = 0
            for _ in range(dist_ranges):
                distance = (distance << 3) | dist.read()
            distance += 1
            if distance >= 512:
                length += 1
            src = len(buf) - distance - length + 1
            for j in range(length):  # 겹치는 복사라 한 바이트씩
                buf.append(buf[src + j])
    out = bytes(buf[start:start + out_len])
    if run_length:
        out = _run_length_decode(out)
    return out


def _run_length_decode(data):
    if not data:
        return data
    escape = data[0]
    out = bytearray()
    i, n = 1, len(data)
    while i < n:
        b = data[i]
        if b != escape:
            out.append(b)
            i += 1
        elif data[i + 1] == 0:
            out.append(escape)
            i += 2
        else:
            out += bytes([data[i + 2]]) * data[i + 1]
            i += 3
    return bytes(out)


# ---------------------------------------------------------------- CTF → TTF (명세 4~7장)

class _Reader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def u8(self):
        v = self.data[self.pos]
        self.pos += 1
        return v

    def u16(self):
        v = struct.unpack_from(">H", self.data, self.pos)[0]
        self.pos += 2
        return v

    def s16(self):
        v = struct.unpack_from(">h", self.data, self.pos)[0]
        self.pos += 2
        return v

    def take(self, n):
        v = self.data[self.pos:self.pos + n]
        self.pos += n
        return v

    def u255(self):
        code = self.u8()
        if code == 253:
            return self.u16()
        if code == 255:
            return 253 + self.u8()
        if code == 254:
            return 506 + self.u8()
        return code

    def s255(self):
        code = self.u8()
        if code == 253:
            return self.s16()
        sign = 1
        if code == 250:
            sign = -1
            code = self.u8()
        if code == 255:
            return sign * (250 + self.u8())
        if code == 254:
            return sign * (500 + self.u8())
        return sign * code


def _triplet(flag, r):
    """명세 5.11 표 (WOFF2 와 같은 표다)."""

    def signed(f, base):
        return base if f & 1 else -base

    if flag < 10:
        return 0, signed(flag, ((flag & 14) << 7) + r.u8())
    if flag < 20:
        return signed(flag, (((flag - 10) & 14) << 7) + r.u8()), 0
    if flag < 84:
        b0, b1 = flag - 20, r.u8()
        return signed(flag, 1 + (b0 & 0x30) + (b1 >> 4)), signed(flag >> 1, 1 + ((b0 & 0x0C) << 2) + (b1 & 0x0F))
    if flag < 120:
        b0 = flag - 84
        b1, b2 = r.u8(), r.u8()
        return signed(flag, 1 + ((b0 // 12) << 8) + b1), signed(flag >> 1, 1 + (((b0 % 12) >> 2) << 8) + b2)
    if flag < 124:
        b1, b2, b3 = r.u8(), r.u8(), r.u8()
        return signed(flag, (b1 << 4) + (b2 >> 4)), signed(flag >> 1, ((b2 & 0x0F) << 8) + b3)
    b1, b2, b3, b4 = r.u8(), r.u8(), r.u8(), r.u8()
    return signed(flag, (b1 << 8) + b2), signed(flag >> 1, (b3 << 8) + b4)


def _push_data(r, count):
    values = []
    while len(values) < count:
        code = r.data[r.pos]
        if code == 251:  # Hop3: A, X, A
            r.pos += 1
            a = values[-2]
            values += [a, r.s255(), a]
        elif code == 252:  # Hop4: A, X1, A, X2, A
            r.pos += 1
            a = values[-2]
            values += [a, r.s255(), a, r.s255(), a]
        else:
            values.append(r.s255())
    return values[:count]


def _push_instructions(values):
    out = bytearray()
    for i in range(0, len(values), 255):
        chunk = values[i:i + 255]
        if all(0 <= v <= 255 for v in chunk):
            out += bytes([0xB0 + len(chunk) - 1]) if len(chunk) <= 8 else bytes([0x40, len(chunk)])
            out += bytes(chunk)
        else:
            out += bytes([0xB8 + len(chunk) - 1]) if len(chunk) <= 8 else bytes([0x41, len(chunk)])
            out += b"".join(struct.pack(">h", v) for v in chunk)
    return bytes(out)


def _instructions(glyf, push, code):
    push_count = glyf.u255()
    code_size = glyf.u255()
    return _push_instructions(_push_data(push, push_count)) + code.take(code_size)




def _glyph(glyf, push, code):
    num_contours = glyf.s16()
    if num_contours == 0:
        return b""
    if num_contours < 0:  # 합성 글리프: 상자 + TTF 와 같은 부품 목록
        bbox = glyf.take(8)
        start = glyf.pos
        while True:
            flags = glyf.u16()
            glyf.pos += 2  # glyphIndex
            glyf.pos += 4 if flags & 0x1 else 2
            if flags & 0x8:
                glyf.pos += 2
            elif flags & 0x40:
                glyf.pos += 4
            elif flags & 0x80:
                glyf.pos += 8
            if not flags & 0x20:
                break
        out = struct.pack(">h", -1) + bbox + glyf.data[start:glyf.pos]
        if flags & 0x100:
            program = _instructions(glyf, push, code)
            out += struct.pack(">H", len(program)) + program
        return out

    bbox = None
    if num_contours == 0x7FFF:
        num_contours = glyf.s16()
        bbox = glyf.take(8)
    # 첫 값은 첫 윤곽의 끝점 번호(= 점 수 - 1), 나머지는 윤곽마다 점 수다(명세 5.7.2).
    end_points = [glyf.u255()]
    for _ in range(num_contours - 1):
        end_points.append(end_points[-1] + glyf.u255())
    total = end_points[-1] + 1
    flags = glyf.take(total)
    xs, ys, x, y = [], [], 0, 0
    for flag in flags:
        dx, dy = _triplet(flag & 0x7F, glyf)
        x += dx
        y += dy
        xs.append(x)
        ys.append(y)
    program = _instructions(glyf, push, code)
    if bbox is None:
        bbox = struct.pack(">4h", min(xs), min(ys), max(xs), max(ys))

    out_flags, out_x, out_y = bytearray(), bytearray(), bytearray()
    px = py = 0
    for flag, x, y in zip(flags, xs, ys):
        f = 0 if flag & 0x80 else 1
        for delta, short, same, buf in ((x - px, 0x2, 0x10, out_x), (y - py, 0x4, 0x20, out_y)):
            if delta == 0:
                f |= same
            elif -255 <= delta <= 255:
                f |= short | (same if delta > 0 else 0)
                buf.append(abs(delta))
            else:
                buf += struct.pack(">h", delta)
        out_flags.append(f)
        px, py = x, y
    return (
        struct.pack(">h", num_contours) + bbox
        + struct.pack(f">{num_contours}H", *end_points)
        + struct.pack(">H", len(program)) + program
        + out_flags + out_x + out_y
    )


def _cvt(data):
    r = _Reader(data)
    values, last = [], 0
    for _ in range(r.u16()):
        c = r.u8()
        if c < 238:
            v = c
        elif c >= 248:
            v = r.u8() + (c - 247) * 238
        elif c >= 239:
            v = -(r.u8() + (c - 239) * 238)
        else:
            v = r.s16()
        last = (last + v) & 0xFFFF
        values.append(last)
    return struct.pack(f">{len(values)}H", *values)


def _mtx_to_ttf(data):
    if data[0] != 3:
        raise ValueError(f"MTX 버전이 다릅니다: {data[0]}")
    offset2 = int.from_bytes(data[4:7], "big")
    offset3 = int.from_bytes(data[7:10], "big")
    ctf = _lzcomp_decompress(data[10:offset2])
    push = _Reader(_lzcomp_decompress(data[offset2:offset3]) if offset3 > offset2 else b"")
    code = _Reader(_lzcomp_decompress(data[offset3:]) if len(data) > offset3 else b"")

    num_tables = struct.unpack_from(">H", ctf, 4)[0]
    tables = {}
    for i in range(num_tables):
        tag, _checksum, offset, length = struct.unpack_from(">4sIII", ctf, 12 + 16 * i)
        tables[tag] = ctf[offset:offset + length]

    num_glyphs = struct.unpack_from(">H", tables[b"maxp"], 4)[0]
    glyf_reader = _Reader(tables[b"glyf"])
    glyf, loca = bytearray(), [0]
    for _ in range(num_glyphs):
        glyf += _glyph(glyf_reader, push, code)
        glyf += b"\0" * (-len(glyf) % 4)
        loca.append(len(glyf))
    tables[b"glyf"] = bytes(glyf)
    tables[b"loca"] = struct.pack(f">{len(loca)}I", *loca)
    head = bytearray(tables[b"head"])
    struct.pack_into(">h", head, 50, 1)  # indexToLocFormat = long
    tables[b"head"] = bytes(head)
    if b"cvt " in tables:
        tables[b"cvt "] = _cvt(tables[b"cvt "])
    for tag in (b"hdmx", b"VDMX", b"DSIG"):  # hdmx·VDMX 는 힌팅 캐시라 없어도 된다. 서명은 맞지 않게 된다
        tables.pop(tag, None)
    return _build_sfnt(tables)


def _checksum(data):
    data += b"\0" * (-len(data) % 4)
    return sum(struct.unpack(f">{len(data) // 4}I", data)) & 0xFFFFFFFF


def _build_sfnt(tables):
    tags = sorted(tables)
    n = len(tags)
    entry_selector = n.bit_length() - 1
    search_range = 16 << entry_selector
    header = struct.pack(">IHHHH", 0x00010000, n, search_range, entry_selector, n * 16 - search_range)
    head = bytearray(tables[b"head"])
    struct.pack_into(">I", head, 8, 0)
    tables[b"head"] = bytes(head)
    directory, body = bytearray(), bytearray()
    offset = 12 + 16 * n
    for tag in tags:
        data = tables[tag]
        directory += struct.pack(">4sIII", tag, _checksum(data), offset + len(body), len(data))
        body += data + b"\0" * (-len(data) % 4)
    font = bytearray(header + directory + body)
    head_offset = 12 + 16 * n + sum(len(tables[t]) + (-len(tables[t]) % 4) for t in tags[:tags.index(b"head")])
    struct.pack_into(">I", font, head_offset + 8, (0xB1B0AFBA - _checksum(bytes(font))) & 0xFFFFFFFF)
    return bytes(font)
