#!/usr/bin/env python3
"""Kiểm chứng giải mã RFB bằng một bộ giải mã ĐỘC LẬP với code Swift.

Đầu vào:
  1. Bản ghi byte server → client do `rfbprobe --record` tạo (sau ServerInit).
  2. Khung hình BGRA do decoder Swift dựng từ cùng các byte đó (`rfbprobe --dump-frame`).

Script giải mã lại bản ghi bằng numpy và zlib của Python (không dùng lại bất kỳ dòng nào của Swift)
rồi so từng pixel. Cả hai bên giải mã CÙNG dữ liệu, nên kết quả không phụ thuộc màn hình có đang
chuyển động hay không, khác với việc so với một khung Raw lấy ở thời điểm khác.

Nó cũng thống kê các loại tile ZRLE thật sự xuất hiện, để biết trường hợp nào đã được kiểm chứng.

Dùng:  zrle_replay.py LOG.bin SWIFT.bgra WIDTH HEIGHT
Chạy bằng:  python3 -I zrle_replay.py ...   (cần numpy)

Lưu ý: bản ghi chứa nội dung màn hình. Không commit và nên xóa sau khi dùng.
"""
import struct
import sys
import zlib
from collections import Counter

import numpy as np

TILE = 64
ENC_RAW, ENC_COPYRECT, ENC_ZRLE, ENC_CURSOR = 0, 1, 16, -239


class Truncated(Exception):
    """Bản ghi bị cắt giữa một message (do đóng kết nối lúc hết giờ). Phần đã đủ vẫn được áp dụng."""


def run_length(data, pos):
    """Độ dài lượt chạy ZRLE: 1 cộng tổng các byte, byte 255 nghĩa là còn tiếp."""
    total = 1
    while True:
        byte = data[pos]
        pos += 1
        total += byte
        if byte != 255:
            return total, pos


def decode_zrle(data, w, h, tile_kinds):
    """Giải mã một hình chữ nhật ZRLE đã giải nén. Trả về mảng (h, w, 3) theo thứ tự B, G, R."""
    out = np.zeros((h, w, 3), np.uint8)
    pos = 0
    for ty in range(0, h, TILE):
        th = min(TILE, h - ty)
        for tx in range(0, w, TILE):
            tw = min(TILE, w - tx)
            n = tw * th
            sub = data[pos]
            pos += 1
            is_rle, psize = bool(sub & 0x80), sub & 0x7F

            if not is_rle and psize == 0:  # raw
                tile = np.frombuffer(data, np.uint8, 3 * n, pos).reshape(th, tw, 3)
                pos += 3 * n
                kind = "raw"
            elif not is_rle and psize == 1:  # một màu
                tile = np.broadcast_to(np.frombuffer(data, np.uint8, 3, pos), (th, tw, 3))
                pos += 3
                kind = "solid"
            elif not is_rle and 2 <= psize <= 16:  # palette đóng gói bit
                palette = np.frombuffer(data, np.uint8, 3 * psize, pos).reshape(psize, 3)
                pos += 3 * psize
                bits = 1 if psize == 2 else (2 if psize <= 4 else 4)
                row_bytes = (tw * bits + 7) // 8
                packed = np.frombuffer(data, np.uint8, row_bytes * th, pos).reshape(th, row_bytes)
                pos += row_bytes * th
                unpacked = np.unpackbits(packed, axis=1, bitorder="big")[:, : tw * bits].reshape(th, tw, bits)
                weights = (1 << np.arange(bits - 1, -1, -1)).astype(np.uint8)
                index = (unpacked * weights).sum(axis=2)
                if index.max() >= psize:
                    raise ValueError(f"chỉ số palette {index.max()} >= {psize}")
                tile = palette[index]
                kind = f"palette {bits}-bit"
            elif is_rle and psize == 0:  # RLE thường
                flat = np.empty((n, 3), np.uint8)
                filled = 0
                while filled < n:
                    colour = np.frombuffer(data, np.uint8, 3, pos)
                    pos += 3
                    run, pos = run_length(data, pos)
                    if filled + run > n:
                        raise ValueError("lượt chạy vượt tile")
                    flat[filled : filled + run] = colour
                    filled += run
                tile = flat.reshape(th, tw, 3)
                kind = "rle"
            elif is_rle and 2 <= psize <= 127:  # RLE có palette
                palette = np.frombuffer(data, np.uint8, 3 * psize, pos).reshape(psize, 3)
                pos += 3 * psize
                flat = np.empty((n, 3), np.uint8)
                filled = 0
                while filled < n:
                    entry = data[pos]
                    pos += 1
                    index = entry & 0x7F
                    if index >= psize:
                        raise ValueError("chỉ số palette vượt cỡ")
                    run = 1
                    if entry & 0x80:
                        run, pos = run_length(data, pos)
                    if filled + run > n:
                        raise ValueError("lượt chạy vượt tile")
                    flat[filled : filled + run] = palette[index]
                    filled += run
                tile = flat.reshape(th, tw, 3)
                kind = "palette rle"
            else:
                raise ValueError(f"subencoding ZRLE {sub} không hợp lệ")

            out[ty : ty + th, tx : tx + tw] = tile
            tile_kinds[kind] += 1
    if pos != len(data):
        raise ValueError(f"ZRLE còn {len(data) - pos} byte thừa")
    return out


def replay(log, width, height):
    framebuffer = np.zeros((height, width, 3), np.uint8)  # B, G, R
    inflater = zlib.decompressobj()  # MỘT luồng zlib duy nhất cho cả bản ghi, đúng như RFB
    rect_counts, tile_kinds = Counter(), Counter()
    updates = 0
    zrle_in = zrle_out = 0
    pos = 0

    def need(end):
        if end > len(log):
            raise Truncated

    try:
        while pos < len(log):
            kind = log[pos]
            if kind == 0:  # FramebufferUpdate
                need(pos + 4)
                (count,) = struct.unpack_from(">H", log, pos + 2)
                cursor = pos + 4
                updates += 1
                for _ in range(count):
                    need(cursor + 12)
                    x, y, w, h, encoding = struct.unpack_from(">HHHHi", log, cursor)
                    cursor += 12
                    if encoding == ENC_RAW:
                        size = w * h * 4
                        need(cursor + size)
                        framebuffer[y : y + h, x : x + w] = np.frombuffer(log, np.uint8, size, cursor).reshape(h, w, 4)[:, :, :3]
                        cursor += size
                    elif encoding == ENC_ZRLE:
                        need(cursor + 4)
                        (length,) = struct.unpack_from(">I", log, cursor)
                        cursor += 4
                        need(cursor + length)
                        inflated = inflater.decompress(log[cursor : cursor + length])
                        cursor += length
                        framebuffer[y : y + h, x : x + w] = decode_zrle(inflated, w, h, tile_kinds)
                        zrle_in += length
                        zrle_out += len(inflated)
                    elif encoding == ENC_COPYRECT:
                        need(cursor + 4)
                        source_x, source_y = struct.unpack_from(">HH", log, cursor)
                        cursor += 4
                        framebuffer[y : y + h, x : x + w] = framebuffer[source_y : source_y + h, source_x : source_x + w].copy()
                    elif encoding == ENC_CURSOR:
                        size = (w * h * 4 + ((w + 7) // 8) * h) if w and h else 0
                        need(cursor + size)
                        cursor += size
                    else:
                        raise ValueError(f"encoding {encoding} chưa được bộ kiểm chứng hỗ trợ")
                    rect_counts[encoding] += 1
                pos = cursor
            elif kind == 2:  # Bell
                pos += 1
            elif kind == 1:  # SetColourMap
                need(pos + 6)
                (colours,) = struct.unpack_from(">H", log, pos + 4)
                need(pos + 6 + colours * 6)
                pos += 6 + colours * 6
            elif kind == 3:  # ServerCutText
                need(pos + 8)
                (length,) = struct.unpack_from(">I", log, pos + 4)
                need(pos + 8 + length)
                pos += 8 + length
            else:
                raise ValueError(f"loại message {kind} tại offset {pos}")
    except Truncated:
        print("Bản ghi kết thúc giữa một message, bỏ phần dở dang (giống cách decoder Swift dừng).")

    return framebuffer, updates, rect_counts, tile_kinds, zrle_in, zrle_out


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    log_path, swift_path, width, height = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    log = open(log_path, "rb").read()
    swift = np.frombuffer(open(swift_path, "rb").read(), np.uint8)
    if swift.size != width * height * 4:
        sys.exit(f"Khung Swift có {swift.size} byte, cần {width * height * 4}")
    swift = swift.reshape(height, width, 4)[:, :, :3]

    framebuffer, updates, rect_counts, tile_kinds, zrle_in, zrle_out = replay(log, width, height)

    names = {ENC_RAW: "Raw", ENC_COPYRECT: "CopyRect", ENC_ZRLE: "ZRLE", ENC_CURSOR: "Cursor"}
    print(f"\nBản ghi: {len(log) / 1024:.0f} KiB, {updates} FramebufferUpdate")
    print("Hình chữ nhật theo encoding:", {names[k]: v for k, v in sorted(rect_counts.items())})
    if zrle_in:
        print(f"ZRLE: {zrle_in / 1024:.0f} KiB nén → {zrle_out / 1024:.0f} KiB sau giải nén (luồng zlib liên tục)")
    total_tiles = sum(tile_kinds.values())
    if total_tiles:
        print(f"Tile ZRLE thật sự xuất hiện ({total_tiles} tile):")
        for kind, count in tile_kinds.most_common():
            print(f"  {kind:<14} {count:>8}  ({100 * count / total_tiles:5.1f}%)")

    different = np.any(framebuffer != swift, axis=2)
    count = int(different.sum())
    print(f"\nSO SÁNH decoder Python độc lập với decoder Swift trên cùng dữ liệu: {count} pixel khác nhau "
          f"trên {width * height}")
    if count:
        ys, xs = np.nonzero(different)
        print(f"  vùng khác biệt: x {xs.min()}..{xs.max()}, y {ys.min()}..{ys.max()}")
        sys.exit(1)
    print("  KHỚP HOÀN TOÀN")


if __name__ == "__main__":
    main()
