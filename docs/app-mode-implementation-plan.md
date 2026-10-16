# App Mode — production implementation plan

Companion to `docs/app-mode-design.md` (the *what* and *why*). This document is the *how*: decisions, work breakdown,
acceptance criteria, security, quality gates and release. Where research changed the design, §2 lists the deltas and
the design document is updated to match.

Confidence tags: **H** Apple documentation or a DTS statement, **M** several consistent independent reports,
**L** single report or inference. **SPIKE** = must be measured before the dependent work starts.

---

## 0. Summary

- **Product**: a Mac menu-bar helper ("Screon Helper") streams individual app windows to Screon on iPad/iPhone; each Mac
  window can be its own iPad window (Stage Manager, Split View, external display). The RFB full-desktop mode stays as
  fallback and as the unlock path.
- **Pixels**: ScreenCaptureKit per window → VideoToolbox HEVC 4:2:0 low-latency → one QUIC stream per window.
- **Control**: AX + CGWindowList window model, CGEvent input, AX menus mirrored into the iPadOS menu bar.
- **Trust**: pinned mutual-TLS identities; pairing by QR one-time secret (or 6-digit comparison) **approved on the Mac
  with Touch ID / account password via LocalAuthentication**; no passwords on the wire.
- **Platforms**: helper on macOS 15+; App Mode on iPadOS/iOS 26+ (RFB mode keeps iOS 18+). Built with the newest SDK.
- **Distribution**: helper Developer ID + notarized `.dmg`; iOS via TestFlight/ad-hoc. No App Store dependency.
- **Shape**: 9 milestones (M0–M8). M0 is a spike gate; nothing after it starts until its go/no-go items are answered.

---

## 1. Scope

### In scope (v1.0, "production")
1. Pair, unpair and revoke devices; Bonjour discovery and manual address; saved computers hold both endpoints.
2. Launcher: running, recent and installed apps with icons; search; launch/activate/quit.
3. Per-window streaming with live updates while covered; up to the measured per-Mac budget of simultaneous windows.
4. One iPad scene per Mac window (or tabs in one scene); Stage Manager resizing resizes the Mac window; scene restoration.
5. Child surfaces: sheets, popovers, menus, tooltips, combo lists composited on their parent.
6. Input: touch (direct and trackpad modes), pointer with hover, hardware keyboard, Unicode text from iPad input methods,
   Apple Pencil pressure/tilt, continuous scrolling with momentum; pinch/rotate where the Mac allows it.
7. Mac menus in the iPadOS menu bar and a "Menus" button; Mac key equivalents.
8. Clipboard (text, rich text, images) both ways; file drop into a Mac app; file share out.
9. Per-app audio.
10. Virtual stage display (when available) with guaranteed window restore.
11. Locked-Mac / login-window handling via the RFB scene; permission-missing states; helper onboarding.
12. Diagnostics export, signposts, crash-safe logs with privacy redaction.
13. English + Vietnamese for every string in app and helper.

### Out of scope (v1.0)
- Access across the Internet without VPN (no relay/NAT traversal). Works over any routed VPN.
- Notification forwarding (no public API).
- Multiple macOS user sessions at once; capture before login (not possible with ScreenCaptureKit).
- Windows/Linux hosts.

### Support matrix

| Component | Minimum | Tested |
|---|---|---|
| Screon (RFB mode) | iOS/iPadOS 18 | 18, 26, 27 |
| Screon (App Mode) | iOS/iPadOS 26 | 26, 27 |
| Screon Helper | macOS 15, Apple silicon or Intel with HEVC hardware | 15, 26, 27 |
| Reference hardware | M1 base Mac, M4 Mac; A-series iPad, M-series iPad Pro | — |

Rationale for iPadOS 26: the Swift `NetworkConnection` QUIC API, `UIMainMenuSystem`, effective-geometry callbacks and
free-form windows all start there (H). Supporting iOS 18 for App Mode would double the transport and menu code.

---

## 2. Design deltas from research

| Topic | Before | Now | Why |
|---|---|---|---|
| Pairing secret check | password verified via OpenDirectory | **LocalAuthentication on the Mac** (`LAContext.evaluatePolicy(.deviceOwnerAuthentication)`) approves each new pairing | OD failures may count toward the account lockout policy → a LAN attacker could lock the user out (L); local presence is stronger anyway |
| TLS | self-signed + pinning, PSK considered | **PKI only**: hand-built self-signed P-256 certificates, pinned by SPKI hash | QUIC in Network.framework is TLS 1.3, which has no PSK support there (H); CryptoKit has no PAKE (M) |
| No-camera pairing | — | commit-then-reveal X25519 + **6-digit SAS** compared on both screens | standard SAS construction from CryptoKit primitives |
| Datagrams | input and probes | **none in v1**; input on its own stream | datagram support on the older API is broken and flaky on the new one (H/M) |
| Mac transport API | `NetworkConnection` | **`NWListener` + `NWConnectionGroup` (QUIC)** on the helper unless SPIKE shows the new listener works | QUIC `NetworkListener` was not ready in 26.0 (M) |
| Codec | HEVC, 4:4:4 if possible | **HEVC Main 4:2:0** (Main10 optional) with LTR loss recovery; sharp text via `.best` capture + idle high-quality refresh; optional lossless tile path later | no hardware HEVC 4:4:4 encode profile exists (M) |
| Low-latency encode | LLRC | LLRC; on macOS 26+ the `VideoConferencing` compression preset | preset documented on 26 (H); LLRC for HEVC only reported (M) → SPIKE |
| Audio | Opus | **48 kHz PCM** on LAN, **AAC-ELD** when bandwidth-limited | no Opus PLC/FEC exposed (M) |
| Child windows | CGWindowList grouping | `includeChildWindows = true` (14.2+) for attached children; CGWindowList (layer, owner pid) for menus/popups | sheets are covered by SCK; context menus are separate, often system-owned windows (M) |
| Permissions | Screen Recording + Accessibility | + **macOS 27 "Remote Desktop" privacy category**; request the persistent-content-capture entitlement | new category not queryable by API (M); entitlement may avoid monthly re-approval (L) |
| Login item | `SMAppService.agent` | **`SMAppService.mainApp`** | one bundle owns every TCC grant (M) |
| Input targeting | raise before input | **focus follows interaction**: raise + activate the window the iPad touches, post at the HID tap | background apps mishandle events posted to their pid (M) |
| unsafeFlags | `-O` for LinkProtocol | **none added** | `LinkProtocol` parses framing only; video decode is in VideoToolbox; respects CLAUDE.md |

---

## 3. Architecture refinements required before App Mode

The current code assumes one RFB session per scene and RFB types everywhere. Three refactors come first (M1).

### 3.1 Input intents (InputKit)
`TouchMapper`, `ModifierKeys`, `KeysymMapper` and `ScreonView.onInput` emit `[ClientMessage]`. Introduce a
protocol-neutral layer:

```
InputKit:  TouchMapper → [InputIntent]           (pointer(at: RemotePoint, buttons), scroll(dx, dy, phase),
                                                  gesture(kind, value, phase), key(KeyStroke), text(String),
                                                  tablet(pressure, tilt))
RFB:       RFBInputEncoder: [InputIntent] → [ClientMessage]   (moves today's logic, bit-for-bit identical)
Link:      LinkInputEncoder: [InputIntent] → [LinkMessage]
```

- `RemotePoint` carries `Double` coordinates in the space's own unit; the RFB encoder rounds to pixels exactly as today.
- Acceptance: all existing InputKit and UI input tests pass unchanged against the RFB encoder (golden comparison of the
  emitted `ClientMessage`s over the existing test corpus).

### 3.2 Surface rendering (RemoteDisplay)
Split `FramebufferRenderer` into:
- `SurfaceTexture` protocol: `size`, `textures(for frame:)`, `pixelLayout` (`.bgra` | `.ycbcr420(bitDepth)`).
- `FramebufferSurface` (today's BGRA dual-texture upload) and `VideoSurface` (`CVPixelBuffer` via `CVMetalTextureCache`).
- `SurfaceCompositor`: draws a main surface with a `uvRect`, then child-surface quads at offsets, then the cursor.
- `ViewportGeometry` gains `sourceRect` (default = whole surface) so crop and zoom share one transform.
- Acceptance: RFB rendering pixel-identical in `RemoteDisplayTests` render-to-texture tests.

### 3.3 Scene and session ownership (App)
- App-level `LinkSessionRegistry` (`@MainActor @Observable`, next to `ConnectionsModel`): one `AppModeSession` actor per
  paired Mac, reference-counted by scenes; the last scene leaving starts a grace timer (30 s) before disconnect.
- Scene roles: `desktop` (today's RFB `RootView`), `launcher`, `remoteWindow(computerId, windowRef)`.
- `ScreonView`'s app-level active/inactive observers move to per-scene `scenePhase`, so one window going inactive does
  not release input in another.
- DEBUG auto-connect runs only in the first scene.
- `ReconnectPolicy` gets a `PermanentFailure` protocol so link errors (revoked, version mismatch) stop retrying.

---

## 4. Milestones and work breakdown

Sizes: **S** ≤ 3 days, **M** ≤ 2 weeks, **L** ≤ 4 weeks (one engineer). Every task ends with `/verify` green,
strings localized (English + `vi.lproj`), tests added, and `CHANGELOG.md` / `docs/app-status.md` updated where
user-visible or newly verified.

### M0 — Spike gate (L)
Throw-away code in a branch or `Spikes/` outside the packages; results recorded in §13 of this document.

| ID | Spike | Go criterion |
|---|---|---|
| S1 | macOS 27 "Remote Desktop" privacy category: which prompt SCK triggers, expiry, detection without prompting | a documented detection + onboarding path |
| S2 | Monthly Screen Recording re-approval on 15/26 with and without the persistent-content-capture entitlement (request it from Apple at M0 start) | known behaviour; onboarding copy written |
| S3 | N per-window `SCStream`s (1/4/8/12 @60 fps, M1 base and M4) vs one stage-display stream with crops: CPU, GPU, pacing, capture-service stability | pick per-window, stage-crop, or hybrid with a threshold N |
| S4 | HEVC + LLRC / VideoConferencing preset on 15/26/27; N concurrent sessions; LTR recovery; encode latency | ≤ 8 ms p95 encode for 1080p on M1 base |
| S5 | iPad decode: N concurrent sessions on A- and M-series; Main10; invalid-session recovery after background | ≤ 8 ms p95 decode; no crash in 30 min |
| S6 | QUIC: helper `NWListener` + groups ↔ iPad `NetworkConnection<QUIC>`; uni streams per window; throughput and HOL on Wi-Fi; Local Network prompt timing on both ends | stable 30 min at 60 Mbit/s, no cross-stream stalls |
| S7 | Hand-built DER certificate → `SecIdentity` on iOS and macOS; mutual TLS over QUIC with pin validators; TLS exporter availability | mTLS works on both OS lines |
| S8 | `CGVirtualDisplay` on 15/26/27: create, HiDPI, teardown, ICC profile build-up, capture after reconfiguration | stable create/remove 100× or decision to ship without stage |
| S9 | Input: clicks into non-front windows with focus-follows-interaction; tablet events in pro drawing apps; Unicode chunks (≤ 20 UTF-16 units) incl. Vietnamese; secure input; gesture fields | per-feature go/no-go + capability flags |
| S10 | AX: menu tree read time on large apps; Electron/Java/Catalyst coverage; set-frame reliability with enhanced-UI toggling | quirks table seeded |
| S11 | Child windows/menus/full-screen/other-Space/minimised behaviour of `desktopIndependentWindow` + `includeChildWindows` | surface model confirmed |

Exit: every row decided; §2 and the design updated; any "no-go" has a fallback recorded.

### M1 — Foundations and refactors (M)
| ID | Task | Files | Acceptance |
|---|---|---|---|
| F1 | Input intents (§3.1) | `Sources/InputKit/*`, `ScreonView.swift`, `SessionController.swift` | golden RFB output identical; all UI input runners pass |
| F2 | Surface rendering split (§3.2) | `Sources/RemoteDisplay/*` | render tests pixel-identical |
| F3 | Scene roles + registry skeleton (§3.3) | `App/ScreonApp/ScreonApp.swift`, `Views.swift`, new `LinkSessionRegistry.swift` | multi-window RFB unchanged; per-scene focus test |
| F4 | `ReconnectPolicy` permanent-failure protocol | `Sources/SessionKit/ReconnectPolicy.swift` | unit tests |
| F5 | `ServiceBrowser` parameterised by service type and transport | `Sources/ConnectionKit/ServiceBrowser.swift` | Bonjour tests with local listener for `_screon-link._udp` |
| F6 | `SavedConnection.helper: HelperEndpoint?` (identity hash, last address), backward-compatible JSON | `Sources/ConnectionKit/SavedConnection.swift` | decode of old JSON fixtures |
| F7 | Repo governance updates (§10) | `CLAUDE.md`, `.claude/rules/*`, skills, `Package.swift` | `/verify` covers the new targets |

### M2 — Link protocol and transport (L)
| ID | Task | Acceptance |
|---|---|---|
| P1 | `LinkProtocol`: message enum (§5 of design + §5 here), TLV framing `u16 type, u32 length`, per-field caps (constants in one `LinkLimits` type), encoder/decoder, `LinkError.malformed(String)` | round-trip tests for every message; malicious tests per field (oversized, truncated, negative/overflow, unknown type → skip by length if in the "ignorable" range, else close) |
| P2 | Fuzz suite modelled on `ZRLEFuzzTests` (seeded SplitMix64, 4 seeds × 1000 iterations, valid-biased) | no trap, no unbounded allocation (allocation counter in tests) |
| P3 | Version and capability negotiation (`hello` with range + bitset; downgrade impossible because `hello` is inside mTLS and echoed in the pairing transcript) | tests for mismatch → `PermanentFailure.versionMismatch` |
| P4 | `LinkTransport` identities: P-256 key in Keychain (`AfterFirstUnlockThisDeviceOnly`), minimal DER X.509 writer (KeyUsage = digitalSignature, ≤ 825 days, auto-rotate at 80 %), SPKI-SHA256 ids | DER output parsed by `SecCertificateCreateWithData`; vectors checked against an independent tool |
| P5 | QUIC client (iOS `NetworkConnection<QUIC>`) and server (macOS `NWListener`); control stream, per-window uni streams, input stream; TCP+TLS fallback with stream multiplexing | loopback tests (macOS) with both ends in-process |
| P6 | Pairing (§6.2): QR payload codec, HMAC proof, SAS mode, attempt limits, single-use secrets | protocol tests with tampered transcript, replay, expired QR, wrong SAS |
| P7 | Session resume tokens (opaque 32 bytes, 10 min, single use, bound to identity) | reconnect test reaches `snapshot` without re-pairing |
| P8 | `Tools/mock-link-helper` (Swift executable, binds 127.0.0.1): synthetic apps, windows, scripted events, encoded colour-bar HEVC per window, input log for verification | used by simulator E2E in M5 |

### M3 — Helper core (L)
| ID | Task | Acceptance |
|---|---|---|
| H1 | `HelperCore` target (`#if os(macOS)`), OS seams as protocols: `WindowSystem`, `CaptureSystem`, `EventPoster`, `MenuSystem`, `Pasteboard`, `DisplayStage` with fakes | logic tests run without permissions |
| H2 | `AppCatalog`: running/installed/recent apps, icons (PNG, ≤ 256 KiB, cache key = bundle id + version + size) | tests with fake workspace |
| H3 | `WindowTracker`: one AXObserver per pid on a dedicated thread, messaging timeout 0.5 s, notifications of §2.3 design, 1 s CGWindowList reconciliation, AX↔`CGWindowID` via private call with frame+pid fallback, transient-surface classification by level/owner | scripted fake-window tests; real-app soak in M7 |
| H4 | `CaptureEngine`: per-window `SCStream` (`420v`, `queueDepth` 3, `.best`, `showsCursor` false, `ignoreShadowsSingleWindow`, `shouldBeOpaque`, `includeChildWindows`), drop non-`.complete` frames, dirty-rect idle detection, resize via `updateConfiguration` (debounced), restart on `didStopWithError`; stage-crop mode if S3 requires | frame-pacing test harness; zero leaked streams after 1000 subscribe/unsubscribe |
| H5 | `Encoder`: VT HEVC session per stream, LLRC/preset, no reordering, `MaxFrameDelayCount` 0, bitrate/fps updates, force-IDR, LTR with acknowledgements | encode latency histogram in diagnostics |
| H6 | `RateController`: per-client budget from `stats` (RTT, receive rate, decode time, drops), focused window priority, idle → 0 fps + one refresh at low QP | simulation tests with synthetic stats traces |
| H7 | `InputInjector`: focus-follows-interaction, HID-tap posting, scroll phases + momentum, tablet proximity/point events, Unicode chunks ≤ 20 UTF-16 units without splitting pairs, key events from virtual keycodes, gesture events behind a capability flag, secure-input detection → `status(secureInput)` | coordinate-resolution tests (window moved between event and injection) |
| H8 | `Stage`: virtual display lifecycle (if S8 go), tiling without overlap, size matching (iPad pt = Mac pt), saved original frames persisted atomically before the first change, restore on end/crash/next launch, enhanced-UI toggle around resizes | kill -9 restore test; 100× create/remove |
| H9 | `MenuReader`: lazy level-by-level menu tree (depth ≤ 6, ≤ 500 items/level, titles ≤ 256 chars), `AXPress` by path re-resolution | stale-path rejection test |
| H10 | `PasteboardBridge` (types allow-list, size caps, concealed types never sent), `FileInbox` (sanitised names, quota 2 GiB, cleanup after 24 h) | path-traversal tests |
| H11 | `AudioCapture`: per-app SCK audio → PCM / AAC-ELD | — |
| H12 | `LinkServer`: session state machine, per-device authorization, `status` reporting (locked, permission missing, stage unavailable, secure input) | state-machine tests |

### M4 — Helper app (M)
| ID | Task | Acceptance |
|---|---|---|
| A1 | `Helper/project.yml` (XcodeGen, macOS 15, `LSUIElement`, hardened runtime, no sandbox, `NSLocalNetworkUsageDescription`, `NSBonjourServices`, signing via `Signing.local.xcconfig` pattern) | builds unsigned in CI |
| A2 | `MenuBarExtra` UI: status, sessions, paired devices (rename/revoke), "Disconnect all", "Restore windows", settings (ask before each session, stage on/off, audio on/off) | localized en/vi |
| A3 | Onboarding: live checklist for Accessibility, Screen Recording / Remote Desktop, Local Network; deep links; restart prompt where grants need it | manual test script |
| A4 | Pairing UI: QR + 6-digit, LocalAuthentication approval sheet, attempt counter | — |
| A5 | Login item via `SMAppService.mainApp`; single-instance guard | clean-user install test |
| A6 | Release pipeline: Developer ID signing, notarization (`notarytool`), stapled `.dmg`, signed update manifest (Ed25519) checked by the helper | `spctl --assess` passes on a clean VM |

### M5 — iPad core (L)
| ID | Task | Acceptance |
|---|---|---|
| I1 | `WindowKit` model: apps, windows, transient surfaces, z-order, state versioning, snapshot+delta application with consistency checks | property tests (random delta sequences converge with snapshot) |
| I2 | `AppModeSession` actor: transport, subscriptions per scene, pause/resume, IDR requests, resume tokens, stats reporting every 250 ms | mock-helper integration tests |
| I3 | Video pipeline: `VTDecompressionSession` per window (`420v`, real-time), invalid-session recovery, frame queue of 1 (latest wins), presentation on the scene's display link | decode/present signposts |
| I4 | `AppWindowView` (Metal) on `SurfaceCompositor`: main + child surfaces, local cursor from `cursor.shape`, letterboxing, zoom/pan reuse | render tests with synthetic CVPixelBuffers |
| I5 | Window coordinate space: view → window points (doubles), clamping, drag capture, outside-window policy | unit tests |
| I6 | Input via intents → `LinkInputEncoder`; text input routed through `UITextInput` so iPad input methods compose locally | E2E: mock helper logs expected events |
| I7 | Error and status UI: macLocked → "Open desktop to unlock", permission missing, secure input, version mismatch, revoked | localized; UI tests |

### M6 — Multi-window experience (L)
| ID | Task | Acceptance |
|---|---|---|
| W1 | Launcher scene (SwiftUI): running/recent/all, search, icons cache on disk (`Caches/`, privacy manifest reason added) | UI tests vs mock |
| W2 | Scene activation via `UISceneSessionActivationRequest` + `NSUserActivity` (`targetContentIdentifier` = window ref), map `windowRef → UISceneSession` to avoid duplicates | opening the same window twice focuses the existing scene |
| W3 | Geometry: `didUpdateEffectiveGeometry` → debounce until not interactively resizing → `window.setFrame`; `sizeRestrictions` from Mac min/max | E2E with mock helper |
| W4 | Restoration: `stateRestorationActivity`, re-bind by (bundle id, title, index), placeholder when gone | relaunch test |
| W5 | Menus: `UIMainMenuSystem` build configuration with a deferred focus-based element; per-scene provider returns the remote app's tree; rebuild on change; key equivalents as `UIKeyCommand`s with priority; Cmd-W policy setting | UI tests |
| W6 | Window actions, new-window policy, tabs-in-one-scene mode, external display | manual test script |
| W7 | iPhone: single scene, window switcher sheet | UI tests |

### M7 — Media and data completeness (M)
| ID | Task | Acceptance |
|---|---|---|
| D1 | Audio playback: `AVAudioEngine` + source node, lock-free ring, adaptive jitter buffer 20–40 ms, drift correction, mute-on-background | glitch counter in diagnostics |
| D2 | Clipboard v2 on the link, sharing rules with `ClipboardBridge` (sensitive types local only) | unit + E2E |
| D3 | File drop in (`UIDropInteraction` → chunks → helper inbox → open with app), share out | E2E with mock |
| D4 | Pencil hover, tablet proximity; gestures per capability flag | device test script |
| D5 | Quality settings per computer (bitrate cap, fps cap, Main10) | — |

### M8 — Hardening and release (L)
| ID | Task | Acceptance |
|---|---|---|
| R1 | `security-review` pass over pairing, transport, decoders, clipboard, files, helper capability surface; findings fixed | review notes in PR |
| R2 | Soak: 8 h session with 4 windows, network drops every 10 min, Mac sleep/wake, app quit/relaunch | no crash, no leak > 50 MB, all windows restored |
| R3 | Performance validation against §8 on the reference hardware | numbers in `docs/app-status.md` |
| R4 | Accessibility of Screon's own UI (VoiceOver labels, Dynamic Type in launcher and helper) | audit checklist |
| R5 | Docs: README (both languages), `SECURITY.md` scope, `docs/app-status.md`, helper install guide, privacy statement | reviewed |
| R6 | Rollout per §12 | — |

---

## 5. Protocol additions (beyond the design's v1 table)

- Framing: `u16 type | u32 length | payload`; types `0x8000–0xFFFF` are **ignorable** (skip by length), others are
  mandatory (unknown → close with `unsupportedMessage`). Max control message 1 MiB; max video access unit 8 MiB.
- `stats` (C→H, 250 ms): per window `{receivedBytes, decodedFrames, droppedFrames, decodeP95Micros}`, connection RTT.
- `video.ack` (C→H): LTR token acknowledgements; `video.lost` (C→H): missing frame sequence → helper refreshes from LTR
  or IDR.
- `status.secureInput(pid?)`, `status.permission(kind, state)`, `status.stage(state)`.
- `window.capabilities` (H→C): per-window flags (resizable, movable, closable, supportsTablet, menuAvailable).
- `session.approvalRequired` (H→C) when "ask on the Mac before each session" is on.
- All coordinates: `Float64` Mac points relative to the window's content origin.

---

## 6. Security

### 6.1 Threat model

| Asset / boundary | Threat | Control |
|---|---|---|
| Mac control channel | Unpaired device on the LAN connects | mTLS with pinned iPad SPKI; unknown certificates only reach the pairing state machine |
| Pairing | Attacker scans/guesses a pairing code | 128-bit QR secret, single use, 5 min expiry, 3 attempts; SAS mode needs on-screen confirmation on both devices; **every new pairing needs local LocalAuthentication approval on the Mac** |
| Pairing | MITM during pairing | QR pins the Mac SPKI; HMAC over `exporter ‖ macSPKI ‖ iPadSPKI ‖ deviceName`; SAS uses commit-then-reveal |
| Discovery | Rogue Bonjour advertiser | TXT data untrusted; trust only from pinned SPKI; UI shows the paired name |
| Downgrade | Force TCP fallback or older protocol | fallback carries the same mTLS; protocol range inside the authenticated `hello`; no unauthenticated mode exists |
| Stolen iPad | Uses an existing pairing | revoke on the Mac (paired sessions connect without a prompt by design, §14.5); opt-in "ask before each session"; menu-bar indicator while connected; iPad identity key `ThisDeviceOnly` |
| Hostile iPad (paired) | Abuse helper capabilities | allow-listed messages only: no shell, no scripting, no arbitrary paths; file inbox only; bounded everything |
| Hostile helper / spoofed Mac | Crash the iPad via malformed data | bounded decoders, fuzz, `VTDecompression` errors handled, image decode of icons via ImageIO with size caps |
| Privacy | Window titles, clipboard, files leak to logs | `.private` logging; diagnostics export redacted; no titles in crash reports |
| Lockout | Password attempts lock the Mac account | no password over the network at all |
| Update channel | Malicious helper update | manifest signed with an Ed25519 key pinned in the helper; download over HTTPS; notarization check |

### 6.2 Pairing protocol (normative)

1. Helper generates `secret = 16 random bytes`, `nonce = 16`, shows QR:
   `screon-pair:v1;h=<host hints>;p=<port>;k=<base64url SHA-256(macSPKI)>;s=<base64url secret>;n=<nonce>;e=<unix expiry>`.
2. iPad connects with ALPN `screon-link/1`, presents its certificate, validates the Mac certificate by SPKI hash `k`.
3. iPad sends `pair.prove{deviceName, ipadSPKIHash, mac = HMAC-SHA256(HKDF-SHA256(secret, salt=nonce, info="screon pair v1"), transcript)}`
   with `transcript = TLS exporter("EXPORTER-screon-pair", 32) ‖ k ‖ ipadSPKIHash ‖ deviceName`
   (if S7 shows no exporter on QUIC: `transcript = k ‖ ipadSPKIHash ‖ deviceName ‖ nonce ‖ helperChallenge`, where
   `helperChallenge` is a fresh value the helper sent on the control stream — still bound to both pinned keys).
4. Helper verifies in constant time, burns the secret, asks the user locally (LocalAuthentication, showing device name).
5. On approval: store `{ipadSPKIHash, name, pairedAt}`; reply `pair.ok{macName, helperId}`; iPad stores `{macSPKIHash}`
   in `SavedConnection.helper`, identity keys stay in the Keychain.
6. SAS mode (only while a pairing window opened by the Mac user is active; at most 3 sessions per 10 minutes per remote
   address and 6 in total): both send `commit = SHA-256(ephemeralPub)`, then reveal;
   `code = HKDF(X25519(shared), macSPKI ‖ ipadSPKI ‖ sorted keys) mod 10^6`. The code is DISPLAYED on both devices and compared
   by the people; confirming is a local act on each device and **nothing on the wire is derived from the digits** (a peer
   that saw a digit-keyed proof could brute-force 10^6 codes offline). The iPad user's "match" travels as an empty
   `sas.confirm`; the Mac user's approval (with the code shown, LocalAuthentication) is local; the helper answers `pair.ok` or
   `pair.denied`. The session is bound by the pinned TLS identities inside the code's transcript.

### 6.3 Rules carried from the repo
- Bounds before allocation everywhere; `LinkError.malformed` never traps; new decoders get malicious tests.
- Secrets only in the Keychain; never in JSON, logs, URLs or test fixtures (test identities are generated per run).
- `gitleaks` on every commit; no captures, real titles, hostnames or screenshots of real screens in the repo.

---

## 7. macOS permissions and onboarding

| Permission | Needed for | macOS 15 | macOS 26 | macOS 27 |
|---|---|---|---|---|
| Accessibility | AX tracking, menus, event posting | once | once | once (MDM pushes now notify) |
| Screen Recording | SCK capture | monthly re-approval for non-picker capture | same (assumed) | possibly replaced by **Remote Desktop** category |
| Remote Desktop (27) | SCK for remote-control apps | — | — | separate grant, no query API |
| Local Network | Bonjour + replying over UDP | yes | yes | yes |
| Login item | auto start | user approval | same | same |

- Detection without prompting: AX via `AXIsProcessTrusted`, event posting via `CGPreflightPostEventAccess`, capture by
  starting a 1×1 stream and classifying the error (S1 defines the exact mapping).
- Grants survive updates only with identical Developer ID signing and bundle id: never ship ad-hoc builds to users.
- Request `com.apple.developer.persistent-content-capture` at M0, in parallel with development (decision 2, §14); if
  granted, ship with an embedded Developer ID provisioning profile. Nothing depends on it.

---

## 8. Performance budget and measurement

| Stage | Budget (p95, 1080p window, LAN) |
|---|---|
| Capture (SCK callback after composite) | 8 ms |
| Encode | 8 ms |
| Network (Wi-Fi 6, same AP) | 10 ms |
| Decode | 8 ms |
| Present (next vsync at 120 Hz / 60 Hz) | 8 / 16 ms |
| **Glass-to-glass** | **≤ 50 ms median, ≤ 80 ms p95** |
| Input → Mac event posted | ≤ 10 ms p95 |
| Mac CPU per active window | ≤ 10 % of a performance core |
| iPad energy | ≤ the RFB mode at the same resolution (MetricKit comparison) |

Measurement: signposts at each stage with a shared frame id carried in `video.frame`; a debug overlay; a
glass-to-glass rig (photo-diode or high-speed camera on a flashing test window from the mock and real helper).

---

## 9. Reliability (failure modes)

| Failure | Detection | Behaviour |
|---|---|---|
| Wi-Fi drop / iPad backgrounded | viability update, `.failed` | resume token reconnect, snapshot, IDR per visible window |
| Window closed on the Mac | `window.destroyed` | scene shows "Window closed" with Reopen / Close |
| App crashed | workspace terminate | same as above, plus relaunch option |
| Capture stream died | `didStopWithError` | restart with backoff (3×), then `status` error on that window |
| Decoder invalid session | VT error | recreate, `stream.keyframe` |
| Mac locked / screensaver | capture `.blank`/`.suspended`, session notifications | `status(macLocked)`, offer RFB desktop scene |
| Permission revoked | stream start error | `status(permission)`, onboarding deep link on the Mac |
| Helper crashed | connection closed; launchd relaunch | windows restored on next launch from the persisted frames |
| Secure input active | `IsSecureEventInputEnabled` | banner "Typing is blocked by a password field on the Mac" |
| Stage unavailable | probe failure | resize-in-place mode, setting greyed out |

---

## 10. Repository and process changes

- `Package.swift`: add `LinkProtocol`, `LinkTransport`, `WindowKit`, `HelperCore` (+ tests) and `mock-link-helper`;
  no new `unsafeFlags`.
- `CLAUDE.md`: layout, dependency direction (`App` → `WindowKit` → `LinkTransport` → `LinkProtocol`; `Helper` →
  `HelperCore` → `LinkTransport`), commands for the helper and the mock.
- `.claude/rules/security.md`: add `Sources/Link*`, `Sources/HelperCore`, `Helper/` to its paths; pairing/pinning rules.
- `.claude/rules/testing-and-privacy.md`: helper tests never require permissions; E2E only against `mock-link-helper`.
- Skills: `verify` builds the helper (`xcodebuild -project Helper/ScreonHelper.xcodeproj … CODE_SIGNING_ALLOWED=NO`)
  and greps `Helper/` for Vietnamese; `security-review` gains a link/pairing checklist; `release` gains the helper
  notarization branch (only when asked).
- `LocalizationTests`: add the new packages that contain `tr()`.
- CI: pin Xcode via `xcode-select` to the SDK used locally; jobs `packages`, `ios-app`, `helper-macos`,
  `mock-e2e` (simulator), `secrets-scan`; notarization in a separate manual workflow with secrets.
- `CODEOWNERS`: add the Link and Helper paths with the security paths.
- `App/project.yml`: `NSBonjourServices += _screon-link._udp`, `NSUserActivityTypes`, privacy manifest reason for the
  icon cache.
- Docs: `docs/app-status.md` sections prefixed "App Mode M<n>" to avoid clashing with the existing phase names.

---

## 11. Observability

- `Logger` subsystems `app.screon.link`, `.video`, `.input`, `.helper.*`; values `.private` by default, enums and
  counters `.public`.
- `OSSignposter` intervals per frame (capture, encode, send, receive, decode, present) and per input event.
- In-app diagnostics: live overlay (fps, bitrate, RTT, decode p95, drops per window).
- Export: `OSLogStore` (current process) + counters → redacted JSON → share sheet; the helper has the same in its menu.
  Never committed to the repo.
- MetricKit behind `#available` (legacy manager and the newer Swift API).

---

## 12. Rollout

1. **Internal**: feature flag `appModeEnabled` (DEBUG default on, Release default off); helper builds signed with the
   maintainer's Developer ID.
2. **Beta**: TestFlight with the flag exposed in Settings → "App Mode (beta)"; helper `.dmg` from GitHub Releases;
   in-app feedback mail with diagnostics export.
3. **GA**: flag on by default when the M8 exit criteria hold for two consecutive beta builds.
- Kill switch: the helper refuses protocol versions marked bad in the signed manifest; the iPad hides App Mode when the
  helper reports an incompatible range.
- Versioning: iPad and helper semver; protocol major bumps are rare and negotiated; one major of overlap supported.

---

## 13. Definition of done (production)

- All M1–M8 acceptance criteria met; spike results (M0) recorded below.
- `swift build && swift test` green; iOS app, helper and mock build in CI; simulator E2E green; fuzz suites green.
- `security-review` completed with no open high findings; `gitleaks` clean.
- Performance budget (§8) met on the reference hardware; 8 h soak passed.
- Every user-visible string in English with a Vietnamese entry; VoiceOver labels on all controls.
- README (both languages), `SECURITY.md`, `docs/app-status.md`, `CHANGELOG.md` updated.
- Helper notarized; install on a clean macOS 15, 26 and 27 user passes the onboarding script.

### Spike results
_To be filled during M0. Partial, from the `LinkTransport` loopback tests (macOS 27, Xcode 27 SDK, no iPad involved):_

- **S7 (partial, macOS only).** A hand-built DER certificate plus its P-256 key becomes a `SecIdentity` and does mutual TLS 1.3
  over QUIC (`NWConnectionGroup`) and over TCP+TLS, with SPKI pin validators in `sec_protocol_options_set_verify_block`.
  The TLS exporter (`sec_protocol_metadata_create_secret`, label `EXPORTER-screon-pair`, 32 bytes) is available on **both**
  transports and equal on both ends, so the `helperChallenge` transcript is only a fallback. Still open: the same on **iOS**
  (identity from the Keychain, `KeychainIdentityStore`), which unit tests on macOS cannot show.
- **S6 (partial, macOS only).** Classic API behaviour found on loopback, all handled in `QUICWire`:
  a group never leaves `setup` unless `newConnectionHandler`/`setReceiveHandler` is set; a stream is invisible to the peer
  until its first byte, so every stream starts with a preamble; the server receives one extra silent `NWConnection` per QUIC
  connection and **cancelling it kills the QUIC connection** (observed as `failed(EINVAL)` exactly at the timeout), so slow
  or silent streams are never cancelled; after the peer closes, cancelling the streams before the group lets the other side
  notice within milliseconds (`group.cancel()` alone is not noticed). Unidirectional streams (`direction = .unidirectional`)
  and helper-opened streams work. Still open: Wi-Fi throughput/HOL over 30 min, Local Network prompt timing on iOS, iOS client
  against a macOS listener.

---

## 14. Maintainer decisions (2026-10-16)

1. **App Mode requires iPadOS/iOS 26.** RFB mode keeps iOS 18.
2. **Persistent-content-capture entitlement is requested in parallel; development does not wait for it.** The helper
   ships without it (users re-approve capture when macOS asks); if granted, it is added with an embedded Developer ID
   provisioning profile and S2 measures the effect.
3. **Private APIs are accepted in the helper**: `CGVirtualDisplay` (stage) and the AX→window-id call, each behind a
   runtime probe with a fallback.
4. **Helper distribution: `.dmg` on GitHub Releases** (Developer ID, notarized, stapled) plus an Ed25519-signed update
   manifest checked by the helper.
5. **Approval only at first pairing.** The Mac user approves each new device once (LocalAuthentication); later sessions
   from a paired device connect without asking. "Ask on the Mac before each session" exists as an opt-in setting, off by
   default; revocation is always available from the helper menu.
