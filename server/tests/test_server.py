import asyncio
import json
import os
import sys
import time

import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from aiohttp import web, WSMsgType

# Import from server
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from server import create_app, active_calls, dispatcher_connections, cleanup_call


async def _noop_gemini_session_task(call_id, audio_queue, dashboard_ws_getter):
    """No-op replacement for gemini_session_task in tests."""
    pass


# ─── Test 1: App Creation ─────────────────────────────────────────────────────

async def test_create_app_returns_valid_app():
    """create_app() returns an aiohttp app with all expected routes."""
    app = create_app()
    assert isinstance(app, web.Application)

    route_paths = {r.resource.canonical for r in app.router.routes() if hasattr(r, "resource") and r.resource}
    assert "/ws/signal" in route_paths
    assert "/ws/audio" in route_paths
    assert "/ws/vitals" in route_paths
    assert "/ws/dashboard" in route_paths


# ─── Test 2: Signal - call_initiated ──────────────────────────────────────────

async def test_signal_call_initiated(aiohttp_client):
    """Sending call_initiated creates an entry in active_calls with correct structure."""
    app = create_app()
    client = await aiohttp_client(app)

    call_id = "test-call-001"
    location = {"lat": 35.9, "lng": -79.0}

    ws = await client.ws_connect(f"/ws/signal?call_id={call_id}&role=caller")
    await ws.send_json({
        "type": "call_initiated",
        "call_id": call_id,
        "location": location,
    })

    # Give the server a moment to process
    await asyncio.sleep(0.05)

    assert call_id in active_calls
    call = active_calls[call_id]
    assert call["location"] == location
    assert call["dispatcher_ws"] is None
    assert call["dashboard_ws"] is None
    assert call["gemini_task"] is None
    assert call["audio_queue"] is not None
    assert isinstance(call["started_at"], float)
    assert call["caller_ws"] is not None

    await ws.close()


# ─── Test 3: Signal - missing call_id ─────────────────────────────────────────

async def test_signal_missing_call_id_closes(aiohttp_client):
    """Connecting to /ws/signal without call_id closes the WebSocket."""
    app = create_app()
    client = await aiohttp_client(app)

    ws = await client.ws_connect("/ws/signal")

    # Server should close the connection
    msg = await ws.receive()
    assert msg.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.CLOSED)


# ─── Test 4: Signal - duplicate call_id ───────────────────────────────────────

async def test_signal_duplicate_call_id(aiohttp_client):
    """Sending call_initiated twice with same call_id only creates one entry."""
    app = create_app()
    client = await aiohttp_client(app)

    call_id = "test-call-dup"

    ws = await client.ws_connect(f"/ws/signal?call_id={call_id}&role=caller")

    await ws.send_json({"type": "call_initiated", "call_id": call_id, "location": {"lat": 0, "lng": 0}})
    await asyncio.sleep(0.05)
    assert call_id in active_calls
    original_started_at = active_calls[call_id]["started_at"]

    # Send duplicate
    await ws.send_json({"type": "call_initiated", "call_id": call_id, "location": {"lat": 1, "lng": 1}})
    await asyncio.sleep(0.05)

    # Should still be the original entry (location unchanged)
    assert active_calls[call_id]["started_at"] == original_started_at
    assert active_calls[call_id]["location"] == {"lat": 0, "lng": 0}

    await ws.close()


# ─── Test 5: Dashboard connect/disconnect ─────────────────────────────────────

async def test_dashboard_connect_disconnect(aiohttp_client):
    """Connecting to /ws/dashboard adds to dispatcher_connections; disconnecting removes."""
    app = create_app()
    client = await aiohttp_client(app)

    assert len(dispatcher_connections) == 0

    ws = await client.ws_connect("/ws/dashboard")
    await asyncio.sleep(0.05)
    assert len(dispatcher_connections) == 1

    await ws.close()
    await asyncio.sleep(0.05)
    assert len(dispatcher_connections) == 0


# ─── Test 6: Dashboard - incoming_call notification ───────────────────────────

async def test_dashboard_receives_incoming_call(aiohttp_client):
    """When a call is initiated, all connected dashboard clients receive incoming_call."""
    app = create_app()
    client = await aiohttp_client(app)

    # Connect dashboard first
    dash_ws = await client.ws_connect("/ws/dashboard")
    await asyncio.sleep(0.05)

    call_id = "test-call-notify"
    location = {"lat": 35.9, "lng": -79.0}

    # Connect caller and initiate call
    caller_ws = await client.ws_connect(f"/ws/signal?call_id={call_id}&role=caller")
    await caller_ws.send_json({
        "type": "call_initiated",
        "call_id": call_id,
        "location": location,
    })

    # Dashboard should receive incoming_call
    msg = await dash_ws.receive_json()
    assert msg["type"] == "incoming_call"
    assert msg["call_id"] == call_id
    assert msg["location"] == location

    await caller_ws.close()
    await dash_ws.close()


# ─── Test 7: Dashboard - dispatcher_joined ────────────────────────────────────

@patch("server.gemini_session_task", new=_noop_gemini_session_task)
async def test_dispatcher_joined(aiohttp_client):
    """dispatcher_joined sets dashboard_ws and sends dispatcher_ready to caller."""
    app = create_app()
    client = await aiohttp_client(app)

    call_id = "test-call-join"

    # Connect dashboard FIRST so it receives incoming_call
    dash_ws = await client.ws_connect("/ws/dashboard")
    await asyncio.sleep(0.05)

    # Connect caller and initiate
    caller_ws = await client.ws_connect(f"/ws/signal?call_id={call_id}&role=caller")
    await caller_ws.send_json({
        "type": "call_initiated",
        "call_id": call_id,
        "location": {"lat": 0, "lng": 0},
    })

    # Read the incoming_call notification
    incoming = await dash_ws.receive_json()
    assert incoming["type"] == "incoming_call"

    await dash_ws.send_json({"type": "dispatcher_joined", "call_id": call_id})
    await asyncio.sleep(0.05)

    # Caller should receive dispatcher_ready
    ready_msg = await caller_ws.receive_json()
    assert ready_msg["type"] == "dispatcher_ready"
    assert ready_msg["call_id"] == call_id

    # dashboard_ws should be set on the call
    assert active_calls[call_id]["dashboard_ws"] is not None

    await caller_ws.close()
    await dash_ws.close()


# ─── Test 8: Vitals forwarding ────────────────────────────────────────────────

@patch("server.gemini_session_task", new=_noop_gemini_session_task)
async def test_vitals_forwarding(aiohttp_client):
    """Vitals sent to /ws/vitals are forwarded to the dashboard_ws."""
    app = create_app()
    client = await aiohttp_client(app)

    call_id = "test-call-vitals"

    # Connect dashboard FIRST
    dash_ws = await client.ws_connect("/ws/dashboard")
    await asyncio.sleep(0.05)

    # Set up caller
    caller_ws = await client.ws_connect(f"/ws/signal?call_id={call_id}&role=caller")
    await caller_ws.send_json({
        "type": "call_initiated",
        "call_id": call_id,
        "location": {"lat": 0, "lng": 0},
    })
    _ = await dash_ws.receive_json()  # incoming_call

    await dash_ws.send_json({"type": "dispatcher_joined", "call_id": call_id})
    await asyncio.sleep(0.05)
    _ = await caller_ws.receive_json()  # dispatcher_ready

    # Send vitals
    vitals_ws = await client.ws_connect(f"/ws/vitals?call_id={call_id}")
    vitals_data = {
        "type": "vitals",
        "call_id": call_id,
        "hr": 118,
        "hrConfidence": 0.91,
        "breathing": 22,
        "breathingConfidence": 0.85,
        "timestamp": 1234567890,
    }
    await vitals_ws.send_json(vitals_data)
    await asyncio.sleep(0.05)

    # Dashboard should receive vitals
    msg = await dash_ws.receive_json()
    assert msg["type"] == "vitals"
    assert msg["call_id"] == call_id
    assert msg["hr"] == 118
    assert msg["breathing"] == 22

    await vitals_ws.close()
    await caller_ws.close()
    await dash_ws.close()


# ─── Test 9: Audio WebSocket - binary PCM ─────────────────────────────────────

async def test_audio_binary_pcm(aiohttp_client):
    """Binary data sent to /ws/audio is enqueued in audio_queue."""
    app = create_app()
    client = await aiohttp_client(app)

    call_id = "test-call-audio"

    # Set up call
    caller_ws = await client.ws_connect(f"/ws/signal?call_id={call_id}&role=caller")
    await caller_ws.send_json({
        "type": "call_initiated",
        "call_id": call_id,
        "location": {"lat": 0, "lng": 0},
    })
    await asyncio.sleep(0.05)

    # Send binary audio
    audio_ws = await client.ws_connect(f"/ws/audio?call_id={call_id}")
    pcm_data = b"\x00\x01\x02\x03" * 100
    await audio_ws.send_bytes(pcm_data)
    await asyncio.sleep(0.05)

    # Check queue
    queue = active_calls[call_id]["audio_queue"]
    assert not queue.empty()
    item = await queue.get()
    assert item["type"] == "audio"
    assert item["data"] == pcm_data

    await audio_ws.close()
    await caller_ws.close()


# ─── Test 10: Audio WebSocket - frame JSON ────────────────────────────────────

async def test_audio_frame_json(aiohttp_client):
    """JSON frame messages sent to /ws/audio are enqueued in audio_queue."""
    app = create_app()
    client = await aiohttp_client(app)

    call_id = "test-call-frame"

    # Set up call
    caller_ws = await client.ws_connect(f"/ws/signal?call_id={call_id}&role=caller")
    await caller_ws.send_json({
        "type": "call_initiated",
        "call_id": call_id,
        "location": {"lat": 0, "lng": 0},
    })
    await asyncio.sleep(0.05)

    # Send frame
    audio_ws = await client.ws_connect(f"/ws/audio?call_id={call_id}")
    frame_b64 = "iVBORw0KGgoAAAANSUhEUg=="  # Fake base64 JPEG
    await audio_ws.send_json({"type": "frame", "data": frame_b64})
    await asyncio.sleep(0.05)

    # Check queue
    queue = active_calls[call_id]["audio_queue"]
    assert not queue.empty()
    item = await queue.get()
    assert item["type"] == "frame"
    assert item["data"] == frame_b64

    await audio_ws.close()
    await caller_ws.close()


# ─── Test 11: Cleanup ─────────────────────────────────────────────────────────

async def test_cleanup_call(aiohttp_client):
    """cleanup_call removes from active_calls and notifies connected parties."""
    app = create_app()
    client = await aiohttp_client(app)

    call_id = "test-call-cleanup"

    # Connect dashboard FIRST
    dash_ws = await client.ws_connect("/ws/dashboard")
    await asyncio.sleep(0.05)

    # Set up a full call
    caller_ws = await client.ws_connect(f"/ws/signal?call_id={call_id}&role=caller")
    await caller_ws.send_json({
        "type": "call_initiated",
        "call_id": call_id,
        "location": {"lat": 0, "lng": 0},
    })
    _ = await dash_ws.receive_json()  # incoming_call
    assert call_id in active_calls

    # Join via dispatcher_joined flow with mocked gemini
    with patch("server.gemini_session_task", new=_noop_gemini_session_task):
        await dash_ws.send_json({"type": "dispatcher_joined", "call_id": call_id})
        await asyncio.sleep(0.05)
        _ = await caller_ws.receive_json()  # dispatcher_ready

    # Now cleanup
    await cleanup_call(call_id, reason="test_cleanup")

    assert call_id not in active_calls

    # Dashboard should receive call_ended
    ended_msg = await dash_ws.receive_json()
    assert ended_msg["type"] == "call_ended"
    assert ended_msg["call_id"] == call_id
    assert ended_msg["reason"] == "test_cleanup"

    # Caller should receive call_ended
    caller_ended = await caller_ws.receive_json()
    assert caller_ended["type"] == "call_ended"
    assert caller_ended["call_id"] == call_id

    await caller_ws.close()
    await dash_ws.close()


# ─── Test 12: End-to-end call lifecycle ───────────────────────────────────────

@patch("server.gemini_session_task", new=_noop_gemini_session_task)
async def test_end_to_end_lifecycle(aiohttp_client):
    """Full flow: call_initiated -> dispatcher_joined -> vitals -> call_ended."""
    app = create_app()
    client = await aiohttp_client(app)

    call_id = "test-call-e2e"
    location = {"lat": 35.9132, "lng": -79.0558}

    # 1. Dashboard connects first
    dash_ws = await client.ws_connect("/ws/dashboard")
    await asyncio.sleep(0.05)

    # 2. Caller initiates call
    caller_ws = await client.ws_connect(f"/ws/signal?call_id={call_id}&role=caller")
    await caller_ws.send_json({
        "type": "call_initiated",
        "call_id": call_id,
        "location": location,
    })

    # Dashboard receives incoming_call
    incoming = await dash_ws.receive_json()
    assert incoming["type"] == "incoming_call"
    assert incoming["call_id"] == call_id
    assert incoming["location"] == location

    # 3. Dispatcher joins
    await dash_ws.send_json({"type": "dispatcher_joined", "call_id": call_id})
    await asyncio.sleep(0.05)

    # Caller receives dispatcher_ready
    ready = await caller_ws.receive_json()
    assert ready["type"] == "dispatcher_ready"

    # 4. Vitals flow
    vitals_ws = await client.ws_connect(f"/ws/vitals?call_id={call_id}")
    await vitals_ws.send_json({
        "type": "vitals",
        "call_id": call_id,
        "hr": 95,
        "hrConfidence": 0.88,
        "breathing": 18,
        "breathingConfidence": 0.82,
        "timestamp": int(time.time()),
    })
    await asyncio.sleep(0.05)

    vitals_msg = await dash_ws.receive_json()
    assert vitals_msg["type"] == "vitals"
    assert vitals_msg["hr"] == 95

    # 5. Call ends (from dashboard)
    await dash_ws.send_json({"type": "call_ended", "call_id": call_id})
    await asyncio.sleep(0.05)

    assert call_id not in active_calls

    # Caller receives call_ended
    ended = await caller_ws.receive_json()
    assert ended["type"] == "call_ended"

    await vitals_ws.close()
    await caller_ws.close()
    await dash_ws.close()
