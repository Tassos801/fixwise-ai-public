from __future__ import annotations

import unittest

import test_support  # noqa: F401
from fixwise_backend.models import FrameMetadata
from fixwise_backend.session_manager import SessionManager


class SessionManagerTests(unittest.TestCase):
    def test_store_frame_replaces_latest_frame(self):
        manager = SessionManager()
        metadata = FrameMetadata(width=512, height=512, sceneDelta=0.05)

        manager.store_frame("session-1", "frame-1", metadata, captured_at=1.0)
        manager.store_frame("session-1", "frame-2", metadata, captured_at=2.0)

        latest = manager.get_latest_frame("session-1")
        self.assertIsNotNone(latest)
        self.assertEqual(latest.base64_jpeg, "frame-2")
        self.assertEqual(latest.captured_at, 2.0)

    def test_next_step_tracks_progress(self):
        manager = SessionManager()

        self.assertEqual(manager.next_step("session-1"), 1)
        self.assertEqual(manager.next_step("session-1"), 2)


if __name__ == "__main__":
    unittest.main()
