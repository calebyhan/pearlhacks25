import asyncio
import base64
import io
import json
import logging
import os
import struct
import time
import uuid
import wave
from typing import Optional

from dotenv import load_dotenv
load_dotenv()

import aiohttp
from aiohttp import web
from google import genai
from google.genai import types

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ─── State ────────────────────────────────────────────────────────────────────

active_calls: dict[str, dict] = {}
# Structure per call_id:
# {
#   "caller_ws": WebSocketResponse,
#   "dispatcher_ws": Optional[WebSocketResponse],
#   "dashboard_ws": Optional[WebSocketResponse],
#   "gemini_task": Optional[asyncio.Task],
#   "location": {"lat": float, "lng": float},
#   "started_at": float,
# }

dispatcher_connections: set[web.WebSocketResponse] = set()

# ─── Gemini ───────────────────────────────────────────────────────────────────

GEMINI_MODEL = "gemini-2.5-flash"

SYSTEM_PROMPT = """You are an AI emergency triage assistant analyzing a 911 call audio clip.
Output ONLY a JSON object — no preamble, no markdown, no extra text:
{
  "situation_summary": "one sentence description",
  "detected_keywords": ["list", "of", "keywords"],
  "caller_emotional_state": "calm|distressed|panicked|unresponsive",
  "recommended_response_type": "medical|police|fire|unknown",
  "severity": 1,
  "can_speak": true
}
Severity: 1=minor, 2=moderate, 3=urgent, 4=serious, 5=life-threatening.
Keep output under 100 tokens. Speed over verbosity."""

ANALYSIS_INTERVAL = 10  # seconds between Gemini calls
AUDIO_SAMPLE_RATE = 16000
AUDIO_BYTES_PER_SAMPLE = 2  # 16-bit PCM


def pcm_to_wav(pcm_bytes: bytes, sample_rate: int = 16000, channels: int = 1, sample_width: int = 2) -> bytes:
    """Wrap raw PCM bytes in a WAV container so Gemini generateContent can process it."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(channels)
        wf.setsampwidth(sample_width)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm_bytes)
    return buf.getvalue()


async def gemini_session_task(call_id: str, audio_queue: asyncio.Queue, dashboard_ws_getter):
    """
    Periodically drains the audio queue, sends buffered PCM (as WAV) + latest
    video frame to Gemini generateContent, and forwards triage JSON to the dashboard.
    """
    client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])
    logger.info(f"[{call_id}] Gemini analysis task started")

    audio_buffer = bytearray()
    latest_frame: str | None = None  # base64 JPEG
    previous_summary: str = ""  # cumulative context across analysis rounds
    analysis_count = 0

    try:
        while True:
            # Collect audio for ANALYSIS_INTERVAL seconds
            deadline = asyncio.get_event_loop().time() + ANALYSIS_INTERVAL
            while asyncio.get_event_loop().time() < deadline:
                timeout = deadline - asyncio.get_event_loop().time()
                try:
                    item = await asyncio.wait_for(audio_queue.get(), timeout=timeout)
                except asyncio.TimeoutError:
                    break
                if item is None:  # Sentinel — call ended
                    return
                if item["type"] == "audio":
                    audio_buffer.extend(item["data"])
                elif item["type"] == "frame":
                    latest_frame = item["data"]  # keep most recent frame

            if not audio_buffer:
                continue

            chunk = bytes(audio_buffer)
            audio_buffer.clear()
            analysis_count += 1

            duration_s = len(chunk) // (AUDIO_BYTES_PER_SAMPLE * AUDIO_SAMPLE_RATE)
            logger.info(f"[{call_id}] Sending {duration_s}s audio to Gemini (round {analysis_count})")

            # Convert raw PCM to WAV — generateContent does NOT support audio/pcm
            wav_bytes = pcm_to_wav(chunk)

            try:
                # Build content parts
                parts: list[types.Part] = [
                    types.Part(
                        inline_data=types.Blob(
                            data=wav_bytes,
                            mime_type="audio/wav"
                        )
                    ),
                ]

                # Include latest video frame if available
                if latest_frame:
                    try:
                        frame_bytes = base64.b64decode(latest_frame)
                        parts.append(types.Part(
                            inline_data=types.Blob(
                                data=frame_bytes,
                                mime_type="image/jpeg"
                            )
                        ))
                    except Exception:
                        pass  # skip bad frame data

                # Build prompt with cumulative context
                prompt = "Analyze this 911 call audio clip and output triage JSON."
                if previous_summary:
                    prompt = (
                        f"Previous analysis: {previous_summary}\n\n"
                        f"New audio segment (update #{analysis_count}). "
                        f"Update your triage based on this new audio. Output triage JSON."
                    )
                if latest_frame:
                    prompt += " A camera frame from the caller is also attached."

                parts.append(types.Part(text=prompt))

                response = await client.aio.models.generate_content(
                    model=GEMINI_MODEL,
                    contents=parts,
                    config=types.GenerateContentConfig(
                        system_instruction=SYSTEM_PROMPT,
                        temperature=0.1,
                    )
                )
                text = response.text.strip() if response.text else ""
                logger.info(f"[{call_id}] Gemini response: {text[:200]}")

                # Extract JSON from response
                start = text.find("{")
                end = text.rfind("}") + 1
                if start >= 0 and end > start:
                    report = json.loads(text[start:end])
                    # Save summary for next round
                    previous_summary = report.get("situation_summary", previous_summary)
                    dashboard_ws = dashboard_ws_getter(call_id)
                    if dashboard_ws and not dashboard_ws.closed:
                        await dashboard_ws.send_json({
                            "type": "triage_update",
                            "call_id": call_id,
                            "report": report
                        })
                else:
                    logger.warning(f"[{call_id}] Gemini returned no JSON: {text[:200]}")

            except asyncio.CancelledError:
                raise
            except Exception as e:
                logger.error(f"[{call_id}] Gemini analysis error: {e}")
                # Notify dashboard so it doesn't stay on "Waiting" forever
                dashboard_ws = dashboard_ws_getter(call_id)
                if dashboard_ws and not dashboard_ws.closed:
                    await dashboard_ws.send_json({
                        "type": "triage_update",
                        "call_id": call_id,
                        "report": {
                            "situation_summary": f"AI analysis error — retrying... ({e.__class__.__name__})",
                            "severity": 0,
                            "caller_emotional_state": "unknown",
                            "recommended_response_type": "unknown",
                            "can_speak": True,
                            "detected_keywords": []
                        }
                    })

    except asyncio.CancelledError:
        logger.info(f"[{call_id}] Gemini task cancelled")


# ─── WebSocket Handlers ────────────────────────────────────────────────────────

async def handle_signal(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse()
    await ws.prepare(request)

    call_id = request.query.get("call_id")
    role = request.query.get("role", "caller")

    if not call_id:
        await ws.close()
        return ws

    logger.info(f"[{call_id}] Signal connected: {role}")

    async for msg in ws:
        if msg.type != aiohttp.WSMsgType.TEXT:
            continue

        try:
            data = json.loads(msg.data)
        except json.JSONDecodeError:
            continue

        msg_type = data.get("type")

        if msg_type == "call_initiated":
            # Guard against duplicate call_id
            if call_id in active_calls:
                logger.warning(f"[{call_id}] Duplicate call_initiated, ignoring")
                continue

            audio_queue: asyncio.Queue = asyncio.Queue(maxsize=500)
            active_calls[call_id] = {
                "caller_ws": ws,
                "dispatcher_ws": None,
                "dashboard_ws": None,
                "audio_queue": audio_queue,
                "gemini_task": None,
                "location": data.get("location", {}),
                "started_at": time.time(),
                "last_vitals": None,
            }

            # Replay any vitals that arrived before call was registered
            buffered = pending_vitals.pop(call_id, None)
            if buffered:
                logger.info(f"[{call_id}] Replaying buffered vitals")
                active_calls[call_id]["last_vitals"] = buffered

            # Notify all connected dispatchers
            for dash_ws in dispatcher_connections.copy():
                if not dash_ws.closed:
                    await dash_ws.send_json({
                        "type": "incoming_call",
                        "call_id": call_id,
                        "location": data.get("location", {})
                    })

        elif msg_type == "call_ended":
            await cleanup_call(call_id)

        else:
            # WebRTC SDP/ICE — forward to the other party
            call = active_calls.get(call_id)
            if not call:
                continue
            if role == "caller":
                target = call.get("dashboard_ws")
            else:
                target = call.get("caller_ws")
            if target and not target.closed:
                await target.send_str(msg.data)

    # WebSocket closed — treat as call end if this was the caller
    if role == "caller" and call_id in active_calls:
        await cleanup_call(call_id)

    return ws


async def handle_audio(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse()
    await ws.prepare(request)

    call_id = request.query.get("call_id")

    async for msg in ws:
        call = active_calls.get(call_id)
        if not call:
            continue

        queue = call.get("audio_queue")
        if not queue:
            continue

        if msg.type == aiohttp.WSMsgType.BINARY:
            await queue.put({"type": "audio", "data": msg.data})

        elif msg.type == aiohttp.WSMsgType.TEXT:
            try:
                data = json.loads(msg.data)
                if data.get("type") == "frame":
                    await queue.put({"type": "frame", "data": data["data"]})
            except json.JSONDecodeError:
                pass

    return ws


# Buffer vitals that arrive before call_initiated registers the call
pending_vitals: dict[str, dict] = {}


async def handle_vitals(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse()
    await ws.prepare(request)

    call_id = request.query.get("call_id")

    async for msg in ws:
        if msg.type != aiohttp.WSMsgType.TEXT:
            continue

        try:
            vitals = json.loads(msg.data)
        except json.JSONDecodeError:
            continue

        call = active_calls.get(call_id)
        if not call:
            # Call not registered yet — buffer so it can be replayed later
            logger.info(f"[{call_id}] Vitals arrived before call registered, buffering")
            pending_vitals[call_id] = vitals
            continue

        logger.info(f"[{call_id}] Vitals received: HR={vitals.get('hr')} BR={vitals.get('breathing')}")
        call["last_vitals"] = vitals

        # Forward to dashboard if already connected
        dashboard_ws = call.get("dashboard_ws")
        if dashboard_ws and not dashboard_ws.closed:
            await dashboard_ws.send_json({
                "type": "vitals",
                "call_id": call_id,
                **vitals
            })

    return ws


async def handle_dashboard(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse()
    await ws.prepare(request)

    dispatcher_connections.add(ws)
    logger.info("Dashboard connected")

    async for msg in ws:
        if msg.type != aiohttp.WSMsgType.TEXT:
            continue
        try:
            data = json.loads(msg.data)
        except json.JSONDecodeError:
            continue

        call_id = data.get("call_id")
        msg_type = data.get("type")

        if msg_type == "dispatcher_joined":
            call = active_calls.get(call_id)
            if call:
                call["dashboard_ws"] = ws

                # Start Gemini session now — not at call_initiated — to avoid
                # burning RPD quota while waiting for a dispatcher to answer.
                if call["gemini_task"] is None:
                    task = asyncio.create_task(
                        gemini_session_task(
                            call_id,
                            call["audio_queue"],
                            lambda cid: active_calls.get(cid, {}).get("dashboard_ws")
                        )
                    )
                    call["gemini_task"] = task

                # Replay cached vitals so dispatcher sees them immediately on answer
                last_vitals = call.get("last_vitals")
                if last_vitals:
                    await ws.send_json({"type": "vitals", "call_id": call_id, **last_vitals})

                caller_ws = call.get("caller_ws")
                if caller_ws and not caller_ws.closed:
                    await caller_ws.send_json({"type": "dispatcher_ready", "call_id": call_id})

        elif msg_type == "call_ended":
            await cleanup_call(call_id)

        else:
            # WebRTC SDP/ICE from dispatcher → forward to caller
            call = active_calls.get(call_id)
            if call:
                caller_ws = call.get("caller_ws")
                if caller_ws and not caller_ws.closed:
                    await caller_ws.send_str(msg.data)

    dispatcher_connections.discard(ws)
    logger.info("Dashboard disconnected")
    return ws


# ─── Cleanup ──────────────────────────────────────────────────────────────────

async def cleanup_call(call_id: str, reason: str = "ended"):
    call = active_calls.pop(call_id, None)
    if not call:
        return

    logger.info(f"[{call_id}] Cleaning up: {reason}")

    # Stop Gemini
    task = call.get("gemini_task")
    if task and not task.done():
        queue = call.get("audio_queue")
        if queue:
            await queue.put(None)  # Sentinel
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass

    # Notify dashboard
    dashboard_ws = call.get("dashboard_ws")
    if dashboard_ws and not dashboard_ws.closed:
        await dashboard_ws.send_json({"type": "call_ended", "call_id": call_id, "reason": reason})

    # Notify caller
    caller_ws = call.get("caller_ws")
    if caller_ws and not caller_ws.closed:
        await caller_ws.send_json({"type": "call_ended", "call_id": call_id, "reason": reason})


# ─── App Setup ────────────────────────────────────────────────────────────────

async def handle_index(request: web.Request) -> web.FileResponse:
    return web.FileResponse("./static/index.html")


def create_app() -> web.Application:
    app = web.Application()
    app.router.add_get("/ws/signal", handle_signal)
    app.router.add_get("/ws/audio", handle_audio)
    app.router.add_get("/ws/vitals", handle_vitals)
    app.router.add_get("/ws/dashboard", handle_dashboard)
    app.router.add_get("/", handle_index)
    app.router.add_static("/static", path="./static", name="static")
    return app


if __name__ == "__main__":
    import ssl as _ssl
    port = int(os.environ.get("PORT", 8080))
    ssl_cert = os.environ.get("SSL_CERT")
    ssl_key = os.environ.get("SSL_KEY")

    ssl_context = None
    if ssl_cert and ssl_key:
        ssl_context = _ssl.create_default_context(_ssl.Purpose.CLIENT_AUTH)
        ssl_context.load_cert_chain(ssl_cert, ssl_key)
        logger.info(f"Starting with TLS on port {port}")
    else:
        logger.info(f"Starting without TLS on port {port} (local dev)")

    web.run_app(create_app(), port=port, ssl_context=ssl_context)
