#!/usr/bin/env python3
"""Sinh vector kiểm thử ZRLE bằng một bộ MÃ HÓA độc lập, bao phủ cả bảy loại tile.

Server Apple (macOS 27) chỉ gửi tile raw, nên dữ liệu thật không kiểm tra được các loại còn lại.
Script này dựng ảnh có pixel đúng biết trước, mã hóa từng tile bằng một loại cụ thể theo RFC 6143
mục 7.7.6, nén bằng một luồng zlib liên tục (đồng bộ bằng Z_SYNC_FLUSH sau mỗi hình chữ nhật), rồi ghi
vector cho test Swift. Test Swift phải giải ra đúng ảnh gốc (so bằng MD5 của toàn bộ framebuffer).

Để chạy lại:  python3 -I Tools/replay-check/make_zrle_fixture.py
"""
import hashlib
import os
import sys
import zlib

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from collections import Counter

from zrle_replay import decode_zrle  # bộ giải mã Python, chỉ dùng để tự kiểm tra bộ mã hóa này

TILE = 64
rng = np.random.default_rng(20261014)


def colour():
    return rng.integers(0, 256, 3, dtype=np.uint8)


def run_length_bytes(length):
    """Mã hóa độ dài lượt chạy L: tổng các byte bằng L-1, byte 255 nghĩa là còn tiếp."""
    value, out = length - 1, []
    while value >= 255:
        out.append(255)
        value -= 255
    out.append(value)
    return bytes(out)


def runs_for(n, choices):
    """Chia n pixel thành các lượt chạy có độ dài lấy từ `choices` (lượt cuối bị cắt cho vừa)."""
    runs, remaining = [], n
    while remaining > 0:
        length = min(int(rng.choice(choices)), remaining)
        runs.append(length)
        remaining -= length
    return runs


def encode_tile(kind, tw, th):
    """Trả về (byte mã hóa, mảng pixel (th, tw, 3) BGR đúng)."""
    n = tw * th
    if kind == "raw":
        pixels = rng.integers(0, 256, (th, tw, 3), dtype=np.uint8)
        return bytes([0]) + pixels.tobytes(), pixels

    if kind == "solid":
        c = colour()
        return bytes([1]) + c.tobytes(), np.broadcast_to(c, (th, tw, 3)).copy()

    if kind.startswith("pal") and not kind.startswith("prle"):  # palette đóng gói bit
        k = int(kind[3:])
        palette = rng.integers(0, 256, (k, 3), dtype=np.uint8)
        index = rng.integers(0, k, (th, tw), dtype=np.uint8)
        index.flat[:k] = np.arange(k) % k  # đảm bảo mọi chỉ số đều xuất hiện nếu đủ pixel
        bits = 1 if k == 2 else (2 if k <= 4 else 4)
        bit_matrix = np.unpackbits(index[..., None], axis=2)[:, :, 8 - bits :].reshape(th, tw * bits)
        packed = np.packbits(bit_matrix, axis=1)  # mỗi hàng đệm số 0 tới byte
        return bytes([k]) + palette.tobytes() + packed.tobytes(), palette[index]

    if kind in ("rle", "rleLong"):  # RLE thường
        choices = [1, 2, 3, 17, 255, 256, 300, 600] if kind == "rleLong" else [1, 2, 5, 40]
        body, flat, filled = b"", np.empty((n, 3), np.uint8), 0
        for length in runs_for(n, choices):
            c = colour()
            body += c.tobytes() + run_length_bytes(length)
            flat[filled : filled + length] = c
            filled += length
        return bytes([0x80]) + body, flat.reshape(th, tw, 3)

    if kind.startswith("prle"):  # RLE có palette
        k = int(kind[4:])
        palette = rng.integers(0, 256, (k, 3), dtype=np.uint8)
        body, flat, filled = b"", np.empty((n, 3), np.uint8), 0
        for length in runs_for(n, [1, 1, 2, 5, 70, 300]):
            index = int(rng.integers(0, k))
            if length == 1 and rng.random() < 0.5:
                body += bytes([index])  # lượt dài 1 không cần cờ
            else:
                body += bytes([0x80 | index]) + run_length_bytes(length)  # kể cả lượt dài 1 mã hóa kiểu có độ dài
            flat[filled : filled + length] = palette[index]
            filled += length
        return bytes([0x80 | k]) + palette.tobytes() + body, flat.reshape(th, tw, 3)

    raise ValueError(kind)


def build_rect(w, h, kinds):
    """Mã hóa một hình chữ nhật w×h; tile thứ i dùng loại kinds[i % len(kinds)]."""
    data, image, seen = b"", np.zeros((h, w, 3), np.uint8), Counter()
    i = 0
    for ty in range(0, h, TILE):
        th = min(TILE, h - ty)
        for tx in range(0, w, TILE):
            tw = min(TILE, w - tx)
            kind = kinds[i % len(kinds)]
            encoded, pixels = encode_tile(kind, tw, th)
            data += encoded
            image[ty : ty + th, tx : tx + tw] = pixels
            seen[kind] += 1
            i += 1
    return data, image, seen


W, H = 256, 160
KINDS_A = ["solid", "pal2", "pal3", "pal4", "pal5", "pal9", "pal16", "rle", "prle3", "prle40", "raw", "rleLong"]
KINDS_B = ["prle3", "pal16", "rleLong", "solid"]
RECTS = [(0, 0, 200, 136, KINDS_A), (150, 70, 70, 70, KINDS_B)]  # hình thứ hai chồng lên hình thứ nhất, lệch lưới 64

stream = zlib.compressobj(level=6)
framebuffer = np.zeros((H, W, 3), np.uint8)
lines = [
    "// Tệp sinh tự động bởi Tools/replay-check/make_zrle_fixture.py. Không sửa tay.",
    "// Bộ MÃ HÓA ZRLE độc lập (Python) tạo ảnh có pixel đúng biết trước, bao phủ mọi loại tile, nén bằng một luồng zlib liên tục.",
    "enum ZRLERoundTripVectors {",
    f"    static let width = {W}",
    f"    static let height = {H}",
    "    /// (x, y, rộng, cao, dữ liệu nén hex). Giải tuần tự bằng CÙNG một decoder vì luồng zlib liên tục.",
    "    static let rects: [(x: Int, y: Int, width: Int, height: Int, compressed: String)] = [",
]
all_seen = Counter()
for x, y, w, h, kinds in RECTS:
    data, image, seen = build_rect(w, h, kinds)
    all_seen += seen
    compressed = stream.compress(data) + stream.flush(zlib.Z_SYNC_FLUSH)

    # Tự kiểm tra: bộ giải mã Python phải dựng lại đúng ảnh gốc từ dữ liệu đã mã hóa (chưa nén).
    check = decode_zrle(data, w, h, Counter())
    assert np.array_equal(check, image), "bộ mã hóa và bộ giải mã Python không khớp nhau"

    framebuffer[y : y + h, x : x + w] = image
    lines.append(f"        ({x}, {y}, {w}, {h}, \"{compressed.hex()}\"),")
    print(f"hình chữ nhật {w}x{h} tại ({x},{y}): {len(data)} byte ZRLE → {len(compressed)} byte nén")
lines.append("    ]")

bgra = np.zeros((H, W, 4), np.uint8)
bgra[:, :, :3] = framebuffer
lines.append(f'    /// MD5 của toàn bộ framebuffer BGRA sau khi áp dụng mọi hình chữ nhật (byte thứ tư luôn 0).')
lines.append(f'    static let expectedMD5 = "{hashlib.md5(bgra.tobytes()).hexdigest()}"')
lines.append(f'    static let tileKinds = {sorted(all_seen)!r}'.replace("'", '"'))
lines.append("}")
out = os.path.join(os.path.dirname(__file__), "..", "..", "Tests", "RFBKitTests", "ZRLERoundTripVectors.swift")
open(out, "w").write("\n".join(lines) + "\n")
print("tile đã dùng:", dict(all_seen))
print("đã ghi", os.path.normpath(out))
