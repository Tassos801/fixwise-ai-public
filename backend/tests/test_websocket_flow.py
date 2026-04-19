from __future__ import annotations

import base64
import os
import time
import unittest
from unittest.mock import patch

import httpx
from fastapi.testclient import TestClient

import test_support  # noqa: F401
from fixwise_backend.app import create_app
from fixwise_backend.config import Settings
from fixwise_backend.database import Database
from fixwise_backend.models import AIResponse
from fixwise_backend.session_manager import SessionManager


class RecordingProvider:
    provider_name = "recording"

    def __init__(self) -> None:
        self.last_mode: str | None = None

    async def analyze(
        self,
        *,
        frame_b64: str | None,
        frame_metadata,
        prompt: str,
        mode: str,
        session_id: str,
        session_context=None,
    ) -> AIResponse:
        self.last_mode = mode
        return AIResponse(
            text=f"Handled {mode} guidance for: {prompt}",
            annotations=[],
            nextAction="Keep going with the highlighted step.",
            followUpPrompts=["What should I do next?"],
            confidence="high",
        )


class WebSocketFlowTests(unittest.TestCase):
    def _mock_gemini_tts_response(self, *, pcm_bytes: bytes) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "content": {
                            "parts": [
                                {
                                    "inlineData": {
                                        "mimeType": "audio/pcm",
                                        "data": base64.b64encode(pcm_bytes).decode("ascii"),
                                    }
                                }
                            ]
                        }
                    }
                ]
            },
            request=httpx.Request(
                "POST",
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent",
            ),
        )

    def test_response_includes_tts_audio_when_enabled(self):
        pcm_bytes = b"\x00\x00\x01\x00" * 32
        response = self._mock_gemini_tts_response(pcm_bytes=pcm_bytes)

        app = create_app(
            Settings(
                ai_mode="mock",
                openai_api_key=None,
                gemma_api_key="google-test-key",
                database_path=":memory:",
            ),
        )

        with patch("fixwise_backend.tts.httpx.AsyncClient") as async_client:
            async_client.return_value.__aenter__.return_value.post.return_value = response

            with TestClient(app) as client:
                with client.websocket_connect("/ws/session") as websocket:
                    websocket.send_json(
                        {
                            "type": "frame",
                            "sessionId": "session-audio",
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
                            "sessionId": "session-audio",
                            "timestamp": 2.0,
                            "text": "What should I do next?",
                        }
                    )

                    response = websocket.receive_json()

        self.assertEqual(response["type"], "response")
        self.assertIsInstance(response["audio"], str)
        self.assertTrue(response["audio"])
        audio_bytes = base64.b64decode(response["audio"])
        self.assertTrue(audio_bytes.startswith(b"RIFF"))
        self.assertIn(b"WAVE", audio_bytes[:16])

    def test_tts_failure_does_not_block_text_response(self):
        app = create_app(
            Settings(
                ai_mode="mock",
                openai_api_key=None,
                gemma_api_key="google-test-key",
                database_path=":memory:",
            ),
        )

        with patch("fixwise_backend.tts.httpx.AsyncClient") as async_client:
            async_client.return_value.__aenter__.side_effect = httpx.HTTPError("boom")

            with TestClient(app) as client:
                with client.websocket_connect("/ws/session") as websocket:
                    websocket.send_json(
                        {
                            "type": "frame",
                            "sessionId": "session-tts-failure",
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
                            "sessionId": "session-tts-failure",
                            "timestamp": 2.0,
                            "text": "What should I do next?",
                        }
                    )

                    response = websocket.receive_json()

        self.assertEqual(response["type"], "response")
        self.assertEqual(response["audio"], None)
        self.assertIn("text", response)

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
        self.assertIn("nextAction", response)
        self.assertIn("needsCloserFrame", response)
        self.assertIn("followUpPrompts", response)
        self.assertIn("confidence", response)
        self.assertEqual(response["mode"], "general")
        self.assertIsNone(response["suggestedMode"])
        self.assertFalse(response["needsCloserFrame"])
        self.assertIsInstance(response["followUpPrompts"], list)

    def test_prompt_mode_is_forwarded_and_echoed_in_response(self):
        provider = RecordingProvider()
        app = create_app(
            Settings(ai_mode="mock", openai_api_key=None, database_path=":memory:"),
            provider=provider,
        )

        with TestClient(app) as client:
            with client.websocket_connect("/ws/session") as websocket:
                websocket.send_json(
                    {
                        "type": "frame",
                        "sessionId": "session-mode",
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
                        "sessionId": "session-mode",
                        "timestamp": 2.0,
                        "text": "Check the battery terminals.",
                        "mode": "car",
                    }
                )

                response = websocket.receive_json()

        self.assertEqual(provider.last_mode, "car")
        self.assertEqual(response["mode"], "car")
        self.assertIsNone(response["suggestedMode"])

    def test_general_mode_can_return_suggested_mode(self):
        provider = RecordingProvider()
        app = create_app(
            Settings(ai_mode="mock", openai_api_key=None, database_path=":memory:"),
            provider=provider,
        )

        with TestClient(app) as client:
            with client.websocket_connect("/ws/session") as websocket:
                websocket.send_json(
                    {
                        "type": "frame",
                        "sessionId": "session-suggest",
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
                        "sessionId": "session-suggest",
                        "timestamp": 2.0,
                        "text": "Can you check the oil and battery under the hood?",
                        "mode": "general",
                    }
                )

                response = websocket.receive_json()

        self.assertEqual(response["mode"], "general")
        self.assertEqual(response["suggestedMode"], "car")

    def test_non_general_mode_does_not_emit_suggested_mode(self):
        provider = RecordingProvider()
        app = create_app(
            Settings(ai_mode="mock", openai_api_key=None, database_path=":memory:"),
            provider=provider,
        )

        with TestClient(app) as client:
            with client.websocket_connect("/ws/session") as websocket:
                websocket.send_json(
                    {
                        "type": "frame",
                        "sessionId": "session-suggest-car",
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
                        "sessionId": "session-suggest-car",
                        "timestamp": 2.0,
                        "text": "Can you check the oil and battery under the hood?",
                        "mode": "car",
                    }
                )

                response = websocket.receive_json()

        self.assertEqual(response["mode"], "car")
        self.assertIsNone(response["suggestedMode"])

    def test_machines_mode_response_includes_pc_setup_task_state(self):
        provider = RecordingProvider()
        app = create_app(
            Settings(ai_mode="mock", openai_api_key=None, database_path=":memory:"),
            provider=provider,
        )

        with TestClient(app) as client:
            with client.websocket_connect("/ws/session") as websocket:
                websocket.send_json(
                    {
                        "type": "frame",
                        "sessionId": "session-pc-setup",
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
                        "sessionId": "session-pc-setup",
                        "timestamp": 2.0,
                        "text": "I am plugging HDMI into my GPU for a monitor. What next?",
                        "mode": "machines",
                    }
                )

                response = websocket.receive_json()

        self.assertEqual(response["mode"], "machines")
        self.assertIn("taskState", response)
        self.assertEqual(response["taskState"]["setupType"], "display_setup")
        self.assertEqual(response["taskState"]["phase"], "connect")
        self.assertTrue(response["taskState"]["checklist"])

    def test_guest_websocket_sessions_are_isolated_identities(self):
        db = Database(":memory:")
        app = create_app(
            Settings(ai_mode="mock", openai_api_key=None, database_path=":memory:"),
            database=db,
        )

        with TestClient(app) as client:
            for index in range(2):
                session_id = f"guest-session-{index}"
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
                    websocket.receive_json()

            import asyncio

            async def _load_ids():
                first = await db.get_session("guest-session-0")
                second = await db.get_session("guest-session-1")
                self.assertIsNotNone(first)
                self.assertIsNotNone(second)
                self.assertNotEqual(first.user_id, second.user_id)
                self.assertTrue(first.user_id.startswith("guest-conn-"))
                self.assertTrue(second.user_id.startswith("guest-conn-"))

            asyncio.run(_load_ids())

    def test_auto_mode_gracefully_falls_back_to_mock(self):
        app = create_app(Settings(ai_mode="auto", openai_api_key=None))

        with TestClient(app) as client:
            health = client.get("/health")

        self.assertEqual(health.status_code, 200)
        self.assertEqual(health.json()["provider"], "mock")
        self.assertFalse(health.json()["liveReady"])

    def test_production_auto_mode_without_key_reports_unavailable(self):
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
                    ai_mode="auto",
                    openai_api_key=None,
                    environment="production",
                    database_path=":memory:",
                )
            )

        with TestClient(app) as client:
            health = client.get("/health")

        self.assertEqual(health.status_code, 200)
        self.assertEqual(health.json()["provider"], "unavailable")
        self.assertEqual(health.json()["availability"], "unavailable")
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
