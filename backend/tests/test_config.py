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


if __name__ == "__main__":
    unittest.main()
