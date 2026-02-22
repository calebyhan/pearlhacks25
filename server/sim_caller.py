#!/usr/bin/env python3
"""Simulate a caller for demo purposes. Sends call_initiated with a location
near the real device so incident clustering triggers report_count > 1.

Also subscribes to /ws/alerts before initiating the call so alerted_count
shows ≥1 on the dispatcher dashboard during demos.

Usage:
    python sim_caller.py                         # default: localhost, Chapel Hill coords
    python sim_caller.py --host visual911.mooo.com --lat 35.9132 --lng -79.0558
    python sim_caller.py --ssl                   # use wss://
"""

import argparse
import asyncio
import json
import uuid

import aiohttp


async def alerts_subscriber(host: str, port: int, ssl: bool, stop_event: asyncio.Event):
    """Hold open a /ws/alerts connection so alerted_count increments on broadcast."""
    scheme = "wss" if ssl else "ws"
    url = f"{scheme}://{host}:{port}/ws/alerts"
    ssl_ctx = None if not ssl else True
    try:
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(url, ssl=ssl_ctx) as ws:
                print(f"Subscribed to alerts at {url}")
                await stop_event.wait()
    except Exception as e:
        print(f"Alerts subscriber error: {e}")


async def run(host: str, port: int, lat: float, lng: float, duration: int, ssl: bool):
    scheme = "wss" if ssl else "ws"
    call_id = str(uuid.uuid4())
    url = f"{scheme}://{host}:{port}/ws/signal?call_id={call_id}&role=caller"
    ssl_ctx = None if not ssl else True

    print(f"Connecting to {url}")
    print(f"Call ID: {call_id}")
    print(f"Location: ({lat}, {lng})")

    stop_alerts = asyncio.Event()
    alerts_task = asyncio.create_task(alerts_subscriber(host, port, ssl, stop_alerts))

    # Give the alerts subscription a moment to establish before initiating the call
    await asyncio.sleep(0.5)

    async with aiohttp.ClientSession() as session:
        async with session.ws_connect(url, ssl=ssl_ctx) as ws:
            # Initiate call
            await ws.send_json({
                "type": "call_initiated",
                "call_id": call_id,
                "location": {"lat": lat, "lng": lng},
            })
            print(f"call_initiated sent — waiting {duration}s before ending")

            # Listen for messages while waiting
            try:
                async with asyncio.timeout(duration):
                    async for msg in ws:
                        if msg.type == aiohttp.WSMsgType.TEXT:
                            data = json.loads(msg.data)
                            print(f"  <- {data.get('type', 'unknown')}: {msg.data[:120]}")
            except TimeoutError:
                pass

            # End call
            await ws.send_json({"type": "call_ended", "call_id": call_id})
            print("call_ended sent")

    stop_alerts.set()
    await alerts_task


def main():
    parser = argparse.ArgumentParser(description="Simulate a Visual911 caller")
    parser.add_argument("--host", default="localhost", help="Server hostname")
    parser.add_argument("--port", type=int, default=8080, help="Server port")
    parser.add_argument("--lat", type=float, default=35.9132, help="Latitude")
    parser.add_argument("--lng", type=float, default=-79.0558, help="Longitude")
    parser.add_argument("--duration", type=int, default=30, help="Seconds before ending call")
    parser.add_argument("--ssl", action="store_true", help="Use wss:// instead of ws://")
    args = parser.parse_args()

    asyncio.run(run(args.host, args.port, args.lat, args.lng, args.duration, args.ssl))


if __name__ == "__main__":
    main()
