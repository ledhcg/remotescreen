#!/usr/bin/env python3
"""Đối chiếu log của server giả sau SidebarUITests.

Khẳng định, theo đúng thứ tự trong log:
  1. ⌘ dính một lần: Meta_L↓, rồi đúng MỘT cú nhấp gần (150, 150), rồi Meta_L↑.
  2. ⌘ khóa: Meta_L↓, hai cú nhấp gần (550, 150) và (550, 450), rồi Meta_L↑ (không nhả giữa hai cú nhấp).
  3. Hoàn tác: Meta_L↓ z↓ z↑ Meta_L↑ liền nhau.
  4. Escape: Escape↓ Escape↑.
  5. Mọi phím nhấn/nhả cân bằng (không kẹt phím).
Dùng:  verify_sidebar.py events.jsonl     Thoát 0 nếu khớp.
"""
import json
import sys

META_L, Z, ESCAPE = 0xFFE7, 0x7A, 0xFF1B
TOLERANCE = 8  # pixel Mac


def main():
    events = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
    stream = [e for e in events if e["type"] in ("key", "pointer")]
    failures = []

    def clicks_between(start, end):
        """Các cú nhấp trái (nhấn xuống) trong stream[start:end], dạng (x, y)."""
        result, previous = [], 0
        for e in stream[start:end]:
            if e["type"] == "pointer":
                if e["buttons"] & 1 and not previous & 1:
                    result.append((e["x"], e["y"]))
                previous = e["buttons"]
        return result

    def near(point, target):
        return abs(point[0] - target[0]) <= TOLERANCE and abs(point[1] - target[1]) <= TOLERANCE

    meta = [(i, e["down"]) for i, e in enumerate(stream) if e["type"] == "key" and e["keysym"] == META_L]
    pairs = []  # (vị trí nhấn, vị trí nhả)
    pending = None
    for index, down in meta:
        if down and pending is None:
            pending = index
        elif not down and pending is not None:
            pairs.append((pending, index))
            pending = None
    if pending is not None:
        failures.append("Meta_L nhấn mà không bao giờ nhả")

    if len(pairs) < 3:
        failures.append(f"cần ít nhất 3 lần nhấn-nhả Meta_L (dính, khóa, hoàn tác), thấy {len(pairs)}")
    else:
        one_shot = clicks_between(*pairs[0])
        if len(one_shot) != 1 or not near(one_shot[0], (150, 150)):
            failures.append(f"⌘ dính một lần: cần đúng một cú nhấp gần (150, 150) trước khi nhả, thấy {one_shot}")
        locked = clicks_between(*pairs[1])
        if len(locked) != 2 or not near(locked[0], (550, 150)) or not near(locked[1], (550, 450)):
            failures.append(f"⌘ khóa: cần hai cú nhấp (550, 150), (550, 450) trước khi nhả, thấy {locked}")
        keys = [(e["down"], e["keysym"]) for e in stream[pairs[2][0]:pairs[2][1] + 1] if e["type"] == "key"]
        if keys != [(True, META_L), (True, Z), (False, Z), (False, META_L)]:
            failures.append(f"hoàn tác: cần ⌘↓ z↓ z↑ ⌘↑, thấy {[('↓' if d else '↑', hex(k)) for d, k in keys]}")
        if clicks_between(*pairs[2]):
            failures.append("hoàn tác: không được có cú nhấp nào xen giữa")

    keys = [(e["down"], e["keysym"]) for e in stream if e["type"] == "key"]
    if not any(keys[i:i + 2] == [(True, ESCAPE), (False, ESCAPE)] for i in range(len(keys))):
        failures.append("không thấy Escape↓ Escape↑")
    held = {}
    for down, keysym in keys:
        held[keysym] = held.get(keysym, 0) + (1 if down else -1)
    stuck = [hex(k) for k, n in held.items() if n != 0]
    if stuck:
        failures.append(f"phím kẹt (nhấn/nhả không cân): {stuck}")

    print(f"sự kiện phím: {len(keys)}, lần nhấn-nhả ⌘: {len(pairs)}")
    for failure in failures:
        print("SAI:", failure)
    if not failures:
        print("SIDEBAR: TẤT CẢ KHỚP")
    sys.exit(1 if failures else 0)


main()
