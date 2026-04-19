from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, UTC
from typing import Literal

from .guidance_modes import DEFAULT_GUIDANCE_MODE, normalize_guidance_mode
from .models import FrameMetadata, TaskState


@dataclass
class SessionFrame:
    base64_jpeg: str
    metadata: FrameMetadata
    captured_at: float


@dataclass
class SessionTurn:
    role: Literal["user", "assistant"]
    text: str
    created_at: float = field(default_factory=lambda: datetime.now(UTC).timestamp())
    next_action: str | None = None
    needs_closer_frame: bool = False
    follow_up_prompts: list[str] = field(default_factory=list)
    confidence: Literal["low", "medium", "high"] = "medium"


@dataclass
class SessionContext:
    session_id: str
    user_id: str
    latest_frame: SessionFrame | None
    selected_mode: str
    task_summary: str | None
    last_next_action: str | None
    task_state: TaskState | None = None
    recent_turns: list[SessionTurn] = field(default_factory=list)


@dataclass
class SessionRecord:
    session_id: str
    user_id: str
    created_at: datetime = field(default_factory=lambda: datetime.now(UTC))
    step_count: int = 0
    latest_frame: SessionFrame | None = None
    turn_history: list[SessionTurn] = field(default_factory=list)
    selected_mode: str = DEFAULT_GUIDANCE_MODE
    task_summary: str | None = None
    last_next_action: str | None = None
    task_state: TaskState | None = None


class SessionManager:
    def __init__(self) -> None:
        self.sessions: dict[str, SessionRecord] = {}

    def ensure_session(
        self,
        session_id: str,
        user_id: str = "guest-ephemeral",
        *,
        selected_mode: str | None = None,
    ) -> SessionRecord:
        session = self.sessions.get(session_id)
        if session is None:
            session = SessionRecord(
                session_id=session_id,
                user_id=user_id,
                selected_mode=normalize_guidance_mode(selected_mode),
            )
            self.sessions[session_id] = session
        elif selected_mode is not None:
            session.selected_mode = normalize_guidance_mode(selected_mode)
        return session

    def store_frame(
        self,
        session_id: str,
        frame_b64: str,
        metadata: FrameMetadata,
        captured_at: float,
        user_id: str = "guest-ephemeral",
    ) -> SessionFrame:
        session = self.ensure_session(session_id=session_id, user_id=user_id)
        session.latest_frame = SessionFrame(
            base64_jpeg=frame_b64,
            metadata=metadata,
            captured_at=captured_at,
        )
        return session.latest_frame

    def record_user_turn(
        self,
        session_id: str,
        text: str,
        *,
        mode: str | None = None,
        user_id: str | None = None,
    ) -> SessionTurn:
        session = self.ensure_session(
            session_id=session_id,
            user_id=user_id or "guest-ephemeral",
            selected_mode=mode,
        )
        turn = SessionTurn(role="user", text=text)
        session.turn_history.append(turn)
        if session.task_summary is None:
            if not _looks_like_follow_up(text):
                session.task_summary = _compact_text(text)
        elif not _looks_like_follow_up(text):
            session.task_summary = _compact_text(text)
        return turn

    def record_assistant_turn(
        self,
        session_id: str,
        *,
        text: str,
        next_action: str | None = None,
        needs_closer_frame: bool = False,
        follow_up_prompts: list[str] | None = None,
        confidence: Literal["low", "medium", "high"] = "medium",
        task_state: TaskState | None = None,
        mode: str | None = None,
        user_id: str | None = None,
    ) -> SessionTurn:
        session = self.ensure_session(
            session_id=session_id,
            user_id=user_id or "guest-ephemeral",
            selected_mode=mode,
        )
        turn = SessionTurn(
            role="assistant",
            text=text,
            next_action=next_action,
            needs_closer_frame=needs_closer_frame,
            follow_up_prompts=list(follow_up_prompts or []),
            confidence=confidence,
        )
        session.turn_history.append(turn)
        if task_state is not None:
            session.task_state = task_state
        if next_action:
            base_summary = session.task_summary or _last_user_text(session.turn_history)
            if base_summary and not _looks_like_follow_up(base_summary):
                session.task_summary = _compose_summary(base_summary, next_action)
            else:
                session.task_summary = _compact_text(next_action)
            session.last_next_action = next_action
        elif session.task_summary is None:
            session.task_summary = _compact_text(text)
        return turn

    def get_latest_frame(self, session_id: str) -> SessionFrame | None:
        session = self.sessions.get(session_id)
        if session is None:
            return None
        return session.latest_frame

    def get_recent_turns(self, session_id: str, limit: int = 3) -> list[SessionTurn]:
        session = self.sessions.get(session_id)
        if session is None:
            return []
        return session.turn_history[-limit:]

    def build_context(self, session_id: str) -> SessionContext | None:
        session = self.sessions.get(session_id)
        if session is None:
            return None
        return SessionContext(
            session_id=session.session_id,
            user_id=session.user_id,
            latest_frame=session.latest_frame,
            selected_mode=session.selected_mode,
            task_summary=session.task_summary,
            last_next_action=session.last_next_action,
            task_state=session.task_state,
            recent_turns=session.turn_history[-3:],
        )

    def next_step(self, session_id: str, user_id: str = "guest-ephemeral") -> int:
        session = self.ensure_session(session_id=session_id, user_id=user_id)
        session.step_count += 1
        return session.step_count

    def end_session(self, session_id: str) -> SessionRecord | None:
        return self.sessions.pop(session_id, None)


def _compact_text(text: str, *, limit: int = 160) -> str:
    stripped = " ".join(text.strip().split())
    if len(stripped) <= limit:
        return stripped
    return stripped[: limit - 1].rstrip() + "…"


def _looks_like_follow_up(text: str) -> bool:
    lower = text.lower()
    return any(
        phrase in lower
        for phrase in (
            "what now",
            "next step",
            "what should i do next",
            "and after that",
            "then what",
            "what do i do next",
            "where do i go next",
        )
    )


def _last_user_text(turns: list[SessionTurn]) -> str | None:
    for turn in reversed(turns):
        if turn.role == "user":
            return _compact_text(turn.text)
    return None


def _compose_summary(base_summary: str, next_action: str) -> str:
    base = _compact_text(base_summary, limit=120)
    action = _compact_text(next_action, limit=80)
    if not base:
        return action
    if action.lower() in base.lower():
        return base
    summary = f"{base} | Next: {action}"
    return _compact_text(summary, limit=180)
