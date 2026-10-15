#!/usr/bin/env python3
"""Checks the mock server's log after ObserveModeUITests.

Asserts:
  1. There is a left click near (250, 300): an action in CONTROL mode reaches the server (positive control).
  2. Every mouse event is near (250, 300): nothing from OBSERVE-mode actions (tap, double tap, drag, two-finger).
  3. There are no key events.

All other UI tests in the same run do not touch the remote screen, so the log holds only this test's events.
Usage:  verify_observe.py events.jsonl     Exits 0 on a match.
"""
import json
import sys

TOLERANCE = 8  # pixel Mac
CONTROL_POINT = (250, 300)


def main():
    events = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
    pointers = [e for e in events if e["type"] == "pointer"]
    keys = [e for e in events if e["type"] == "key"]
    failures = []

    def near(e):
        return abs(e["x"] - CONTROL_POINT[0]) <= TOLERANCE and abs(e["y"] - CONTROL_POINT[1]) <= TOLERANCE

    pressed = [e for e in pointers if e["buttons"] == 1 and near(e)]
    if not pressed:
        failures.append(f"no control-mode click at {CONTROL_POINT}: the test could not tap, or control is broken")
    stray = [e for e in pointers if not near(e)]
    if stray:
        failures.append(f"{len(stray)} mouse events away from the control point (leaked from observe mode?): {stray[:3]}")
    if keys:
        failures.append(f"{len(keys)} key events, expected none: {keys[:3]}")

    print(f"mouse events: {len(pointers)}, near the control point: {len(pointers) - len(stray)}, keys: {len(keys)}")
    for failure in failures:
        print("FAIL:", failure)
    if not failures:
        print("OBSERVE SENDS NOTHING, CONTROL STILL SENDS: MATCH")
    sys.exit(1 if failures else 0)


main()
