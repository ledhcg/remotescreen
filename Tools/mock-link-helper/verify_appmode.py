#!/usr/bin/env python3
"""Checks the JSONL event log of mock-link-helper after the App Mode UI test ran.

Expectations: the iPad paired (or opened a session), listed and fetched icons for the three apps, activated an app, subscribed to a
window, and its pointer, text or key events, a menu press (File > New), a resize of the Mac window and a close command arrived.
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

    print("Event types:", ", ".join(f"{k}={len(v)}" for k, v in sorted(by_type.items())))
    check("paired (or session opened)", bool(by_type.get("paired")) or bool(by_type.get("session")))
    check("subscribed to a window", bool(by_type.get("subscribe")))
    check("pointer events received", bool(pointers))
    check("key or text events received", bool(keys) or bool(by_type.get("text")))
    check("apps listed", bool(by_type.get("apps_list")))
    check("icons fetched for the three apps", len({e["key"] for e in by_type.get("apps_icon", [])}) >= 3)
    check("app activated", bool(by_type.get("apps_activate")))
    check("menu tree fetched", bool(by_type.get("menu_get")))
    check("menu item pressed (File > New = path [0, 0])", any(e["path"] == [0, 0] for e in by_type.get("menu_press", [])))
    check("Mac window resized to the iPad window", bool(by_type.get("set_frame")))
    check("Mac window closed by command", any(e["command"] == "close" for e in by_type.get("command", [])))
    stuck = {k["keysym"] for k in keys if k["down"]} - {k["keysym"] for k in keys if not k["down"]}
    check("no stuck keys (every press has a release)", not stuck, f"stuck: {sorted(hex(s) for s in stuck)}")
    check("mouse buttons end released", not pointers or pointers[-1]["buttons"] == 0)
    check("no unexpected messages", not by_type.get("unexpected"), f"{len(by_type.get('unexpected', []))} unexpected")

    print("\nRESULT:", "ALL MATCH" if not failures else f"{len(failures)} FAILED: {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
