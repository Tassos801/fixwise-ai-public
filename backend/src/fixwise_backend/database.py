"""
SQLite-backed persistence for users, API keys, sessions, and session steps.
MVP-grade: uses aiosqlite for async access. Swap to PostgreSQL for production.
"""
from __future__ import annotations

import json
import sqlite3
from contextlib import asynccontextmanager
from datetime import datetime, UTC
from dataclasses import dataclass
from pathlib import Path
from typing import AsyncIterator

import aiosqlite


DEFAULT_DB_PATH = Path(__file__).parent.parent.parent / "fixwise.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    display_name TEXT,
    tier TEXT NOT NULL DEFAULT 'free',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS api_keys (
    user_id TEXT PRIMARY KEY REFERENCES users(id),
    encrypted_key BLOB NOT NULL,
    key_mask TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    status TEXT NOT NULL DEFAULT 'active',
    step_count INTEGER NOT NULL DEFAULT 0,
    started_at TEXT NOT NULL DEFAULT (datetime('now')),
    ended_at TEXT,
    report_url TEXT
);

CREATE TABLE IF NOT EXISTS session_steps (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES sessions(id),
    step_number INTEGER NOT NULL,
    frame_thumbnail TEXT,
    ai_response_text TEXT NOT NULL,
    annotations_json TEXT,
    safety_warning TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_steps_session ON session_steps(session_id);
"""


@dataclass
class UserRow:
    id: str
    email: str
    password_hash: str
    display_name: str | None
    tier: str
    created_at: str
    updated_at: str


@dataclass
class APIKeyRow:
    user_id: str
    encrypted_key: bytes
    key_mask: str
    created_at: str
    updated_at: str


@dataclass
class SessionRow:
    id: str
    user_id: str
    status: str
    step_count: int
    started_at: str
    ended_at: str | None
    report_url: str | None


@dataclass
class SessionStepRow:
    id: int
    session_id: str
    step_number: int
    frame_thumbnail: str | None
    ai_response_text: str
    annotations_json: str | None
    safety_warning: str | None
    created_at: str


class Database:
    """Async SQLite wrapper for FixWise persistence."""

    def __init__(self, db_path: str | Path = DEFAULT_DB_PATH) -> None:
        self._db_path = str(db_path)
        self._db: aiosqlite.Connection | None = None

    async def connect(self) -> None:
        self._db = await aiosqlite.connect(self._db_path)
        self._db.row_factory = aiosqlite.Row
        await self._db.executescript(SCHEMA)
        await self._db.commit()

    async def close(self) -> None:
        if self._db:
            await self._db.close()
            self._db = None

    @property
    def db(self) -> aiosqlite.Connection:
        assert self._db is not None, "Database not connected. Call connect() first."
        return self._db

    # ── Users ──────────────────────────────────────────────────

    async def create_user(
        self, *, user_id: str, email: str, password_hash: str, display_name: str | None = None
    ) -> UserRow:
        await self.db.execute(
            "INSERT INTO users (id, email, password_hash, display_name) VALUES (?, ?, ?, ?)",
            (user_id, email, password_hash, display_name),
        )
        await self.db.commit()
        return UserRow(
            id=user_id,
            email=email,
            password_hash=password_hash,
            display_name=display_name,
            tier="free",
            created_at=datetime.now(UTC).isoformat(),
            updated_at=datetime.now(UTC).isoformat(),
        )

    async def get_user_by_email(self, email: str) -> UserRow | None:
        cursor = await self.db.execute("SELECT * FROM users WHERE email = ?", (email,))
        row = await cursor.fetchone()
        if not row:
            return None
        return UserRow(**dict(row))

    async def get_user_by_id(self, user_id: str) -> UserRow | None:
        cursor = await self.db.execute("SELECT * FROM users WHERE id = ?", (user_id,))
        row = await cursor.fetchone()
        if not row:
            return None
        return UserRow(**dict(row))

    # ── API Keys (BYOK) ───────────────────────────────────────

    async def store_api_key(self, *, user_id: str, encrypted_key: bytes, key_mask: str) -> None:
        await self.db.execute(
            """INSERT INTO api_keys (user_id, encrypted_key, key_mask)
               VALUES (?, ?, ?)
               ON CONFLICT(user_id) DO UPDATE SET
                   encrypted_key = excluded.encrypted_key,
                   key_mask = excluded.key_mask,
                   updated_at = datetime('now')""",
            (user_id, encrypted_key, key_mask),
        )
        await self.db.commit()

    async def get_api_key(self, user_id: str) -> APIKeyRow | None:
        cursor = await self.db.execute("SELECT * FROM api_keys WHERE user_id = ?", (user_id,))
        row = await cursor.fetchone()
        if not row:
            return None
        return APIKeyRow(**dict(row))

    async def delete_api_key(self, user_id: str) -> bool:
        cursor = await self.db.execute("DELETE FROM api_keys WHERE user_id = ?", (user_id,))
        await self.db.commit()
        return cursor.rowcount > 0

    # ── Sessions ───────────────────────────────────────────────

    async def create_session(self, *, session_id: str, user_id: str) -> SessionRow:
        now = datetime.now(UTC).isoformat()
        await self.db.execute(
            "INSERT OR IGNORE INTO sessions (id, user_id, started_at) VALUES (?, ?, ?)",
            (session_id, user_id, now),
        )
        await self.db.commit()
        return SessionRow(
            id=session_id, user_id=user_id, status="active",
            step_count=0, started_at=now, ended_at=None, report_url=None,
        )

    async def end_session(self, session_id: str, report_url: str | None = None) -> None:
        now = datetime.now(UTC).isoformat()
        await self.db.execute(
            "UPDATE sessions SET status = 'completed', ended_at = ?, report_url = ? WHERE id = ?",
            (now, report_url, session_id),
        )
        await self.db.commit()

    async def increment_step_count(self, session_id: str) -> int:
        await self.db.execute(
            "UPDATE sessions SET step_count = step_count + 1 WHERE id = ?",
            (session_id,),
        )
        await self.db.commit()
        cursor = await self.db.execute(
            "SELECT step_count FROM sessions WHERE id = ?", (session_id,)
        )
        row = await cursor.fetchone()
        return row["step_count"] if row else 0

    async def list_sessions(self, user_id: str, limit: int = 50) -> list[SessionRow]:
        cursor = await self.db.execute(
            "SELECT * FROM sessions WHERE user_id = ? ORDER BY started_at DESC LIMIT ?",
            (user_id, limit),
        )
        rows = await cursor.fetchall()
        return [SessionRow(**dict(r)) for r in rows]

    async def get_session(self, session_id: str) -> SessionRow | None:
        cursor = await self.db.execute("SELECT * FROM sessions WHERE id = ?", (session_id,))
        row = await cursor.fetchone()
        if not row:
            return None
        return SessionRow(**dict(row))

    # ── Session Steps ──────────────────────────────────────────

    async def add_session_step(
        self,
        *,
        session_id: str,
        step_number: int,
        ai_response_text: str,
        frame_thumbnail: str | None = None,
        annotations_json: str | None = None,
        safety_warning: str | None = None,
    ) -> None:
        await self.db.execute(
            """INSERT INTO session_steps
               (session_id, step_number, frame_thumbnail, ai_response_text, annotations_json, safety_warning)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (session_id, step_number, frame_thumbnail, ai_response_text, annotations_json, safety_warning),
        )
        await self.db.commit()

    async def get_session_steps(self, session_id: str) -> list[SessionStepRow]:
        cursor = await self.db.execute(
            "SELECT * FROM session_steps WHERE session_id = ? ORDER BY step_number",
            (session_id,),
        )
        rows = await cursor.fetchall()
        return [SessionStepRow(**dict(r)) for r in rows]
