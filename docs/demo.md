# Demo

## Scenario

A community safety emergency unfolds in real time. First, one person presses SOS — they can't speak, but their elevated vitals and the AI triage tell the dispatcher everything. Then a second report comes in from the same location, corroborating the first. Every Visual911 user nearby gets an alert. The dispatcher sees it all on one screen.

Target duration: 3 minutes. Never go longer than 10 minutes (Gemini API budget).

---

## Roles

| Person | Role | Device |
|---|---|---|
| Teammate A | Caller (SOS) | iPhone (physical device, app installed) |
| Teammate B | Dispatcher | Laptop browser (visual911.mooo.com) |
| Teammate C | Presents / narrates + runs sim_caller.py | Laptop terminal |

---

## Pre-Demo Setup (15 minutes before)

### Environment
- [ ] Room has ≥60 lux lighting on Teammate A's face (overhead lights on, face visible)
- [ ] Teammate A's phone propped 1–2ft from face, front camera pointing at face
- [ ] Both devices on the same WiFi (preferred) or Teammate A on LTE
- [ ] **Third phone (Device C) also on same WiFi, app open in idle state** — this is the "community member" device
- [ ] Laptop browser has visual911.mooo.com open and dispatcher dashboard loaded
- [ ] Dashboard connected (green dot in header)
- [ ] Terminal open with: `cd server && python sim_caller.py --host visual911.mooo.com --ssl --lat <venue_lat> --lng <venue_lng> --duration 60`  — **DO NOT RUN YET**, just have it ready

### Devices
- [ ] iPhone charged, screen timeout disabled (Settings → Display → Never)
- [ ] Visual911 app installed and launched — verify idle screen shows, no crashes
- [ ] Device C (community member phone) app open on idle screen — verify no crash
- [ ] Presage API key confirmed working (check last test run logs)
- [ ] coturn running on Vultr: `systemctl status coturn`
- [ ] Server running on Vultr: `systemctl status visual911`
- [ ] Server logs open in terminal: `journalctl -u visual911 -f`

### Demo location setup
Set `Config.demoLocationOverride` in `ios/Config.swift` to the venue's coordinates so the map pin lands somewhere recognizable. Example:
```swift
static let demoLocationOverride: CLLocationCoordinate2D? =
    CLLocationCoordinate2D(latitude: 35.9132, longitude: -79.0558)
```
Also pass the same coordinates to `sim_caller.py` so both calls cluster into one incident.

### Vitals boost (optional but impactful)
Have Teammate A do 30 seconds of jumping jacks right before the demo. Natural HR elevation (90–130 bpm) reads more dramatically than resting HR (~65 bpm).

---

## Demo Script

### Opening (Teammate C narrates)

> "Visual911 is a community-aware emergency response platform. When someone presses SOS, they don't just call a dispatcher — they alert everyone nearby. Let me show you how it works."

---

### Step 1: Community member is already subscribed (0:00)

Point to Device C (the idle iPhone).

> "This phone represents anyone in the community running Visual911. Right now it's idle — but it's connected to our alert network in the background. If something happens nearby, it'll know."

Dashboard community metrics bar shows: **Active Incidents: 0 · Total Reports: 0 · Users Alerted: 0**

---

### Step 2: Press SOS (0:10)

Teammate A taps the SOS button.

> "Our caller can't speak — but they press SOS. The app immediately starts a 15-second contactless vitals scan using the Presage SmartSpectra SDK. Heart rate and breathing rate, just from the front camera. No wearable required."

---

### Step 3: Community alert fires (0:12)

**Device C banner appears**: "1 incident nearby · 1 report"

Dashboard metrics update (flash animation): **Active Incidents: 1 · Total Reports: 1 · Users Alerted: 1**
Map pin appears on the Leaflet map with a badge showing "1".

> "The moment SOS is pressed, every Visual911 user nearby gets an alert. Our platform has broadcast this incident to the community — in real time, before a dispatcher has even answered."

---

### Step 4: Second report clusters in (0:20)

Teammate C runs the prepared `sim_caller.py` command.

> "Now watch what happens when a second person nearby reports the same incident."

**Device C banner updates**: "1 incident nearby · 2 reports"
Dashboard map badge updates from "1" → "2". Metrics: **Total Reports: 2 · Users Alerted: 1**

> "The system automatically cross-references submissions by GPS location. Two reports, same incident. The dispatcher can see this corroboration instantly — higher confidence, higher priority."

---

### Step 5: Dispatcher answers (0:30)

Dashboard shows the incoming call banner. Teammate B clicks ANSWER.

> "The dispatcher answers. WebRTC establishes a direct peer-to-peer connection."

Live video appears in the video panel.

---

### Step 6: Vitals appear (0:35)

The vitals panel shows HR (elevated) and breathing rate.

> "The vitals from the pre-call scan appear immediately. Heart rate elevated at [X] bpm. Breathing rapid at [X] per minute. Confidence bars show how reliable the reading is."

---

### Step 7: AI triage activates (0:45–1:30)

Gemini has been receiving audio since the call connected. Triage panel starts populating.

> "In the background, Gemini analyzes every audio segment — not just words, but tone, distress markers, even silence. Watch the triage panel."

Have Teammate A make noise — cough, gasp, or stay silent. Panel should show:
- Caller emotional state: distressed / panicked
- Can speak: No
- Recommended response: Medical
- Severity: 3–4

> "Gemini builds a cumulative picture across analysis rounds. Each update refines the previous one."

---

### Step 8: Severity escalation (1:30–2:00)

Severity dots turn red. At severity ≥ 4, dashboard border flashes red.

> "As severity rises, the dispatcher gets a visual alert. They can dispatch the right resources — medical, fire, police — before they've said a word."

---

### Step 9: Location map (2:00)

Point to the map showing both the caller pin and the incident badge.

> "GPS coordinates pinned on the map. The incident badge shows 2 corroborating reports. Responding units get this the moment they're dispatched."

---

### Step 10: End call (2:30)

Teammate B clicks END CALL. When both calls end, the incident closes.

Dashboard metrics reset. Device C banner disappears.

> "When the incident resolves, the alert clears. The community knows it's over."

---

### Closing (Teammate C)

> "Visual911 uses Presage for contactless vitals — no wearable. Gemini for AI triage — understanding not just words but the absence of them. WebRTC for low-latency video. And a community broadcast layer so emergencies aren't invisible. This is how 911 should work in 2025."

Total time: ~3 minutes.

---

## Credit Budget

### Presage
300 credits total. 1 credit = 30s of measurement.

| Activity | Credits Used |
|---|---|
| Each full demo run | ~6 (15s scan + buffer) |
| Each integration test | ~4 |
| Each unit test of Presage alone | ~2 |
| Buffer for failures/retries | 50 |

Estimated capacity: ~40 demo/test sessions. Confirm balance at physiology.presagetech.com before the hackathon.

### Gemini
250 requests per day on free tier. Each batch `generateContent` = 1 request. 10-second intervals → ~18 requests per 3-minute demo.

| Activity | Requests |
|---|---|
| Each demo run (3 min) | ~18 |
| Daily testing budget | ~50 |

---

## What to Do If Things Break

**Community alert not appearing on Device C:**
- Verify Device C is on the same WiFi as the server
- Check server logs for `Alert subscriber connected` — if missing, the `/ws/alerts` WebSocket didn't connect
- Restart the app on Device C — AlertsClient reconnects with 3s backoff
- Fallback: narrate the feature without Device C, point to dashboard metrics bar

**sim_caller.py not clustering with real call:**
- Check that `--lat` and `--lng` match `Config.demoLocationOverride` to within 50m
- Indoor GPS jitter can scatter coordinates. If not clustering, increase `CLUSTER_RADIUS_M` in `server.py` to `200` and redeploy

**Presage not reading:**
- Check lighting (≥60 lux). Turn on overhead lights, move near a window.
- Restart the app and try again.

**WebRTC video not appearing:**
- Check coturn: `systemctl status coturn`
- Verify TURN credentials: `curl https://visual911.mooo.com/api/turn-credentials`
- Try same WiFi for both devices

**Gemini not producing output:**
- Check server logs for 429 (rate limit) — wait 1 minute
- First triage update appears ~10s after dispatcher joins — be patient

**Dashboard WebSocket not connecting:**
- Refresh the browser
- Check server: `systemctl status visual911`

**Demo time and something is broken:**
- Fallback: screencast of a working run if you pre-recorded one
- Know your story cold: Presage rPPG + Gemini affective audio + WebRTC P2P + community broadcast + Vultr infrastructure

---

## Judging Talking Points

**Why community alerting matters:**
- Current 911 systems are purely reactive and private — the community has no visibility
- Corroborating reports increase dispatcher confidence and incident priority
- Real-time broadcast turns every phone into a community safety sensor

**Why the 1:1 call matters:**
- 911 callers who can't speak are common: cardiac arrest, domestic violence, throat injury
- Contactless vitals give dispatchers medical data before any responder arrives
- AI triage reduces cognitive load on dispatchers handling multiple simultaneous calls

**Technical depth to highlight:**
- Presage clinical accuracy (<1.62% RMSD for HR vs hospital equipment)
- Haversine-based GPS clustering — calls within 50m group into one incident
- Gemini batch analysis with cumulative context — each round builds on previous
- The camera conflict problem: why we time-slice Presage and WebRTC instead of running concurrently
- AlertsClient reconnect loop — community alert delivery survives transient network drops
- Dynamic TURN credentials with HMAC-SHA1 matching coturn's auth mechanism

**Track alignment:**
- Broadcasting alerts ✓ — `/ws/alerts` broadcast to all idle subscribers
- Cross-check submissions ✓ — GPS clustering groups corroborating reports per incident
- # users alerted per situation ✓ — `alerted_count` tracked per incident, shown on dashboard
- # alerts raised per event ✓ — `report_count` per incident, shown as badge on map pin
