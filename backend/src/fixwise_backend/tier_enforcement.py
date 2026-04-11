"""
Subscription tier enforcement middleware.

Enforces session quotas and duration limits per subscription tier:
- free: 3 sessions/month, 5 min per session
- pro: unlimited sessions, 30 min per session
- enterprise: unlimited sessions, unlimited duration
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, UTC

from fastapi import HTTPException

from fixwise_backend.database import Database


@dataclass
class TierLimits:
    max_sessions_per_month: int | None  # None = unlimited
    max_session_duration_seconds: int | None  # None = unlimited


TIER_LIMITS: dict[str, TierLimits] = {
    "free": TierLimits(max_sessions_per_month=3, max_session_duration_seconds=300),
    "pro": TierLimits(max_sessions_per_month=None, max_session_duration_seconds=1800),
    "enterprise": TierLimits(max_sessions_per_month=None, max_session_duration_seconds=None),
}


async def check_session_quota(db: Database, user_id: str, tier: str) -> None:
    """Raise HTTPException(403) if the user has exceeded their monthly session quota."""
    limits = TIER_LIMITS.get(tier)
    if limits is None:
        raise HTTPException(status_code=403, detail=f"Unknown tier: {tier}")

    if limits.max_sessions_per_month is None:
        return  # unlimited

    now = datetime.now(UTC)
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0).isoformat()

    cursor = await db.db.execute(
        "SELECT COUNT(*) FROM sessions WHERE user_id = ? AND started_at >= ?",
        (user_id, month_start),
    )
    row = await cursor.fetchone()
    count = row[0] if row else 0

    if count >= limits.max_sessions_per_month:
        raise HTTPException(
            status_code=403,
            detail=f"Monthly session limit reached ({limits.max_sessions_per_month} sessions). Upgrade your plan for more.",
        )


def check_session_duration(started_at: str, tier: str) -> int | None:
    """Check whether a session is approaching or has exceeded its duration limit.

    Returns:
        None  - not near the limit (or tier has no limit)
        int>0 - remaining seconds (when < 60s left)
        0     - session has exceeded the limit
    """
    limits = TIER_LIMITS.get(tier)
    if limits is None or limits.max_session_duration_seconds is None:
        return None  # no limit

    started = datetime.fromisoformat(started_at)
    if started.tzinfo is None:
        started = started.replace(tzinfo=UTC)

    elapsed = (datetime.now(UTC) - started).total_seconds()
    remaining = limits.max_session_duration_seconds - elapsed

    if remaining <= 0:
        return 0
    if remaining < 60:
        return int(remaining)
    return None
