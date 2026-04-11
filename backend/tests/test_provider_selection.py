from __future__ import annotations

import unittest

import test_support  # noqa: F401
from fixwise_backend.ai import (
    MockAIProvider,
    OpenAIVisionProvider,
    UnavailableAIProvider,
    build_ai_provider,
)
from fixwise_backend.config import Settings


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

    def test_live_mode_without_key_uses_unavailable_provider(self):
        provider = build_ai_provider(
            Settings(ai_mode="live", openai_api_key=None)
        )
        self.assertIsInstance(provider, UnavailableAIProvider)


if __name__ == "__main__":
    unittest.main()
