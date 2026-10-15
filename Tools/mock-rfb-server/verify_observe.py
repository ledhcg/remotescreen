#!/usr/bin/env python3
"""Đối chiếu log của server giả sau ObserveModeUITests.

Khẳng định:
  1. Có một cú nhấp trái gần (250, 300): thao tác lúc ĐIỀU KHIỂN tới được server (đối chứng dương).
  2. Mọi sự kiện chuột đều nằm gần (250, 300): không có gì từ các thao tác lúc CHỈ XEM (chạm, chạm đúp, kéo, hai ngón).
  3. Không có sự kiện phím nào.

Mọi bài UI test khác trong cùng lượt chạy không chạm vào màn hình từ xa, nên log chỉ có sự kiện của bài này.
Dùng:  verify_observe.py events.jsonl     Thoát 0 nếu khớp.
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
        failures.append(f"không thấy cú nhấp lúc điều khiển tại {CONTROL_POINT}: bài test không chạm được, hoặc điều khiển hỏng")
    stray = [e for e in pointers if not near(e)]
    if stray:
        failures.append(f"{len(stray)} sự kiện chuột ngoài điểm điều khiển (lọt từ chế độ chỉ xem?): {stray[:3]}")
    if keys:
        failures.append(f"{len(keys)} sự kiện phím, không được có: {keys[:3]}")

    print(f"sự kiện chuột: {len(pointers)}, gần điểm điều khiển: {len(pointers) - len(stray)}, phím: {len(keys)}")
    for failure in failures:
        print("SAI:", failure)
    if not failures:
        print("CHỈ XEM KHÔNG GỬI GÌ, ĐIỀU KHIỂN VẪN GỬI: KHỚP")
    sys.exit(1 if failures else 0)


main()
