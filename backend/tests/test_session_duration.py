from __future__ import annotations

import unittest
from datetime import datetime, timedelta, UTC

import test_support  # noqa: F401
from fixwise_backend.tier_enforcement import check_session_duration, TIER_LIMITS


class SessionDurationTests(unittest.TestCase):
    def test_free_tier_expired_session(self):
        # Free tier: 300s limit. Session started 6 minutes ago should be expired.
        started = (datetime.now(UTC) - timedelta(minutes=6)).isoformat()
        result = check_session_duration(started, "free")
        self.assertEqual(result, 0)

    def test_free_tier_warning_near_limit(self):
        # Free tier: 300s limit. Session started 4 min 30s ago => 30s remaining.
        started = (datetime.now(UTC) - timedelta(seconds=270)).isoformat()
        result = check_session_duration(started, "free")
        self.assertIsNotNone(result)
        self.assertGreater(result, 0)
        self.assertLess(result, 60)

    def test_free_tier_well_within_limit(self):
        # Free tier: 300s limit. Session started 1 minute ago => no warning.
        started = (datetime.now(UTC) - timedelta(minutes=1)).isoformat()
        result = check_session_duration(started, "free")
        self.assertIsNone(result)

    def test_pro_tier_expired_session(self):
        # Pro tier: 1800s (30 min). Session started 31 min ago should be expired.
        started = (datetime.now(UTC) - timedelta(minutes=31)).isoformat()
        result = check_session_duration(started, "pro")
        self.assertEqual(result, 0)

    def test_enterprise_tier_no_limit(self):
        # Enterprise has no duration limit.
        started = (datetime.now(UTC) - timedelta(hours=5)).isoformat()
        result = check_session_duration(started, "enterprise")
        self.assertIsNone(result)

    def test_unknown_tier_no_limit(self):
        started = (datetime.now(UTC) - timedelta(minutes=1)).isoformat()
        result = check_session_duration(started, "nonexistent")
        self.assertIsNone(result)

    def test_tier_limits_configured_correctly(self):
        self.assertEqual(TIER_LIMITS["free"].max_sessions_per_month, 3)
        self.assertEqual(TIER_LIMITS["free"].max_session_duration_seconds, 300)
        self.assertIsNone(TIER_LIMITS["pro"].max_sessions_per_month)
        self.assertEqual(TIER_LIMITS["pro"].max_session_duration_seconds, 1800)
        self.assertIsNone(TIER_LIMITS["enterprise"].max_sessions_per_month)
        self.assertIsNone(TIER_LIMITS["enterprise"].max_session_duration_seconds)


if __name__ == "__main__":
    unittest.main()
