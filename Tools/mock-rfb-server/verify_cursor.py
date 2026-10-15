#!/usr/bin/env python3
"""Checks an app screenshot: does the cursor appear exactly at the marker square the mock RFB server draws?

The mock server draws a magenta square (255, 0, 255) at the exact coordinates it receives, independent of the app. The app draws
an arrow cursor (black outline, white fill) with Metal, hotspot at the arrow tip. If the app places the cursor correctly, the tip coincides with the centre of the magenta square.

Usage:  verify_cursor.py screenshot.png [--scale N]
Exits 0 if every check passes.
"""
import sys

import numpy as np
from PIL import Image

MAGENTA = (255, 0, 255)
WINDOW = 120  # image pixels around the marker in which to look for the cursor
TOLERANCE = 8  # image pixels between the arrow tip and the marker centre


def mask_of(pixels, colour, tolerance=0):
    return np.all(np.abs(pixels.astype(int) - np.array(colour)) <= tolerance, axis=-1)


def main():
    image = np.array(Image.open(sys.argv[1]).convert("RGB"))
    height, width, _ = image.shape
    failures = []

    def check(name, condition, detail=""):
        print(f"  {'PASS' if condition else 'FAIL'} {name}{(': ' + detail) if detail and not condition else ''}")
        if not condition:
            failures.append(name)

    print(f"Image {width}x{height}")

    # 1. The mock server's 9x9 Mac-pixel marker, magenta after a left press (it keeps its colour after release).
    #    The cursor covers the marker's lower-right part, so locate the centre from the marker's TOP-LEFT corner (uncovered), not its centroid.
    ys, xs = np.nonzero(mask_of(image, MAGENTA, 12))
    check("found the mock server's magenta marker", len(xs) >= 4, "no magenta pixels")
    if len(xs) < 4:
        return finish(failures)
    # The app fits the 800x600 Mac screen to the full screen (the view ignores the safe area): image pixels per Mac pixel.
    pixels_per_mac_pixel = min(width / 800, height / 600)
    marker_x = float(xs.min()) + 4.5 * pixels_per_mac_pixel
    marker_y = float(ys.min()) + 4.5 * pixels_per_mac_pixel
    print(f"  {len(xs)} magenta pixels, {pixels_per_mac_pixel:.3f} image pixels per Mac pixel")
    print(f"  marker centre (derived from top-left corner): ({marker_x:.1f}, {marker_y:.1f})")

    # 2. Cursor: pure black pixels in the window around the marker (the cursor outline). The mock background has no pure black here.
    x0, x1 = max(int(marker_x) - WINDOW, 0), min(int(marker_x) + WINDOW, width)
    y0, y1 = max(int(marker_y) - WINDOW, 0), min(int(marker_y) + WINDOW, height)
    window = image[y0:y1, x0:x1]
    black = mask_of(window, (0, 0, 0), 8)
    white = mask_of(window, (255, 255, 255), 8)
    by, bx = np.nonzero(black)
    check("black cursor outline around the marker", len(bx) >= 30, f"only {len(bx)} black pixels")
    check("white cursor fill", int(white.sum()) >= 30, f"only {int(white.sum())} white pixels")
    if len(bx) < 30:
        return finish(failures)

    # The arrow tip is the top-left corner of the bounding box of the black pixels.
    tip_x, tip_y = x0 + int(bx.min()), y0 + int(by.min())
    print(f"  cursor tip (bounding box of black pixels): ({tip_x}, {tip_y})")
    dx, dy = tip_x - marker_x, tip_y - marker_y
    check(f"cursor tip coincides with the marker centre (tolerance <= {TOLERANCE} image pixels)",
          abs(dx) <= TOLERANCE and abs(dy) <= TOLERANCE, f"off by ({dx:+.1f}, {dy:+.1f})")

    # 3. Shape: the arrow extends right of and below the hotspot, not above or to the left.
    width_box, height_box = int(bx.max() - bx.min()) + 1, int(by.max() - by.min()) + 1
    print(f"  cursor bounding box: {width_box}x{height_box}")
    check("cursor is taller than wide (11x17 arrow)", height_box > width_box, f"{width_box}x{height_box}")
    check("cursor lies below and right of the hotspot", bx.max() + x0 > marker_x and by.max() + y0 > marker_y)
    # About 20 points tall; the image may be 2x or 3x, so the valid range is wide.
    check("plausible cursor size (30...90 pixels tall)", 30 <= height_box <= 90, f"height {height_box}")
    return finish(failures)


def finish(failures):
    print("\nRESULT:", "ALL MATCH" if not failures else f"{len(failures)} FAILED: {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
