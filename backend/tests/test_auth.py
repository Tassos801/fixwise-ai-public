from __future__ import annotations

import unittest

from fastapi.testclient import TestClient

import test_support  # noqa: F401
from fixwise_backend.app import create_app
from fixwise_backend.config import Settings


class AuthTests(unittest.TestCase):
    """Test registration, login, and token flows."""

    def setUp(self):
        self.app = create_app(Settings(ai_mode="mock", openai_api_key=None))
        self.client = TestClient(self.app)

    def test_register_creates_user_and_returns_tokens(self):
        with self.client:
            resp = self.client.post("/api/auth/register", json={
                "email": "test@example.com",
                "password": "securepass123",
                "display_name": "Test User",
            })

        self.assertEqual(resp.status_code, 200)
        data = resp.json()
        self.assertIn("access_token", data)
        self.assertIn("refresh_token", data)
        self.assertEqual(data["user"]["email"], "test@example.com")
        self.assertEqual(data["user"]["display_name"], "Test User")
        self.assertEqual(data["user"]["displayName"], "Test User")
        self.assertEqual(data["user"]["tier"], "free")

    def test_register_duplicate_email_returns_409(self):
        with self.client:
            self.client.post("/api/auth/register", json={
                "email": "dup@example.com",
                "password": "securepass123",
            })
            resp = self.client.post("/api/auth/register", json={
                "email": "dup@example.com",
                "password": "differentpass123",
            })

        self.assertEqual(resp.status_code, 409)

    def test_login_with_valid_credentials(self):
        with self.client:
            self.client.post("/api/auth/register", json={
                "email": "login@example.com",
                "password": "securepass123",
            })
            resp = self.client.post("/api/auth/login", json={
                "email": "login@example.com",
                "password": "securepass123",
            })

        self.assertEqual(resp.status_code, 200)
        self.assertIn("access_token", resp.json())

    def test_login_with_wrong_password_returns_401(self):
        with self.client:
            self.client.post("/api/auth/register", json={
                "email": "wrong@example.com",
                "password": "securepass123",
            })
            resp = self.client.post("/api/auth/login", json={
                "email": "wrong@example.com",
                "password": "wrongpassword1",
            })

        self.assertEqual(resp.status_code, 401)

    def test_me_endpoint_with_valid_token(self):
        with self.client:
            reg = self.client.post("/api/auth/register", json={
                "email": "me@example.com",
                "password": "securepass123",
                "display_name": "Me User",
            })
            token = reg.json()["access_token"]
            resp = self.client.get("/api/auth/me", headers={
                "Authorization": f"Bearer {token}",
            })

        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json()["email"], "me@example.com")
        self.assertEqual(resp.json()["display_name"], "Me User")
        self.assertEqual(resp.json()["displayName"], "Me User")

    def test_me_endpoint_without_token_returns_401(self):
        with self.client:
            resp = self.client.get("/api/auth/me")

        self.assertEqual(resp.status_code, 401)


if __name__ == "__main__":
    unittest.main()
