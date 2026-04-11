from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from threading import RLock
from typing import Any


@dataclass
class SessionRecord:
    session_id: str
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    latest_frame: str | None = None
    latest_frame_metadata: dict[str, Any] = field(default_factory=dict)
    step_count: int = 0


class SessionManager:
    """Tracks active WebSocket sessions and their latest frame state."""

    def __init__(self) -> None:
        self._sessions: dict[str, SessionRecord] = {}
        self._lock = RLock()

    def get_or_create(self, session_id: str) -> SessionRecord:
        with self._lock:
            record = self._sessions.get(session_id)
            if record is None:
                record = SessionRecord(session_id=session_id)
                self._sessions[session_id] = record
            return record

    def store_frame(self, session_id: str, frame_b64: str, metadata: dict[str, Any] | None = None) -> SessionRecord:
        with self._lock:
            record = self.get_or_create(session_id)
            record.latest_frame = frame_b64
            record.latest_frame_metadata = metadata or {}
            return record

    def next_step(self, session_id: str) -> int:
        with self._lock:
            record = self.get_or_create(session_id)
            record.step_count += 1
            return record.step_count

    def get(self, session_id: str) -> SessionRecord | None:
        with self._lock:
            return self._sessions.get(session_id)

    def end(self, session_id: str) -> SessionRecord | None:
        with self._lock:
            return self._sessions.pop(session_id, None)

    @property
    def session_count(self) -> int:
        with self._lock:
            return len(self._sessions)
