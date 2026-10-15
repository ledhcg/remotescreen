#!/usr/bin/env python3
"""Server RFB giả để kiểm thử app mà không đụng vào máy thật.

Phục vụ một ảnh kiểm tra 800x600 có nội dung biết trước (bốn góc bốn màu, lưới, chữ thập), không xác thực (security type 1),
và ghi mọi sự kiện chuột, phím, clipboard nhận được ra file JSON Lines. Khi nhận sự kiện chuột, nó vẽ một ô vuông đánh dấu tại
đúng toạ độ nhận được, nên nhìn ảnh chụp app là thấy ngay chạm đã tới đâu trên "màn hình Mac".

Dùng:  server.py [--host 127.0.0.1] [--port 5959] [--log events.jsonl] [--send-cut-text TEXT] [--append-log] [--apple]
--apple: tự xưng `RFB 003.889` như `screensharingd` để app coi là Mac (bật các tính năng riêng của Apple), và hiểu các message
riêng mà app có thể gửi: 8 (thu nhỏ phía server: chỉ log), 11 và 31 (clipboard: chỉ log), 23 (cử chỉ, cuộn mượt: log đã giải mã
theo docs/protocol-notes.md mục 4h).
--send-cut-text: 2 giây sau khi client nối, gửi một ServerCutText (Latin-1) để thử đường clipboard chuẩn Mac → thiết bị.
Mặc định chỉ nghe loopback. Muốn thử với iPad/iPhone thật thì truyền `--host <IP LAN của Mac>`; server không có xác thực,
nên chỉ mở trong lúc thử rồi tắt.
Chỉ dùng thư viện chuẩn của Python.
"""
import argparse
import asyncio
import json
import struct
import time

WIDTH, HEIGHT = 800, 600
NAME = b"MockMac"
MARKER = 9  # cạnh ô đánh dấu, pixel


def build_test_pattern():
    """BGRA, hàng đầu tiên là hàng trên cùng. Góc trên trái đỏ, trên phải xanh lá, dưới trái xanh dương, dưới phải vàng."""
    quadrant = {(0, 0): (200, 40, 40), (1, 0): (40, 180, 60), (0, 1): (50, 70, 210), (1, 1): (220, 200, 40)}  # R, G, B
    pixels = bytearray(WIDTH * HEIGHT * 4)
    for y in range(HEIGHT):
        for x in range(WIDTH):
            r, g, b = quadrant[(x >= WIDTH // 2, y >= HEIGHT // 2)]
            if x % 100 == 0 or y % 100 == 0:  # lưới mỗi 100 pixel
                r, g, b = r // 2, g // 2, b // 2
            if abs(x - WIDTH // 2) < 2 or abs(y - HEIGHT // 2) < 2:  # chữ thập trắng ở giữa
                r, g, b = 255, 255, 255
            i = (y * WIDTH + x) * 4
            pixels[i : i + 4] = bytes((b, g, r, 0))
    return pixels


class Session:
    def __init__(self, reader, writer, log_path, cut_text=None, apple=False):
        self.apple = apple
        self.reader, self.writer, self.log_path, self.cut_text = reader, writer, log_path, cut_text
        self.frame = build_test_pattern()
        self.dirty = None  # (x0, y0, x1, y1) cần gửi
        self.pending = False  # client đang chờ một cập nhật tăng dần
        self.marker = None
        self.buttons = 0
        self.bpp = 32  # định dạng pixel client đã yêu cầu (SetPixelFormat): 32 (BGRX) hoặc 16 (RGB565 little-endian)
        self.last_pressed = 0  # nút nhấn gần nhất: ô đánh dấu giữ màu của nó sau khi nhả, để ảnh chụp còn thấy chỗ vừa chạm

    def log(self, **event):
        event["t"] = round(time.time(), 3)
        with open(self.log_path, "a") as handle:
            handle.write(json.dumps(event, ensure_ascii=False) + "\n")

    async def read(self, count):
        return await self.reader.readexactly(count)

    # --- Vẽ ô đánh dấu theo chuột ---
    def paint_marker(self, x, y, buttons):
        # Xóa ô cũ bằng cách vẽ lại ảnh gốc ở vùng đó, rồi vẽ ô mới. Màu theo nút nhấn gần nhất: chưa nhấn lần nào trắng, trái magenta, phải xanh ngọc (giữ nguyên sau khi nhả).
        pattern = self._pattern()
        touched = []
        if self.marker:
            touched.append(self._restore(pattern, *self.marker))
        if buttons & 5:
            self.last_pressed = buttons & 5
        colour = {0: (255, 255, 255), 1: (255, 0, 255), 4: (0, 255, 255)}.get(self.last_pressed if self.last_pressed else 0, (255, 128, 0))
        rect = self._draw(x, y, colour)
        touched.append(rect)
        self.marker = (x, y)
        x0 = min(r[0] for r in touched); y0 = min(r[1] for r in touched)
        x1 = max(r[2] for r in touched); y1 = max(r[3] for r in touched)
        self.dirty = (x0, y0, x1, y1) if self.dirty is None else (
            min(self.dirty[0], x0), min(self.dirty[1], y0), max(self.dirty[2], x1), max(self.dirty[3], y1))

    _cached_pattern = None

    def _pattern(self):
        if Session._cached_pattern is None:
            Session._cached_pattern = build_test_pattern()
        return Session._cached_pattern

    def _restore(self, pattern, x, y):
        x0, y0, x1, y1 = max(x - MARKER, 0), max(y - MARKER, 0), min(x + MARKER + 1, WIDTH), min(y + MARKER + 1, HEIGHT)
        for yy in range(y0, y1):
            row = (yy * WIDTH + x0) * 4
            self.frame[row : row + (x1 - x0) * 4] = pattern[row : row + (x1 - x0) * 4]
        return (x0, y0, x1, y1)

    def _draw(self, x, y, colour):
        x0, y0, x1, y1 = max(x - MARKER // 2, 0), max(y - MARKER // 2, 0), min(x + MARKER // 2 + 1, WIDTH), min(y + MARKER // 2 + 1, HEIGHT)
        r, g, b = colour
        for yy in range(y0, y1):
            for xx in range(x0, x1):
                i = (yy * WIDTH + xx) * 4
                self.frame[i : i + 4] = bytes((b, g, r, 0))
        return (x0 - MARKER, y0 - MARKER, x1 + MARKER, y1 + MARKER)

    _cache565 = {}

    def to_rgb565(self, body):
        """BGRX 32 bit -> RGB565 little-endian, theo đúng định dạng client đã xin (đỏ dịch 11, lục dịch 5, lam dịch 0)."""
        cache = self._cache565
        out = bytearray()
        for i in range(0, len(body), 4):
            key = body[i : i + 4]
            value = cache.get(key)
            if value is None:
                b, g, r = key[0], key[1], key[2]
                packed = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
                value = cache[key] = bytes((packed & 0xFF, packed >> 8))
            out += value
        return bytes(out)

    # --- Gửi cập nhật ---
    async def send_rect(self, x0, y0, x1, y1):
        x0, y0, x1, y1 = max(x0, 0), max(y0, 0), min(x1, WIDTH), min(y1, HEIGHT)
        w, h = x1 - x0, y1 - y0
        if w <= 0 or h <= 0:
            return
        body = b"".join(bytes(self.frame[((y * WIDTH + x0) * 4) : ((y * WIDTH + x1) * 4)]) for y in range(y0, y1))
        if self.bpp == 16:
            body = self.to_rgb565(body)
        self.writer.write(struct.pack(">BxH", 0, 1) + struct.pack(">HHHHi", x0, y0, w, h, 0) + body)
        await self.writer.drain()

    async def flush_if_possible(self):
        if self.pending and self.dirty:
            rect, self.dirty, self.pending = self.dirty, None, False
            await self.send_rect(*rect)

    # --- Giao thức ---
    async def handshake(self):
        self.writer.write(b"RFB 003.889\n" if self.apple else b"RFB 003.008\n")
        await self.read(12)
        self.writer.write(bytes([1, 1]))  # một security type: None
        await self.read(1)
        self.writer.write(struct.pack(">I", 0))  # SecurityResult: thành công
        await self.read(1)  # ClientInit
        pixel_format = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
        self.writer.write(struct.pack(">HH", WIDTH, HEIGHT) + pixel_format + struct.pack(">I", len(NAME)) + NAME)
        await self.writer.drain()
        self.log(type="connected")
        if self.cut_text is not None:
            asyncio.get_running_loop().create_task(self.send_cut_text_later())

    async def send_cut_text_later(self):
        await asyncio.sleep(2)
        data = self.cut_text.encode("latin-1", errors="replace")
        self.writer.write(struct.pack(">B3xI", 3, len(data)) + data)
        await self.writer.drain()
        self.log(type="sent_cut_text", length=len(data))

    async def serve(self):
        await self.handshake()
        while True:
            kind = (await self.read(1))[0]
            if kind == 0:  # SetPixelFormat
                data = await self.read(19)
                bpp, depth, big_endian, true_colour = data[3], data[4], data[5], data[6]
                red_max, green_max, blue_max = struct.unpack(">HHH", data[7:13])
                shifts = tuple(data[13:16])
                self.log(type="pixel_format", bpp=bpp, depth=depth, big_endian=big_endian, true_colour=true_colour,
                         max=[red_max, green_max, blue_max], shifts=list(shifts))
                # Chỉ hỗ trợ hai định dạng app dùng. Định dạng khác: giữ nguyên 32 bit (và log để thấy).
                if (bpp, big_endian, true_colour, (red_max, green_max, blue_max), shifts) == (16, 0, 1, (31, 63, 31), (11, 5, 0)):
                    self.bpp = 16
                else:
                    self.bpp = 32
            elif kind == 2:  # SetEncodings
                (count,) = struct.unpack(">xH", await self.read(3))
                encodings = struct.unpack(f">{count}i", await self.read(4 * count)) if count else ()
                self.log(type="encodings", list=list(encodings))
            elif kind == 3:  # FramebufferUpdateRequest
                incremental, x, y, w, h = struct.unpack(">BHHHH", await self.read(9))
                self.log(type="update_request", incremental=bool(incremental))
                if not incremental:
                    await self.send_rect(x, y, x + w, y + h)
                else:
                    self.pending = True
                    await self.flush_if_possible()
            elif kind == 4:  # KeyEvent
                down, key = struct.unpack(">B2xI", await self.read(7))
                self.log(type="key", down=bool(down), keysym=key)
            elif kind == 5:  # PointerEvent
                buttons, x, y = struct.unpack(">BHH", await self.read(5))
                self.log(type="pointer", buttons=buttons, x=x, y=y)
                self.paint_marker(min(x, WIDTH - 1), min(y, HEIGHT - 1), buttons)
                await self.flush_if_possible()
            elif kind == 6:  # ClientCutText
                (length,) = struct.unpack(">3xI", await self.read(7))
                text = await self.read(length)
                self.log(type="cut_text", text=text.decode("latin-1"))
            elif self.apple and kind == 8:  # thu nhỏ phía server: [8][0][double]
                (scale,) = struct.unpack(">xd", await self.read(9))
                self.log(type="server_scaling", scale=scale)
            elif self.apple and kind == 11:  # xin clipboard của Mac
                (token,) = struct.unpack(">3xI", await self.read(7))
                self.log(type="clipboard_request", token=token)
            elif self.apple and kind == 31:  # gửi clipboard lên Mac
                _flags, token, _size, length = struct.unpack(">xBxIII", await self.read(15))
                await self.read(length)
                self.log(type="clipboard_send", token=token)
            elif self.apple and kind == 23:  # HandleEventMessage2: cử chỉ, cuộn mượt
                flags, length = struct.unpack(">BH", await self.read(3))
                self.log(type="apple_event", flags=flags, **decode_apple_event(await self.read(length)))
            else:
                self.log(type="unknown_message", kind=kind)
                return


def decode_apple_event(payload):
    """Giải payload message 23 theo bố cục đọc từ binary (protocol-notes 4h). Không tự đoán thêm: loại lạ chỉ log độ dài."""
    if len(payload) < 4:
        return {"error": "payload ngắn", "length": len(payload)}
    version, kind = struct.unpack(">HH", payload[:4])
    event = {"version": version, "kind": kind, "length": len(payload)}
    if kind in (3, 5) and len(payload) >= 16:
        value, x, y = struct.unpack(">dHH", payload[4:16])
        event.update(name="magnify" if kind == 3 else "rotate", value=value, x=x, y=y)
        if version >= 2 and len(payload) >= 32:
            phase, mask = struct.unpack(">QQ", payload[16:32])
            event.update(phase=phase, mask=mask)
    elif kind == 11 and len(payload) >= 54:
        (line2, line1, line3, fixed2, fixed1, fixed3, point2, point1, point3,
         phase, momentum, count, flags, x, y) = struct.unpack(">hhhiiiiiiIIiIHH", payload[4:54])
        event.update(name="scroll", point_x=point2, point_y=point1, line_x=line2, line_y=line1, fixed_y=fixed1,
                     phase=phase, momentum=momentum, flags=flags, x=x, y=y)
    elif kind == 4 and len(payload) >= 8:
        x, y = struct.unpack(">HH", payload[4:8])
        event.update(name="smart_magnify", x=x, y=y)
    return event


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5959)
    parser.add_argument("--log", default="events.jsonl")
    parser.add_argument("--send-cut-text", default=None)
    parser.add_argument("--apple", action="store_true", help="tự xưng screensharingd (RFB 003.889), hiểu message 8/11/23/31")
    parser.add_argument("--append-log", action="store_true", help="không xóa log cũ (để thấy cả lần kết nối lại sau khi khởi động lại server)")
    args = parser.parse_args()
    if not args.append_log:
        open(args.log, "w").close()  # xóa log cũ

    async def handle(reader, writer):
        session = Session(reader, writer, args.log, args.send_cut_text, apple=args.apple)
        try:
            await session.serve()
        except (asyncio.IncompleteReadError, ConnectionError):
            session.log(type="disconnected")
        finally:
            writer.close()

    server = await asyncio.start_server(handle, args.host, args.port)
    print(f"server RFB giả đang nghe {args.host}:{args.port}, ghi sự kiện vào {args.log}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
