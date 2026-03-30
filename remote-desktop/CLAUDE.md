# ShowDropGo Remote Desktop — Developer Context

Custom browser-based remote desktop for the ShowDropGo Mac Mini (M1, macOS 15).
Streams the display over WebSocket to any browser via Cloudflare tunnel.

## Stack

- **Go server** (`server/`) — HTTP + WebSocket server, spawns Swift binary as subprocess, polls clipboard
- **Swift binary** (`capture/`) — ScreenCaptureKit display capture → VideoToolbox H.264 encode → stdout; reads input events from stdin
- **Browser client** (`client/index.html`) — WebCodecs VideoDecoder, canvas rendering, pointer/keyboard events
- **Cloudflare tunnel** — exposes `localhost:8080` at `https://desktop.showdropgo.io` with Cloudflare Access OTP auth

## How to start (MUST be from GUI terminal, not SSH)

```bash
# Terminal 1 — video server
~/remote-desktop/server/sdg-rdp-server \
  -addr 0.0.0.0:8080 \
  -capture ~/remote-desktop/capture/.build/arm64-apple-macosx/release/CaptureHelper \
  -client ~/remote-desktop/client

# Terminal 2 — Cloudflare tunnel
cloudflared tunnel run desktop
```

## Build

```bash
cd ~/remote-desktop && make
```

After rebuilding Swift binary, re-sign it:
```bash
codesign --force --deep --sign - ~/remote-desktop/capture/.build/arm64-apple-macosx/release/CaptureHelper
```

## Why GUI terminal only

ScreenCaptureKit requires the process to run in a WindowServer/GUI session.
SSH sessions are detached from the display server — capture fails with TCC error -3801.
Must launch from Terminal.app opened on the Mac Mini desktop (e.g. via Chrome Remote Desktop).

## Permissions (already granted, one-time)

- **Screen Recording**: Terminal.app — system TCC DB, auth_value=2
- **Accessibility**: Terminal.app — system TCC DB, auth_value=2
- CaptureHelper must be ad-hoc signed after every rebuild (see above)

## IPC protocol (Go ↔ Swift)

- Go reads stdout from Swift: `[4 bytes BE length][1 byte flags: 0x01=keyframe][H.264 Annex B bytes]`
- Go writes to Swift stdin: JSON lines — `{"type":"mouse","x":100,"y":200,"buttons":1,"dx":0,"dy":0}`
- Input types: `mouse`, `key`, `clipboard`

## WebSocket protocol (server ↔ browser)

- Binary frames: `[1 byte flags][H.264 NAL unit]` — flags: 0x01 = keyframe
- Text frames: JSON — `{"type":"clipboard","text":"..."}` / `{"type":"ping"}`

## What works

- Screen capture and H.264 streaming (ScreenCaptureKit + VideoToolbox hardware encoder)
- WebCodecs H.264 decode in browser, canvas rendering, correct scaling to fill viewport
- Mouse tracking, clicks, right-click, scroll wheel
- Clipboard server → browser (pbpaste polling every 500ms)
- Cloudflare HTTPS tunnel with Access OTP auth

## Outstanding issue: window dragging

Mouse tracks correctly but `leftMouseDragged` events don't move windows.

**What's been tried:**
- Added `leftMouseDragged` event type (was using `mouseMoved` before)
- Changed to `CGEventSource(stateID: .hidSystemState)` instead of nil source
- Added `prevPos` tracking to avoid firing drag at same position as mouseDown
- Switched browser from mouse events to pointer events with `setPointerCapture`

**Debug logging is active** — the Swift binary prints every CGEventPost call to stderr,
which flows through to the Go server's terminal output. To diagnose:
1. Start the server (GUI terminal)
2. Open `https://desktop.showdropgo.io` in browser
3. Try dragging a window title bar
4. Observe what event sequence appears in the terminal

**Hypothesis:** CGEvent clickState may need to be set on the mouseDown event,
or the drag event needs delta values set explicitly.

## Bitrate / fps

Currently: 1.5 Mbps, 15fps — tuned for low Cloudflare tunnel usage (~375 MB/hr).
To change: edit `Encoder.swift` (bitrateBps) and `Capture.swift` (minimumFrameInterval).

## Cloudflare tunnel

- Tunnel ID: `451f72c6-7506-42b0-9953-94ae234f03ff`
- Credentials: `~/.cloudflared/451f72c6-7506-42b0-9953-94ae234f03ff.json`
- Config: `~/.cloudflared/config.yml`
- DNS: `desktop.showdropgo.io` → Cloudflare → tunnel → `localhost:8080`
- Access policy: email OTP (set in Cloudflare Zero Trust dashboard)
