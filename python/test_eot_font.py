"""PPT 심은 글꼴(EOT/MTX) 풀기 self-check: python3 python/test_eot_font.py [글꼴을 심은 pptx]

LibreOffice 불필요. MTX 를 만드는 도구가 없어 압축 해제 전체는 pptx 를 넘겨 줄 때만 본다
(저작권 글꼴이라 저장소에 표본을 못 둔다). 나머지는 명세의 예시 값으로 조각마다 확인한다.
"""
import os
import struct
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import eot_font as E


def main():
    # 255USHORT / 255SHORT (명세 6.1)
    r = E._Reader(bytes([7, 255, 1, 254, 1, 253, 0x12, 0x34]))
    assert [r.u255(), r.u255(), r.u255(), r.u255()] == [7, 254, 507, 0x1234]
    r = E._Reader(bytes([250, 5, 255, 0, 250, 254, 3]))
    assert [r.s255(), r.s255(), r.s255()] == [-5, 250, -503]

    # Hop3 = A,X1,A,X2,A / Hop4 = A,X1,A,X2,A,X3,A (명세 6.2)
    assert E._push_data(E._Reader(bytes([9, 1, 251, 2])), 5) == [9, 1, 9, 2, 9]
    assert E._push_data(E._Reader(bytes([9, 1, 252, 2, 3])), 7) == [9, 1, 9, 2, 9, 3, 9]
    # PUSHB 로 바이트 값, 범위를 넘으면 PUSHW
    assert E._push_instructions([1, 2]) == bytes([0xB1, 1, 2])
    assert E._push_instructions([-1]) == bytes([0xB8]) + struct.pack(">h", -1)

    # cvt: 앞 값과의 차이를 1~3 바이트로 (명세 5.2)
    cvt = struct.pack(">H", 4) + bytes([5, 248, 0, 239, 3, 238]) + struct.pack(">h", -300)
    assert struct.unpack(">4h", E._cvt(cvt)) == (5, 5 + 238, 5 + 238 - 3, 5 + 238 - 3 - 300)

    # 좌표 세 쌍 (명세 5.11 표): 0번 = dx 0, dy -(바이트), 125번 = (+X 16비트, -Y 16비트)
    assert E._triplet(0, E._Reader(bytes([7]))) == (0, -7)
    assert E._triplet(11, E._Reader(bytes([7]))) == (7, 0)
    assert E._triplet(20, E._Reader(bytes([0x00]))) == (-1, -1)
    assert E._triplet(125, E._Reader(bytes([1, 0, 0, 2]))) == (256, -2)

    # 런 렝스: 첫 바이트가 탈출 문자, (탈출, 0) = 탈출 문자 하나, (탈출, n, b) = b 를 n 번
    assert E._run_length_decode(bytes([9, 1, 9, 0, 9, 4, 7, 2])) == bytes([1, 9, 7, 7, 7, 7, 2])

    if len(sys.argv) > 1:
        with zipfile.ZipFile(sys.argv[1]) as archive:
            for name in archive.namelist():
                if name.startswith("ppt/fonts/") and name.endswith(".fntdata"):
                    ttf = E.eot_to_ttf(archive.read(name))
                    assert ttf[:4] == b"\0\1\0\0", name
                    print(name, "->", len(ttf), "bytes")
    print("ok")


if __name__ == "__main__":
    main()
