from __future__ import annotations

import unittest

import test_support  # noqa: F401
from fixwise_backend.safety import check_safety


class SafetyTests(unittest.TestCase):
    def test_blocked_topic_returns_reason(self):
        reason = check_safety("Can you help me replace a breaker panel?")
        self.assertIsNotNone(reason)
        self.assertIn("breaker panel", reason)

    def test_safe_prompt_returns_none(self):
        self.assertIsNone(check_safety("How do I organize these PC cables neatly?"))


if __name__ == "__main__":
    unittest.main()
