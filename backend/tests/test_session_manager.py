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

    def test_session_memory_tracks_recent_turns_and_summary(self):
        manager = SessionManager()
        metadata = FrameMetadata(width=512, height=512, sceneDelta=0.05)

        manager.record_user_turn("session-1", "What should I do next?", mode="car")
        manager.store_frame("session-1", "frame-1", metadata, captured_at=1.0)
        manager.record_assistant_turn(
            "session-1",
            text="Keep the camera steady on the connector.",
            next_action="Keep the camera steady on the connector.",
            follow_up_prompts=["Should I zoom in?"],
            mode="car",
        )

        context = manager.build_context("session-1")
        self.assertIsNotNone(context)
        self.assertEqual(context.session_id, "session-1")
        self.assertEqual(context.selected_mode, "car")
        self.assertEqual(context.last_next_action, "Keep the camera steady on the connector.")
        self.assertTrue(context.recent_turns)
        self.assertIn("connector", context.task_summary or "")


if __name__ == "__main__":
    unittest.main()
