"""WebSocket hub. Engine events are published synchronously; a sender task flushes them
at most every 100 ms. High-rate kinds (tick, state, account, floating) are coalesced to
the latest value, so the UI gets ~10 updates/s no matter how fast the engine polls."""

import asyncio
import logging
from typing import Any

from fastapi import WebSocket

log = logging.getLogger(__name__)

COALESCE = {"tick", "state", "account", "floating"}
FLUSH_S = 0.1


class Hub:
    def __init__(self) -> None:
        self.clients: set[WebSocket] = set()
        self._latest: dict[str, dict[str, Any]] = {}
        self._dirty: set[str] = set()
        self._queue: list[dict[str, Any]] = []

    def publish(self, kind: str, payload: dict[str, Any]) -> None:
        if kind in COALESCE:
            self._latest[kind] = payload
            self._dirty.add(kind)
        else:
            self._queue.append({"type": kind, "data": payload})
            del self._queue[:-500]

    def latest(self, kind: str) -> dict[str, Any] | None:
        return self._latest.get(kind)

    async def add(self, ws: WebSocket) -> None:
        self.clients.add(ws)
        for kind, data in self._latest.items():
            await ws.send_json({"type": kind, "data": data})

    def remove(self, ws: WebSocket) -> None:
        self.clients.discard(ws)

    async def run(self, stop: asyncio.Event) -> None:
        while not stop.is_set():
            msgs = self._queue
            self._queue = []
            msgs += [{"type": k, "data": self._latest[k]} for k in self._dirty]
            self._dirty = set()
            if msgs and self.clients:
                for ws in list(self.clients):
                    try:
                        for m in msgs:
                            await ws.send_json(m)
                    except Exception as e:
                        log.info("ws client dropped: %s", e)
                        self.clients.discard(ws)
            try:
                await asyncio.wait_for(stop.wait(), timeout=FLUSH_S)
            except TimeoutError:
                pass
