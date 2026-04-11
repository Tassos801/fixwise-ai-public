from __future__ import annotations

import math
import time
from collections import defaultdict, deque
from dataclasses import dataclass
from threading import Lock

from fastapi import HTTPException, Request, WebSocket, status


@dataclass(frozen=True)
class RateLimitPolicy:
    max_requests: int
    window_seconds: int


class InMemoryRateLimiter:
    """Simple sliding-window limiter for low-volume API protection."""

    def __init__(self) -> None:
        self._events: dict[str, deque[float]] = defaultdict(deque)
        self._lock = Lock()

    def hit(self, key: str, policy: RateLimitPolicy) -> int | None:
        now = time.monotonic()
        window_start = now - policy.window_seconds

        with self._lock:
            events = self._events[key]
            while events and events[0] <= window_start:
                events.popleft()

            if len(events) >= policy.max_requests:
                retry_after = max(1, math.ceil(policy.window_seconds - (now - events[0])))
                return retry_after

            events.append(now)
            return None


def client_identifier_from_request(request: Request) -> str:
    forwarded_for = request.headers.get("x-forwarded-for")
    if forwarded_for:
        return forwarded_for.split(",")[0].strip()

    if request.client and request.client.host:
        return request.client.host

    return "unknown"


def client_identifier_from_websocket(websocket: WebSocket) -> str:
    forwarded_for = websocket.headers.get("x-forwarded-for")
    if forwarded_for:
        return forwarded_for.split(",")[0].strip()

    if websocket.client and websocket.client.host:
        return websocket.client.host

    return "unknown"


def raise_for_rate_limit(retry_after: int, scope: str) -> None:
    raise HTTPException(
        status_code=status.HTTP_429_TOO_MANY_REQUESTS,
        detail=f"Rate limit exceeded for {scope}. Retry in {retry_after} seconds.",
        headers={"Retry-After": str(retry_after)},
    )
