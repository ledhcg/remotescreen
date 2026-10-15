#!/usr/bin/env python3
"""Checks the keysyms the mock server received after HardwareKeyboardUITests.

Expectations come from X11's keysymdef.h, not generated from the code under test. Each key must be pressed then released, in typing order.
Usage:  verify_keys.py events.jsonl     Exits 0 on a match.
"""
import json
import sys

EXPECTED = [  # (name, keysym): the keys XCUITest produces reliably (see HardwareKeyboardUITests)
    ("Tab", 0xFF09), ("Up", 0xFF52), ("Down", 0xFF54), ("Left", 0xFF51), ("Right", 0xFF53),
]
SYSTEM_COMBOS = "zsopftnw"  # ⌘ + letter: iPadOS may keep some, but the remote Mac needs to receive all of them
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
            failures.append(f"{name} (0x{keysym:X}): press not seen")
            continue
        if index + 1 >= len(keys) or keys[index + 1] != (False, keysym):
            failures.append(f"{name}: pressed but not released right after")
        cursor = index + 2
    for name, sequence in COMBOS:
        found = any(keys[i:i + len(sequence)] == sequence for i in range(len(keys)))
        if not found:
            failures.append(f"{name}: sequence not seen {[('↓' if d else '↑', hex(k)) for d, k in sequence]}")
    for letter in SYSTEM_COMBOS:
        code = ord(letter)
        sequence = [(True, 0xFFE7), (True, code), (False, code), (False, 0xFFE7)]
        if not any(keys[i:i + 4] == sequence for i in range(len(keys))):
            failures.append(f"Command+{letter.upper()}: did not reach the server (kept by iPadOS?)")
    held = {}
    for down, keysym in keys:
        held[keysym] = held.get(keysym, 0) + (1 if down else -1)
    stuck = [hex(k) for k, n in held.items() if n != 0]
    if stuck:
        failures.append(f"stuck keys (unbalanced press/release): {stuck}")

    print(f"total key events: {len(keys)}")
    if failures:
        print("received:", " ".join(("↓" if d else "↑") + hex(k) for d, k in keys))
    for failure in failures:
        print("FAIL:", failure)
    if not failures:
        print("HARDWARE KEYBOARD: ALL MATCH")
    sys.exit(1 if failures else 0)


main()
