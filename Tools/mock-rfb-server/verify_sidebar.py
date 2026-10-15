#!/usr/bin/env python3
"""Checks the mock server's log after SidebarUITests.

Asserts, in log order:
  1. Sticky ⌘: Meta_L down, then exactly ONE click near (150, 150), then Meta_L up.
  2. Locked ⌘: Meta_L down, two clicks near (550, 150) and (550, 450), then Meta_L up (not released between the clicks).
  3. Undo: Meta_L down, z down, z up, Meta_L up, back to back.
  4. Escape: Escape↓ Escape↑.
  5. Every key press is matched by a release (no stuck keys).
Usage:  verify_sidebar.py events.jsonl     Exits 0 on a match.
"""
import json
import sys

META_L, Z, ESCAPE = 0xFFE7, 0x7A, 0xFF1B
TOLERANCE = 8  # Mac pixels


def main():
    events = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
    stream = [e for e in events if e["type"] in ("key", "pointer")]
    failures = []

    def clicks_between(start, end):
        """Left clicks (button down) in stream[start:end], as (x, y)."""
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
    pairs = []  # (press index, release index)
    pending = None
    for index, down in meta:
        if down and pending is None:
            pending = index
        elif not down and pending is not None:
            pairs.append((pending, index))
            pending = None
    if pending is not None:
        failures.append("Meta_L pressed but never released")

    if len(pairs) < 3:
        failures.append(f"expected at least 3 Meta_L press/release pairs (sticky, locked, undo), saw {len(pairs)}")
    else:
        one_shot = clicks_between(*pairs[0])
        if len(one_shot) != 1 or not near(one_shot[0], (150, 150)):
            failures.append(f"sticky ⌘: expected exactly one click near (150, 150) before release, saw {one_shot}")
        locked = clicks_between(*pairs[1])
        if len(locked) != 2 or not near(locked[0], (550, 150)) or not near(locked[1], (550, 450)):
            failures.append(f"locked ⌘: expected two clicks (550, 150), (550, 450) before release, saw {locked}")
        keys = [(e["down"], e["keysym"]) for e in stream[pairs[2][0]:pairs[2][1] + 1] if e["type"] == "key"]
        if keys != [(True, META_L), (True, Z), (False, Z), (False, META_L)]:
            failures.append(f"undo: expected ⌘↓ z↓ z↑ ⌘↑, saw {[('↓' if d else '↑', hex(k)) for d, k in keys]}")
        if clicks_between(*pairs[2]):
            failures.append("undo: no click may occur in between")

    keys = [(e["down"], e["keysym"]) for e in stream if e["type"] == "key"]
    if not any(keys[i:i + 2] == [(True, ESCAPE), (False, ESCAPE)] for i in range(len(keys))):
        failures.append("Escape↓ Escape↑ not seen")
    held = {}
    for down, keysym in keys:
        held[keysym] = held.get(keysym, 0) + (1 if down else -1)
    stuck = [hex(k) for k, n in held.items() if n != 0]
    if stuck:
        failures.append(f"stuck keys (unbalanced press/release): {stuck}")

    print(f"key events: {len(keys)}, ⌘ press/release pairs: {len(pairs)}")
    for failure in failures:
        print("FAIL:", failure)
    if not failures:
        print("SIDEBAR: ALL MATCH")
    sys.exit(1 if failures else 0)


main()
