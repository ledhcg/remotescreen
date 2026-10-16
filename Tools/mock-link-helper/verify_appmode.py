#!/usr/bin/env python3
"""Checks the JSONL event log of mock-link-helper after the App Mode UI test ran.

Expectations: the iPad paired (or opened a session), subscribed to a window, and its pointer and key events arrived.
Every key press must also have been released.

Usage:  verify_appmode.py events.jsonl
Exits 0 if every expectation matches.
"""
import json
import sys


def load(path):
    events = []
    with open(path) as f:
        for line in f:
            if line.strip():
                events.append(json.loads(line))
    return events


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    events = load(sys.argv[1])
    by_type = {}
    for e in events:
        by_type.setdefault(e["type"], []).append(e)
    failures = []

    def check(name, condition, detail=""):
        print(f"  {'PASS' if condition else 'FAIL'} {name}{(': ' + detail) if detail and not condition else ''}")
        if not condition:
            failures.append(name)

    pointers = by_type.get("pointer", [])
    keys = by_type.get("key", [])
    print(f"Received {len(events)} events: {len(pointers)} pointer, {len(keys)} key, {len(by_type.get('subscribe', []))} subscribe")

    check("paired (or session opened)", bool(by_type.get("paired")) or bool(by_type.get("session")))
    check("subscribed to a window", bool(by_type.get("subscribe")))
    check("pointer events received", bool(pointers))
    check("key events received", bool(keys))
    stuck = {k["keysym"] for k in keys if k["down"]} - {k["keysym"] for k in keys if not k["down"]}
    check("no stuck keys (every press has a release)", not stuck, f"stuck: {sorted(hex(s) for s in stuck)}")
    check("mouse buttons end released", not pointers or pointers[-1]["buttons"] == 0)
    check("no unexpected messages", not by_type.get("unexpected"), f"{len(by_type.get('unexpected', []))} unexpected")

    print("\nRESULT:", "ALL MATCH" if not failures else f"{len(failures)} FAILED: {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
