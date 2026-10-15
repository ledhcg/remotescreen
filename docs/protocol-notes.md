# Protocol notes: Apple Screen Sharing (RFB)

> **Note on provenance.** This document records *behavioural observations* of the Screen Sharing protocol and the inferences drawn from them. It contains no Apple source code. Function addresses and binary hashes have been removed. Apple does not publish this protocol, so the content may be wrong or may change between macOS releases.

Label convention: **[QS]** observed directly, **[SL]** inferred, **[CB]** unknown / needs verification.

Observation environment: macOS 27.0.1 (26A434), local `screensharingd` over loopback, 2026-10-14.
Tools: `rfbprobe` (live probing, no credentials sent) and REA/Hopper (reading the binary).

## 1. Handshake (confirmed with `rfbprobe`)

| Item | Value | Label |
|---|---|---|
| Server version string | `RFB 003.889` | [QS] |
| Client reply | `RFB 003.008`, the server accepts and continues | [QS] |
| Security types, **in the order the server sends them** | `30, 33, 36, 31, 32, 2, 35` | [QS] |

## 2. The server's first response after selecting each type (`rfbprobe --select N`)

| Type | Response within 1.5 seconds | Interpretation | Label |
|---|---|---|---|
| 2 | 16 bytes | Standard VNC Authentication challenge (validates the tool) | [QS] |
| 30 | 1028 bytes | DH structure, see section 3 | [QS] |
| 31 | 1028 bytes, same layout as 30 | A variant of the DH type. **Unclear at which step it differs from 30** | [QS] layout; [CB] difference |
| 32 | 1028 bytes, same layout as 30 | A variant of the DH type. **Unclear at which step it differs from 30/31** | [QS] layout; [CB] difference |
| 33 | 0 bytes, server silent | **The client must speak first** (for example by sending a user identifier) | [QS] silence; [SL] SRP |
| 35 | 0 bytes, server silent | Same as 33 | [QS] silence; [CB] function |
| 36 | 0 bytes, server silent | Same as 33 | [QS] silence; [CB] function |

What can be concluded: **[SL]** 33, 35 and 36 are the types where the client opens the exchange. The `screensharingd` binary imports `ccsrp_server_*` and the RFC 5054 groups (1024/2048/4096/8192), so at least one of these uses SRP. No number could be assigned yet.

## 3. Response structure of types 30, 31, 32 (1028 bytes)

```
offset  length  content
0       2       00 05
2       2       02 00            (= 512)
4       512     prime p          (4096-bit)
516     512     server public key (changes on every connection)
        ----
        1028    = 4 + 512 + 512
```

- **[QS]** The total of 1028 bytes matches `2 + 2 + 512 + 512` exactly, so the second 2-byte field (`0x0200 = 512`) is the key length.
- **[QS]** The 512 bytes of the prime match the leading and trailing bytes of the 4096-bit MODP group in RFC 3526 (starting `FFFFFFFF FFFFFFFF C90FDAA2 2168C234`, ending `... 34063199 FFFFFFFF FFFFFFFF`).
- **[SL]** The first 2-byte field `00 05` is the generator g = 5. Older community documentation usually says g = 2 for the 1024-bit group, so this is a difference to watch for.
- **[CB]** The whole prime has not been checked byte by byte against RFC 3526. How the AES key is derived from the shared secret is unknown (the earlier assumption: MD5 of the shared secret, **not verified for this 4096-bit group**).

**Design consequence:** the big-number library must handle **4096-bit** values, not 1024-bit as the original plan said.

**Measured performance [QS]** (home-grown `BigUInt`, Montgomery multiplication, Apple Silicon, release build; one modexp):

| Exponent | Time |
|---|---|
| 512-bit | ≈ 38 ms |
| 4096-bit (full) | ≈ 287 ms |

One DH exchange needs 2 modexps (the client's public key and the shared secret). The initial assumption that "a short exponent is required to be fast enough" is **wrong**: a short exponent is only an optional optimisation. The current default is 512-bit. Not yet measured on a real iPhone, so the figures for a device need to be re-measured. The debug build is about 20 times slower (0.9 s and 6 s).

## 4. Observations from the binary (see the earlier analysis)

- **[QS]** `screensharingd` embeds ZRLE (`EncodeZRLE.c`), zlib, JPEG DCT, a cursor with cached IDs, two HEVC streams (`RFBMediaStreamMessage1`), `DisplayInfo`/`DisplayInfo2`, and bandwidth measurement.
- **[QS]** The ARD session key uses `CCCryptor` AES-ECB (`viewer->AESKeyECB`).
- **[QS]** SRP uses corecrypto's `ccsrp_*` functions (`ccsrp_server_compute_session`, `ccsrp_server_generate_public_key`, `ccsrp_server_verify_session`, `ccsrp_ctx_init`) and the groups `ccsrp_gp_rfc5054_{1024,2048,4096,8192}`.
- **[QS]** The caller of `ccsrp_server_compute_session` is not recognised by the binary reader: it recognises the function that contains it, so the logic could not be read yet.
- **[CB]** The hash used in SRP (SHA-1 or SHA-256), the number padding, the message format, and which group is used with which type: unknown.
- **[CB]** corecrypto has no public API on iOS, so SRP must be implemented from scratch. That is why the details above must be known exactly.

## 4b. Apple's SRP (read from the binary + experiments, round 2)

The handler lives in the `arm64e` slice of `screensharingd`, with the original names `srp_server_mech_step1/step2` in `common/srp.m`.

**Observations from the binary [QS]:**

| Item | Value |
|---|---|
| Format used to read the client's step 1 message | `"%s%s%s%o"` |
| Format used to read the client's step 2 message | `"%m%-o%s%-o"` (`%-o` is a variant of `os`, **where it differs is unknown**) |
| Default group | `rfc5054_4096` (1024/2048/8192 are also supported) |
| Default hash function | `sha512` (`SHA-512`) |
| KDF | `SALTED-SHA512-PBKDF2` |
| Options in the message | `mda=`, `maxbuffersize=`, `replay_detection`, confidentiality + integrity, KDF |
| User data source | Looks up the record via OpenDirectory, gets the salt via `customFunction` |
| Security layer after authentication | Yes (`LayerInit`, random IV `sIV`). **The session may be encrypted** |
| Kerberos / GSS | Yes, the strings `GSS_S_BAD_MECH`, `gss-code`, `KerberosProcessesCipherMessage` are present |

**Inference [SL]:** this code derives from the cyrus-sasl SRP plugin (`ScreenSharing.plist` records `SRP` from `cyrus-sasl 1.59`, the function names match, the error messages match). Apple's step 1 format matches the original `{ utf8(U) utf8(I) utf8(sid) os(cn) }` exactly.

**Buffer encoding conventions of the original cyrus-sasl (for reference; Apple's version may differ):**

| Type | Encoding |
|---|---|
| Whole buffer | 4-byte length (big-endian) + content |
| `utf8` (`%s`) | 2-byte length + bytes |
| `os` (`%o`) | 1-byte length + bytes |
| `mpi` (`%m`) | 2-byte length + bytes |
| `uint` (`%u`) | 4 bytes |
| `char` (`%c`) | 1 byte |

**Experiments with `rfbprobe --send-hex` (sending only an account name, no password) [QS]:**

| Type | Sent | Response |
|---|---|---|
| 33 | Any 4 bytes, or a step 1 message (with or without a length prefix) | Connection closed immediately, 0 bytes |
| 36 | as above | Connection closed immediately, 0 bytes |
| 35 | step 1 message with a 4-byte prefix | Echoes the first 4 bytes, then closes |
| 35 | step 1 message without a prefix | `00 09 64 69` (the first 4 bytes of the body), then closes |
| 35 | `00000000` | Echoes `00000000`, keeps the connection open, waits for more |
| 35 | `00000001` or `ffffffff` | Echoes the 4 bytes, then closes |

**Not yet explained [CB]:**
- Why type 35 echoes the first 4 bytes and reacts differently depending on the value. It may be an exchange of one 32-bit word before entering SRP, but that is speculation.
- 33 and 36 close the connection immediately, even on messages that are valid in the cyrus format. One of the two may be Kerberos (which needs a GSS token), but there is no evidence for assigning numbers.
- The RFB framing wrapped around the SRP buffers.

**Conclusion:** blind probing has run out of value. Learning the exact details needs one of two things: (a) capture the traffic of an Apple client from a second Mac, (b) keep reading the buffer-splitting function and the caller of `srp_server_mech_step`.

## 4c. Implementation status (RFBKit)

| Component | Status | Verification |
|---|---|---|
| Handshake, security type listing | Done | Real server + unit tests |
| Type 1 None, type 2 VNC Authentication | Done | DES checked against OpenSSL; flow checked with a fake stream. **Not yet tried against a real server** (needs a VNC password) |
| Type 30 Apple Remote Desktop | Done | Big numbers checked against Python; two-way DH with a fake server using the real 4096-bit prime. **Real login succeeded** (2026-10-14, `rfbprobe --login 30` against `screensharingd` on macOS 27.0.1) |
| `ClientInit` / `ServerInit` / `PixelFormat` | Done | Unit tests + real server |
| `SetPixelFormat` / `SetEncodings` / `FramebufferUpdateRequest`, `RFBSession`, `Framebuffer` | Done | Unit tests + **real server**: received a complete Raw frame (2048×1152, 9216 KiB, ≈ 0.56 s over loopback) and compared it by eye with the real UI, colours correct, no row skew |
| Raw, CopyRect decoders, pseudo DesktopSize / LastRect | Done | Unit tests. Raw verified against a real server. **CopyRect not yet seen sent by a real server** because we have only declared Raw |
| ZRLE decoder (continuous zlib, 7 tile types) | Done. **First frame verified against a real server**; multiple consecutive updates await verification (`--watch`) | Unit tests: tiles computed by hand per RFC 6143, consecutive zlib stream compressed by Python. Real server (2026-10-14, `--compare-encodings`): requested Raw then ZRLE on the same connection, **0/2,359,296 pixels differ**; Raw 9216 KiB / 0.54 s, ZRLE 829 KiB / 0.05 s (11.1× compression) |
| Continuous incremental ZRLE updates | **Verified** [QS] | Recorded 8 seconds of real bytes from the server (290 updates, 40,478 tiles, 22.7 MiB compressed to 440 MiB, one continuous zlib stream) and decoded them with an **independent Python decoder**: **0/2,359,296 pixels differ** from the Swift decoder. See section 4d |
| Cursor pseudo-encoding (-239) | **Works**: the server sends it when the cursor shape changes [QS] | 6 cursor events in 15 seconds while the user moved the mouse; last cursor 16×16, hotspot (5, 8). The server does **not** send it with the first frame (the `--compare-encodings` run did not receive one). My earlier assumption "the server does not support -239" was **wrong** |
| CopyRect | Decoder done; **0 times sent by the server during the `--watch` run** [QS] | No conclusion yet that the server never uses it, since it is unknown whether the user dragged a window or scrolled a page during the run |
| Hextile, Zlib, Tight decoders | Not done | |

**On the final-frame comparison of `--watch` [explained]:** comparing the accumulated frame against a Raw frame fetched afterwards **cannot give a clean result while the screen is moving**. The control experiment shows this: the identical run, but receiving **Raw** (no compression decoder), still gave 229,003 differing pixels (9.7%), more than ZRLE (27,133 pixels, 1.15%), because the screen then had up to ~47 updates/second. The first run (102,412 pixels) was also disturbed by the tool printing to the terminal on the very screen being captured; fixed by taking the reference frame before printing. The conclusion about the decoder's correctness therefore rests on the parallel decoding in section 4d, not on this comparison.

Design note about zlib [QS, via tests]: zlib only checks Adler32 at the end of the stream, and an RFB stream does not end mid-session, so a bit flipped in the compressed data still decodes to wrong data **without any error**. Detecting stream desynchronisation must rely on ZRLE-layer checks (extra or missing bytes after the last tile, runs that exceed the tile, bad palette indices) and on a cap on the decompressed size (against zip bombs).
| Types 31, 32, 33, 35, 36 | **Not supported**, returns `unsupportedSecurityType` | See section 4b |

**Confirmed with a real login [QS]** on the 4096-bit DH group of type 30: AES-128 key = MD5(shared secret padded to 512 bytes) and the 128-byte login block = name (64) + password (64), each field terminated by NUL. The client's 512-bit private exponent was accepted by the server.

After authentication, `ServerInit` reads [QS]: 2048 × 1152, name `Mac mini`, pixel format 32 bpp / depth 24 / little-endian / true colour / max 255 / shift R16 G8 B0, i.e. the bytes in memory are B, G, R, X, which matches `MTLPixelFormat.bgra8Unorm`.

Trying a real login and capturing a frame (the password is read only from an environment variable and is never printed; the image contains the whole screen, and the `.snapshots/` directory is in `.gitignore`):

```sh
read -s "RFB_PASSWORD?Password: "; export RFB_PASSWORD
RFB_USER=<account name> swift run -c release -q rfbprobe 127.0.0.1 5900 --login 30 --snapshot .snapshots/first-frame.png
```

## 4d. Verifying ZRLE decoding with an independent decoder

**Method.** `rfbprobe --watch N --record FILE --dump-frame FILE` writes out every byte the server sends (after `ServerInit`) verbatim, plus the frame built by the Swift decoder. `Tools/replay-check/zrle_replay.py` decodes exactly those bytes again using Python's numpy and zlib (without reusing the Swift code) and then compares pixel by pixel. Both sides decode the same data, so the result does not depend on whether the screen is moving. **The recording contains screen content: do not commit it, delete it after use** (`.snapshots/` and temporary recording files should not be in the repo).

**Result [QS]** (macOS 27.0.1, 2026-10-14): 290 `FramebufferUpdate`s, all ZRLE (no Raw, CopyRect or Cursor in the recorded stretch); 22,735 KiB compressed → 439,667 KiB after decompression; **0 pixels differ**.

**Important finding [QS]:** of 40,478 real tiles, **100% are the raw type** (sub-encoding 0). The Apple server does not use solid-colour tiles, palettes or RLE; all compression is done by zlib. Consequences:
- Real data **only verifies the raw path** of the decoder.
- The other six tile types (solid colour, palette 1/2/4-bit, RLE, palette RLE) were verified with `Tools/replay-check/make_zrle_fixture.py`: an independent ZRLE **encoder** (Python) that builds an image with known-correct pixels covering all seven tile types, runs longer than 255, rectangles not on the 64 grid, and two rectangles in the same zlib stream. The Swift test `ZRLERoundTripTests` decodes the image, which must match the MD5. Checked by mutation: deliberately breaking the palette bit shift, the run length, the palette-RLE flag, and the neighbouring tile offset was caught by the tests in all four cases.
- Remaining limitation: the encoder and the decoder were both written by the same person with the same understanding of the specification. They catch implementation bugs, but not a misreading of the specification in tile types the Apple server does not send. When another VNC server (TigerVNC, UltraVNC...) is available, the parallel decoding should be run again on its data.

## 4e. Clipboard (measured and read from the binary on 2026-10-14)

**Short conclusion [QS]:** the Apple server does **not** use the standard `ServerCutText`/`ClientCutText` to synchronise the clipboard. It uses its own **request-response** messages, with UTF-8 (Vietnamese and emoji pass through intact). Both directions were verified against a real `screensharingd` over the LAN.

### How it was found

1. `strings screensharingd` shows `HandleViewerClipboardRequest`, `HandleViewerClipboardSend`, `HandleAutoPasteboardCommand`,
   `RFBAutoPasteboardMessage`, "uncompressed size %u pasteboardDataCnt %d", "only want promises".
2. `otool -arch arm64e -tV` (Hopper cannot resolve functions in this binary). The main message-handling function reads the type byte into `[sp+0xab]`,
   does `cmp w8, #0x25` and then jumps through a **jump table** (38 entries, signed 32-bit offsets relative to the `adr` instruction).
   Read the table with Python, then match the target addresses against the `Handle...` log strings in each function.
3. Direct experiments with `rfbprobe --clipboard-request`, `--send-apple-clipboard`, `--clipboard-probe`.

### Map of client → server message types (the clipboard-related part)

| Type | Function | Notes |
|---|---|---|
| 6 | `HandleViewerCutTextMessage` | Standard `ClientCutText`. The server handles it but **ignores** it if `[session+0x60c]`, a global variable, or `[session+0xe22]` is non-zero. In the measured sessions, sending it **did not change** the Mac clipboard (both loopback and LAN, in Latin-1, UTF-8 and MacRoman). Not used. |
| 11 (`0x0b`) | `HandleViewerClipboardRequest` | 8 bytes. Byte 1 bit 0 = "ask for promises only". Bytes 4-7 = a code the server echoes. |
| 21 (`0x15`) | `HandleAutoPasteboardCommand` | 8 bytes (`RFBAutoPasteboardMessage`). A 16-bit big-endian number at offset 2, only 1 or 2 accepted. Turns on automatic clipboard tracking. **After sending 1 or 2 and then changing the Mac clipboard, the server stayed silent** for 10 seconds. Not understood, **not used**. |
| 31 (`0x1f`) | `HandleViewerClipboardSend` | Sends the clipboard to the Mac, format below. |
| 33 (`0x21`) | `HandleViewerInfoMessage` | Not clipboard-related (mistaken once: do not assign by address proximity, go by the jump table). |

### Message type 31 (both directions, same format) [QS]

```
u8  31
u8  0
u8  flags (bit 0 = "promise", 0 observed)
u8  0
u32 code                     (chosen by the client; the server echoes it in the ClipboardRequest answer)
u32 decompressed size        (<= 100 MiB on the server side)
u32 compressed data size     (<= 100 MiB on the server side)
... compressed data
```

Confirmed: sending `0b 00 00 00 de ad be ef` received `1f 00 00 00 de ad be ef 00 00 01 e4 00 00 01 08 78 da ...` within 0.5 seconds.

The compressed data is **zlib level 9 (`78 da`), ending with a sync flush, the stream NOT closed** (decompressing with Python's `zlib.decompress` reports "incomplete or truncated"; `decompressobj` must be used). The reverse direction (client → server) also accepts exactly this form.

### Payload after decompression [QS], 32-bit big-endian integers

```
u32 number of representations
each representation:
    u32 length, UTI                         e.g. "public.utf8-plain-text"
    u32 flags                               always 0
    u32 number of attribute pairs
    each pair: u32 length, key; u32 length, value
    u32 length, data
```

For text, the server sends three representations in this order: `public.utf8-plain-text` (UTF-8), `com.apple.traditional-mac-plain-text` (MacRoman, **loses characters it cannot represent**), `public.utf16-plain-text` (**UTF-16 big-endian, no BOM**). Parsing and then re-encoding the real payload reproduces it byte for byte (with tests).

A client sending to the Mac needs only UTF-8 + UTF-16: checking `pbpaste` afterwards returns exactly `Xin chào Việt Nam đệ ố ữ 🙂`.

### Unknown [CB]

- The condition that makes the server ignore the standard `ClientCutText` (the three flags above). It could be the account's "view only" permission or a session option.
- Whether the server pushes the clipboard to the client by itself when the Mac's changes, and how (type 21 is not enough). For now only request-response is used.
- The format for non-text content (images, files, RTF): not tried.

## 5. What remains of Phase 0

| Question | How to answer it | Status |
|---|---|---|
| What are types 33/35/36, and what does the client send first | Keep reading the relevant code, or capture an Apple client's packets from another machine | Not done |
| The difference between 30, 31, 32 | Same approach | Not done |
| SRP hash and padding | Same approach | Not done |
| Encoding IDs Apple uses (cursor cache, DisplayInfo, MediaStream) | Needs authentication to finish, then read the client's `SetEncodings` | Not done |
| HEVC and audio message framing | Packet capture + REA | Not done (gate for Phase 6) |

### Constraints encountered

- **[QS]** The Apple client refuses to connect to this very machine (`You cannot control your own screen.`) and does not open a socket, so **packets cannot be captured over loopback**. A second Mac is needed to capture an Apple client's traffic.

## How to reproduce

```sh
swift run -q rfbprobe 127.0.0.1 5900               # list the security types
swift run -q rfbprobe 127.0.0.1 5900 --select 30   # print a hex dump of the first response
```

Clipboard probing (needs RFB_USER/RFB_PASSWORD; prints content only when it starts with `rfbprobe-marker`, and **back up then restore the Mac clipboard**
before and after):

```sh
rfbprobe HOST 5900 --login 30 --clipboard-probe 10 --clipboard-request                 # ask for the Mac clipboard
rfbprobe HOST 5900 --login 30 --clipboard-probe 4 --send-apple-clipboard "rfbprobe-marker-x"   # send to the Mac
```

The tool only reads the version, the type list and the first response. It never sends a password or credentials.

## 4f. Encodings and pixel formats the Apple server accepts (measured 2026-10-14, macOS 27.0.1, `rfbprobe --probe-encodings`)

| Client request (`SetEncodings`) | Server returns | Label |
|---|---|---|
| ZRLE (16) | ZRLE | [QS] |
| Tight (7) + JPEG quality 5 + ZRLE | **ZRLE** (Tight ignored) | [QS] |
| Hextile (5) | **Raw** | [QS] |
| RRE (2) | **Raw** | [QS] |
| Zlib (6) | Zlib | [QS] |
| `SetPixelFormat` 16-bit RGB565 (redMax 31, greenMax 63, blueMax 31, shift 11/5/0) + Raw | Raw, **exactly 2 bytes per pixel** | [QS] |
| `SetPixelFormat` 16-bit + ZRLE | ZRLE (2-byte CPIXEL), decoded with correct colours (99.4-99.99% of pixels within ±8 of 32-bit) | [QS] |
| `SetPixelFormat` 8-bit BGR233 | **Closes the connection** | [QS] |

[CB] Whether changing `SetPixelFormat` **mid-session** is safe with the Apple server: not tried. Reason for not trying: RFB does not mark which update uses which format, so an update in flight at the moment of the change may be in the old format. The app picks the format at connection time.

## 4g. Apple's own messages for display, gestures and keyboard (read from the binary + real tests, 2026-10-14)

The jump table of the message dispatcher. The handler branches are written **inline in** the dispatcher function; look them up by the `Handle...` log strings inside each branch.

| Type | Function | Format / behaviour | Label |
|---|---|---|---|
| 8 | `HandleSetServerScalingMessage` | 10 bytes: `[8][0][double IEEE 754 big-endian]`. The scale must be in (0, 1] (the `fcmp`/`fccmp` instructions reject ≤ 0 and > 1). Stored at `viewer+0x580`. | [QS] binary |
| 8 | (real test) | Scale 0.5 → the server returns **`DesktopSize` 1280x720** and then **waits**, it does not resend the whole image by itself; 0.75 → 1920x1080. Later updates are in the scaled-down coordinates. **The Mac screen does not change**: only this viewer's stream gets smaller. The client must request a **non-incremental** update again at the new size. | [QS] real test |
| 8 | Coordinates | A leaf function divides (x, y, width, height) by the scale when the flag `viewer+0x57a` is on, called from the type 3 branch (FramebufferUpdateRequest): the requested update region is converted from viewer coordinates to real coordinates. A similar conversion was **not found** in the type 5 branch (PointerEvent: reads x, y at offsets 2, 4, calls (address removed) then (address removed)). The app assumes mouse coordinates are also in viewer space. **Not verified by experiment** (needs moving the mouse on a real Mac). | [SL] |
| 29 | `HandleSetDisplayConfiguration` | 12-byte header: u16 big-endian "message size" at offset 2 (minimum 192), u16 "messageVersion" at offset 4, u16 display count at offset 6 (at most 2, "resetting to 2"), u32 flags at offset 8; then the `displayInfo` entries (size in mm, list of display modes, refresh rate). Creates a **virtual display** (`SSAgentVirtualDisplay ... dynamicResolution:`), with a `blankScreen` parameter (darkens the real screen). **Not used**: it changes the Mac's display configuration. | [QS] binary, not tried |
| 23 | `HandleEventMessage2` | Gestures, smooth scrolling. Format: see section 4h. | [QS] binary + real Mac (types 3, 5, 11) |
| 26 | `HandleSetKeyboardInputSource` | The viewer reports the keyboard layout in use. Format unknown. | [QS] strings |

Apple-specific encodings in `HandleSetEncodingsMessage` (address range removed): 1010 turns on the "ScreenSharing/ProMode" flag (High Performance, video via AVConference), 1107 "vendor keysyms supported", 1109 "keyboard input language encoding supported", 1100-1106 and 1110 unclear. There is a separate lossy encoder (`EncodeMultiVariant.c`, 8x8 blocks, with DCT) whose encoding number is unknown. [QS] strings, not tried.

ExtendedDesktopSize (-308) is **not supported**: when requested, the first update contains only ZRLE, with no -308 rectangle (`rfbprobe --probe-desktop-size`). [QS]

Cursor shape (-239): the server **does not send** it to a viewer that has not yet sent any mouse event (first 200 updates, both 32 and 16 bit, `rfbprobe --probe-cursor`). So it has not been measured in which format the server sends cursor pixels when the client asks for 16 bit. [QS]

## 4h. Message type 23 (`HandleEventMessage2`): gestures and smooth scrolling (binary read 2026-10-14, real Mac tried 2026-10-15)

Both ends were read: `screensharingd` (checks the size, swaps bytes, forwards the payload unchanged through the MIG `SSAgent_PostGestureEvent_rpc`) and `ScreensharingAgent` (`agent_SSAgent_PostGestureEvent_rpc` in the arm64e slice, builds a `CGEvent` and calls `CGEventPost`). [QS] binary for the layout; **the semantics of some fields are inferred** [SL], because nothing has been sent to a real Mac yet (needs the user's permission).

**Frame**: `[23][flags u8][u16 BE payload length, < 50 001][payload]`. Flags bit 0 = 1: the minimum size grows by 8, meaning unclear; send 0. The payload starts with `u16 BE version` and `u16 BE type` (1…12); every number in the payload is big-endian (the server swaps before forwarding). A payload shorter than the minimum: the server **closes the connection** ("message size too small %d %d closing connection"). A viewer in view-only mode: ignored.

| Type | Minimum size | What the agent does | Payload layout (offset: type → meaning) |
|---|---|---|---|
| 1, 2 | 12 | mouse event (separate path, "lookup gesture") | 4: u32, 8: u16, 10: u16. Not decoded |
| 3 | 16 (v1), 32 (v2) | `CGEvent` type 29 (gesture), field 110 = 8 (`kIOHIDEventTypeZoom`), field 113 = magnification | 4: double → magnification (`NSEvent`'s `magnification`); 12: u16 x; 14: u16 y (framebuffer pixels, converted to screen coordinates by (address removed)). v1: field 133 = 4. v2 (version ≥ 2): 16: u64 → field 132 ("phase"), 24: u64 → field 133 ("mask") |
| 4 | 8 | gesture, field 110 = 22, field 133 = 2, log "zoom toggle" (smart zoom, two-finger double tap) | 4: u16 x; 6: u16 y |
| 5 | 16 (v1), 32 | gesture, field 110 = 5 (`kIOHIDEventTypeRotation`), field 114 = rotation | as type 3 (4: double rotation, 12/14: x/y, v2 adds phase/mask) |
| 6 | 48 | swipe/"fluid" ("x %f y %f motion %lld swipemask …") | 4…43: 10 32-bit numbers; 44/46: x/y. Not decoded |
| 8 | 32 | not read | 4…27: 6 32-bit numbers; 28/30: x/y |
| 9 | 36 | "deprecated scroll wheel event" | skipped, use type 11 |
| 10 | 4 | no data | |
| 11 | 54 | `CGEvent` type 22 (`kCGEventScrollWheel`), public fields | 4: s16 → `DeltaAxis2` (12, horizontal, lines); 6: s16 → `DeltaAxis1` (11, vertical); 8: s16 → `DeltaAxis3`; 10: s32 → `FixedPtDeltaAxis2` (94); 14: s32 → `FixedPtDeltaAxis1` (93); 18: s32 → `FixedPtDeltaAxis3` (95); 22: s32 → `PointDeltaAxis2` (97); 26: s32 → `PointDeltaAxis1` (96); 30: s32 → `PointDeltaAxis3` (98); 34: u32 → `ScrollPhase` (99); 38: u32 → `MomentumPhase` (123); 42: s32 → `ScrollCount` (100); 46: u32 flags (bit 0 → field 14 `InstantMouser`, bit 1 → field 88 `IsContinuous`, bit 2 → field 137); 50: u16 x; 52: u16 y |
| 12 | 22 | handled separately inside `screensharingd` | not read |

Implications for the app:
- **Trackpad-style smooth scrolling** (type 11): send distances in points (`PointDelta`), the scroll phase (`kCGScrollPhase`: begin 1, change 2, end 4) and the momentum phase (`kCGMomentumScrollPhase`: begin 1, continue 2, end 3), and the "continuous" flag. The Mac scrolls smoothly by itself, with edge bounce, like a real trackpad. This replaces the discrete button 4/5 wheel notches of standard RFB.
- **Pinch and rotate** (types 3 and 5) plus **smart zoom** (type 4) carry coordinates: Preview, Maps and Safari receive them as trackpad gestures.

**Tried on a real Mac** (macOS, 2560x1440 1x display; a test AppKit window records `NSEvent`s; `rfbprobe --apple-gesture-test`, `--apple-raw`): [QS]
- Type 11: arrives in full. `scrollingDeltaY` = the `PointDeltaAxis1` sent (same sign, same magnitude), `hasPreciseScrollingDeltas` = true. `kCGScrollPhase` 1/2/4 → `NSEvent.phase` began/changed/ended; momentum 1/2/3 → `momentumPhase` began/changed/ended.
- Types 3 and 5 **version 1** (16 bytes, no phase): the server accepts them and does not close the connection, but **no application receives an event**.
- Types 3 and 5 **version 2** (32 bytes): the u64 phase at offset 16 = 1 (began), 2 (changed), 4 (ended), like the scroll phases → `NSEvent.phase` began/changed/ended; `magnification`/`rotation` exactly equal the double sent (positive rotation = counter-clockwise). The u64 "mask" at offset 24: 0, 2, 4, 8 give the same result. The app sends version 2, with began and ended carrying the value 0.
- The x, y coordinates are framebuffer pixels, like `PointerEvent`. Whether they are rescaled while scaled down on the server side (type 8) is unclear (same question as for `PointerEvent`).
