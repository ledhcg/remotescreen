#!/usr/bin/env python3
"""Đối chiếu log của server giả (--apple) sau AppleGestureUITests.

Khẳng định:
  1. App coi server là Mac và gửi message 23: có sự kiện chụm (loại 3) và xoay (loại 5), payload 32 byte, phiên bản 2;
     mỗi loại mở bằng pha began (1), đóng bằng ended (4), giữa là changed (2) (Mac thật bỏ qua bản 1 không có pha).
  2. Tổng độ phóng dương (chụm ra, tỉ lệ 2 → tổng khoảng +1), tổng độ xoay khác 0 đáng kể (π/4 ≈ 45°).
  3. Toạ độ nằm trong màn hình 800x600.
  4. Kết nối không bị đóng: có cú nhấp (250, 300) SAU các cử chỉ, và không có message lạ.
Dùng:  verify_gestures.py events.jsonl     Thoát 0 nếu khớp.
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
        failures.append("không có sự kiện chụm (loại 3)")
    if not rotate:
        failures.append("không có sự kiện xoay (loại 5)")
    for e in magnify + rotate:
        if e["length"] != 32 or e["version"] != 2:
            failures.append(f"payload sai cỡ/phiên bản: {e}")
            break
        if not (0 <= e["x"] < 800 and 0 <= e["y"] < 600):
            failures.append(f"toạ độ ngoài màn hình: {e}")
            break
    for name, events_of_kind in (("chụm", magnify), ("xoay", rotate)):
        # Có thể nhiều lượt (chụm của XCUITest cũng làm bộ nhận diện xoay bắt đầu): mỗi lượt phải là began, changed…, ended.
        open_gesture = False
        for e in events_of_kind:
            phase = e.get("phase")
            if (phase == 1) == open_gesture or phase not in (1, 2, 4):
                failures.append(f"{name}: pha {phase} sai chỗ (mỗi lượt phải là began, changed…, ended)")
                break
            open_gesture = phase != 4
        else:
            if open_gesture:
                failures.append(f"{name}: lượt cuối không có ended")
    total_zoom = sum(e["value"] for e in magnify)
    total_rotation = sum(e["value"] for e in rotate)
    if magnify and not 0.3 <= total_zoom <= 2.5:
        failures.append(f"tổng độ phóng {total_zoom:.3f}, cần dương (chụm ra tỉ lệ 2)")
    if rotate and not 15 <= abs(total_rotation) <= 90:
        failures.append(f"tổng độ xoay {total_rotation:.1f}°, cần khoảng 45°")
    last_gesture = max((i for i, e in enumerate(events) if e["type"] == "apple_event"), default=-1)
    clicked_after = any(e["type"] == "pointer" and e["buttons"] == 1 and abs(e["x"] - 250) <= 8 and abs(e["y"] - 300) <= 8
                        for e in events[last_gesture + 1:])
    if not clicked_after:
        failures.append("không thấy cú nhấp (250, 300) sau cử chỉ: kết nối hỏng sau message 23?")
    unknown = [e for e in events if e["type"] == "unknown_message"]
    if unknown:
        failures.append(f"message server giả không hiểu: {unknown[:3]}")

    print(f"chụm: {len(magnify)} (tổng {total_zoom:+.3f}), xoay: {len(rotate)} (tổng {total_rotation:+.1f}°)")
    for failure in failures:
        print("SAI:", failure)
    if not failures:
        print("CỬ CHỈ LÊN MAC (MESSAGE 23): TẤT CẢ KHỚP")
    sys.exit(1 if failures else 0)


main()
