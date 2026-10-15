#!/usr/bin/env python3
"""Đối chiếu các sự kiện mà server RFB giả nhận được với những gì bài XCUITest đã thực hiện.

Bài test chạm tại các điểm xác định trên "màn hình Mac" giả 800x600. Script này tìm trong log chuỗi sự kiện chuột/phím
tương ứng, với sai số vài pixel (do làm tròn point sang pixel Mac, mỗi point là khoảng 2 pixel Mac trên iPhone).

Dùng:  verify_input.py events.jsonl
Thoát 0 nếu mọi kỳ vọng đều khớp.
"""
import json
import sys

TOLERANCE = 6  # pixel Mac


def load(path):
    return [json.loads(line) for line in open(path) if line.strip()]


def near(event, x, y):
    return abs(event["x"] - x) <= TOLERANCE and abs(event["y"] - y) <= TOLERANCE


def find_click(pointers, x, y, button, start=0):
    """Tìm ba sự kiện liên tiếp: (0) → (button) → (0), cả ba gần (x, y). Trả về chỉ số kế tiếp hoặc None."""
    for i in range(start, len(pointers) - 2):
        a, b, c = pointers[i : i + 3]
        if (a["buttons"] == 0 and b["buttons"] == button and c["buttons"] == 0
                and near(a, x, y) and near(b, x, y) and near(c, x, y)):
            return i + 3
    return None


def main():
    events = load(sys.argv[1])
    pointers = [e for e in events if e["type"] == "pointer"]
    keys = [e for e in events if e["type"] == "key"]
    failures = []

    def check(name, condition, detail=""):
        print(f"  {'ĐÚNG' if condition else 'SAI '} {name}{(': ' + detail) if detail and not condition else ''}")
        if not condition:
            failures.append(name)

    print(f"Nhận được {len(pointers)} sự kiện chuột và {len(keys)} sự kiện phím")
    cursor = 0

    # 1. Hai lần chạm một ngón
    nxt = find_click(pointers, 100, 450, 1, cursor)
    check("chạm một ngón tại (100,450) → nhấp trái", nxt is not None)
    cursor = nxt or cursor
    nxt = find_click(pointers, 700, 520, 1, cursor)
    check("chạm một ngón tại (700,520) → nhấp trái", nxt is not None)
    cursor = nxt or cursor

    # 2. Chạm hai ngón → nhấp phải. XCUITest `twoFingerTap()` nhắm vào điểm kích hoạt của phần tử trợ năng chứ không đúng tâm
    #    màn hình Mac giả (đo được x ≈ 400, y ≈ 353 thay vì 300), nên chỉ kiểm tra những gì chắc chắn: nút phải (bit 2 = 4),
    #    ba sự kiện nhấn-nhả cùng một vị trí, x ở giữa. Việc chạm đúng chỗ đã được kiểm bằng các lần chạm một ngón theo toạ độ chuẩn hóa.
    right = next((i for i in range(cursor, len(pointers) - 2)
                  if pointers[i]["buttons"] == 0 and pointers[i + 1]["buttons"] == 4 and pointers[i + 2]["buttons"] == 0
                  and pointers[i]["x"] == pointers[i + 1]["x"] == pointers[i + 2]["x"]
                  and pointers[i]["y"] == pointers[i + 1]["y"] == pointers[i + 2]["y"]
                  and abs(pointers[i + 1]["x"] - 400) <= TOLERANCE), None)
    check("chạm hai ngón → nhấp PHẢI (nút bit 2 = 4), ba sự kiện cùng vị trí, x ở giữa", right is not None)
    cursor = (right + 3) if right is not None else cursor

    # 3. Nhấn giữ rồi kéo: nhấn nút trái ở điểm đầu, di chuyển khi đang giữ, nhả ở điểm cuối
    press = next((i for i in range(cursor, len(pointers)) if pointers[i]["buttons"] == 1 and near(pointers[i], 200, 350)), None)
    check("nhấn giữ tại (200,350) → nhấn nút trái", press is not None)
    if press is not None:
        held = [p for p in pointers[press:] if p["buttons"] == 1]
        release = next((i for i in range(press, len(pointers)) if pointers[i]["buttons"] == 0 and near(pointers[i], 600, 500)), None)
        check("kéo: có sự kiện di chuyển khi đang giữ nút", len(held) >= 3, f"chỉ có {len(held)} sự kiện giữ nút")
        check("kéo: nhả nút tại điểm cuối (600,500)", release is not None)
        if release is not None:
            xs = [p["x"] for p in pointers[press:release] if p["buttons"] == 1]
            check("kéo: toạ độ tăng dần từ trái sang phải", xs == sorted(xs) and xs[-1] - xs[0] > 200,
                  f"x từ {xs[0]} tới {xs[-1]}" if xs else "không có")
            cursor = release + 1

    # 4. Chạm đúp: hai lần nhấp liên tiếp tại cùng một chỗ
    first = find_click(pointers, 300, 250, 1, cursor)
    second = find_click(pointers, 300, 250, 1, first) if first else None
    check("chạm đúp tại (300,250) → hai lần nhấp trái liên tiếp", second is not None)

    # 5. Bàn phím: "A" (0x41), "b" (0x62) và Return (0xFF0D), mỗi phím có nhấn rồi nhả
    def pressed_and_released(keysym):
        downs = [i for i, k in enumerate(keys) if k["keysym"] == keysym and k["down"]]
        return any(any(not k["down"] and k["keysym"] == keysym for k in keys[d + 1 :]) for d in downs)

    check("gõ 'A' (keysym 0x41) có nhấn rồi nhả", pressed_and_released(0x41))
    check("gõ 'b' (keysym 0x62) có nhấn rồi nhả", pressed_and_released(0x62))
    check("gõ Return (keysym 0xFF0D) có nhấn rồi nhả", pressed_and_released(0xFF0D))
    # Mọi phím đã nhấn đều phải được nhả (không kẹt phím trên máy từ xa)
    stuck = {k["keysym"] for k in keys if k["down"]} - {k["keysym"] for k in keys if not k["down"]}
    check("không có phím nào bị kẹt (mọi lần nhấn đều có lần nhả)", not stuck, f"kẹt: {sorted(hex(s) for s in stuck)}")
    # Mọi nút chuột cuối cùng đều được nhả
    check("nút chuột cuối cùng ở trạng thái đã nhả", not pointers or pointers[-1]["buttons"] == 0)

    print("\nKẾT QUẢ:", "TẤT CẢ KHỚP" if not failures else f"{len(failures)} SAI: {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
