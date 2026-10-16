# iPhone/iPad app status

Updated: 2026-10-14. The app is named **Screon** and its bundle id is `com.ledinhcuong.screon`.

## Localization

English is the source language of all UI strings (in code, tests and docs); Vietnamese is a translation kept in the `vi.lproj` string tables. Test and measurement entries below quote the UI wording in English. The rules (the `tr(...)` helper, table locations, forced language in tests) are in `.claude/rules/localization.md`. Some UI strings below were quoted from the earlier Vietnamese wording and are given here in English; check the `vi.lproj` tables for the exact current text.

## Architecture

```
Sources/
  RFBCrypto/      DES, AES-ECB, MD5, 4096-bit big numbers (Montgomery), random numbers
  RFBKit/         RFB protocol: handshake, authentication (None, VNC, ARD), Raw/CopyRect/ZRLE, Cursor, session, send queue
  RemoteDisplay/  viewport geometry, Metal renderer (runs on macOS for tests), ScreonView (UIKit)
  InputKit/       keyboard → X11 keysym, touch gestures → mouse events, virtual keys and sticky modifiers (pure logic, no UIKit)
  SessionKit/     reconnect policy (ReconnectPolicy), clipboard sync (ClipboardBridge, pure logic, abstract pasteboard), user-facing messages
  ConnectionKit/  saved computers (atomically written JSON), password store (interface; the Keychain is in the app), form validation, Bonjour discovery
  Localization/   shared localization support (the `Localization` target; string tables live in each package's `Resources/vi.lproj`)
Tools/
  rfbprobe/            command-line protocol diagnostic tool (not used in the app)
  replay-check/        independent ZRLE decoder/encoder in Python for cross-checking
  mock-rfb-server/     fake RFB server + end-to-end input test scripts
App/
  project.yml          source of truth for the Xcode project (XcodeGen). The .xcodeproj file is generated, not committed.
  ScreonApp/     SwiftUI: connection screen, viewer screen, SessionController
  ScreonAppUITests/  input XCUITests
```

## How to run

| Task | Command |
|---|---|
| All package tests (macOS) | `swift test` |
| Xcode project | `cd App && xcodegen generate` |
| Build for the simulator | `xcodebuild -project App/ScreonApp.xcodeproj -scheme ScreonApp -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath App/build CODE_SIGNING_ALLOWED=NO build` |
| End-to-end input test (does not touch a real machine) | `Tools/mock-rfb-server/run_input_test.sh <UDID>` |
| UI tests for choosing a computer, login, toolbar, view-only, display modes, quality (fake server; argument 2 is the folder for simulator screenshots) | `Tools/mock-rfb-server/run_ui_test.sh <UDID> [screenshot folder]` |
| Hardware keyboard end-to-end on the simulator (fake server) | `Tools/mock-rfb-server/run_keyboard_test.sh <UDID>` (runs on both iPhone and iPad) |
| Trying it against a real Mac from the simulator | `SIMCTL_CHILD_RFB_HOST=127.0.0.1 SIMCTL_CHILD_RFB_USER=<account> SIMCTL_CHILD_RFB_PASSWORD=<password> xcrun simctl launch <UDID> com.ledinhcuong.screon` (DEBUG build only) |

## Running on a real iPhone/iPad

An Apple Developer team is needed for signing. This machine's signing settings are in `App/Signing.local.xcconfig` (not committed), for example:

```
DEVELOPMENT_TEAM = <TEAM_ID>
CODE_SIGN_STYLE = Automatic
```

```sh
cd App && xcodegen generate
xcodebuild -project ScreonApp.xcodeproj -scheme ScreonApp \
  -destination 'platform=iOS,id=<device UDID>' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <device UDID> build/Build/Products/Debug-iphoneos/ScreonApp.app
```

The phone must be **unlocked** for `devicectl device process launch` to open the app. The first time, you may need to trust the certificate:
Settings > General > VPN & Device Management.

Status (2026-10-14): **built, signed, installed and run** on an iPad Air 4 (iPad13,1, iPadOS 27.0.1); it connected to a real Mac (tried by the user). It was installed on an iPhone 12 Pro Max but could not be opened because the device was locked at install time.

The first attempt on the iPad reported `NWError 50` (`ENETDOWN`, "Network is down"). Two things were fixed: (1) `NWByteStream.connect(waitingPatience:)` no longer treats `.waiting` as a fatal error for recoverable system errors (50, 51, 65, the DNS PolicyDenied of the Local Network permission), and instead waits up to 20 seconds, because iOS keeps the connection in `.waiting` while the permission dialog is showing. `ECONNREFUSED` also goes through `.waiting` on macOS (measured: 21 seconds lost if waited on by mistake), so it is still reported immediately. (2) `SessionController.describe` states what to do for each network error code. **The real cause of error 50 on the iPad is not confirmed**: it could be that the Local Network permission was not granted, or that the iPad's Wi-Fi was off or on a different network.

## Verified

| Item | Evidence |
|---|---|
| Correct content, colours and position are displayed | App in the simulator connected to a fake server with a test image of known content: the 4 corners have the exact colour values, black letterbox border |
| A real Mac screen is displayed, with continuous updates | App in the simulator connected to a real `screensharingd`, content seen changing between captures |
| GPU drawing matches the CPU coordinate transform | Real Metal test reading pixels back (`FramebufferRendererTests`), including when zooming and panning |
| One-finger tap, double tap, two-finger tap (right click), press-and-hold then drag | XCUITest + fake server: 13 checks match |
| Virtual keyboard (`A`, `b`, Return), no stuck keys | As above |
| The send queue keeps the right order (press before release) | 4 tests, 200 event pairs |
| **Real iPad**: one-finger tap at the right coordinates | The fake server received (201,220), (599,449), (300,399) for targets (200,220), (600,450), (300,400): off by ≤ 1 Mac pixel |
| **Real iPad**: double tap, press-and-hold then drag | Two clicks 106 ms apart at the same point; left button pressed after holding for 0.36 s, moved while holding the button, released at the right place |
| **Real iPad**: the remote cursor is drawn in the right place | Screenshot: the arrow coincides with the fake server's marker. On the simulator: `run_cursor_test.sh`, off by ≤ 1 image pixel. GPU: `CursorRenderingTests`, mutation-tested |
| **Real iPad**: toolbar buttons, no click-through to the Mac | `toggleKeyboard`/`toggleActualSize` log lines were called; the fake server received no mouse from the button press |
| **Real iPad**: hardware keyboard (letters, Shift+letter, arrows, Ctrl+letter, Option+letter) | The fake server received the correct keysyms and press/release order |
| **Real iPad**: save a computer, persistence across restarts, password retrieved from the **real Keychain**, delete | The "Saved computers" item appears after connecting; still there after reopening the app; tapping it connects directly (no password prompt); swiping then Delete makes the item disappear |
| **Real iPad**: Bonjour discovery | The "Computers on the network" item shows the correct name of the Mac on the network; selecting it changes the form to "Selected" |
| Real Bonjour on macOS | `ServiceBrowserLiveTests`: a service advertised inside the test process is found, disappears when stopped, and can be connected to through the `.service` endpoint |
| Real Keychain | `ScreonAppTests` on the simulator (needs signing, cannot run with `CODE_SIGNING_ALLOWED=NO`: error -34018); mutation-tested |
| Apple clipboard (type 11 request, type 31 reply/send): decoding the server's **real** payload, encoding, corrupt/malicious data | `ClipboardTests` (35 tests) using a real 264-byte payload + a payload produced by Python's zlib; re-encoding gives exactly the same bytes; mutation-tested |
| Apple clipboard with a **real Mac** (`rfbprobe`) | Asking for the Mac clipboard returns Vietnamese intact; sending `Xin chào Việt Nam đệ ố ữ 🙂` to the Mac makes `pbpaste` output exactly that string |
| **Real iPad → real Mac**: the Get from Mac button | The notice "Copied 32 characters from the Mac." has exactly the length of the Vietnamese test string that was set |
| **Real iPad → real Mac**: ⌘V pushes the iPad clipboard to the Mac | The Mac clipboard `changeCount` rose 236→237 after allowing the paste (the content could not be told apart from the Mac clipboard because Device Hub syncs the Mac clipboard to the iPad) |
| **Real iPad + standard (fake) server**: Mac→iPad (`ServerCutText`) and iPad→Mac (⌘V produces a `ClientCutText` placed BEFORE the v key) | Fake server log: `cut_text "mock-clip-1 café"` appears between `Meta_L` press and `v` press |
| **Real iPad**: automatic reconnect | Stopping the fake server mid-session: the banner "Reconnecting (3/6)", reopening the server makes the app reconnect after ~3 s, on the correct backoff schedule |
| `ReconnectPolicy`, `ClipboardBridge`, `ClipboardShortcutDetector` | 8 + 26 + 11 tests, each key point mutation-tested |
| **Real iPad**: extra key bar, sticky modifiers | ⌘ then `c` gives Meta↓ c↓ c↑ Meta↑; ⌃ then ← gives Ctrl↓ Left↓ Left↑ Ctrl↑; esc gives Escape↓↑ |
| **Screen Sharing-style computer picker**: address field, saved computers (green dot when Bonjour sees them), computers on the network, name + password dialog, errors shown right in the dialog | `ConnectionUITests` + `SessionChromeUITests` (11 tests, iPhone and iPad simulator); `ComputerListTests` (8), `ConnectionFailureMessageTests` (8). Screenshots at both sizes were reviewed. **Real iPad**: the list shows the saved "Mac mini" correctly with a green dot |
| The "blank username" error (hit by the user) has a message with the right action | `blankUsernameIsCalledOutBecauseMacsNeedAnAccountName`: no longer blames a "wrong name" when no name has been entered |
| **"View only" mode** really sends nothing to the Mac | `ObserveModeUITests` + `verify_observe.py`: tap, double tap, drag, two fingers while view-only = 0 events; a tap while in control mode = exactly 3. Mutation-tested: removing the blocking layer lets 41 events through and the test reports FAIL |
| **Real iPad**: holding a key repeats it | Holding the right arrow for 2 s: pressed at 0 s, repeats from 0.41 s, about every 65 ms (24 times), exactly one release when the key is released. Before the fix: one press, one release, no repeat. 10 `KeyRepeatTests` tests |
| **Real iPad**: Home, End, Return, Backspace, Tab, arrows, F5, ⌘+letter (Meta_L), Control+letter, Option+letter, Shift+letter | The fake server received the correct keysyms and press/release order. The iPad console confirms that Home (HID 0x4A) and End (0x4D) reach `pressesBegan` |
| iPadOS reserves ⌘F; we take it back with a high-priority `UIKeyCommand` | On the iPad simulator: before the fix `Command+F: did not reach the server`, after the fix it matches. Other ⌘+letter combinations (Z, S, O, P, T, N, W) arrive normally |
| Big-number time in the debug build | 49 ms (512-bit exponent modexp), thanks to the separate `-O` flag for `RFBCrypto` |

## Stream performance (measured 2026-10-14)

Symptom reported by the user: "connection and streaming are laggy". The cause and how it was measured:

| Finding | Figures |
|---|---|
| **The Debug build (`-Onone`) decodes ZRLE 63 times slower.** An Xcode install defaults to Debug, so the iPad only got 1-2 frames/second | The same real 2560x1440 stream stretch (362 updates, 188 MiB): Release 11 ms/update, Debug 702 ms/update |
| Fix: turn on `-O` for `RFBKit` and `RemoteDisplay` even in Debug (`Package.swift`) | Debug drops to 13 ms/update |
| Rewrote `decodeTile` with pointers with explicit bounds checks, writing straight into the framebuffer; zlib decompression into a reused buffer | Release 10.7 ms → 4.1 ms/update (2.6×). The final frame is **identical** to the old decoder's (FNV-1a hash `59e83c05109f5bdd`) after 362 real updates. The `ZRLEFuzzTests` fuzz test confirms nothing is written outside the rectangle; two bounds checks were mutated and the fuzz test caught both |
| The controller kept `latestFrame`, which forced the session to copy the whole buffer (14.7 MB) on every later update even though only a few pixels changed | Removed; a late-created view takes the frame from the session |
| The next update was requested **after** decoding finished, so the server waited | `pipelinesUpdateRequests`: request immediately on receiving the update header (request again at the new size if the server changes the size). 6 `SessionPipeliningTests` tests |
| **Real iPad (A14), real Mac, Debug build after the fix** | 24-33 frames/s, 12-18 Mbit/s, decode 1.5-2.3 ms, draw 0.6-0.9 ms per update (the first window is a full frame: 43 ms) |
| **The heavy stream measured from the Mac itself**: the wallpaper is a 4K `.mov` video (Aerial), so when the screen shows the wallpaper the server sends nearly the whole screen every frame | One 20 s recording: 361 updates, 192 MiB (about 77 Mbit/s), an average of 2.5 million pixels per update. Switching to a still wallpaper would reduce it sharply. I do not change your settings myself |

How to measure again:
- **Record a real stretch then replay it (read-only, sends no mouse or keys)**: `RFB_USER=<account> RFB_PASSWORD=<password> .build/release/rfbprobe --login 30 --watch 20 --record <file> 127.0.0.1`, then `.build/release/rfbprobe --replay <file> --size 2560x1440` (prints the time per update and the hash of the final frame). The recording contains an image of the real screen: **delete after use, do not commit**.
- **On the device**: the "…" menu › "Show stream statistics" (frames/s, Mbit/s, decode ms, draw ms). The Debug build also prints an `RS_STATS` line to the console (`devicectl device process launch --console ... --environment-variables '{"RFB_STATS":"1"}'`).
- For maximum speed when installing: build with `-configuration Release`.

## Image quality: Automatic / Best Quality / Best Performance

Menu "…" › "Image quality", kept between app launches (`UserDefaults`, key `qualityMode`). There are only **two real knobs** with the Apple server (see below), so the three modes are:

| Mode | Colour | Frame cap | Notes |
|---|---|---|---|
| **Automatic** (default) | 32-bit | `nil` → 30 → 20 → 12 depending on load (`AdaptiveGovernor`) | Steps down after 3 consecutive heavy seconds (≥ 30 Mbit/s or CPU ≥ 45%), steps up after 15 light seconds (≤ 10 Mbit/s and CPU ≤ 15%), one step at a time |
| **Best Quality** | 32-bit | unlimited | No colour loss, as fast as possible |
| **Best Performance** | 16-bit (RGB565) | 20 frames/s | Fewest bytes |

Colour depth **cannot be changed mid-session**: RFB gives no indication of which format an in-flight update uses, so switching to or from "Best Performance" makes the app briefly reconnect (~1 second, the last screen stays visible, banner "Applying the new quality mode…"). Switching between the two 32-bit modes only changes the frame pacing, with no reconnect.

| Finding / result | Evidence |
|---|---|
| **The Apple server does not support Tight/JPEG, Hextile, RRE** (it falls back to ZRLE or Raw) and **does not accept 8-bit** (closes the connection). It supports ZRLE, Zlib, Raw, CopyRect, and **16-bit RGB565** | `rfbprobe --login 30 --probe-encodings`: Tight → returns ZRLE; Hextile, RRE → Raw; Raw 16-bit → exactly half the size (7200 KiB versus 14400 KiB); 8-bit → `connectionClosed` |
| 16-bit uses fewer bytes | Two parallel connections, 15 seconds, same content, twice: **71% and 65%** of the 32-bit byte count. Full frame: **51%** (372 versus 725 KiB) |
| 16-bit displays correctly on the real server | `rfbprobe --check-depth-image` (three parallel connections, three times): 99.4-99.99% of pixels are within ±8 of 32-bit, no worse than the content drift between two 32-bit frames (A versus B: 99.5-99.99%) |
| 16-bit decoding is not slower | Replaying the real stream, Release: 32-bit 832 million pixels/s, 16-bit 922 million pixels/s; the generic rewrite did not slow down the 32-bit path (792 → 832) |
| **Real iPad + real Mac**, Debug build, same conditions | Best Quality: ~25 frames/s, ~22 Mbit/s, decode 2.8 ms. Best Performance: ~17 frames/s, ~8 Mbit/s (2.7 times less), decode 3.9 ms, exactly at the cap of 20 |
| 16-bit colours correct, the mode is remembered, switching between the two 32-bit modes does not reconnect, the fake server receives the pixel formats in the right order | `QualityUITests` + `verify_quality.py`: sequence `[32, 16, 16, 32, 32, 16]`; the colours of the four corners read from the simulator screenshot, off by ≤ 12 from the 32-bit frame |
| Logic | `QualityModeTests` (6), `AdaptiveGovernorTests` (9: step down, step up, no oscillation, heavy CPU, still screen), `RGB565ConversionTests`/`RGB565DecodingTests` (Raw and all five ZRLE tile types at 16-bit), `SessionPacingTests` (3) |

To measure again: `rfbprobe --login 30 --probe-encodings`, `--compare-depth 15`, `--check-depth-image`, and `--depth16` together with `--watch/--record/--replay`. On the iPad: `devicectl ... --environment-variables '{"RFB_STATS":"1"}' com.ledinhcuong.screon -- -qualityMode bestPerformance` (values `adaptive`, `bestQuality`, `bestPerformance`).

## Display modes (menu "…" › "Display", remembered between launches)

| Mode | How it works | Verification |
|---|---|---|
| Fit to screen | The client scales the whole Mac screen down to fit | Unit test `DisplayModeTests`; UI test reading real pixels: the black border is in the right place |
| Fill screen | Covers everything, crops the two edges, drag to view | As above: no more black border |
| Actual pixels (1:1) | 1 Mac pixel = 1 device pixel | As above: the 800x600 image appears small in the middle on an iPhone 3x |
| **Match device resolution** | Uses the **Apple server to scale down** the image to exactly the pixel size of the viewport (message type 8, see `protocol-notes.md` 4g), then shows it 1:1. Does not change the Mac screen. Resent automatically when the device rotates (waits 0.3 s for the layout to settle). A non-Apple server: same as fit to screen | `DeviceDisplayModeTests` (5), `AuditFixTests` (10-byte format, scale clamping, requesting everything again after a size change); real Mac: 0.5 → 1280x720, 0.75 → 1920x1080 |

Every mode adapts automatically to rotation, Split View and Stage Manager: a UI test rotates to landscape and reads the displayed size through the view's accessibility value ("Mac screen 800×600, displayed W×H points").

**Not verified in "Match device resolution" mode**: mouse coordinates. The app sends coordinates in the scaled-down space, and assumes the server converts them back to real coordinates as it does for the requested update region. Verifying this needs a real tap on a Mac (see 4g).

## Audit 2026-10-14: two independent reviewers, then each finding re-checked

Fixed, each with a test (`AuditFixTests`, `CommandHeldTests`, `SensitiveClipboardTests`, `ConnectionDraftAuditTests`, updated tests):

| Finding | Severity | Fix |
|---|---|---|
| At 16-bit the cursor was always read as 4 bytes per pixel → stream desynchronisation, the session dropped when the cursor changed shape (a bug introduced by the new 16-bit feature) | High | Read according to the client format and convert RGB565 → BGRA. The app does not ask for a separate cursor at 16-bit (not yet measured which format the Apple server sends) |
| Missing `PrivacyInfo.xcprivacy` (UserDefaults is an API that requires a declared reason) and an app icon → App Store rejection | High | Added the declaration file (CA92.1, no tracking, no collection) and a self-drawn 1024 px icon (original, not using any Apple imagery) |
| Version number hard-coded as 1.0 (1) in Info.plist | Low | Taken from `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` |
| Cancelling the network wait timer still finished the state stream → **the connection failed right when the user had just tapped Allow Local Network** | Medium | When cancelled, do not finish the stream |
| A malicious server forcing repeated 1 GB allocations (16384x16384) | Medium | Total cap of 64 million pixels (enough for 8K) |
| A Mac clipboard that is too large (for example ⌘C on an image) dropped the whole session | Medium | Read and discard the data, report "The Mac clipboard is too large (x MB) and was skipped" |
| A "ghost" touch-blocking region under the toolbar after each reconnect (the banner's frame was not cleared) | Medium | Clear the frame when the banner disappears |
| ⌘F (a high-priority key command) auto-released the ⌘ the user was holding → a following ⌘G/⌘V became lowercase letters | Medium | Do not resend ⌘ when ⌘ is held or sticky |
| Changing the quality mode while reconnecting → the session was at 16-bit while the menu said "Best Quality" | Medium | After connecting, compare the colour depth with the mode and reconnect if they differ |
| Reconnecting to change quality did not release keys first → ⌘ could get stuck on the Mac | Medium | `forceReconnect` releases keys, buttons and sticky keys before closing |
| Multiple windows: each window had its own list of computers, and a window saving after the other deleted a computer would bring it back | Medium | One `ConnectionsModel` for the whole app; a window that loses focus releases keys |
| Key repeat had no safe stopping point if the release went to a different view | Medium | On focus loss release everything; repeat at most 30 seconds |
| Cancelling in the middle of the handshake did not close the socket | Low-medium | `withTaskCancellationHandler` closes the stream (test: cancel exits in < 2 s) |
| CopyRect copied the whole region through a temporary array (slow, double the memory) | Low | `memmove` row by row, in the correct direction when overlapping (checked against 7 overlap patterns) |
| RFB 3.3 sent an extra security-type selection byte | Low | Not sent at 3.3 |
| A session dropped without `close()` kept the TCP connection | Low (latent) | `NWByteStream.deinit` cancels the connection |
| Removing the frame cap did not release a deferred request | Low | Reschedule at the new pace |
| Statistics and the automatic controller froze when the screen was still | Low | Run on a separate clock every second |
| View-only mode still made the drawn cursor follow the finger | Low | The view ignores control gestures (drag and pinch still pan and zoom the viewport) |
| A sticky key pressed while reconnecting was dropped yet still showed as "sticky" | Low | Lock the extra key bar and the keyboard button until connected |
| A password copied from a password manager on the Mac became a normal clipboard (Universal Clipboard sync, no expiry) | Low | With the Concealed/Transient marker, write it on this device only and clear it after 90 seconds |
| `vnc://name:password@host` showed the password in the name field; `[fe80::1]:5900` was not accepted | Low | Drop the password part; support IPv6 in square brackets |
| If Bonjour failed once it did not look again by itself | Low | Restart automatically after 3 seconds |
| The password stayed in memory after a failed connection | Low | Clear the request on failure |
| VoiceOver did not know whether the keyboard/extra-key button was on | Low | Added the "selected" state; the collapsed pill also reads out the state |

Not fixed (with reasons): possible tearing when `replace(region:)` writes the texture while the GPU is reading (needs double buffering, not seen in practice); `unsafeFlags(["-O"])` makes the package unusable as a version-based dependency (the app uses the package locally so it is unaffected); `ITSAppUsesNonExemptEncryption` is a legal declaration about encryption (DH, AES, DES only for authentication), which the publisher must decide.

Log check: the `screensharingd`/`ScreensharingAgent` logs from the past 3 hours (67,239 lines) contain no protocol error caused by the app; "Connection reset by peer" and "No such process" are what the server records when test sessions are cut off. Crash logs: the iPad has no report for the app; the iPhone has one JetsamEvent listing the app (suspended, 29 MB, **not** killed; the largest process was Facebook).

## Smoothness: probing (Phase 0) and changes (Phase 1), 2026-10-14

Why the old "Best Performance" was less smooth: a 20 frames/s cap (deliberate, to save bandwidth), 16-bit so the server drew the cursor into the frame itself (the cursor moved at the frame rate), scrolling was discrete wheel notches, and drawing happened as soon as a frame arrived rather than at the display's rhythm.

| Probing on a real Mac (read-only) | Result |
|---|---|
| How fast the server captures the screen (`ScreensharingAgent` log "screen capture frame count") | ≈ 55 frames/s: the server is not the bottleneck |
| ContinuousUpdates (-313) | **Not supported** (`rfbprobe --probe-continuous`: no message 150) |
| Two update requests pending instead of one | **Gains nothing**: 36.4 versus 36.5 updates/s, two parallel connections (`--compare-outstanding`) |
| Server-side scaling (type 8): 1 / 0.92 / 0.46, three parallel connections | Updates/s about the same (~25, following the rhythm of content changes); bandwidth at 0.46 is about 1/3. On a landscape iPad (0.92) almost no benefit (`--compare-scale`) |
| Order of the scaling command relative to the first request | Before or after both work. **The client must declare DesktopSize**: without it the server stops sending after scaling down (`--probe-scale-order`) |

Changes:
- **Drawing at the display's rhythm** (the view's `CADisplayLink`, stopping when still); several updates within one beat are merged into one draw. **Two alternating textures**: each update is written to the GPU texture that is not being read (removing the tearing risk raised by the audit), each texture remembers the region it is missing so only what is needed is uploaded, and no frame is kept (so the 14.7 MB copy bug does not come back). Real GPU tests: `alternatingTexturesStillShowEveryChange`, `anUploadNeverWritesTheTextureTheGPUIsReading`, `resizingWhileTheGPUIsBusyKeepsTheCountsSane`.
- **Scroll momentum** (`InputKit/MomentumScroller`): lifting two fingers during a swipe keeps scrolling, slowing down like a trackpad (factor 0.998/ms like `UIScrollView`), stopping on touch again; while zoomed it becomes viewport panning with momentum. Correct integration, so 60 Hz or 120 Hz scroll the same distance (tested).
- **Merging mouse events when the network is congested** (`RFBKit/Session/OutboundQueue.swift`): the write task takes everything pending and drops pure mouse moves that a later one has replaced; it keeps the press position, every button press/release (including scroll notches), keys, requests, and the clipboard.
- **"Best Performance"** (name kept): no frame cap, 32-bit (the cursor is always in place), by having the Apple server scale down to the viewport resolution. 16-bit returns only once the Apple server's 16-bit cursor format has been measured.
- **Small fixes**: no more double cursor at 16-bit (the server drew one, the app drew another); a sticky key now releases after one click (before, only after one key); turned off iPadOS's three-finger text-editing gestures on the Mac screen.
- **Smoothness metrics** (`SessionKit/FramePacing`): the statistics panel gains "median/p95 pace ms" (the gap between two frames with new content).

Measured after Phase 1 on a **real iPad Air 4 → real Mac** (2026-10-15, Debug build, `RFB_DROP_INPUT=1`, `RFB_STATS=1`, `RFB_QUALITY=…`, each mode ~30 seconds, same content, a running terminal window; median of the seconds):

| Mode | Frames/s | Mbit/s | Decode | Draw | Pace median / p95 |
|---|---|---|---|---|---|
| Automatic | 25 | 16.3 | 1.9 ms | 1.3 ms | 33 / 100 ms |
| Best Quality | 27 | 16.9 | 1.9 ms | 1.2 ms | 33 / 100 ms |
| Best Performance | 25 | 17.8 | 1.9 ms | 1.0 ms | 33 / 100 ms |

"Best Performance" went **from 17 to 25 frames/s** (before Phase 1, due to the cap of 20 and 16-bit) and is now on par with the other two modes. Decode + draw take under 3.5 ms per frame, so the iPad is not the bottleneck: the ceiling of ~25-30 frames/s comes from the RFB request-response loop and the server-side ZRLE compressor (the server captures ~55 frames/s, ContinuousUpdates is absent, two pending requests do not help). Going beyond that would need a hardware video stream like Sidecar, outside the scope of RFB.

## Sidecar-style modifier sidebar (Phase 2), 2026-10-14

A vertical bar beside the Mac screen (iPad: on the left, on by default; iPhone: hidden by default because the screen is narrow). Menu "…" › Sidebar: left / right / hidden, remembered between launches (`sidebarPosition`). The Mac screen sits **next to** the sidebar so it shrinks rather than being covered; "Match device resolution" recalculates for the remaining space. When the sidebar is visible, the floating toolbar drops the duplicate buttons (disconnect, keyboard, extra keys) and the extra key bar drops ⌃ ⌥ ⌘ ⇧, covering less of the Mac's menu bar.

- Buttons: ⌘ ⌥ ⌃ ⇧, Undo (⌘Z; with ⇧ sticky it becomes ⌘⇧Z), esc, keyboard, extra key bar, disconnect.
- Modifier keys (`InputKit/ModifierKeys.swift`, replacing the old `StickyModifiers`, shared with the extra key bar):
  - **Hold**: putting a finger down presses on the Mac immediately, lifting releases (⌘-click, ⇧-click with the other hand).
  - **Sticky once**: a short tap (≤ 0.4 s, doing nothing while held). Released after the next key **or click**.
  - **Lock**: a second tap within 0.3 s. Kept through every action, tap again to unlock. Shows a padlock icon.
  - Tapping a sticky key again (later than 0.3 s): drop it. Focus loss, going to the background, view-only, disconnect, hiding the sidebar (when the extra key bar is also hidden): release everything, in reverse press order.
- The sidebar keys are `UIControl`s (tracking touches, not gesture recognisers) so a finger holding ⌘ does not block the other hand's gestures on the Mac screen.
- Tests: `ModifierKeysTests` (8, including "every press has exactly one release"), `KeyBarModifierTests` (4); UI test `SidebarUITests` + `verify_sidebar.py` (pass 3 of `run_ui_test.sh`): the fake server sees ⌘↓, exactly one click, ⌘↑ (sticky); ⌘↓, two clicks, ⌘↑ (lock); ⌘↓ z↓ z↑ ⌘↑ (undo); Escape; no stuck keys; hiding the sidebar widens the Mac screen.
- **Not verified**: holding ⌘ with one hand and tapping with the other (XCUITest cannot create two independent simultaneous touches): needs a manual test on the iPad, for example selecting multiple files in Finder.

## iPad Apple Pencil, mouse and trackpad (Phase 3), 2026-10-14

- **Apple Pencil** (`InputKit/PencilGesture.swift`, a separate recogniser that accepts only the pencil): the pencil is always an **absolute** pointer, even in trackpad mode. Tap = left click at the point where the pencil is placed; moving more than 4 points = drag-and-drop immediately (no need to hold first as with a finger, convenient for selecting text); holding still ≥ 0.6 s then lifting = right click. Tapping the black border outside the Mac screen: no click.
- **Double tap on the pencil** (Pencil 2, Pro; `UIPencilInteraction`): by default a right click at the cursor; change it in the "…" › Apple Pencil menu (right click / show-hide keyboard / do nothing), remembered between launches.
- **Fingers only scroll when using the pencil** (like Sidecar): after the first pencil stroke, a finger tap does not click and a one-finger drag scrolls. The default follows the system setting "Only Draw with Apple Pencil" (`UIPencilInteraction.prefersPencilOnlyDrawing`), changeable in the menu.
- **Mouse/trackpad attached to the iPad** (`UIApplicationSupportsIndirectInputEvents`): moving the mouse = moving the Mac cursor (`UIHoverGestureRecognizer`), the left button press/drag/release is immediate, the right button = right click, the wheel and two fingers on the trackpad = Mac scroll (including while zoomed), the trackpad has momentum. The iPad's round pointer is hidden over the Mac screen (the Mac cursor is already there); shown again when view-only or when the Mac cursor is turned off.
- Finger gestures now accept only fingers (`allowedTouchTypes = [.direct]`), so the pencil and mouse are no longer interpreted as fingers.
- The pencil's pressure and tilt **cannot be sent** over RFB (a mouse event has only coordinates and buttons).
- Tests: `PencilGestureTests` (5), `PointerDeviceTests` (10). **Not verified on a device**: the simulator and XCUITest cannot create pencil touches or indirect pointer touches. A manual test is needed on an iPad Air 4 + Pencil 2: tap, drag to select text, hold to right click, double tap on the pencil; and with a mouse/trackpad if available. The scroll distance of one mouse wheel notch has not been measured (`scrollTickDistance` may need adjusting).

## Real gestures on the Mac: message type 23 (Phase 4), 2026-10-14

- The needed part has been reverse engineered (`docs/protocol-notes.md` section 4h): type 11 = a full `kCGEventScrollWheel` (distance in points, scroll phase, momentum phase, continuous flag), type 3 = pinch, type 5 = rotate, type 4 = smart zoom; payloads are big-endian, and the server closes the connection if bytes are missing.
- App (`RFBKit/Protocol/AppleInputEvent.swift`, `ClientMessage.appleEvent`): trackpad-style smooth scrolling (began/changed/ended then momentum begin/continue/end, keeping the fractional part so slow scrolling is not lost) and pinch/rotate (**version 2 with phases**: began value 0, changed…, ended value 0; the pointer is first moved to the midpoint between the two fingers). Enabled only with an Apple server.
- Menu "…" › Gestures on Mac: "Trackpad-style smooth scrolling" (**on by default** since the real test) and "Pinch/rotate with two fingers: Zoom the iPad viewport (default, per your choice) / Send to the Mac". When sending to the Mac, two-finger scrolling pauses during a pinch/rotate (like a real trackpad).
- Tests: `AppleInputEventTests` (5, checking each offset against the decoded table; version 2 pinch/rotate of 32 bytes), `AppleGestureMappingTests` (5); end to end `run_gesture_test.sh` (fake server `--apple` presenting itself as `RFB 003.889`, decoding the payload and logging): pinch and rotate reach the server at exactly 16 bytes, coordinates within the screen, the connection stays alive. XCUITest cannot create a two-finger drag so smooth scrolling has only unit tests.
- **Tried on a real Mac (2026-10-15, with your permission)**: `rfbprobe --apple-gesture-test X,Y` sends to a test AppKit window (created separately, touching none of your windows) that records the `NSEvent`s it receives:
  - Type 11 scrolling: all 18 events, `hasPreciseScrollingDeltas`, `scrollingDeltaY` **exactly equals** the points sent (+12 → +12, same sign), phases began/changed/ended → `NSEvent.phase` 1/4/8, momentum begin/continue/end → `momentumPhase` 1/4/8.
  - Pinch/rotate **version 1 (no phase): the Mac ignores all of it**, no event reaches the window (the server keeps the connection). **Version 2 with phases 1/2/4**: arrives in full, `magnification` and `rotation` have the right value and sign (+3 → +3, counter-clockwise). The mask (field 133) tried at 0, 2, 4, 8 gives the same result; the app sends 0.
  - This Mac's display is 2560x1440 at 1x: framebuffer pixels = points, so `remotePixelsPerMacPoint` changed its default from 2 to **1** (the old Retina assumption made content scroll only half the finger's distance). A Retina Mac has not been measured.
  - `rfbprobe --apple-raw FILE --apple-gesture-test X,Y` sends arbitrary hex payloads (each line `delay_ms hex`), used to try variants.
- Still unknown: the x, y coordinates while scaled down on the server side (same question as for `PointerEvent`); type 4 (smart zoom) and 6 (swipe) not tried.

## App Mode (beta) overview

App Mode shows individual Mac windows as iPad windows through the Screon Helper (see `docs/app-mode-implementation-plan.md`).
It requires iPadOS/iOS 26; RFB mode is unchanged.

Implemented and covered by `swift test` with fakes or on `127.0.0.1` (no permissions, no real Mac, no iPad):

- `LinkProtocol`: framing, message codecs with bounds, malicious-input tests (`LinkProtocolTests`).
- `LinkTransport`: QUIC and TCP+TLS wires, pinned mutual TLS, pairing, resume, revoke, backpressure (details in the next section).
- `WindowKit`: iPad-side window model and input glue (`WindowKitTests`).
- `HelperCore`: helper logic behind protocols with fakes: input injector, stage, pasteboard bridge, file inbox
  (`HelperCoreTests`). The `Helper/` app target and `Tools/mock-link-helper` are exercised only by build and loopback runs.

Not yet verified (nothing below has run on a real Mac or iPad; spike ids refer to the plan, section 4):

- S1 Remote Desktop privacy category on macOS 27, S2 monthly Screen Recording re-approval and the persistent-capture entitlement.
- S3 per-window `SCStream` scaling, S4 HEVC encode latency, S5 iPad decode with concurrent sessions.
- S6 QUIC over real Wi-Fi and the Local Network prompt, S7 mutual TLS with identities on real iOS/macOS (partly done on macOS loopback).
- S8 `CGVirtualDisplay` stage stability, S9 input into non-front windows, tablet events, Unicode and secure input, S10 AX coverage
  on real apps, S11 child windows, menus, full screen, other Spaces.
- Signed, notarized helper builds and the update manifest: skeleton only (`.github/workflows/helper-release.yml`, `scripts/`).

## App Mode transport (`LinkTransport`, macOS loopback tests only)

Verified by `swift test` on 127.0.0.1 with identities generated per run (tests `LoopbackTests`, `MaliciousPeerTests`,
`BackpressureTests`, `SessionMachineTests`, `TransportPureTests`), over QUIC and over the TCP+TLS fallback:

- QR pairing, SAS pairing, reconnect by pinned SPKI, session resume with a single-use token, revoke while connected,
  "ask before each session", close codes, session replacement, automatic QUIC to TCP fallback.
- Three window streams carrying 150 KB frames concurrently, in order; input moves coalesced while presses/releases survive;
  video queue drops to the next key frame when the receiver stalls and reports it.
- Hostile peer: garbage, oversized/unknown frames, bad preambles, wrong stream or direction, wrong stream ids, silent
  connections; the connection is closed and the server keeps serving.
- Not verified: anything on a real iPad/iOS, Keychain-backed identities, Wi-Fi behaviour, Local Network prompt, throughput over
  time. Test identities use `SecIdentityCreate` (a Security function missing from the public headers; tests only) and fall back to a temporary keychain if it is missing.

## App Mode iPad core (M5 I2, I4, I6, I7)

Verified (`swift test`, macOS; `ScreonAppTests` in the simulator; iOS build):

- Pure session logic in `WindowKit` (`SessionLogicTests`): per-window stats deltas (including a decoder reset and absurd values),
  at most two key frame requests per second per window with the last request never lost, subscribe/pause/resume/reconnect
  state machine, frame sequence gaps across the 2^32 wrap, LTR acknowledgements, and the overlay shown for every connection and
  helper state (connecting, reconnecting, window closed, app quit, Mac locked, missing permission, secure input banner, version
  mismatch, device revoked, identity changed, declined, replaced, lost).
- Child surface and cursor pictures (`BGRAImageDecoderTests`): only the declared PNG or JPEG, exactly one image, decoded size equal
  to its header, bounded before allocation; hostile hotspots do not trap.
- App glue (`AppModeGlueTests`): link errors stop `ReconnectPolicy` when permanent and are retried when transient, error to window
  message mapping, typed text splitting, the Keychain pin store.
- Not verified: everything that needs a Mac helper or an iPad. `AppModeConnection` against a real or mock helper, decoding real
  video, drawing, touch and pencil input, Telex composition through the on-screen and hardware keyboards, the camera scan, the
  Local Network prompt, Stage Manager behaviour. The mock helper (`Tools/mock-link-helper`) did not exist yet, so the DEBUG hooks
  (`LINK_HOST`, `LINK_PORT`, `LINK_PAIRING`) have not been exercised either.

## App Mode launcher and multi-window experience (M6 W1-W7)

Verified (`swift test`; `Tools/mock-link-helper/run_appmode_test.sh` on the iPad simulator, iOS 26.5 and iOS 27.0, mock helper only):

- Pure logic in `WindowKit` (`SceneLogicTests`): icon cache bounds and least-recently-used eviction, resize debounce with warm-up,
  size limits from the Mac window, the window reference (live id plus hint, hostile text refused) and re-binding after a helper
  restart (`SceneBindings.revalidate`), launcher listing and search, app open plans, new-window policy and badges, window
  switcher, menu paths and key equivalents (reserved shortcuts, duplicate and disabled items, ⌘W policy), menu tree cache.
- End to end against the mock helper (`AppModeUITests`, then `verify_appmode.py` on the helper's log): QR pairing, the launcher
  lists the three apps with icons fetched through `apps.icon`, tapping an app activates it and opens its window in a new scene,
  video appears, a tap reaches the helper as pointer events, typed text arrives, Menus > File > New arrives as
  `menu.press([0, 0])`, "Resize Mac window to fit" arrives as `window.setFrame`, "Close Mac window" as `window.command(close)`, the
  placeholder appears and Close destroys the iPad scene; the launcher search filters the list.
- Not verified: the iPadOS menu bar (`UIMainMenuSystem`, only that the app launches with it), key equivalents as `UIKeyCommand`
  with a hardware keyboard, resizing by dragging a Stage Manager window (the debounce is unit tested, the system resize signal is
  not exercised), tabs-in-one-window, opening several scenes at once, external displays, the iPhone window switcher (built, not run
  on an iPhone simulator), restoration after a relaunch. The mock helper only answers `apps.list` with the running apps.
- In the iOS simulator a client-initiated one-way QUIC stream (the input stream) fails with "Network is down", so the UI test
  forces TCP+TLS with the DEBUG variable `LINK_TRANSPORT=tcp`. Whether QUIC input works on a real iPad is not verified.

## Not yet verified, do not treat as done

- **No real mouse/keys have been sent to a real Mac from this machine** (it is a working machine). Every input check on a real device used the fake server. It is also **unknown** whether the Apple server understands `Meta_L` (0xFFE7) as the Command key (see `KeysymMapper.commandLeft`). The app sends exactly `Meta_L`, measured with the fake server. A trial with a person sitting next to it is needed.
- **Two-finger scroll and pinch to zoom** on a real device: Device Hub does not turn mouse scroll or pinch into touch gestures, so there are only `TouchMapper` unit tests.
- **Typing Vietnamese / Unicode** (keysym `0x01000000 + code`): the computer-use typing tool cannot emit these characters (it sends keycode 0 = `a`). A person typing on the iPad is needed, and it must be learned whether the Apple server accepts this keysym form.
- **The hardware keyboard Escape key**: never reaches `pressesBegan`, measured on a real iPad (through Device Hub, with the console) and on the simulator. A high-priority `UIKeyCommand` over the system was added but **Escape still has not been seen reaching the server** through Device Hub, so it is unclear whether the fault is in iPadOS or in Device Hub not forwarding Escape. A test with a real hardware keyboard is needed. Escape on the extra key bar has been measured.
- **Page Up/Down, forward Delete, F-keys other than F5** on a hardware keyboard: the mapping table exists (`KeyboardMappingTests`), but they have not reached the server when typed through Device Hub (the tool has no correct key names) and XCUITest cannot generate them. Not verified on a device.
- **Key repeat with a real Mac**: the repeater (0.4 s and then ~15 times/second) was verified with the fake server. It is not known whether `screensharingd` also repeats by itself (if so, holding a key would produce double). Holding Backspace on a real Mac is needed to see.
- **Typing Vietnamese from the virtual keyboard**: uses Unicode keysyms. The `ScreensharingAgent` binary has the string "secure input do not send unicode char" so the server has a path for sending Unicode, and `AppleVNCServer` has `HandleSetKeyboardInputSource` (the viewer reports the keyboard layout), but real typing has not been tried.
- **Performance measurement on a real device**: connection time, smoothness and battery have not been measured. The first tap right after opening the app is sometimes not received (unclear whether it is the app or Device Hub).
- **Pointer lock** (relative mouse for games): not done.
- **The cursor position** is the position we last sent. RFB does not report when the Mac's real mouse moves, so if someone uses the real mouse on the Mac, the cursor drawn on the iPad will be off.
- **The system Paste button (`PasteButton`)**: does not respond to touches generated by Device Hub (it is an iOS security control), so it is **not verifiable**. The ⌘V path has been verified.
- **The iOS "allow paste" dialog**: ⌘V when the clipboard comes from another app makes iOS ask "Screon would like to paste from …". This is iOS behaviour and cannot be avoided if the app reads the clipboard itself. The user can choose Allow in Settings › Screon › Paste from Other Apps, or use the Paste button. If denied, the app says so clearly.
- **Text-only clipboard** (UTF-8, Vietnamese and emoji get through). Images, files, RTF are not done. Apple's own protocol is not fully understood (see `protocol-notes.md` section 4e): whether the server pushes the clipboard by itself when the Mac changes is still unknown, so the Mac → iPad direction is always request-response (after ⌘C or the Get button).
- **Automatic reconnect**: the following paths have not been verified on a real device: returning from the background after more than 10 s reconnects immediately, `NWPathMonitor` wakes up when the network is back, TCP keepalive detects a dead connection (~35 s), after 6 attempts it gives up and shows the error. The policy has tests; these paths have no end-to-end tests.
- **Lag from Wi-Fi bandwidth when the screen changes heavily** (video wallpaper, video playback, scrolling): the stream can reach ~77 Mbit/s. Decoding is no longer the bottleneck, but this has not been measured on an iPad under that heavy a load (the load cannot be generated without controlling your Mac). If it is still laggy, the next steps are limiting the frame rate or reducing colour depth (not done).
- **Automatic mode stepping down on a real device**: the logic has tests and works, but the stream measured on the iPad (22 Mbit/s) did not exceed the 30 Mbit/s threshold to see it step down by itself. The 30 Mbit/s, 45% CPU and 15 second thresholds are inferred, not tuned from real experience: if it steps down too early or too late, adjust them in `AdaptiveGovernor`.
- **No lossy compression path** (JPEG, HEVC) like Screen Sharing "High Performance": the Apple server does not accept Tight, and Apple's own format has not been decoded.
- **Multiple displays**: not done.
- **A real Bonjour connection to a real Mac** (choosing "Mac mini" then logging in): not tried, because it is a working machine. The connection path through `.service` has been verified with a fake service in tests.
- **Types 31, 32, 33, 35, 36** (Apple's SRP and variants): not supported, see `protocol-notes.md`.

## Operating a real iPad from the Mac with computer use (Device Hub)

Xcode 27 no longer has `Simulator.app`. `Xcode.app/Contents/Applications/DeviceHub.app` mirrors both simulators and real devices and accepts mouse/keys. To try gestures **without** controlling the real Mac: run `Tools/mock-rfb-server/server.py --host <the Mac's LAN IP>` (no authentication, open only during the trial and then shut down), open the app with `devicectl device process launch --environment-variables '{"RFB_HOST":"<IP>","RFB_PORT":"5959"}'` (DEBUG build only), then compare against `events.jsonl`.

What was encountered in this environment (may differ on another machine):

- **Coordinate offset**: the real pointer is off by `+164` image pixels on the y axis relative to the commanded coordinates (x is correct). You must command `y - 164`. The tool also only allows clicking within the running window or the menu bar, so points with a real y smaller than about 254 are hard to reach (the app's toolbar can be reached by commanding y=8 on the menu bar). Check with `cursor_position` before trusting it.
- **The mirrored image lags by about one action**: wait a few seconds before capturing, otherwise you see the state from the *previous* click.
- The tool's double click puts the second click in the wrong place; two separate clicks close together are correct.
- The `type` tool emits keycode 0 (`a`), which may leave a stuck key on the app: use `key` for each key.
- Mouse scrolling produces no event.

## DEBUG flags for testing on a device (Debug builds only, passed through `devicectl ... --environment-variables`)

| Variable | Effect |
|---|---|
| `RFB_HOST`, `RFB_PORT`, `RFB_USER`, `RFB_PASSWORD` | Connect automatically when the app opens |
| `RFB_SAVE=1` | Save the computer to the list after connecting (test the save flow without typing the form) |
| `RFB_KEYBAR=1` | Open the extra key bar from the start |
| `RFB_STATS=1` | Open the stream statistics panel from the start, and print `RS_STATS ...` to the console every second |
| `RFB_DROP_INPUT=1` | **Drop every mouse and key event** before sending, letting only the clipboard through. Use it when connecting to a real Mac so that a missed tap does not become a real mouse click (verified: 0 mouse/key events reached the fake server) |
| `RFB_DEFAULTS_SUITE=<name>` | Use a separate `UserDefaults` suite (UI tests isolate settings) |
| `RFB_SIDEBAR=leading\|trailing\|hidden` | Set the sidebar for this run (not saved) |
| `RFB_SMOOTH_SCROLL=1\|0`, `RFB_PINCH_TO_MAC=1` | Turn smooth scrolling on/off, turn on pinch-rotate to the Mac (message 23) for this run |
| `RFB_QUALITY=adaptive\|bestQuality\|bestPerformance` | Quality mode for this run (not saved), to measure each mode on the iPad with `devicectl` |

## Two bugs that only showed up on a real device

- Tapping the toolbar both failed to trigger the button and **clicked down onto the Mac right beneath it**. A SwiftUI button sitting over a `UIViewRepresentable` does not receive the touch if that area has no SwiftUI gesture (`claimingTouches` in `Views.swift`), and `ScreonView.excludedRegions` blocks the one-finger gesture in that area. Multi-finger gestures are not blocked.
- Option+letter sent the composed character (`≈`) instead of the base key (`x`). Fixed: Option also uses `charactersIgnoringModifiers`.

## A tunable point based on habit: `TouchPolicy` (Sources/InputKit/TouchMapping.swift)

Two functions decide which gesture does what, with default values already set:

- `oneFingerDrag(isZoomed:)`: a one-finger drag **moves the pointer**, **drags and drops**, or **pans the viewport**. Default: trackpad mode always moves the pointer; with direct touch it pans the viewport while zoomed, otherwise it moves the pointer. A real drag-and-drop uses press-and-hold then drag.
- `twoFingerPan(isZoomed:)`: a two-finger drag **scrolls** or **pans the viewport**. Default: scroll, unless zoomed.

This is a core UX decision and only a real user can judge what feels right. Changing the returned value is enough; the tests will show which places depended on the old choice.
