from __future__ import annotations

import asyncio
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import httpx

import test_support  # noqa: F401
from fixwise_backend.ai import (
    GemmaVisionProvider,
    MockAIProvider,
    OpenAIVisionProvider,
    UnavailableAIProvider,
    build_ai_provider,
    validate_ai_api_key,
)
from fixwise_backend.config import Settings
from fixwise_backend.guidance_modes import get_system_prompt
from fixwise_backend.models import FrameMetadata


class StubAsyncClient:
    def __init__(self, response: httpx.Response) -> None:
        self.response = response
        self.calls: list[tuple[str, tuple, dict]] = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, tb):
        return False

    async def get(self, *args, **kwargs):
        self.calls.append(("get", args, kwargs))
        return self.response

    async def post(self, *args, **kwargs):
        self.calls.append(("post", args, kwargs))
        return self.response


class ProviderSelectionTests(unittest.TestCase):
    def test_auto_mode_without_key_uses_mock(self):
        provider = build_ai_provider(
            Settings(ai_mode="auto", openai_api_key=None)
        )
        self.assertIsInstance(provider, MockAIProvider)

    def test_production_auto_mode_without_key_uses_unavailable_provider(self):
        provider = build_ai_provider(
            Settings(ai_mode="auto", openai_api_key=None, environment="production")
        )
        self.assertIsInstance(provider, UnavailableAIProvider)

    def test_mock_mode_uses_mock(self):
        provider = build_ai_provider(
            Settings(ai_mode="mock", openai_api_key=None)
        )
        self.assertIsInstance(provider, MockAIProvider)

    def test_live_mode_with_key_uses_openai_provider(self):
        provider = build_ai_provider(
            Settings(ai_mode="live", openai_api_key="sk-test", openai_model="gpt-test")
        )
        self.assertIsInstance(provider, OpenAIVisionProvider)

    def test_live_mode_with_gemma_key_uses_gemma_provider(self):
        provider = build_ai_provider(
            Settings(
                ai_mode="live",
                ai_provider="gemma",
                gemma_api_key="google-test-key",
                gemma_model="gemma-4-31b-it",
            )
        )
        self.assertIsInstance(provider, GemmaVisionProvider)

    def test_live_mode_without_key_uses_unavailable_provider(self):
        provider = build_ai_provider(
            Settings(ai_mode="live", openai_api_key=None)
        )
        self.assertIsInstance(provider, UnavailableAIProvider)

    def test_api_key_override_bypasses_mock_mode(self):
        provider = build_ai_provider(
            Settings(ai_mode="mock", ai_provider="gemma", gemma_model="gemma-4-31b-it"),
            api_key_override="google-test-key",
        )
        self.assertIsInstance(provider, GemmaVisionProvider)

    def test_gemma_provider_parses_generate_content_response(self):
        response = httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "content": {
                            "parts": [
                                {
                                    "text": (
                                        '{"text":"Tighten the bracket gently.",'
                                        '"annotations":[],"safetyWarning":null}'
                                    )
                                }
                            ]
                        }
                    }
                ]
            },
            request=httpx.Request(
                "POST",
                "https://generativelanguage.googleapis.com/v1beta/models/gemma-4-31b-it:generateContent",
            ),
        )
        provider = GemmaVisionProvider(
            api_key="google-test-key",
            model="gemma-4-31b-it",
            base_url="https://generativelanguage.googleapis.com/v1beta",
        )
        stub_client = StubAsyncClient(response)

        with patch(
            "fixwise_backend.ai.httpx.AsyncClient",
            return_value=stub_client,
        ):
            result = asyncio.run(
                provider.analyze(
                    frame_b64="ZmFrZS1qcGVn",
                    frame_metadata=FrameMetadata(width=512, height=512, sceneDelta=0.11),
                    prompt="What should I do next?",
                    mode="car",
                    session_id="session-1",
                )
            )

        self.assertEqual(result.text, "Tighten the bracket gently.")
        self.assertIsNone(result.nextAction)
        self.assertEqual(
            stub_client.calls[0][2]["json"]["system_instruction"]["parts"][0]["text"],
            get_system_prompt("car"),
        )

    def test_openai_provider_uses_selected_mode_prompt(self):
        class StubOpenAIClient:
            def __init__(self) -> None:
                self.last_request: dict | None = None
                self.chat = SimpleNamespace(completions=SimpleNamespace(create=self.create))

            async def create(self, **kwargs):
                self.last_request = kwargs
                return SimpleNamespace(
                    choices=[
                        SimpleNamespace(
                            message=SimpleNamespace(
                                content='{"text":"Use the highlighted step.","annotations":[],"safetyWarning":null}'
                            )
                        )
                    ]
                )

        stub_client = StubOpenAIClient()

        with patch.dict(sys.modules, {"openai": SimpleNamespace(AsyncOpenAI=lambda **_: stub_client)}):
            provider = OpenAIVisionProvider(
                api_key="sk-test",
                model="gpt-test",
                base_url="https://api.openai.com/v1",
            )
            result = asyncio.run(
                provider.analyze(
                    frame_b64="ZmFrZS1qcGVn",
                    frame_metadata=FrameMetadata(width=512, height=512, sceneDelta=0.11),
                    prompt="What should I do next?",
                    mode="gardening",
                    session_id="session-1",
                )
            )

        self.assertEqual(result.text, "Use the highlighted step.")
        self.assertEqual(
            stub_client.last_request["messages"][0]["content"],
            get_system_prompt("gardening"),
        )

    def test_validate_gemma_api_key_uses_google_models_endpoint(self):
        response = httpx.Response(
            200,
            json={"models": []},
            request=httpx.Request(
                "GET",
                "https://generativelanguage.googleapis.com/v1beta/models",
            ),
        )

        with patch(
            "fixwise_backend.ai.httpx.AsyncClient",
            return_value=StubAsyncClient(response),
        ):
            asyncio.run(
                validate_ai_api_key(
                    Settings(
                        ai_provider="gemma",
                        gemma_base_url="https://generativelanguage.googleapis.com/v1beta",
                    ),
                    "google-test-key",
                )
            )

    def test_validate_gemma_api_key_rejects_invalid_google_key(self):
        response = httpx.Response(
            400,
            json={"error": {"message": "API key not valid. Please pass a valid API key."}},
            request=httpx.Request(
                "GET",
                "https://generativelanguage.googleapis.com/v1beta/models",
            ),
        )

        with patch(
            "fixwise_backend.ai.httpx.AsyncClient",
            return_value=StubAsyncClient(response),
        ):
            with self.assertRaisesRegex(ValueError, "invalid or revoked"):
                asyncio.run(
                    validate_ai_api_key(
                        Settings(
                            ai_provider="gemma",
                            gemma_base_url="https://generativelanguage.googleapis.com/v1beta",
                        ),
                        "google-test-key",
                    )
                )

    def test_mock_provider_next_step_guidance_is_actionable(self):
        provider = MockAIProvider()

        result = asyncio.run(
                provider.analyze(
                    frame_b64="ZmFrZS1qcGVn",
                    frame_metadata=FrameMetadata(width=512, height=512, sceneDelta=0.11),
                    prompt="What should I do next?",
                    mode="general",
                    session_id="session-1",
                )
            )

        self.assertIn("smallest reversible action", result.text)
        self.assertNotIn("then ask for the next step", result.text.lower())

    def test_mock_provider_generic_frame_guidance_hides_internal_session_details(self):
        provider = MockAIProvider()

        result = asyncio.run(
                provider.analyze(
                    frame_b64="ZmFrZS1qcGVn",
                    frame_metadata=FrameMetadata(width=512, height=512, sceneDelta=0.11),
                    prompt="Can you help with this?",
                    mode="machines",
                    session_id="session-12345678",
                )
            )

        self.assertIn("I can see the area you mean", result.text)
        self.assertNotIn("session", result.text.lower())
        self.assertNotIn("latest frame", result.text.lower())

    def test_mock_provider_closer_frame_guidance_sets_schema_fields(self):
        provider = MockAIProvider()

        result = asyncio.run(
            provider.analyze(
                frame_b64="ZmFrZS1qcGVn",
                frame_metadata=FrameMetadata(width=200, height=200, sceneDelta=0.7),
                prompt="What should I do next?",
                mode="general",
                session_id="session-1",
            )
        )

        self.assertTrue(result.needsCloserFrame)
        self.assertGreater(len(result.followUpPrompts), 0)
        self.assertEqual(result.confidence, "low")


if __name__ == "__main__":
    unittest.main()
