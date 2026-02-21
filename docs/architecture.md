# Architecture

## System Overview

Visual911 has three main components: an iOS caller app, a Python backend on Vultr, and a browser-based dispatcher dashboard. The iOS app never communicates directly with the dispatcher dashboard except for the P2P WebRTC video/audio stream — all other data (vitals, AI triage, call events) routes through the Vultr server.

```
┌─────────────────────────────────────────────────────────────────┐
│                         iOS Caller App                           │
│                                                                   │
│  Presage SDK ──► vitals JSON ──────────────────────────────────► │
│  AVAudioEngine ──► PCM audio + JPEG frames ────────────────────► │
│  WebRTC ◄──────────────────────────────── signaling ───────────► │ Vultr Server
│  CLLocationManager ──► GPS coords ─────────────────────────────► │
│                                                                   │
│  WebRTC video/audio ◄──────────────────────────P2P──────────────►│ Dispatcher
└─────────────────────────────────────────────────────────────────┘    Browser
                              │
                    ┌─────────▼─────────┐
                    │   Vultr Server     │
                    │   (server.py)      │
                    │                   │
                    │  /ws/signal       │──► forwards SDP/ICE
                    │  /ws/audio   ─────┼──► Gemini Live API
                    │  /ws/vitals       │
                    │  /ws/dashboard ───┼──► Dispatcher Browser
                    └───────────────────┘
```

---

## Components

### iOS App (Swift)

The caller-facing application. Manages the full call lifecycle and coordinates three hardware resources:

**Presage SmartSpectra SDK** reads contactless vitals (heart rate, breathing rate, HRV) from the front camera using rPPG. Runs for 15 seconds when SOS is pressed to establish a baseline, then stops so the camera can be used for WebRTC. Results are shown as "last measured" on the dispatcher dashboard.

**RTCCameraVideoCapturer** (stasel/WebRTC) runs after Presage completes its scan. Captures front camera video and streams it P2P to the dispatcher's browser via WebRTC. Audio is included in the WebRTC stream for the dispatcher to hear ambient sounds.

**AVAudioEngine tap** runs in parallel with WebRTC audio using `mixWithOthers` session mode. Captures a separate 16kHz mono PCM stream and sends it over a secondary WebSocket to the server, which forwards it to Gemini. This parallel stream is what Gemini analyzes — the dispatcher still hears audio directly via WebRTC.

**CLLocationManager** provides a one-shot GPS coordinate sent with the `call_initiated` message and periodically refreshed during the call.

### Vultr Server (Python asyncio)

A single `server.py` process handles all backend logic. Uses `aiohttp` for WebSocket serving and asyncio tasks for concurrent call management.

Four WebSocket endpoints:
- `/ws/signal` — forwards WebRTC SDP offers, answers, and ICE candidates between caller and dispatcher
- `/ws/audio` — receives PCM audio and JPEG frames from iOS, forwards to Gemini Live API
- `/ws/vitals` — receives vitals JSON from iOS, forwards to the connected dispatcher dashboard
- `/ws/dashboard` — browser-facing endpoint; pushes incoming call notifications, triage updates, vitals, and critical flags

One asyncio task per active call manages the Gemini Live API session: consuming audio/frame input and emitting parsed triage JSON to `/ws/dashboard`.

A separate `coturn` process (port 3478/5349) provides STUN/TURN for WebRTC NAT traversal.

### Dispatcher Dashboard (Browser)

A single `index.html` served from `/static` on Vultr. Uses the browser WebRTC API for the P2P video connection and a WebSocket to `/ws/dashboard` for all other data.

Four panels:
- **Video** — `<video>` element fed by the WebRTC P2P stream
- **Vitals** — Chart.js rolling graph of HR and breathing rate, with confidence indicator
- **Gemini Triage** — live situation summary, severity level (1–5), emotional state, recommended response type, critical flag alerts
- **Location** — Leaflet.js map with GPS pin

---

## Data Flow

### Call Initiation

```
1. User presses SOS
2. Presage starts scanning (15s, camera exclusive)
3. After scan: Presage stops, results cached locally

4. iOS opens:
   - /ws/signal?call_id=<uuid>
   - /ws/audio?call_id=<uuid>
   - /ws/vitals?call_id=<uuid>

5. iOS sends: { type: "call_initiated", call_id, location }

6. Server:
   - Stores call state
   - Starts Gemini Live API session (asyncio task)
   - Notifies all connected dispatcher dashboards: { type: "incoming_call", call_id, location }

7. Dispatcher clicks Answer → sends { type: "dispatcher_joined", call_id }

8. Server records dispatcher WebSocket, sends { type: "dispatcher_ready" } to iOS

9. WebRTC handshake begins (iOS creates offer, signals through /ws/signal)

10. P2P video/audio connection established
```

### Active Call

```
Every ~2s (vitals):
iOS → /ws/vitals → server → /ws/dashboard → dispatcher vitals panel

Continuously (audio):
iOS AVAudioEngine → PCM chunks → /ws/audio → server → Gemini Live API

Every 2s (frames):
iOS → JPEG snapshot → /ws/audio (same connection) → server → Gemini realtime_input.video

Gemini output (on change):
Gemini → triage JSON → server parses → /ws/dashboard { type: "triage_update" }
Gemini tool call → { type: "critical_flag" } → /ws/dashboard (plays alert sound)

Video/audio (P2P, server not involved):
iOS RTCCameraVideoCapturer → WebRTC → dispatcher <video> element
```

### Call End

```
Either party sends { type: "call_ended", call_id }
Server:
  - Cancels Gemini asyncio task
  - Notifies other party
  - Removes call from active_calls dict
iOS:
  - Closes all 3 WebSockets
  - Stops RTCCameraVideoCapturer
  - Returns to IDLE state
```

---

## State Machine (iOS)

```
IDLE
  │ SOS pressed
  ▼
SCANNING  ← Presage running, camera exclusive, 15s
  │ scan complete
  ▼
INITIATING  ← open 3 WebSockets, Gemini session starts server-side
  │ dispatcher answers (dispatcher_ready received)
  ▼
CONNECTING  ← WebRTC offer/answer/ICE exchange via /ws/signal
  │ P2P established
  ▼
ACTIVE  ← video, audio, vitals, Gemini all live
  │ end call (either party) or connection drop
  ▼
CLEANUP  ← close WebSockets, stop capturer, notify server
  │
  ▼
IDLE
```

---

## Ports and Protocols

| Service | Port | Protocol |
|---|---|---|
| Vultr server (HTTP/WS) | 443 | WSS/HTTPS (TLS via Let's Encrypt) |
| coturn STUN | 3478 | UDP/TCP |
| coturn TURN (TLS) | 5349 | TLS |
| WebRTC P2P | ephemeral | SRTP/DTLS (UDP) |

---

## Key Design Decisions

**Why a single Python process instead of Node.js + Python?**
Fewer moving parts for a hackathon. aiohttp handles WebSockets fine. No IPC needed between services.

**Why audio-only Gemini session (not video+audio)?**
Free tier video+audio sessions cap at 2 minutes. Audio-only sessions last 15 minutes. We work around the lack of a persistent video stream by injecting JPEG frames every 2 seconds via `realtime_input.video` — Gemini processes video at 1 FPS anyway, so this is equivalent.

**Why time-slice Presage and WebRTC instead of running them concurrently?**
Both need exclusive access to `AVCaptureSession` on the front camera. Two sessions on the same camera cause a hard crash. The 15-second pre-call scan gives dispatchers biometric context the moment the call connects, which is actually a better UX story than trying to show live vitals mid-call.

**Why route vitals through the server instead of RTCDataChannel?**
DataChannel is P2P — the server never sees it. Routing through `/ws/vitals` lets the server inject vitals context into Gemini ("caller HR just spiked to 142 bpm") and keeps the dashboard on a single data pipeline (`/ws/dashboard`) instead of two separate channels.
