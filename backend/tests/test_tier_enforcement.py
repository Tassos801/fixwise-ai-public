from __future__ import annotations

import asyncio
import tempfile
import unittest
from datetime import datetime, timedelta, UTC
from pathlib import Path
from unittest.mock import patch

import test_support  # noqa: F401
from fixwise_backend.database import Database
from fixwise_backend.tier_enforcement import (
    TIER_LIMITS,
    TierLimits,
    check_session_duration,
    check_session_quota,
)


def run_async(coro):
    """Helper to run async functions in sync tests."""
    return asyncio.run(coro)


class TestTierLimitsConfig(unittest.TestCase):
    """Verify tier configuration is correct."""

    def test_free_tier_limits(self):
        limits = TIER_LIMITS["free"]
        self.assertEqual(limits.max_sessions_per_month, 3)
        self.assertEqual(limits.max_session_duration_seconds, 300)

    def test_pro_tier_limits(self):
        limits = TIER_LIMITS["pro"]
        self.assertIsNone(limits.max_sessions_per_month)
        self.assertEqual(limits.max_session_duration_seconds, 1800)

    def test_enterprise_tier_limits(self):
        limits = TIER_LIMITS["enterprise"]
        self.assertIsNone(limits.max_sessions_per_month)
        self.assertIsNone(limits.max_session_duration_seconds)


class TestCheckSessionQuota(unittest.TestCase):
    """Test monthly session quota enforcement."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.db = Database(self.tmp.name)
        run_async(self.db.connect())

    def tearDown(self):
        run_async(self.db.close())
        Path(self.tmp.name).unlink(missing_ok=True)

    def test_free_tier_blocked_after_3_sessions(self):
        async def _test():
            await self.db.create_user(
                user_id="u1", email="free@example.com", password_hash="h",
            )
            # Create 3 sessions (the monthly limit for free)
            for i in range(3):
                await self.db.create_session(session_id=f"s{i}", user_id="u1")

            # Fourth session should be blocked
            from fastapi import HTTPException
            with self.assertRaises(HTTPException) as ctx:
                await check_session_quota(self.db, "u1", "free")
            self.assertEqual(ctx.exception.status_code, 403)

        run_async(_test())

    def test_free_tier_allowed_under_limit(self):
        async def _test():
            await self.db.create_user(
                user_id="u2", email="free2@example.com", password_hash="h",
            )
            # Create only 2 sessions (under the limit)
            for i in range(2):
                await self.db.create_session(session_id=f"s2-{i}", user_id="u2")

            # Should not raise
            await check_session_quota(self.db, "u2", "free")

        run_async(_test())

    def test_pro_tier_not_blocked(self):
        async def _test():
            await self.db.create_user(
                user_id="u3", email="pro@example.com", password_hash="h",
            )
            # Create many sessions - pro has unlimited
            for i in range(20):
                await self.db.create_session(session_id=f"s3-{i}", user_id="u3")

            # Should not raise
            await check_session_quota(self.db, "u3", "pro")

        run_async(_test())

    def test_enterprise_tier_not_blocked(self):
        async def _test():
            await self.db.create_user(
                user_id="u4", email="ent@example.com", password_hash="h",
            )
            for i in range(50):
                await self.db.create_session(session_id=f"s4-{i}", user_id="u4")

            # Should not raise
            await check_session_quota(self.db, "u4", "enterprise")

        run_async(_test())

    def test_unknown_tier_raises_403(self):
        async def _test():
            await self.db.create_user(
                user_id="u5", email="bad@example.com", password_hash="h",
            )
            from fastapi import HTTPException
            with self.assertRaises(HTTPException) as ctx:
                await check_session_quota(self.db, "u5", "nonexistent")
            self.assertEqual(ctx.exception.status_code, 403)

        run_async(_test())


class TestCheckSessionDuration(unittest.TestCase):
    """Test session duration limit checks."""

    def test_free_tier_exceeded(self):
        # Session started 6 minutes ago, free limit is 5 min
        started_at = (datetime.now(UTC) - timedelta(minutes=6)).isoformat()
        result = check_session_duration(started_at, "free")
        self.assertEqual(result, 0)

    def test_free_tier_approaching_limit(self):
        # Session started 4 min 30 sec ago (30 sec remaining, which is < 60)
        started_at = (datetime.now(UTC) - timedelta(minutes=4, seconds=30)).isoformat()
        result = check_session_duration(started_at, "free")
        self.assertIsNotNone(result)
        self.assertGreater(result, 0)
        self.assertLessEqual(result, 30)

    def test_free_tier_not_near_limit(self):
        # Session started 1 minute ago (4 min remaining, well above 60s)
        started_at = (datetime.now(UTC) - timedelta(minutes=1)).isoformat()
        result = check_session_duration(started_at, "free")
        self.assertIsNone(result)

    def test_pro_tier_exceeded(self):
        # Session started 31 minutes ago, pro limit is 30 min
        started_at = (datetime.now(UTC) - timedelta(minutes=31)).isoformat()
        result = check_session_duration(started_at, "pro")
        self.assertEqual(result, 0)

    def test_pro_tier_approaching_limit(self):
        # Session started 29 min 20 sec ago (40 sec remaining)
        started_at = (datetime.now(UTC) - timedelta(minutes=29, seconds=20)).isoformat()
        result = check_session_duration(started_at, "pro")
        self.assertIsNotNone(result)
        self.assertGreater(result, 0)
        self.assertLessEqual(result, 40)

    def test_enterprise_no_limit(self):
        # Even a very long session returns None for enterprise
        started_at = (datetime.now(UTC) - timedelta(hours=24)).isoformat()
        result = check_session_duration(started_at, "enterprise")
        self.assertIsNone(result)

    def test_naive_datetime_handled(self):
        # started_at without timezone info should still work
        started_at = (datetime.now(UTC) - timedelta(minutes=6)).strftime("%Y-%m-%dT%H:%M:%S")
        result = check_session_duration(started_at, "free")
        self.assertEqual(result, 0)


if __name__ == "__main__":
    unittest.main()
