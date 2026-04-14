from __future__ import annotations

import os
import time
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

import test_support  # noqa: F401
from fixwise_backend.app import create_app
from fixwise_backend.config import Settings
from fixwise_backend.session_manager import SessionManager


class WebSocketFlowTests(unittest.TestCase):
    def test_frame_then_prompt_returns_response(self):
        app = create_app(Settings(ai_mode="mock", openai_api_key=None))

        with TestClient(app) as client:
            with client.websocket_connect("/ws/session") as websocket:
                websocket.send_json(
                    {
                        "type": "frame",
                        "sessionId": "session-1",
                        "timestamp": 1.0,
                        "frame": "ZmFrZS1qcGVn",
                        "frameMetadata": {
                            "width": 512,
                            "height": 512,
                            "sceneDelta": 0.11,
                        },
                    }
                )
                websocket.send_json(
                    {
                        "type": "prompt",
                        "sessionId": "session-1",
                        "timestamp": 2.0,
                        "text": "What should I do next?",
                    }
                )

                response = websocket.receive_json()

        self.assertEqual(response["type"], "response")
        self.assertEqual(response["sessionId"], "session-1")
        self.assertEqual(response["stepNumber"], 1)
        self.assertIn("workspace", response["text"].lower())

    def test_auto_mode_gracefully_falls_back_to_mock(self):
        app = create_app(Settings(ai_mode="auto", openai_api_key=None))

        with TestClient(app) as client:
            health = client.get("/health")

        self.assertEqual(health.status_code, 200)
        self.assertEqual(health.json()["provider"], "mock")
        self.assertFalse(health.json()["liveReady"])

    def test_safety_block_is_returned_for_prohibited_prompt(self):
        app = create_app(Settings(ai_mode="mock", openai_api_key=None))

        with TestClient(app) as client:
            with client.websocket_connect("/ws/session") as websocket:
                websocket.send_json(
                    {
                        "type": "prompt",
                        "sessionId": "session-1",
                        "timestamp": 2.0,
                        "text": "Can you help me repair a gas line?",
                    }
                )

                response = websocket.receive_json()

        self.assertEqual(response["type"], "safety_block")
        self.assertIn("gas line", response["reason"])

    def test_prompt_without_frame_returns_error(self):
        app = create_app(Settings(ai_mode="mock", openai_api_key=None))

        with TestClient(app) as client:
            with client.websocket_connect("/ws/session") as websocket:
                websocket.send_json(
                    {
                        "type": "prompt",
                        "sessionId": "session-2",
                        "timestamp": 1.0,
                        "text": "What should I do next?",
                    }
                )

                response = websocket.receive_json()

        self.assertEqual(response["type"], "error")
        self.assertIn("frame must be sent", response["message"])

    def test_invalid_json_returns_error(self):
        app = create_app(Settings(ai_mode="mock", openai_api_key=None))

        with TestClient(app) as client:
            with client.websocket_connect("/ws/session") as websocket:
                websocket.send_text("not-json")
                response = websocket.receive_json()

        self.assertEqual(response["type"], "error")
        self.assertIn("Invalid JSON", response["message"])

    def test_unexpected_disconnect_clears_in_memory_session(self):
        session_manager = SessionManager()
        app = create_app(
            Settings(ai_mode="mock", openai_api_key=None, database_path=":memory:"),
            session_manager=session_manager,
        )

        with TestClient(app) as client:
            with client.websocket_connect("/ws/session") as websocket:
                websocket.send_json(
                    {
                        "type": "frame",
                        "sessionId": "session-1",
                        "timestamp": 1.0,
                        "frame": "ZmFrZS1qcGVn",
                        "frameMetadata": {
                            "width": 512,
                            "height": 512,
                            "sceneDelta": 0.11,
                        },
                    }
                )

                deadline = time.time() + 1.0
                while time.time() < deadline:
                    if session_manager.get_latest_frame("session-1") is not None:
                        break
                    time.sleep(0.01)

                self.assertIsNotNone(session_manager.get_latest_frame("session-1"))

            deadline = time.time() + 1.0
            while time.time() < deadline:
                if session_manager.get_latest_frame("session-1") is None:
                    break
                time.sleep(0.01)

            self.assertIsNone(session_manager.get_latest_frame("session-1"))
            self.assertNotIn("session-1", session_manager.sessions)

    def test_development_ignores_free_tier_session_quota(self):
        app = create_app(
            Settings(
                ai_mode="mock",
                openai_api_key=None,
                database_path=":memory:",
                environment="development",
            )
        )

        with TestClient(app) as client:
            for index in range(4):
                session_id = f"session-dev-{index}"
                with client.websocket_connect("/ws/session") as websocket:
                    websocket.send_json(
                        {
                            "type": "frame",
                            "sessionId": session_id,
                            "timestamp": 1.0 + index,
                            "frame": "ZmFrZS1qcGVn",
                            "frameMetadata": {
                                "width": 512,
                                "height": 512,
                                "sceneDelta": 0.11,
                            },
                        }
                    )
                    websocket.send_json(
                        {
                            "type": "prompt",
                            "sessionId": session_id,
                            "timestamp": 2.0 + index,
                            "text": "What should I do next?",
                        }
                    )
                    response = websocket.receive_json()

                self.assertEqual(response["type"], "response")

    def test_production_enforces_free_tier_session_quota(self):
        with patch.dict(
            os.environ,
            {
                "FIXWISE_JWT_SECRET": "x" * 32,
                "FIXWISE_MASTER_KEY": "ab" * 32,
            },
            clear=False,
        ):
            app = create_app(
                Settings(
                    ai_mode="mock",
                    openai_api_key=None,
                    database_path=":memory:",
                    environment="production",
                )
            )

        with TestClient(app) as client:
            for index in range(3):
                session_id = f"session-prod-{index}"
                with client.websocket_connect("/ws/session") as websocket:
                    websocket.send_json(
                        {
                            "type": "frame",
                            "sessionId": session_id,
                            "timestamp": 1.0 + index,
                            "frame": "ZmFrZS1qcGVn",
                            "frameMetadata": {
                                "width": 512,
                                "height": 512,
                                "sceneDelta": 0.11,
                            },
                        }
                    )
                    websocket.send_json(
                        {
                            "type": "prompt",
                            "sessionId": session_id,
                            "timestamp": 2.0 + index,
                            "text": "What should I do next?",
                        }
                    )
                    response = websocket.receive_json()
                    self.assertEqual(response["type"], "response")

            with client.websocket_connect("/ws/session") as websocket:
                websocket.send_json(
                    {
                        "type": "frame",
                        "sessionId": "session-prod-limit",
                        "timestamp": 10.0,
                        "frame": "ZmFrZS1qcGVn",
                        "frameMetadata": {
                            "width": 512,
                            "height": 512,
                            "sceneDelta": 0.11,
                        },
                    }
                )
                response = websocket.receive_json()

            self.assertEqual(response["type"], "error")
            self.assertIn("Monthly session limit reached", response["message"])


if __name__ == "__main__":
    unittest.main()
