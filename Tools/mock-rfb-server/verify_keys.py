#!/usr/bin/env python3
"""Đối chiếu keysym mà server giả nhận được sau HardwareKeyboardUITests.

Kỳ vọng lấy từ keysymdef.h của X11, không sinh từ code đang test. Mỗi phím phải có nhấn rồi nhả, đúng thứ tự gõ.
Dùng:  verify_keys.py events.jsonl     Thoát 0 nếu khớp.
"""
import json
import sys

EXPECTED = [  # (tên, keysym): các phím XCUITest tạo ra đáng tin (xem HardwareKeyboardUITests)
    ("Tab", 0xFF09), ("Up", 0xFF52), ("Down", 0xFF54), ("Left", 0xFF51), ("Right", 0xFF53),
]
SYSTEM_COMBOS = "zsopftnw"  # ⌘ + chữ: iPadOS có thể giữ lại một số, Mac từ xa cần nhận hết
COMBOS = [
    ("Command+C", [(True, 0xFFE7), (True, 0x63), (False, 0x63), (False, 0xFFE7)]),
    ("Control+C", [(True, 0xFFE3), (True, 0x63), (False, 0x63), (False, 0xFFE3)]),
    ("Option+X", [(True, 0xFFE9), (True, 0x78), (False, 0x78), (False, 0xFFE9)]),
]


def main():
    events = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
    keys = [(e["down"], e["keysym"]) for e in events if e["type"] == "key"]
    failures = []
    cursor = 0
    for name, keysym in EXPECTED:
        try:
            index = keys.index((True, keysym), cursor)
        except ValueError:
            failures.append(f"{name} (0x{keysym:X}): không thấy lần nhấn")
            continue
        if index + 1 >= len(keys) or keys[index + 1] != (False, keysym):
            failures.append(f"{name}: nhấn nhưng không nhả ngay sau")
        cursor = index + 2
    for name, sequence in COMBOS:
        found = any(keys[i:i + len(sequence)] == sequence for i in range(len(keys)))
        if not found:
            failures.append(f"{name}: không thấy chuỗi {[('↓' if d else '↑', hex(k)) for d, k in sequence]}")
    for letter in SYSTEM_COMBOS:
        code = ord(letter)
        sequence = [(True, 0xFFE7), (True, code), (False, code), (False, 0xFFE7)]
        if not any(keys[i:i + 4] == sequence for i in range(len(keys))):
            failures.append(f"Command+{letter.upper()}: không tới server (hệ thống iPadOS giữ lại?)")
    held = {}
    for down, keysym in keys:
        held[keysym] = held.get(keysym, 0) + (1 if down else -1)
    stuck = [hex(k) for k, n in held.items() if n != 0]
    if stuck:
        failures.append(f"phím kẹt (nhấn/nhả không cân): {stuck}")

    print(f"tổng số sự kiện phím: {len(keys)}")
    if failures:
        print("đã nhận:", " ".join(("↓" if d else "↑") + hex(k) for d, k in keys))
    for failure in failures:
        print("SAI:", failure)
    if not failures:
        print("BÀN PHÍM CỨNG: TẤT CẢ KHỚP")
    sys.exit(1 if failures else 0)


main()
