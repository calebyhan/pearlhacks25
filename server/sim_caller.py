#!/usr/bin/env python3
"""Simulate a caller for demo purposes. Sends call_initiated with a location
near the real device so incident clustering triggers report_count > 1.

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


async def run(host: str, port: int, lat: float, lng: float, duration: int, ssl: bool):
    scheme = "wss" if ssl else "ws"
    call_id = str(uuid.uuid4())
    url = f"{scheme}://{host}:{port}/ws/signal?call_id={call_id}&role=caller"

    print(f"Connecting to {url}")
    print(f"Call ID: {call_id}")
    print(f"Location: ({lat}, {lng})")

    async with aiohttp.ClientSession() as session:
        async with session.ws_connect(url, ssl=False if not ssl else None) as ws:
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
