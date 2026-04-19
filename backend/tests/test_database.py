from __future__ import annotations

import asyncio
import unittest
import tempfile
from pathlib import Path

import test_support  # noqa: F401
from fixwise_backend.database import Database


def run_async(coro):
    """Helper to run async functions in sync tests."""
    return asyncio.run(coro)


class DatabaseTests(unittest.TestCase):
    """Test SQLite database operations."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.db = Database(self.tmp.name)
        run_async(self.db.connect())

    def tearDown(self):
        run_async(self.db.close())
        Path(self.tmp.name).unlink(missing_ok=True)

    def test_create_and_get_user(self):
        async def _test():
            user = await self.db.create_user(
                user_id="u1", email="test@example.com",
                password_hash="hash123", display_name="Test",
            )
            self.assertEqual(user.email, "test@example.com")

            found = await self.db.get_user_by_email("test@example.com")
            self.assertIsNotNone(found)
            self.assertEqual(found.id, "u1")

        run_async(_test())

    def test_api_key_store_and_retrieve(self):
        async def _test():
            await self.db.create_user(
                user_id="u2", email="key@example.com", password_hash="h",
            )
            await self.db.store_api_key(
                user_id="u2", encrypted_key=b"encrypted-data", key_mask="sk-...abc",
            )
            row = await self.db.get_api_key("u2")
            self.assertIsNotNone(row)
            self.assertEqual(row.key_mask, "sk-...abc")

        run_async(_test())

    def test_api_key_delete(self):
        async def _test():
            await self.db.create_user(
                user_id="u3", email="del@example.com", password_hash="h",
            )
            await self.db.store_api_key(
                user_id="u3", encrypted_key=b"data", key_mask="sk-...xyz",
            )
            deleted = await self.db.delete_api_key("u3")
            self.assertTrue(deleted)

            row = await self.db.get_api_key("u3")
            self.assertNone(row)

        run_async(_test())

    def test_session_lifecycle(self):
        async def _test():
            await self.db.create_user(
                user_id="u4", email="sess@example.com", password_hash="h",
            )
            session = await self.db.create_session(session_id="s1", user_id="u4", selected_mode="car")
            self.assertEqual(session.status, "active")
            self.assertEqual(session.selected_mode, "car")
            self.assertIsNone(session.summary)
            self.assertIsNone(session.last_next_action)

            step_count = await self.db.increment_step_count("s1")
            self.assertEqual(step_count, 1)

            await self.db.add_session_step(
                session_id="s1", step_number=1,
                ai_response_text="Turn the valve counterclockwise.",
                mode="car",
                next_action="Turn the valve counterclockwise.",
                needs_closer_frame=False,
                follow_up_prompts_json='["Should I keep turning it?"]',
                confidence="high",
            )

            steps = await self.db.get_session_steps("s1")
            self.assertEqual(len(steps), 1)
            self.assertEqual(steps[0].ai_response_text, "Turn the valve counterclockwise.")
            self.assertEqual(steps[0].mode, "car")
            self.assertEqual(steps[0].next_action, "Turn the valve counterclockwise.")
            self.assertEqual(steps[0].confidence, "high")

            await self.db.update_session_mode("s1", "machines")
            await self.db.end_session(
                "s1",
                summary="Turn the valve",
                last_next_action="Turn the valve counterclockwise.",
            )
            ended = await self.db.get_session("s1")
            self.assertEqual(ended.status, "completed")
            self.assertEqual(ended.selected_mode, "machines")
            self.assertEqual(ended.summary, "Turn the valve")
            self.assertEqual(ended.last_next_action, "Turn the valve counterclockwise.")

        run_async(_test())

    def test_list_sessions_for_user(self):
        async def _test():
            await self.db.create_user(user_id="u5", email="list@example.com", password_hash="h")
            await self.db.create_session(session_id="s2", user_id="u5")
            await self.db.create_session(session_id="s3", user_id="u5")

            sessions = await self.db.list_sessions("u5")
            self.assertEqual(len(sessions), 2)

        run_async(_test())

    def assertNone(self, val):
        self.assertIsNone(val)


if __name__ == "__main__":
    unittest.main()
