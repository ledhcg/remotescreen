# mock-link-helper

A fake Mac helper for App Mode end-to-end tests in the simulator. It speaks the real Screon link protocol (`LinkProtocol` +
`LinkTransport`: QUIC with a TCP+TLS fallback, mutual TLS, pairing), but everything it shows is synthetic: three demo apps,
four windows (one of them a transient menu surface), generated icons, and a moving colour-bar video per subscribed window.
It never reads the real screen, never posts input, and never touches the login keychain.

- Binds loopback only (`127.0.0.1`). `--bind` accepts only loopback values.
- Test use only: `--pairing auto` approves any device that pairs and prints a warning.
- Logs only synthetic content. Received files go to a temporary directory that is removed on exit.

## Usage

```bash
swift run mock-link-helper --self-test            # in-process iPad client; exits 0 on success, 1 on failure
swift run mock-link-helper --port 7361 --pairing auto --log /tmp/events.jsonl --qr-out /tmp/qr.txt
Tools/mock-link-helper/run_appmode_test.sh <simulator-UDID> [basic|churn|locked]
```

| Option | Meaning |
|---|---|
| `--port <n>` | QUIC (UDP) and TCP+TLS port, default 7361 (`0` picks a free one) |
| `--log <file.jsonl>` | event log: one JSON object per line with `type` and `t_ms` |
| `--scenario basic\|churn\|locked` | `basic`: 3 apps, 4 windows including one transient menu. `churn`: basic plus windows created, moved and destroyed every 1.5 s. `locked`: sends `status(macLocked: true)` on every session |
| `--pairing auto\|qr` | `auto`: approve any first pairing. `qr`: approve only a device that proved the QR secret |
| `--qr-out <file>` | write the pairing QR payload (`screon-pair:v1...`) here; also printed as `QR_PAYLOAD=...`. Refreshed every two minutes (a secret lives five minutes) |
| `--identity-dir <dir>` | keep the mock identity (`helper.key`, `helper.cer`) and paired devices as files; without it everything is in memory |
| `--inbox-dir <dir>` | where received files are written |
| `--no-quic` | TCP+TLS only |
| `--self-test` | see below |

SIGINT and SIGTERM shut down cleanly (sessions closed with "helper shutting down", log flushed).

## What it does

- Sends a `snapshot` after the handshake; answers `apps.list`, `apps.icon` (generated PNG: solid colour and a letter), `menu.get`
  (a small File/Edit/View tree), `ping`; handles `window.subscribe`/`unsubscribe`/`setFrame`/`command`.
- On `window.subscribe` it encodes a colour-bar pattern with VideoToolbox (HEVC, H.264 when HEVC is unavailable or the iPad does
  not offer it) at the requested size and frame rate, sends `video.config` and length-prefixed frames, and produces a key frame on
  `stream.keyframe`, `video.lost` and back pressure. A black crosshair with an orange square is drawn where the last pointer event
  landed, so a UI test can see that input took effect. Subscribing to the transient window delivers a `surface.snapshot` PNG.
- Clipboard: offers are requested, data is stored and echoed back as an offer, requests are answered with the stored data.
- Files: validated name, sequential chunks, SHA-256 check, written to the inbox directory only (64 MiB cap in the mock).

## Event log

`paired`, `session`, `approval`, `subscribe`, `unsubscribe`, `keyframe_request`, `pointer` (`window x y buttons modifiers`),
`scroll`, `gesture`, `key` (`keycode keysym down modifiers`), `text`, `command`, `set_frame`, `menu_get`, `menu_press`,
`apps_list`, `apps_icon`, `apps_launch/activate/quit`, `clipboard_offer/request/data`, `file_begin`, `file`, `file_rejected`,
`stats`, `churn`, `status`, `backpressure`, `session_closed`, `unexpected`.

## Self-test

`--self-test` starts the server on a free port and an in-process `LinkConnection` client against it. It pairs by QR, checks the
snapshot (3 apps, 4 windows, 1 transient), subscribes to a window and receives the video config and at least three frames
(first one a key frame, length-prefixed), requests another key frame, sends pointer and key input and checks the helper logged
them, then round-trips ping, icon, menu, clipboard and a file with a checksum.

## Simulator test

`run_appmode_test.sh` starts the helper, runs the `AppModeUITests` class (skips with a message while it does not exist), then
checks the log with `verify_appmode.py` (paired, subscribed, pointer and key events received, no stuck keys). The UI test reads
`SCREON_MOCK_HOST`, `SCREON_MOCK_PORT` and `SCREON_MOCK_QR` from its environment (xcodebuild forwards `TEST_RUNNER_*`).
