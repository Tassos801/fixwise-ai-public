from __future__ import annotations

import unittest

from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.responses import PlainTextResponse

import test_support  # noqa: F401
from fixwise_backend.app import create_app
from fixwise_backend.config import Settings
from fixwise_backend.security_headers import SecurityHeadersMiddleware


class SecurityHeadersTests(unittest.TestCase):
    def setUp(self):
        self.app = create_app(Settings(ai_mode="mock", environment="development"))

    def test_security_headers_present_on_all_responses(self):
        with TestClient(self.app) as client:
            resp = client.get("/health")

        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(resp.headers["X-Frame-Options"], "DENY")
        self.assertEqual(resp.headers["X-XSS-Protection"], "1; mode=block")
        self.assertEqual(resp.headers["Referrer-Policy"], "strict-origin-when-cross-origin")
        self.assertIn("camera=()", resp.headers["Permissions-Policy"])

    def test_hsts_absent_in_development(self):
        with TestClient(self.app) as client:
            resp = client.get("/health")
        self.assertNotIn("Strict-Transport-Security", resp.headers)

    def test_hsts_present_in_production_middleware(self):
        """Test the middleware directly with environment='production'."""
        mini_app = FastAPI()
        mini_app.add_middleware(SecurityHeadersMiddleware, environment="production")

        @mini_app.get("/ping")
        def ping():
            return PlainTextResponse("pong")

        with TestClient(mini_app) as client:
            resp = client.get("/ping")
        self.assertIn("Strict-Transport-Security", resp.headers)
        self.assertIn("max-age=31536000", resp.headers["Strict-Transport-Security"])

    def test_security_headers_on_error_responses(self):
        with TestClient(self.app) as client:
            resp = client.get("/api/auth/me")  # 401 without token

        self.assertEqual(resp.headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(resp.headers["X-Frame-Options"], "DENY")


if __name__ == "__main__":
    unittest.main()
