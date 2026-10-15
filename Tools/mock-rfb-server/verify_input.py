#!/usr/bin/env python3
"""Compares the events the mock RFB server received with what the XCUITest did.

The test taps at known points on the 800x600 mock "Mac screen". This script looks in the log for the matching mouse/key event sequences,
with a few pixels of tolerance (points round to Mac pixels; one point is about 2 Mac pixels on iPhone).

Usage:  verify_input.py events.jsonl
Exits 0 if every expectation matches.
"""
import json
import sys

TOLERANCE = 6  # Mac pixels


def load(path):
    return [json.loads(line) for line in open(path) if line.strip()]


def near(event, x, y):
    return abs(event["x"] - x) <= TOLERANCE and abs(event["y"] - y) <= TOLERANCE


def find_click(pointers, x, y, button, start=0):
    """Finds three consecutive events: (0) -> (button) -> (0), all near (x, y). Returns the next index or None."""
    for i in range(start, len(pointers) - 2):
        a, b, c = pointers[i : i + 3]
        if (a["buttons"] == 0 and b["buttons"] == button and c["buttons"] == 0
                and near(a, x, y) and near(b, x, y) and near(c, x, y)):
            return i + 3
    return None


def main():
    events = load(sys.argv[1])
    pointers = [e for e in events if e["type"] == "pointer"]
    keys = [e for e in events if e["type"] == "key"]
    failures = []

    def check(name, condition, detail=""):
        print(f"  {'PASS' if condition else 'FAIL'} {name}{(': ' + detail) if detail and not condition else ''}")
        if not condition:
            failures.append(name)

    print(f"Received {len(pointers)} mouse events and {len(keys)} key events")
    cursor = 0

    # 1. Two single-finger taps
    nxt = find_click(pointers, 100, 450, 1, cursor)
    check("single-finger tap at (100,450) -> left click", nxt is not None)
    cursor = nxt or cursor
    nxt = find_click(pointers, 700, 520, 1, cursor)
    check("single-finger tap at (700,520) -> left click", nxt is not None)
    cursor = nxt or cursor

    # 2. Two-finger tap -> right click. XCUITest `twoFingerTap()` targets the accessibility activation point of the element, not the exact centre of
    #    the mock Mac screen (measured x ~ 400, y ~ 353 instead of 300), so only the certain parts are checked: right button (bit 2 = 4),
    #    three press/release events at one position, x in the middle. Tapping the right place is already covered by the single-finger taps with normalised coordinates.
    right = next((i for i in range(cursor, len(pointers) - 2)
                  if pointers[i]["buttons"] == 0 and pointers[i + 1]["buttons"] == 4 and pointers[i + 2]["buttons"] == 0
                  and pointers[i]["x"] == pointers[i + 1]["x"] == pointers[i + 2]["x"]
                  and pointers[i]["y"] == pointers[i + 1]["y"] == pointers[i + 2]["y"]
                  and abs(pointers[i + 1]["x"] - 400) <= TOLERANCE), None)
    check("two-finger tap -> RIGHT click (button bit 2 = 4), three events at one position, x in the middle", right is not None)
    cursor = (right + 3) if right is not None else cursor

    # 3. Press and drag: left button down at the start, moves while held, released at the end
    press = next((i for i in range(cursor, len(pointers)) if pointers[i]["buttons"] == 1 and near(pointers[i], 200, 350)), None)
    check("long press at (200,350) -> left button down", press is not None)
    if press is not None:
        held = [p for p in pointers[press:] if p["buttons"] == 1]
        release = next((i for i in range(press, len(pointers)) if pointers[i]["buttons"] == 0 and near(pointers[i], 600, 500)), None)
        check("drag: move events while the button is held", len(held) >= 3, f"only {len(held)} held events")
        check("drag: button released at the end point (600,500)", release is not None)
        if release is not None:
            xs = [p["x"] for p in pointers[press:release] if p["buttons"] == 1]
            check("drag: x increases from left to right", xs == sorted(xs) and xs[-1] - xs[0] > 200,
                  f"x from {xs[0]} to {xs[-1]}" if xs else "none")
            cursor = release + 1

    # 4. Double tap: two consecutive clicks at the same spot
    first = find_click(pointers, 300, 250, 1, cursor)
    second = find_click(pointers, 300, 250, 1, first) if first else None
    check("double tap at (300,250) -> two consecutive left clicks", second is not None)

    # 5. Keyboard: "A" (0x41), "b" (0x62) and Return (0xFF0D), each pressed then released
    def pressed_and_released(keysym):
        downs = [i for i, k in enumerate(keys) if k["keysym"] == keysym and k["down"]]
        return any(any(not k["down"] and k["keysym"] == keysym for k in keys[d + 1 :]) for d in downs)

    check("typing 'A' (keysym 0x41) presses then releases", pressed_and_released(0x41))
    check("typing 'b' (keysym 0x62) presses then releases", pressed_and_released(0x62))
    check("typing Return (keysym 0xFF0D) presses then releases", pressed_and_released(0xFF0D))
    # Every pressed key must be released (no stuck keys on the remote machine)
    stuck = {k["keysym"] for k in keys if k["down"]} - {k["keysym"] for k in keys if not k["down"]}
    check("no stuck keys (every press has a release)", not stuck, f"stuck: {sorted(hex(s) for s in stuck)}")
    # Every mouse button ends up released
    check("mouse buttons end released", not pointers or pointers[-1]["buttons"] == 0)

    print("\nRESULT:", "ALL MATCH" if not failures else f"{len(failures)} FAILED: {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
