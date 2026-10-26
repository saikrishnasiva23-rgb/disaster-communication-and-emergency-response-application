"""In-process sliding-window rate limiter for sensitive endpoints.

Per-process by design (no Redis, per the project's no-extra-infrastructure
rule): with several server replicas each enforces its own window, so the
effective limit is `limit x replicas`. A shared store would be the upgrade
path if that ever matters."""

from __future__ import annotations

import threading
import time
from collections import deque


class SlidingWindowRateLimiter:
    def __init__(self, max_events: int, window_seconds: float) -> None:
        self.max_events = max_events
        self.window_seconds = window_seconds
        self._events: dict[str, deque[float]] = {}
        self._lock = threading.Lock()

    def hit(self, key: str) -> float | None:
        """Records one event for `key`. Returns None if allowed, otherwise the
        number of seconds until the next event would be allowed."""
        now = time.monotonic()
        cutoff = now - self.window_seconds
        with self._lock:
            events = self._events.setdefault(key, deque())
            while events and events[0] <= cutoff:
                events.popleft()
            if len(events) >= self.max_events:
                return max(0.0, events[0] + self.window_seconds - now)
            events.append(now)
            if len(self._events) > 50_000:
                self._prune(cutoff)
            return None

    def reset(self, key: str) -> None:
        with self._lock:
            self._events.pop(key, None)

    def _prune(self, cutoff: float) -> None:
        for key in [k for k, v in self._events.items() if not v or v[-1] <= cutoff]:
            del self._events[key]
