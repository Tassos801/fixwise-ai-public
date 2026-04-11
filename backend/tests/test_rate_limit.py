from __future__ import annotations

import unittest

from fastapi.testclient import TestClient

import test_support  # noqa: F401
from fixwise_backend.app import create_app
from fixwise_backend.config import Settings


class RateLimitTests(unittest.TestCase):
    def test_auth_route_returns_429_when_limit_is_exceeded(self):
        app = create_app(
            Settings(
                ai_mode="mock",
                openai_api_key=None,
                rate_limit_window_seconds=60,
                auth_rate_limit_requests=1,
            )
        )

        with TestClient(app) as client:
            first = client.post(
                "/api/auth/register",
                json={"email": "first@example.com", "password": "securepass123"},
            )
            second = client.post(
                "/api/auth/register",
                json={"email": "second@example.com", "password": "securepass123"},
            )

        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 429)
        self.assertIn("Rate limit exceeded", second.json()["detail"])
        self.assertEqual(second.headers.get("Retry-After"), "60")

    def test_websocket_prompt_limit_returns_error_message(self):
        app = create_app(
            Settings(
                ai_mode="mock",
                openai_api_key=None,
                rate_limit_window_seconds=60,
                websocket_prompt_rate_limit_requests=1,
            )
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
                websocket.send_json(
                    {
                        "type": "prompt",
                        "sessionId": "session-1",
                        "timestamp": 2.0,
                        "text": "What should I do next?",
                    }
                )
                first = websocket.receive_json()

                websocket.send_json(
                    {
                        "type": "prompt",
                        "sessionId": "session-1",
                        "timestamp": 3.0,
                        "text": "And after that?",
                    }
                )
                second = websocket.receive_json()

        self.assertEqual(first["type"], "response")
        self.assertEqual(second["type"], "error")
        self.assertIn("Rate limit exceeded", second["message"])


if __name__ == "__main__":
    unittest.main()
