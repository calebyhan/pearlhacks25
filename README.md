# Visual911

A hackathon project for Pearl Hacks. Visual911 is a FaceTime-style emergency call system that gives dispatchers live video, real-time contactless biometrics, and AI-generated triage — so callers who cannot speak can still communicate.

---

## What It Does

A caller taps SOS on their iPhone. The app:
1. Runs a rapid **15-second vitals scan** using the Presage SmartSpectra SDK (contactless heart rate and breathing via front camera)
2. Connects a **live WebRTC video call** to the dispatcher's browser
3. Streams audio to **Gemini Live API** for real-time AI triage analysis
4. Sends GPS coordinates and vitals to the **dispatcher dashboard**

The dispatcher sees: live video, biometric readings, an AI-generated situation summary, severity score, and a location pin — all updating in real time.

---

## Sponsor Tracks

| Track | How We Hit It |
|---|---|
| Triad STEM Emergency Support | Core use case — contactless vitals during 911 calls |
| Presage | SmartSpectra SDK for HR, breathing rate, HRV, stress |
| Gemini API | Live audio analysis, affective dialogue, function calling |
| Vultr | Cloud VPS for signaling server, Gemini relay, TURN server |

---

## Stack

| Layer | Technology |
|---|---|
| iOS App | Swift, Presage SmartSpectra SDK, stasel/WebRTC, AVAudioEngine, CLLocationManager |
| Backend | Python asyncio, aiohttp, google-genai |
| Infrastructure | Vultr Ubuntu VPS, coturn TURN server, Let's Encrypt SSL |
| Dispatcher UI | HTML/JS, WebRTC browser API, Chart.js, Leaflet.js |
| AI | Gemini 2.5 Flash Native Audio (Live API) |

---

## Repo Structure

```
/
├── ios/                    # Swift iOS app (Xcode project)
├── server/
│   └── server.py           # Single Python asyncio backend
├── dashboard/
│   └── index.html          # Dispatcher browser UI
└── deploy/
    └── turnserver.conf     # coturn config template
```

---

## Quickstart

### Prerequisites
- Xcode 15+, physical iOS device (iOS 15+)
- Python 3.11+
- Vultr VPS (Ubuntu 24.04)
- API keys: Presage, Gemini (Google AI Studio)

### Local Development

```bash
# Backend
pip install aiohttp google-genai
python3 server/server.py

# iOS — open in Xcode, set API keys in Config.swift, run on device
```

### Production Deployment

See [deployment.md](deployment.md) for full Vultr + coturn + SSL setup.

---

## Docs

- [architecture.md](architecture.md) — system overview and data flow
- [ios.md](ios.md) — Swift app implementation guide
- [server.md](server.md) — Python backend, WebSocket endpoints, Gemini integration
- [dashboard.md](dashboard.md) — dispatcher UI implementation
- [deployment.md](deployment.md) — Vultr VPS setup, coturn, SSL
- [demo.md](demo.md) — demo script, credit budget, environment checklist

---

## Credit Budget (Presage)

300 total credits across 3 team members. 1 credit = 30s of continuous measurement.

- Each demo call: ~6 credits (15s scan + 15s buffer per call)
- Estimated capacity: ~40–50 demo/test calls
- **Never run Presage in idle.** Start on SOS press, stop when call ends.
