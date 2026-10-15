#!/usr/bin/env python3
"""Mock RFB server for testing the app without touching a real machine.

Serves an 800x600 test image with known content (four differently coloured corners, a grid, a crosshair) with no authentication (security type 1),
and logs every mouse, key and clipboard event it receives to a JSON Lines file. On a mouse event it draws a square marker at
the exact coordinates received, so an app screenshot shows right away where a touch landed on the "Mac screen".

Usage:  server.py [--host 127.0.0.1] [--port 5959] [--log events.jsonl] [--send-cut-text TEXT] [--append-log] [--apple]
--apple: announces itself as `RFB 003.889` like `screensharingd` so the app treats it as a Mac (enabling Apple-specific features), and understands the
Apple-specific messages the app may send: 8 (server-side scaling: logged only), 11 and 31 (clipboard: logged only), 23 (gestures, smooth scrolling: logged, decoded
per docs/protocol-notes.md section 4h).
--send-cut-text: 2 seconds after the client connects, sends a ServerCutText (Latin-1) to exercise the standard Mac -> device clipboard path.
Listens on loopback only by default. To test with a real iPad/iPhone pass `--host <the Mac's LAN IP>`; the server has no authentication,
so open it only while testing and then shut it down.
Python standard library only.
"""
import argparse
import asyncio
import json
import struct
import time

WIDTH, HEIGHT = 800, 600
NAME = b"MockMac"
MARKER = 9  # marker square side, in pixels


def build_test_pattern():
    """BGRA, first row is the top row. Top-left red, top-right green, bottom-left blue, bottom-right yellow."""
    quadrant = {(0, 0): (200, 40, 40), (1, 0): (40, 180, 60), (0, 1): (50, 70, 210), (1, 1): (220, 200, 40)}  # R, G, B
    pixels = bytearray(WIDTH * HEIGHT * 4)
    for y in range(HEIGHT):
        for x in range(WIDTH):
            r, g, b = quadrant[(x >= WIDTH // 2, y >= HEIGHT // 2)]
            if x % 100 == 0 or y % 100 == 0:  # grid line every 100 pixels
                r, g, b = r // 2, g // 2, b // 2
            if abs(x - WIDTH // 2) < 2 or abs(y - HEIGHT // 2) < 2:  # white crosshair in the middle
                r, g, b = 255, 255, 255
            i = (y * WIDTH + x) * 4
            pixels[i : i + 4] = bytes((b, g, r, 0))
    return pixels


class Session:
    def __init__(self, reader, writer, log_path, cut_text=None, apple=False):
        self.apple = apple
        self.reader, self.writer, self.log_path, self.cut_text = reader, writer, log_path, cut_text
        self.frame = build_test_pattern()
        self.dirty = None  # (x0, y0, x1, y1) to send
        self.pending = False  # the client is waiting for an incremental update
        self.marker = None
        self.buttons = 0
        self.bpp = 32  # pixel format the client requested (SetPixelFormat): 32 (BGRX) or 16 (RGB565 little-endian)
        self.last_pressed = 0  # most recent button pressed: the marker keeps its colour after release, so a screenshot still shows where the last touch landed

    def log(self, **event):
        event["t"] = round(time.time(), 3)
        with open(self.log_path, "a") as handle:
            handle.write(json.dumps(event, ensure_ascii=False) + "\n")

    async def read(self, count):
        return await self.reader.readexactly(count)

    # --- Drawing the mouse marker ---
    def paint_marker(self, x, y, buttons):
        # Erase the old marker by redrawing the base image in that region, then draw the new one. Colour follows the most recent button: white if none pressed yet, magenta for left, teal for right (kept after release).
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
        """BGRX 32-bit -> RGB565 little-endian, matching the format the client requested (red shift 11, green shift 5, blue shift 0)."""
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

    # --- Sending updates ---
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

    # --- Protocol ---
    async def handshake(self):
        self.writer.write(b"RFB 003.889\n" if self.apple else b"RFB 003.008\n")
        await self.read(12)
        self.writer.write(bytes([1, 1]))  # one security type: None
        await self.read(1)
        self.writer.write(struct.pack(">I", 0))  # SecurityResult: success
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
                # Only the two formats the app uses are supported. Any other: keep 32-bit (and log it so it shows).
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
            elif self.apple and kind == 8:  # server-side scaling: [8][0][double]
                (scale,) = struct.unpack(">xd", await self.read(9))
                self.log(type="server_scaling", scale=scale)
            elif self.apple and kind == 11:  # request the Mac's clipboard
                (token,) = struct.unpack(">3xI", await self.read(7))
                self.log(type="clipboard_request", token=token)
            elif self.apple and kind == 31:  # send the clipboard to the Mac
                _flags, token, _size, length = struct.unpack(">xBxIII", await self.read(15))
                await self.read(length)
                self.log(type="clipboard_send", token=token)
            elif self.apple and kind == 23:  # HandleEventMessage2: gestures, smooth scrolling
                flags, length = struct.unpack(">BH", await self.read(3))
                self.log(type="apple_event", flags=flags, **decode_apple_event(await self.read(length)))
            else:
                self.log(type="unknown_message", kind=kind)
                return


def decode_apple_event(payload):
    """Decodes the message 23 payload using the layout read from the binary (protocol-notes 4h). No further guessing: an unknown kind logs only its length."""
    if len(payload) < 4:
        return {"error": "payload too short", "length": len(payload)}
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
    parser.add_argument("--apple", action="store_true", help="announces itself as screensharingd (RFB 003.889), understands messages 8/11/23/31")
    parser.add_argument("--append-log", action="store_true", help="keep the old log (so a reconnect after restarting the server is also visible)")
    args = parser.parse_args()
    if not args.append_log:
        open(args.log, "w").close()  # clear the old log

    async def handle(reader, writer):
        session = Session(reader, writer, args.log, args.send_cut_text, apple=args.apple)
        try:
            await session.serve()
        except (asyncio.IncompleteReadError, ConnectionError):
            session.log(type="disconnected")
        finally:
            writer.close()

    server = await asyncio.start_server(handle, args.host, args.port)
    print(f"mock RFB server listening on {args.host}:{args.port}, writing events to {args.log}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
