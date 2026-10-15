#!/usr/bin/env python3
"""Đối chiếu log của server giả sau QualityUITests: định dạng pixel app yêu cầu, theo đúng thứ tự.

Ba bài test chạy lần lượt (xếp theo tên), mỗi lần mở app là một kết nối. Mọi chế độ giờ đều 32 bit (con trỏ tại chỗ),
nên đổi chế độ không bao giờ nối lại:
  testBestPerformanceKeepsFullColour...:      32 (mở)
  testQualityModeIsRememberedAcrossLaunches:  32 (mở), 32 (mở lại)
  testSwitchingBetweenFullColourModes...:     32 (mở)
Dùng:  verify_quality.py events.jsonl     Thoát 0 nếu khớp.
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
        failures.append(f"chuỗi định dạng pixel {seen}, mong đợi {EXPECTED}")
    for e in formats:
        if e["bpp"] == 16 and (e["max"] != [31, 63, 31] or e["shifts"] != [11, 5, 0] or e["big_endian"] or not e["true_colour"]):
            failures.append(f"định dạng 16 bit sai chi tiết: {e}")
    print(f"định dạng pixel đã xin: {seen}")
    for failure in failures:
        print("SAI:", failure)
    if not failures:
        print("CHẾ ĐỘ CHẤT LƯỢNG: ĐỊNH DẠNG PIXEL ĐÚNG THỨ TỰ: KHỚP")
    sys.exit(1 if failures else 0)


main()
