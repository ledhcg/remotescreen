#!/usr/bin/env python3
"""Verifies RFB decoding with a decoder INDEPENDENT of the Swift code.

Inputs:
  1. A recording of server -> client bytes made by `rfbprobe --record` (after ServerInit).
  2. The BGRA frame the Swift decoder built from the same bytes (`rfbprobe --dump-frame`).

The script decodes the recording again with Python's numpy and zlib (reusing nothing from the Swift code)
and compares pixel by pixel. Both sides decode the SAME data, so the result does not depend on whether the screen is
moving, unlike comparing against a Raw frame captured at a different time.

It also counts which ZRLE tile kinds actually occur, to show which cases were verified.

Usage:  zrle_replay.py LOG.bin SWIFT.bgra WIDTH HEIGHT
Run with:  python3 -I zrle_replay.py ...   (needs numpy)

Note: the recording contains screen content. Do not commit it, and delete it after use.
"""
import struct
import sys
import zlib
from collections import Counter

import numpy as np

TILE = 64
ENC_RAW, ENC_COPYRECT, ENC_ZRLE, ENC_CURSOR = 0, 1, 16, -239


class Truncated(Exception):
    """The recording was cut in the middle of a message (the connection was closed at the timeout). The complete part is still applied."""


def run_length(data, pos):
    """ZRLE run length: 1 plus the sum of the bytes; a byte of 255 means more follow."""
    total = 1
    while True:
        byte = data[pos]
        pos += 1
        total += byte
        if byte != 255:
            return total, pos


def decode_zrle(data, w, h, tile_kinds):
    """Decodes one decompressed ZRLE rectangle. Returns an (h, w, 3) array in B, G, R order."""
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
            elif not is_rle and psize == 1:  # single colour
                tile = np.broadcast_to(np.frombuffer(data, np.uint8, 3, pos), (th, tw, 3))
                pos += 3
                kind = "solid"
            elif not is_rle and 2 <= psize <= 16:  # bit-packed palette
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
                    raise ValueError(f"palette index {index.max()} >= {psize}")
                tile = palette[index]
                kind = f"palette {bits}-bit"
            elif is_rle and psize == 0:  # plain RLE
                flat = np.empty((n, 3), np.uint8)
                filled = 0
                while filled < n:
                    colour = np.frombuffer(data, np.uint8, 3, pos)
                    pos += 3
                    run, pos = run_length(data, pos)
                    if filled + run > n:
                        raise ValueError("run exceeds the tile")
                    flat[filled : filled + run] = colour
                    filled += run
                tile = flat.reshape(th, tw, 3)
                kind = "rle"
            elif is_rle and 2 <= psize <= 127:  # palette RLE
                palette = np.frombuffer(data, np.uint8, 3 * psize, pos).reshape(psize, 3)
                pos += 3 * psize
                flat = np.empty((n, 3), np.uint8)
                filled = 0
                while filled < n:
                    entry = data[pos]
                    pos += 1
                    index = entry & 0x7F
                    if index >= psize:
                        raise ValueError("palette index out of range")
                    run = 1
                    if entry & 0x80:
                        run, pos = run_length(data, pos)
                    if filled + run > n:
                        raise ValueError("run exceeds the tile")
                    flat[filled : filled + run] = palette[index]
                    filled += run
                tile = flat.reshape(th, tw, 3)
                kind = "palette rle"
            else:
                raise ValueError(f"invalid ZRLE subencoding {sub}")

            out[ty : ty + th, tx : tx + tw] = tile
            tile_kinds[kind] += 1
    if pos != len(data):
        raise ValueError(f"ZRLE has {len(data) - pos} leftover bytes")
    return out


def replay(log, width, height):
    framebuffer = np.zeros((height, width, 3), np.uint8)  # B, G, R
    inflater = zlib.decompressobj()  # ONE zlib stream for the whole recording, as RFB specifies
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
                        raise ValueError(f"encoding {encoding} is not supported by the verifier")
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
                raise ValueError(f"message type {kind} at offset {pos}")
    except Truncated:
        print("The recording ends in the middle of a message; dropping the partial remainder (as the Swift decoder stops).")

    return framebuffer, updates, rect_counts, tile_kinds, zrle_in, zrle_out


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    log_path, swift_path, width, height = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    log = open(log_path, "rb").read()
    swift = np.frombuffer(open(swift_path, "rb").read(), np.uint8)
    if swift.size != width * height * 4:
        sys.exit(f"Swift frame has {swift.size} bytes, expected {width * height * 4}")
    swift = swift.reshape(height, width, 4)[:, :, :3]

    framebuffer, updates, rect_counts, tile_kinds, zrle_in, zrle_out = replay(log, width, height)

    names = {ENC_RAW: "Raw", ENC_COPYRECT: "CopyRect", ENC_ZRLE: "ZRLE", ENC_CURSOR: "Cursor"}
    print(f"\nRecording: {len(log) / 1024:.0f} KiB, {updates} FramebufferUpdate")
    print("Rectangles by encoding:", {names[k]: v for k, v in sorted(rect_counts.items())})
    if zrle_in:
        print(f"ZRLE: {zrle_in / 1024:.0f} KiB compressed -> {zrle_out / 1024:.0f} KiB after decompression (continuous zlib stream)")
    total_tiles = sum(tile_kinds.values())
    if total_tiles:
        print(f"ZRLE tiles that actually occurred ({total_tiles} tiles):")
        for kind, count in tile_kinds.most_common():
            print(f"  {kind:<14} {count:>8}  ({100 * count / total_tiles:5.1f}%)")

    different = np.any(framebuffer != swift, axis=2)
    count = int(different.sum())
    print(f"\nCOMPARISON of the independent Python decoder with the Swift decoder on the same data: {count} pixels differ "
          f"out of {width * height}")
    if count:
        ys, xs = np.nonzero(different)
        print(f"  differing region: x {xs.min()}..{xs.max()}, y {ys.min()}..{ys.max()}")
        sys.exit(1)
    print("  EXACT MATCH")


if __name__ == "__main__":
    main()
