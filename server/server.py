import asyncio
import base64
import json
import logging
import os
import time
import uuid
from typing import Optional

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

GEMINI_MODEL = "gemini-2.5-flash-native-audio-preview-12-2025"

SYSTEM_PROMPT = """You are an AI emergency triage assistant monitoring a 911 call.
Analyze audio for emergency indicators: keywords, emotional state, breathing patterns, background sounds.
When your assessment changes, output ONLY a JSON object — no preamble, no markdown:
{
  "situation_summary": "one sentence description",
  "detected_keywords": ["list", "of", "keywords"],
  "caller_emotional_state": "calm|distressed|panicked|unresponsive",
  "recommended_response_type": "medical|police|fire|unknown",
  "severity": 1,
  "can_speak": true
}
Severity: 1=minor, 2=moderate, 3=urgent, 4=serious, 5=life-threatening.
Keep output under 100 tokens. Speed over verbosity. Output only on meaningful changes."""

GEMINI_CONFIG = {
    "response_modalities": ["TEXT"],
    "system_instruction": SYSTEM_PROMPT,
    "tools": [
        types.Tool(function_declarations=[
            types.FunctionDeclaration(
                name="flag_critical",
                description="Immediately flag this call as life-threatening",
                parameters=types.Schema(
                    type=types.Type.OBJECT,
                    properties={
                        "reason": types.Schema(type=types.Type.STRING),
                        "severity": types.Schema(type=types.Type.INTEGER),
                    }
                ),
                behavior=types.Behavior.NON_BLOCKING,
            )
        ])
    ],
}


async def gemini_session_task(call_id: str, audio_queue: asyncio.Queue, dashboard_ws_getter):
    """
    Asyncio task that manages one Gemini Live API session per call.
    Consumes from audio_queue (PCM chunks and JPEG frames).
    Emits parsed triage JSON to the dashboard WebSocket.
    """
    client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])

    try:
        async with client.aio.live.connect(model=GEMINI_MODEL, config=GEMINI_CONFIG) as session:
            logger.info(f"[{call_id}] Gemini session opened")

            async def send_loop():
                """Pull from queue, forward to Gemini."""
                while True:
                    item = await audio_queue.get()
                    if item is None:  # Sentinel to stop
                        break
                    if item["type"] == "audio":
                        await session.send(input={
                            "realtime_input": {
                                "audio": {
                                    "data": base64.b64encode(item["data"]).decode(),
                                    "mime_type": "audio/pcm;rate=16000"
                                }
                            }
                        })
                    elif item["type"] == "frame":
                        await session.send(input={
                            "realtime_input": {
                                "video": {
                                    "data": item["data"],  # Already base64
                                    "mime_type": "image/jpeg"
                                }
                            }
                        })

            async def receive_loop():
                """Receive Gemini output, parse and forward to dashboard."""
                text_buffer = ""
                async for response in session.receive():
                    if response.text:
                        text_buffer += response.text
                        # Try to parse complete JSON
                        if "}" in text_buffer:
                            try:
                                report = json.loads(text_buffer.strip())
                                text_buffer = ""
                                dashboard_ws = dashboard_ws_getter(call_id)
                                if dashboard_ws and not dashboard_ws.closed:
                                    await dashboard_ws.send_json({
                                        "type": "triage_update",
                                        "call_id": call_id,
                                        "report": report
                                    })
                            except json.JSONDecodeError:
                                # Buffer overflow protection for malformed Gemini JSON
                                if len(text_buffer) > 2000:
                                    logger.warning(f"[{call_id}] Discarding malformed Gemini buffer")
                                    text_buffer = ""

                    # Handle tool calls
                    if response.tool_call:
                        for fc in response.tool_call.function_calls:
                            if fc.name == "flag_critical":
                                dashboard_ws = dashboard_ws_getter(call_id)
                                if dashboard_ws and not dashboard_ws.closed:
                                    await dashboard_ws.send_json({
                                        "type": "critical_flag",
                                        "call_id": call_id,
                                        "reason": fc.args.get("reason", ""),
                                        "severity": fc.args.get("severity", 5)
                                    })

            await asyncio.gather(send_loop(), receive_loop())

    except asyncio.CancelledError:
        logger.info(f"[{call_id}] Gemini session cancelled")
    except Exception as e:
        logger.error(f"[{call_id}] Gemini error: {e}")


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
            }

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


async def handle_vitals(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse()
    await ws.prepare(request)

    call_id = request.query.get("call_id")

    async for msg in ws:
        if msg.type != aiohttp.WSMsgType.TEXT:
            continue

        call = active_calls.get(call_id)
        if not call:
            continue

        try:
            vitals = json.loads(msg.data)
        except json.JSONDecodeError:
            continue

        # Forward to dashboard
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
