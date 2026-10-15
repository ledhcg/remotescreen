#!/usr/bin/env python3
"""Kiểm tra ảnh chụp app: con trỏ có hiện đúng tại ô đánh dấu mà server RFB giả vẽ không.

Server giả vẽ một ô magenta (255, 0, 255) tại đúng toạ độ nó nhận được, độc lập với app. App vẽ con trỏ mũi tên viền đen
ruột trắng bằng Metal, điểm nóng ở đỉnh mũi tên. Nếu app đặt con trỏ đúng thì đỉnh mũi tên trùng tâm ô magenta.

Dùng:  verify_cursor.py screenshot.png [--scale N]
Thoát 0 nếu mọi kiểm tra đúng.
"""
import sys

import numpy as np
from PIL import Image

MAGENTA = (255, 0, 255)
WINDOW = 120  # pixel ảnh quanh ô đánh dấu để tìm con trỏ
TOLERANCE = 8  # pixel ảnh giữa đỉnh mũi tên và tâm ô đánh dấu


def mask_of(pixels, colour, tolerance=0):
    return np.all(np.abs(pixels.astype(int) - np.array(colour)) <= tolerance, axis=-1)


def main():
    image = np.array(Image.open(sys.argv[1]).convert("RGB"))
    height, width, _ = image.shape
    failures = []

    def check(name, condition, detail=""):
        print(f"  {'ĐÚNG' if condition else 'SAI '} {name}{(': ' + detail) if detail and not condition else ''}")
        if not condition:
            failures.append(name)

    print(f"Ảnh {width}x{height}")

    # 1. Ô đánh dấu 9x9 pixel Mac của server giả, magenta sau một cú nhấn trái (giữ màu sau khi nhả).
    #    Con trỏ che phần dưới-phải của ô, nên định vị tâm từ GÓC TRÊN TRÁI của ô (không che) chứ không từ trọng tâm.
    ys, xs = np.nonzero(mask_of(image, MAGENTA, 12))
    check("tìm thấy ô đánh dấu magenta của server giả", len(xs) >= 4, "không có pixel magenta")
    if len(xs) < 4:
        return finish(failures)
    # App đặt màn hình Mac 800x600 vừa khít toàn màn hình (view bỏ qua vùng an toàn): số pixel ảnh trên mỗi pixel Mac.
    pixels_per_mac_pixel = min(width / 800, height / 600)
    marker_x = float(xs.min()) + 4.5 * pixels_per_mac_pixel
    marker_y = float(ys.min()) + 4.5 * pixels_per_mac_pixel
    print(f"  {len(xs)} pixel magenta, {pixels_per_mac_pixel:.3f} pixel ảnh mỗi pixel Mac")
    print(f"  tâm ô đánh dấu (suy từ góc trên trái): ({marker_x:.1f}, {marker_y:.1f})")

    # 2. Con trỏ: pixel đen thuần trong cửa sổ quanh ô đánh dấu (viền con trỏ). Nền giả không có đen thuần ở đây.
    x0, x1 = max(int(marker_x) - WINDOW, 0), min(int(marker_x) + WINDOW, width)
    y0, y1 = max(int(marker_y) - WINDOW, 0), min(int(marker_y) + WINDOW, height)
    window = image[y0:y1, x0:x1]
    black = mask_of(window, (0, 0, 0), 8)
    white = mask_of(window, (255, 255, 255), 8)
    by, bx = np.nonzero(black)
    check("có viền đen của con trỏ quanh ô đánh dấu", len(bx) >= 30, f"chỉ {len(bx)} pixel đen")
    check("có ruột trắng của con trỏ", int(white.sum()) >= 30, f"chỉ {int(white.sum())} pixel trắng")
    if len(bx) < 30:
        return finish(failures)

    # Đỉnh mũi tên là góc trên trái của hộp bao các pixel đen.
    tip_x, tip_y = x0 + int(bx.min()), y0 + int(by.min())
    print(f"  đỉnh con trỏ (hộp bao pixel đen): ({tip_x}, {tip_y})")
    dx, dy = tip_x - marker_x, tip_y - marker_y
    check(f"đỉnh con trỏ trùng tâm ô đánh dấu (sai số ≤ {TOLERANCE} pixel ảnh)",
          abs(dx) <= TOLERANCE and abs(dy) <= TOLERANCE, f"lệch ({dx:+.1f}, {dy:+.1f})")

    # 3. Hình dạng: mũi tên rủ xuống phải và xuống dưới điểm nóng, không phải lên trên hay sang trái.
    width_box, height_box = int(bx.max() - bx.min()) + 1, int(by.max() - by.min()) + 1
    print(f"  hộp bao con trỏ: {width_box}x{height_box}")
    check("con trỏ cao hơn rộng (mũi tên 11x17)", height_box > width_box, f"{width_box}x{height_box}")
    check("con trỏ nằm dưới-phải điểm nóng", bx.max() + x0 > marker_x and by.max() + y0 > marker_y)
    # Cao khoảng 20 point; ảnh có thể ở 2x hoặc 3x nên dải hợp lệ rộng.
    check("kích thước con trỏ hợp lý (30...90 pixel cao)", 30 <= height_box <= 90, f"cao {height_box}")
    return finish(failures)


def finish(failures):
    print("\nKẾT QUẢ:", "TẤT CẢ KHỚP" if not failures else f"{len(failures)} SAI: {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
