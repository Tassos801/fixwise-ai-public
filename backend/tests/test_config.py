from __future__ import annotations

import os
import unittest
from unittest.mock import patch

import test_support  # noqa: F401
from fixwise_backend.app import create_app
from fixwise_backend.config import Settings


class ConfigTests(unittest.TestCase):
    def test_create_app_rejects_missing_production_secrets(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ValueError) as ctx:
                create_app(
                    Settings(
                        environment="production",
                        ai_mode="mock",
                        openai_api_key=None,
                        database_path=":memory:",
                    )
                )

        self.assertIn("FIXWISE_JWT_SECRET", str(ctx.exception))
        self.assertIn("FIXWISE_MASTER_KEY", str(ctx.exception))

    def test_settings_from_env_supports_gemma_provider(self):
        with patch.dict(
            os.environ,
            {
                "FIXWISE_AI_PROVIDER": "gemma",
                "GEMMA_API_KEY": "google-test-key",
                "GEMMA_MODEL": "gemma-4-31b-it",
                "FIXWISE_JWT_SECRET": "x" * 32,
                "FIXWISE_MASTER_KEY": "ab" * 32,
            },
            clear=True,
        ):
            settings = Settings.from_env()

        self.assertEqual(settings.ai_provider, "gemma")
        self.assertEqual(settings.gemma_api_key, "google-test-key")
        self.assertEqual(settings.active_ai_model, "gemma-4-31b-it")
        self.assertEqual(
            settings.active_ai_base_url,
            "https://generativelanguage.googleapis.com/v1beta",
        )


if __name__ == "__main__":
    unittest.main()
