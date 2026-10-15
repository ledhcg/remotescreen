#!/usr/bin/env python3
"""Checks the mock server's log (--apple) after AppleGestureUITests.

Asserts:
  1. The app treats the server as a Mac and sends message 23: magnify (kind 3) and rotate (kind 5) events, 32-byte payload, version 2;
     each kind opens with phase began (1), closes with ended (4), with changed (2) in between (a real Mac ignores version 1 without phases).
  2. The total magnification is positive (pinch out, scale 2 -> total about +1) and the total rotation is clearly non-zero (pi/4 = 45 degrees).
  3. Coordinates lie within the 800x600 screen.
  4. The connection was not closed: a click at (250, 300) AFTER the gestures, and no unknown messages.
Usage:  verify_gestures.py events.jsonl     Exits 0 on a match.
"""
import json
import sys


def main():
    events = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
    gestures = [e for e in events if e["type"] == "apple_event"]
    magnify = [e for e in gestures if e.get("kind") == 3]
    rotate = [e for e in gestures if e.get("kind") == 5]
    failures = []
    if not magnify:
        failures.append("no magnify events (kind 3)")
    if not rotate:
        failures.append("no rotate events (kind 5)")
    for e in magnify + rotate:
        if e["length"] != 32 or e["version"] != 2:
            failures.append(f"payload has wrong size/version: {e}")
            break
        if not (0 <= e["x"] < 800 and 0 <= e["y"] < 600):
            failures.append(f"coordinates outside the screen: {e}")
            break
    for name, events_of_kind in (("magnify", magnify), ("rotate", rotate)):
        # There may be several runs (the XCUITest pinch also starts the rotation recogniser): each run must be began, changed..., ended.
        open_gesture = False
        for e in events_of_kind:
            phase = e.get("phase")
            if (phase == 1) == open_gesture or phase not in (1, 2, 4):
                failures.append(f"{name}: phase {phase} out of place (each run must be began, changed..., ended)")
                break
            open_gesture = phase != 4
        else:
            if open_gesture:
                failures.append(f"{name}: last run has no ended")
    total_zoom = sum(e["value"] for e in magnify)
    total_rotation = sum(e["value"] for e in rotate)
    if magnify and not 0.3 <= total_zoom <= 2.5:
        failures.append(f"total magnification {total_zoom:.3f}, expected positive (pinch out, scale 2)")
    if rotate and not 15 <= abs(total_rotation) <= 90:
        failures.append(f"total rotation {total_rotation:.1f}°, expected about 45°")
    last_gesture = max((i for i, e in enumerate(events) if e["type"] == "apple_event"), default=-1)
    clicked_after = any(e["type"] == "pointer" and e["buttons"] == 1 and abs(e["x"] - 250) <= 8 and abs(e["y"] - 300) <= 8
                        for e in events[last_gesture + 1:])
    if not clicked_after:
        failures.append("no click at (250, 300) after the gestures: connection broken after message 23?")
    unknown = [e for e in events if e["type"] == "unknown_message"]
    if unknown:
        failures.append(f"message the mock server did not understand: {unknown[:3]}")

    print(f"magnify: {len(magnify)} (total {total_zoom:+.3f}), rotate: {len(rotate)} (total {total_rotation:+.1f}°)")
    for failure in failures:
        print("FAIL:", failure)
    if not failures:
        print("GESTURES TO MAC (MESSAGE 23): ALL MATCH")
    sys.exit(1 if failures else 0)


main()
