from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, UTC

from .models import FrameMetadata


@dataclass
class SessionFrame:
    base64_jpeg: str
    metadata: FrameMetadata
    captured_at: float


@dataclass
class SessionRecord:
    session_id: str
    user_id: str
    created_at: datetime = field(default_factory=lambda: datetime.now(UTC))
    step_count: int = 0
    latest_frame: SessionFrame | None = None


class SessionManager:
    def __init__(self) -> None:
        self.sessions: dict[str, SessionRecord] = {}

    def ensure_session(self, session_id: str, user_id: str = "demo_user") -> SessionRecord:
        session = self.sessions.get(session_id)
        if session is None:
            session = SessionRecord(session_id=session_id, user_id=user_id)
            self.sessions[session_id] = session
        return session

    def store_frame(
        self,
        session_id: str,
        frame_b64: str,
        metadata: FrameMetadata,
        captured_at: float,
        user_id: str = "demo_user",
    ) -> SessionFrame:
        session = self.ensure_session(session_id=session_id, user_id=user_id)
        session.latest_frame = SessionFrame(
            base64_jpeg=frame_b64,
            metadata=metadata,
            captured_at=captured_at,
        )
        return session.latest_frame

    def get_latest_frame(self, session_id: str) -> SessionFrame | None:
        session = self.sessions.get(session_id)
        if session is None:
            return None
        return session.latest_frame

    def next_step(self, session_id: str, user_id: str = "demo_user") -> int:
        session = self.ensure_session(session_id=session_id, user_id=user_id)
        session.step_count += 1
        return session.step_count

    def end_session(self, session_id: str) -> SessionRecord | None:
        return self.sessions.pop(session_id, None)
