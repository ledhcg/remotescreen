# App Mode: per-app remote windows — design and implementation plan

Status: **design, not started.** Target: the full feature set, distributed outside the App Store (Developer ID +
notarization for the Mac helper). Optimise for the best result, not for review constraints.
The production plan, with the decisions research changed, is `docs/app-mode-implementation-plan.md` (its §2 lists the
deltas; where the two documents disagree, the plan wins).

Evidence tags: **[doc]** Apple documentation or a public spec, **[obs]** our own observation in `docs/protocol-notes.md`,
**[bin]** seen in a shipped binary but never exercised, **[3p]** unverified third-party report, **[inf]** our inference.

---

## 1. Goal

Let the user browse the apps installed and running on a Mac, open one app (or one window) and use it as its own iPad
window — full screen, in Split View, in Stage Manager or on an external display — interacting only with that app,
instead of mirroring the whole desktop. Several Mac apps can be open as several iPad windows at once.
The existing full-desktop RFB mode stays, and is the fallback and recovery path.

---

## 2. Background

### 2.1 Seamless-window models

Systems that present remote applications as local windows fall into three models:

| Model | How it works | Strength | Weakness |
|---|---|---|---|
| **Masked shared framebuffer** | An agent next to the remote apps reports window geometry and shapes; the client receives one desktop image and shows each window's region in its own local window. | Simple pixel path. | Covered windows show what covers them; transparent regions leak the desktop; one live window per screen area. |
| **Window orders over a desktop stream** | The server sends a structured window model (create/update/delete, z-order, active window, icons); pixels still come from a desktop stream. | Rich window model. | Same occlusion limits as above. |
| **Per-window forwarding** | Each window (and each transient surface such as a menu or tooltip) has its own pixel stream and metadata. | Covered windows stay live; unlimited simultaneous windows; true isolation. | Highest cost: capture and encode per window. |

Any of them needs roughly the same control vocabulary:

1. Window lifecycle: create, destroy, map/unmap, minimise/zoom/full-screen state; owner process and parent window.
2. Geometry and stacking: frame, optional shape, z-order, active window, level (normal/floating/popup/modal).
3. Metadata: title, app name and identifier, icon by cache id, resizability, min/max size.
4. Pixels: one stream per window, or one desktop stream plus crop rectangles.
5. Client → server: launch, activate, move/resize, close, minimise, window-relative input.
6. Session: seamless negotiation, full resync, app-list and icon queries.
7. Also: clipboard, audio, and — on macOS — the **global menu bar**, which lives outside the window.

Transient surfaces (menus, popovers, tooltips, combo-box lists) must be modelled separately from managed windows: they
belong to a parent window, are short-lived and must be composited on top of it.

### 2.2 What Apple's built-in Screen Sharing server offers (no helper)

| Primitive | Status | Use for App Mode |
|---|---|---|
| Window/app/process messages | **None** [obs] | — |
| Display selection | Reported by a public client bug report: the framebuffer stays the bounding box of all displays, the selected display's frames arrive at (0,0) [3p] | Select a stage display |
| Type 29 `SetDisplayConfiguration` | Creates up to 2 virtual displays, `blankScreen` option [bin], never tried | Create an iPad-shaped display |
| Type 8 `SetServerScaling` | Works [obs] | — |
| Sub-rect `FramebufferUpdateRequest` | Allowed by the wire format; untested on Apple's server | Bandwidth when cropping |
| Encoding 1010 / HEVC media streams | Unexplored [bin] | Unknown |
| High Performance mode | Apple silicon + macOS 14 on both ends, UDP, virtual displays up to 4K, one session per Mac [doc] | Confirms virtual displays are first-class in the server |

A helper-free approximation exists — create a virtual display, select it, launch the app with Spotlight keystrokes,
make it full screen with ⌃⌘F — but gives no app list, no icons, no isolation (⌘Tab, notifications and dialogs still
appear) and at most two displays. **Rejected as the main design**; kept as an optional Phase 0 experiment.

### 2.3 What a Mac helper can do

| API | Gives | Permission | Notes |
|---|---|---|---|
| `NSWorkspace` (`runningApplications`, `icon(forFile:)`, `openApplication(at:configuration:)`, launch/terminate/activate notifications) | Running apps, icons, launching | none | public |
| `NSMetadataQuery` / LaunchServices | Installed apps | none | public |
| `CGWindowListCopyWindowInfo` | Window id, owner pid, bounds (global points), layer, alpha, on-screen | none for geometry; titles need Screen Recording | visibility rules changing in macOS 27 betas [3p] |
| Accessibility `AXUIElement` | Titles, position/size (read/write), `AXRaise`, minimise, full screen, menu bar tree, `AXPress`; `AXObserver` notifications | **Accessibility** | writes can succeed yet be ignored → always read back; `_AXUIElementGetWindow` (private) maps AX → `CGWindowID` |
| ScreenCaptureKit (`SCStream`, `SCContentFilter(desktopIndependentWindow:)`, `init(display:including:exceptingWindows:)`, per-app audio, `SCStreamFrameInfo.dirtyRects`) | Per-window pixels even when covered or on another Space; per-app audio; damage rects | **Screen Recording** | since macOS 15, non-picker capture is re-confirmed periodically (monthly) [3p] |
| VideoToolbox | Hardware HEVC/H.264 encode and decode, low-latency rate control | none | public |
| `CGEvent` (`post(tap:)`, `postToPid`, Unicode keyboard strings, tablet pressure/tilt fields, continuous scroll phases) | Input injection | **Accessibility** | gestures (magnify/rotate) need undocumented fields [3p] |
| `CGVirtualDisplay*` (private) | Virtual displays of any size, HiDPI | none | can break with any macOS release; macOS 14 requires a unique serial and non-zero vendor id [3p] |
| `NSPasteboard` | Full clipboard (text, rich text, images, files) | none (newer macOS may prompt for programmatic access — verify) | far richer than the RFB text bridge |
| `SMAppService.agent`, `MenuBarExtra` | Login item, menu-bar UI | user approval | public |

### 2.4 What Screon already has (iPad side)

- `UIApplicationSupportsMultipleScenes` is on (`App/project.yml:51`); each `RootView` owns a `SessionController`.
- `ViewportGeometry` is pure math with a `RemoteCoordinateSpace` seam used by `TouchMapper` (InputKit); it has no
  "source rect" yet — `contentRect` is always the whole remote screen.
- `FramebufferRenderer` draws one BGRA texture with UVs fixed to 0..1; no video (YUV/`CVPixelBuffer`) path.
- `RFBSession` treats unknown server message types as `malformed` and drops the session.
- No Mac-side component and no channel other than RFB.

---

## 3. Design options

| | A. RFB only | B. Hybrid helper (RFB pixels + helper metadata) | **C. Full helper (per-window streams)** |
|---|---|---|---|
| App list, icons, titles | no | yes | yes |
| Isolation | none | crop + input clamp | true: only that window's pixels and events |
| Covered windows stay live | no | no (must raise or tile) | **yes** |
| Simultaneous iPad windows | 1 | limited by stage area | **unlimited (bandwidth-bound)** |
| Window sized to the iPad scene | manual | via AX | via AX + virtual stage, crisp HiDPI |
| Menus, popups, sheets | visible if on screen | union crop | separate transient surfaces |
| Mac permissions | none | Accessibility | Accessibility + Screen Recording |
| Private API | none | none | `CGVirtualDisplay` (optional), `_AXUIElementGetWindow` (optional, with fallback) |
| Authentication | ARD type 30 | type 30 + pairing | pairing + macOS account verification |
| Cost | small | medium | large |

**Decision: C**, with the full-desktop RFB mode kept as fallback and recovery path (locked screen, login window, helper
not installed, permission missing). B is not built: once the helper has Screen Recording, per-window capture is strictly
better than cropping a shared framebuffer.

---

## 4. Architecture

```
┌──────────────────────────── iPad: Screon ─────────────────────────────┐          ┌────────────────────── Mac ───────────────────────┐
│                                                                        │          │                                                  │
│  UIScene "Desktop"  ── SessionController ── RFBSession ────────────────┼── RFB ───┤ Apple Screen Sharing server                      │
│                                                                        │          │                                                  │
│  UIScene "Launcher" ─┐                                                 │          │ Screon Helper (menu-bar agent, user session)     │
│  UIScene window A  ──┼── AppModeSession (actor, one per Mac) ──────────┼── QUIC ──┤  LinkServer ── pairing, TLS 1.3, streams         │
│  UIScene window B  ──┘    ├ WindowModel (WindowKit)                    │  TLS 1.3 │  AppCatalog (NSWorkspace, LaunchServices)        │
│  External display   ──    ├ StreamDecoder per window (VideoToolbox)    │          │  WindowTracker (AXObserver + CGWindowList)       │
│                           ├ InputRouter (window-relative events)       │          │  Stage (virtual display, layout, restore)        │
│                           ├ MenuBridge (AX menu → UIMenu / menu bar)   │          │  CaptureEngine (SCStream per window/surface)     │
│                           ├ ClipboardBridge v2, FileTransfer           │          │  Encoder (VTCompressionSession, ABR)             │
│                           └ AudioPlayer (per-app audio)                │          │  InputInjector (CGEvent)                         │
│                                                                        │          │  MenuReader, Pasteboard, AudioCapture            │
└────────────────────────────────────────────────────────────────────────┘          └──────────────────────────────────────────────────┘
```

### 4.1 Repository layout

```
Sources/LinkProtocol    wire format: messages, framing, bounded decode, versioning. Pure, iOS + macOS. Fuzz-tested
Sources/LinkTransport   Network.framework QUIC/TLS, pairing, identity keys (CryptoKit), reconnect/resume. iOS + macOS
Sources/WindowKit       client model: windows, apps, z-order, transient-surface grouping, coordinate transforms,
                        scene ↔ window mapping, input routing policy. Pure logic, Swift Testing
Sources/RemoteDisplay   + VideoSurfaceRenderer (CVPixelBuffer → Metal via CVMetalTextureCache), uvRect support
Sources/HelperCore      macOS only: AppCatalog, WindowTracker, Stage, CaptureEngine, Encoder, InputInjector,
                        MenuReader, PasteboardBridge, AudioCapture. Each OS-facing piece behind a protocol with a fake
Helper/                 macOS app (XcodeGen project.yml): MenuBarExtra UI, onboarding, SMAppService login item
Tools/mock-link-helper  fake helper serving synthetic windows and encoded test patterns for simulator E2E tests
```

Dependency direction: `App` → `WindowKit` → `LinkTransport` → `LinkProtocol`; `Helper` → `HelperCore` → `LinkTransport`
→ `LinkProtocol`. `RemoteDisplay` gains the video renderer but does not import `LinkTransport`. Never import upward.
No third-party dependencies: CryptoKit, Network, VideoToolbox, ScreenCaptureKit, ApplicationServices only.
No new `unsafeFlags`: `LinkProtocol` only parses framing, and video decoding happens in VideoToolbox.

### 4.2 Transport

- **QUIC over Network.framework** (`NWProtocolQUIC`), one connection per Mac, ALPN `screon-link/1`.
  - Stream 0: control (bidirectional, ordered).
  - One unidirectional stream per window/surface for video: no head-of-line blocking between windows.
  - Input on its own stream; pointer moves coalesced like `OutboundQueue`.
  - No QUIC datagrams in v1 (unreliable in Network.framework today).
- Fallback: TLS 1.3 over TCP with the same framing multiplexed, for networks that block UDP.
- Discovery: Bonjour `_screon-link._udp` with TXT `v=1`, `fp=<identity fingerprint prefix>`; manual host/port too.
  Saved computers in `ConnectionKit` gain an optional helper endpoint next to the RFB endpoint.

### 4.3 Security (non-negotiables #1 and #2 apply in full)

- **Identities**: each device and each helper has a long-term Curve25519 signing key (CryptoKit), private keys in the
  Keychain only. TLS 1.3 with a self-signed certificate per identity, **pinned** after pairing.
- **Pairing**: the helper shows a QR code (host, port, fingerprint, one-time 128-bit secret, 2-minute expiry) and a
  6-digit code. Both sides prove knowledge of the secret inside the TLS channel (HMAC over the transcript and both
  fingerprints), so a MITM cannot pair. Every new pairing is then **approved locally on the Mac** with LocalAuthentication
  (Touch ID or the account password typed on the Mac). No password ever crosses the network, so a LAN attacker cannot
  trigger account lockout. QUIC here supports certificates only (no PSK) and CryptoKit has no PAKE, hence pinned
  certificates plus an HMAC proof; a 6-digit comparison (SAS) covers devices without a camera.
- **Authorization**: per paired device, revocable from the helper menu; optional "ask on the Mac before each session".
- **Capability surface**: the helper accepts only the messages in §5. No shell, no scripting, no arbitrary file paths
  (file transfer writes only into a helper-owned inbox and opens it with the chosen app).
- **Hostile input both ways**: every length, count, size, id and rect from the wire is bounded before it allocates or
  indexes (max windows, surfaces, icon bytes, title length, frame size, menu depth/items). `LinkProtocol` gets
  malicious-input tests and a fuzz suite like `ZRLEFuzzTests`.
- **Privacy**: window titles, app names and clipboard contents are logged only with `os_log` `.private`. The helper shows a
  menu-bar indicator and "Disconnect all" whenever a session is active.
- No unpaired or unencrypted mode exists.

### 4.4 Capture and encoding (helper)

- One `SCStream` per **managed window**, `SCContentFilter(desktopIndependentWindow:)`, so the window stays live when
  covered or on another Space.
- **Transient surfaces** (same pid, level above normal: menus, popovers, tooltips, combo-box lists, sheets that are
  separate windows) are detected by `WindowTracker` and sent as **child surfaces** with an offset relative to their
  parent, composited on the iPad. Small surfaces may use a snapshot path (PNG/JPEG per change) instead of video.
- Output size = window size in Mac pixels, capped to the iPad scene's pixel size (never upscale on the Mac).
- `SCStreamConfiguration`: pixel format per codec mode; `minimumFrameInterval` from the scene's refresh (60, or 120 on
  ProMotion when the Mac path allows); `showsCursor = false` (the iPad draws the pointer).
- Use `SCStreamFrameInfo.status` and `dirtyRects`: skip idle frames; when a window goes idle, send one high-quality
  refresh frame so text is sharp.
- **VideoToolbox**: HEVC (Main/Main10) hardware encoder, `EnableLowLatencyRateControl`, no B-frames, real-time, long key
  frame interval + **on-demand IDR** (new subscriber, decode error, scene restored), long-term reference frames for loss
  recovery. No hardware HEVC 4:4:4 encode profile exists, so text sharpness comes from `.best` capture resolution and a
  high-quality refresh when idle. H.264 High fallback where HEVC hardware is missing.
- **Adaptive bitrate**: the iPad reports RTT, decode time, drops and receive rate every 250 ms; the helper adjusts each
  window's bitrate and frame rate, giving the focused window the largest share (other visible windows 15–30 fps).
- Per-app **audio**: app-filtered SCK audio → 48 kHz PCM (AAC-ELD when bandwidth is short) → its own stream; mixed per window on the iPad,
  muted when that window's scene is in the background (configurable).

### 4.5 The stage (helper window management)

- Optional **virtual stage display** (HiDPI) created when App Mode starts and removed when the last session ends.
  Streamed windows move onto it so they do not clutter or leak onto the physical screen, and can be sized freely.
  Without it (API unavailable or self-test failed), windows stay where they are and are only resized.
- Size matching: the iPad scene's size in points becomes the window's size in Mac points, clamped to the AX min/max.
  Stage Manager resizes are debounced (~150 ms), applied with AX, then read back.
- **Restore**: on session end, crash or helper quit, every moved or resized window is put back. Original frames are saved
  before the first change and persisted, so a helper crash restores on next launch.
- **Input needs a visible target**: injected mouse events hit whatever is topmost. Before a pointer event for window W,
  the helper makes W topmost at that point (raise, activate the app if needed). On the stage, windows are tiled without
  overlap so raising is rare. Keyboard events go to the active app; focusing an iPad scene activates its Mac window.
- Native full-screen windows (own Space) are captured fine but cannot be moved by AX: offer "Exit full screen"
  (`AXFullScreen = false`) when opened in App Mode.

### 4.6 Input (iPad → helper)

- Every event carries `windowId` and **window-relative coordinates in Mac points** (doubles). The helper resolves global
  coordinates at injection time, so a window moving on the Mac never receives a click meant for elsewhere. Events for
  unknown or destroyed windows are dropped.
- Pointer: move, buttons, drag, hover. The iPad pointer is drawn locally with the Mac cursor shape sent by the helper.
- Scroll: continuous scrolling with phases and momentum; line scrolling for mice.
- Gestures: pinch/rotate/smart zoom, behind a capability flag (undocumented event fields), fallback ⌘+scroll.
- Keyboard: hardware keys as virtual keycodes with modifiers. **Text as Unicode strings**
  (`CGEventKeyboardSetUnicodeString`), so the iPad's own input methods (including Vietnamese Telex/VNI) compose locally
  and the Mac receives final characters. Per-app toggle for raw keys (games, terminals).
- Apple Pencil: tablet events with pressure, tilt and azimuth; hover as pointer moves.
- InputKit touch modes (direct, trackpad) reused through a window-relative `RemoteCoordinateSpace`.

### 4.7 Menus

- The helper reads the active app's menu bar through AX (`kAXMenuBarAttribute`, recursively: title, enabled, checked,
  key equivalent, submenu), on demand and on menu/title change notifications, with bounded depth and count.
- The iPad shows it natively: the iPadOS 26 menu bar (`UIMainMenuSystem`) for the focused scene, and a toolbar "Menus"
  button with `UIMenu` otherwise. Choosing an item sends `menu.press(path)`; the helper re-resolves the path and performs
  `AXPress` (stale paths are rejected).
- Mac key equivalents become `UIKeyCommand`s for the focused scene so ⌘-shortcuts reach the Mac (Screon's own reserved
  shortcuts excluded).

### 4.8 Launcher and window UI (iPad)

- **Launcher scene**: running apps (with window counts), recents, all installed apps, search. Icons cached on disk by
  `bundleId + version`.
- Opening an app launches or activates it, then opens one iPad scene per window (setting: separate iPad windows, or tabs
  in one iPad window).
- New Mac windows open new scenes automatically (setting) or appear as a badge in the launcher.
- Window actions: close, minimise, zoom, move to another display, "Show on full desktop" (jumps to the RFB Desktop scene).
- Scene restoration stores `(computerId, bundleId, title + index hint)`; after reconnect the scene re-binds to the best
  matching live window or falls back to the launcher.
- External display: any window scene can move to an external monitor.

### 4.9 Clipboard and files

- **Clipboard v2**: text, RTF, HTML, images, file references; size-limited. Sensitive types (concealed pasteboard types,
  local-only `UIPasteboard` items) are never sent, matching `ClipboardBridge`. Sync on scene focus and before paste.
- **File transfer**: dropping a file from Files onto an App Mode window uploads it to the helper inbox and opens it with
  that app (`NSWorkspace.open(_:withApplicationAt:)`). Mac → iPad through a share action saving into Files.

### 4.10 Lifecycle and resilience

- A backgrounded scene **pauses** its stream (the helper stops that `SCStream`). When iOS suspends the app, the connection
  may die; on foreground it reconnects with a **resume token**, gets a full snapshot, and each visible window gets an IDR.
- Mac locked / screen saver / login window: capture produces nothing, the helper reports `macLocked`, and the iPad offers
  the RFB Desktop scene to unlock (existing type-30 path); App Mode resumes afterwards.
- The helper keeps the display awake during a session (`IOPMAssertion`) and releases it on disconnect.
- A permission revoked mid-session produces an explicit error state, never a silent black window.

### 4.11 Helper app

- SwiftUI `MenuBarExtra`: status, paired devices, active sessions, "Disconnect all", "Restore windows", settings.
- Onboarding with a live checklist and deep links for Accessibility, Screen Recording and Local Network.
- Login item via `SMAppService.mainApp` (one bundle owns every privacy grant); runs only in the logged-in user's session.
- Developer ID signed, hardened runtime, notarized `.dmg`. Updates via a signed version manifest (no third-party
  updater). `hello` carries a protocol range and capability flags so iPad and helper update independently.

---

## 5. Link protocol (v1)

Binary, little-endian; each message is `u32 length (bounded) | u16 type | payload`. Strings are UTF-8 with `u16` lengths,
bounded per field. Ids are `u32`, assigned by the helper, never reused within a session.

**Session**

| Dir | Message | Payload |
|---|---|---|
| ↔ | `hello` | protocol range, capability bitset, device name, scene limits |
| H→C | `welcome` | session id, resume token, display info, capabilities |
| C→H | `resume` | resume token, last state version |
| H→C | `snapshot` | state version, all apps and windows (replaces client state) |
| ↔ | `ping` / `stats` | timestamps; RTT, decode time, drops, receive rate |
| H→C | `status` | `macLocked`, `permissionMissing(kind)`, `stageUnavailable`, … |

**Apps**

| Dir | Message | Payload |
|---|---|---|
| C→H | `apps.list` | filter (running / installed / recent) |
| H→C | `apps.items` | `[bundleId, name, pid?, iconKey, isActive, windowCount]` |
| C→H | `apps.icon` | iconKey, pixel size |
| H→C | `apps.iconData` | iconKey, PNG (≤ 256 KiB) |
| C→H | `apps.launch` / `apps.activate` / `apps.quit` | bundleId |
| H→C | `apps.changed` | launched / terminated / activated |

**Windows**

| Dir | Message | Payload |
|---|---|---|
| H→C | `window.created` | id, pid, bundleId, parentId?, kind (managed/transient), level, frame (pt), scale, title, flags, min/max size |
| H→C | `window.updated` | id, changed fields only, state version |
| H→C | `window.destroyed` | id |
| H→C | `window.order` | ordered ids, active id |
| C→H | `window.subscribe` / `window.unsubscribe` | id, target pixel size, max fps, quality tier |
| C→H | `window.setFrame` | id, size (pt), placement hint |
| C→H | `window.command` | id, raise / close / minimise / zoom / exitFullScreen |
| C→H | `stream.keyframe` | id |

**Media** (per-window streams)

| Dir | Message | Payload |
|---|---|---|
| H→C | `video.config` | codec, parameter sets, pixel size, content rect, scale |
| H→C | `video.frame` | pts, flags (key, refresh), NAL units (bounded) |
| H→C | `surface.snapshot` | id, parent offset, PNG/JPEG |
| H→C | `cursor.shape` / `cursor.ref` | id, hotspot, PNG / id |
| H→C | `audio.config` / `audio.packet` | pid, Opus packets |

**Input, menus, data**

| Dir | Message | Payload |
|---|---|---|
| C→H | `input.pointer` | windowId, x, y (pt, window-relative), buttons, modifiers, pressure, tilt |
| C→H | `input.scroll` | windowId, dx, dy, phase, momentum phase |
| C→H | `input.gesture` | windowId, kind, value, phase |
| C→H | `input.key` | keycode, down/up, modifiers |
| C→H | `input.text` | Unicode string (≤ 1 KiB) |
| C→H / H→C | `menu.get` / `menu.tree` | bundleId / bounded tree |
| C→H | `menu.press` | bundleId, item path |
| ↔ | `clipboard.offer` / `clipboard.request` / `clipboard.data` | types, bounded payloads |
| C→H | `file.begin` / `file.chunk` / `file.end` | sanitised name, bounded size, target app |

---

## 6. Implementation plan

Every phase ends with `/verify` green, new strings localized (English in code + `vi.lproj`), `CHANGELOG.md` and
`docs/app-status.md` updated, and no real data in the repo. Real-Mac testing only when the maintainer asks.

### Phase 0 — Spikes and decisions
- Helper spike: SCK per-window capture → VT HEVC → decode on iPad over a plain local socket; measure glass-to-glass
  latency, Mac CPU/GPU, text sharpness at 4:2:0 vs 4:4:4.
- Virtual display on the current macOS and the macOS 27 beta: create, HiDPI modes, move windows onto it, capture.
- `CGEvent` injection into a window on the virtual display; tablet pressure; gesture fields.
- AX menu reading across AppKit, Catalyst, Electron and SwiftUI apps.
- Look for a supported way to avoid the periodic Screen Recording re-confirmation.
- Optional: type 29 + display selection on Apple's server (record with the `protocol-finding` skill).
- **Exit**: results written here; go/no-go for the virtual stage and gesture injection.

### Phase 1 — Protocol and transport
- `LinkProtocol`: §5 messages, framing, bounded decoder, encoder, version/capability negotiation; round-trip,
  malicious-input and fuzz tests.
- `LinkTransport`: QUIC + TCP fallback, identities, pinning, pairing (OpenDirectory check behind a protocol), resume.
  Tests use local listeners only.
- `Tools/mock-link-helper`: synthetic apps and windows, scripted window events, encoded test patterns.
- **Exit**: the simulator pairs with the mock helper and receives a snapshot; fuzz suite in CI.

### Phase 2 — Helper core
- `HelperCore`: `AppCatalog`, `WindowTracker` (AXObserver + CGWindowList reconciliation, AX↔`CGWindowID` with fallback),
  `CaptureEngine`, `Encoder` with ABR, `InputInjector`, `Stage` with persisted restore, `PasteboardBridge`.
- `Helper` app: menu bar, onboarding, pairing UI, device list, login item, signed + notarized build script.
- **Exit**: the helper streams any window to a test client; windows are restored after `kill -9`.

### Phase 3 — iPad core
- `RemoteDisplay`: `VideoSurfaceRenderer` (VTDecompressionSession → CVMetalTextureCache → Metal, YUV → RGB),
  child-surface compositing, local cursor rendering, `uvRect` (also usable by the RFB renderer).
- `WindowKit`: model from snapshot + deltas, transient-surface grouping, window-relative coordinate space, input routing
  (events outside the window's surfaces are dropped; a drag that starts inside is captured until release).
- `AppModeSession` actor per Mac shared by all scenes; scene ↔ window binding; pause/resume per scene.
- **Exit**: one Mac window usable full screen on iPad with touch, pointer, keyboard, text input and Pencil.

### Phase 4 — Multi-window experience
- Launcher scene, icon cache, search, recents.
- One `UIScene` per window (`requestSceneSessionActivation` + `NSUserActivity`); Stage Manager resize → `window.setFrame`;
  external display; scene restoration and re-binding.
- Menu bridge (iPadOS menu bar + "Menus" button), Mac key equivalents as `UIKeyCommand`s.
- Window commands, new-window settings, tabs-in-one-scene option.
- **Exit**: three apps in three Stage Manager windows plus one on an external display, all live and independently usable.

### Phase 5 — Media quality and completeness
- Per-window ABR priorities, idle refresh frames, 120 Hz where possible, H.264 fallback.
- Per-app audio (Opus).
- Clipboard v2, file transfer.
- Gesture injection (if Phase 0 says go), cursor shapes, Pencil hover.
- **Exit**: §7 targets met on the reference hardware.

### Phase 6 — Integration and hardening
- `ConnectionKit`: one saved computer = RFB endpoint + optional helper identity; Bonjour discovery for both.
- Locked-Mac flow through the RFB Desktop scene; helper missing → explain and offer Desktop mode.
- `security-review` over pairing, transport, decoders, clipboard and files; `gitleaks`; threat model section here.
- Simulator UI tests against `mock-link-helper`; localization complete; README (both languages), `app-status.md`,
  helper install guide.

---

## 7. Targets

| Metric | Target (local network, Apple silicon Mac, recent iPad) |
|---|---|
| Glass-to-glass latency, focused window | ≤ 50 ms median, ≤ 80 ms p95 |
| Frame rate, focused window | 60 fps (120 where supported) |
| Input → Mac event | ≤ 10 ms |
| Bitrate of an idle document window | ~0 plus one refresh frame |
| Mac CPU per active 1080p window | ≤ 10 % of one performance core |
| Foreground → first frame | ≤ 1 s |
| Windows restored after session end or crash | 100 % |

---

## 8. Testing

- Pure packages (`LinkProtocol`, `WindowKit`, coordinate and scene logic, ABR policy) with Swift Testing.
- Fuzz and malicious-input tests for every decoder, in both directions (the helper treats the iPad as hostile too).
- `HelperCore` pieces behind protocols with fakes (`FakeWindowSystem`, `FakeCapture`, `FakeInjector`), so tracking,
  stage and restore logic are tested without permissions.
- Simulator E2E only against `Tools/mock-link-helper` on `127.0.0.1`.
- Real-Mac runs only on maintainer request; never commit captures, real-screen screenshots, window titles or hostnames.

---

## 9. Risks and open questions

| Risk | Impact | Mitigation |
|---|---|---|
| Periodic Screen Recording re-confirmation | Friction for always-on use | Investigate supported options; clear onboarding; Desktop mode works without it |
| Private virtual display API breaks | No stage | Feature flag, runtime self-test, fall back to resize in place |
| Injected input needs a topmost target | Clicks on the wrong window | Stage tiling, raise before input, window-relative coordinates resolved at injection |
| Gesture injection is undocumented | No pinch/rotate | Capability flag, ⌘+scroll fallback |
| AX coverage varies by app framework | Missing menus, unreliable resize | Read back, per-app quirks table, graceful degradation |
| macOS 27 window-list visibility changes | Tracker breaks | Prefer `SCShareableContent` + AX over `CGWindowList` |
| iOS suspends sockets in the background | Stream gaps | Pause/resume, resume tokens, fast IDR |
| A second authentication surface | Security exposure | Pinned identities, transcript-bound pairing, OpenDirectory check, minimal capabilities, fuzzing, `security-review` |

Open questions:
1. HEVC 4:4:4 hardware encode/decode on the target Mac and iPad generations.
2. Whether one `SCStream` per window scales past ~8 windows, or a shared display stream with crops is cheaper beyond that.
3. Whether the server's type 29 virtual displays can replace the private API for the stage.
4. Notification forwarding: no public API to read other apps' notifications; out of scope unless a safe source appears.

---

## 10. References

- Apple: ScreenCaptureKit (`SCContentFilter`, `SCStream`) documentation and WWDC22 session 10155
- Apple: "Supporting multiple windows on iPad" (UIKit)
- Apple: Remote Desktop User Guide — High Performance screen sharing
- Apple: Accessibility (`AXUIElement`), Quartz Event Services (`CGEvent`), VideoToolbox, Network.framework (QUIC)
- `docs/protocol-notes.md` (Apple server messages 8 and 29, encodings)
