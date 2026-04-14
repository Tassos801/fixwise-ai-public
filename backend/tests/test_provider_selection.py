from __future__ import annotations

import asyncio
import unittest
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


class StubAsyncClient:
    def __init__(self, response: httpx.Response) -> None:
        self.response = response

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, tb):
        return False

    async def get(self, *args, **kwargs):
        return self.response

    async def post(self, *args, **kwargs):
        return self.response


class ProviderSelectionTests(unittest.TestCase):
    def test_auto_mode_without_key_uses_mock(self):
        provider = build_ai_provider(
            Settings(ai_mode="auto", openai_api_key=None)
        )
        self.assertIsInstance(provider, MockAIProvider)

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

        with patch(
            "fixwise_backend.ai.httpx.AsyncClient",
            return_value=StubAsyncClient(response),
        ):
            result = asyncio.run(
                provider.analyze(
                    frame_b64="ZmFrZS1qcGVn",
                    prompt="What should I do next?",
                    session_id="session-1",
                )
            )

        self.assertEqual(result.text, "Tighten the bracket gently.")

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
                prompt="What should I do next?",
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
                prompt="Can you help with this?",
                session_id="session-12345678",
            )
        )

        self.assertIn("I can see the area you mean", result.text)
        self.assertNotIn("session", result.text.lower())
        self.assertNotIn("latest frame", result.text.lower())


if __name__ == "__main__":
    unittest.main()
