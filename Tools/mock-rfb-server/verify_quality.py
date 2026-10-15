#!/usr/bin/env python3
"""Checks the mock server's log after QualityUITests: the pixel formats the app requested, in order.

The three tests run one after another (sorted by name), and each app launch is one connection. Every mode is now 32-bit (local cursor),
so changing mode never reconnects:
  testBestPerformanceKeepsFullColour...:      32 (launch)
  testQualityModeIsRememberedAcrossLaunches:  32 (launch), 32 (relaunch)
  testSwitchingBetweenFullColourModes...:     32 (launch)
Usage:  verify_quality.py events.jsonl     Exits 0 on a match.
"""
import json
import sys

EXPECTED = [32, 32, 32, 32]


def main():
    events = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
    formats = [e for e in events if e["type"] == "pixel_format"]
    seen = [e["bpp"] for e in formats]
    failures = []
    if seen != EXPECTED:
        failures.append(f"pixel format sequence {seen}, expected {EXPECTED}")
    for e in formats:
        if e["bpp"] == 16 and (e["max"] != [31, 63, 31] or e["shifts"] != [11, 5, 0] or e["big_endian"] or not e["true_colour"]):
            failures.append(f"16-bit format has wrong details: {e}")
    print(f"pixel formats requested: {seen}")
    for failure in failures:
        print("FAIL:", failure)
    if not failures:
        print("QUALITY MODE: PIXEL FORMATS IN ORDER: MATCH")
    sys.exit(1 if failures else 0)


main()
