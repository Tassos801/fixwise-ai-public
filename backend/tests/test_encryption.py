from __future__ import annotations

import unittest

import test_support  # noqa: F401
from fixwise_backend.encryption import decrypt_api_key, encrypt_api_key, mask_api_key


class EncryptionTests(unittest.TestCase):
    """Test BYOK key encryption/decryption and masking."""

    def test_encrypt_decrypt_roundtrip(self):
        user_id = "user-123"
        key = "sk-proj-abc123xyz456def789ghi012jkl345mno678pqr901"

        encrypted = encrypt_api_key(user_id, key)
        decrypted = decrypt_api_key(user_id, encrypted)

        self.assertEqual(decrypted, key)

    def test_different_users_get_different_ciphertext(self):
        key = "sk-proj-abc123xyz456def789ghi012jkl345mno678pqr901"

        encrypted_a = encrypt_api_key("user-a", key)
        encrypted_b = encrypt_api_key("user-b", key)

        self.assertNotEqual(encrypted_a, encrypted_b)

    def test_wrong_user_cannot_decrypt(self):
        key = "sk-proj-abc123xyz456def789ghi012jkl345mno678pqr901"
        encrypted = encrypt_api_key("user-a", key)

        with self.assertRaises(Exception):
            decrypt_api_key("user-b", encrypted)

    def test_mask_api_key_format(self):
        key = "sk-proj-abc123xyz456def789ghi012jkl345mno678pqr901"
        masked = mask_api_key(key)

        self.assertTrue(masked.startswith("sk-proj"))
        self.assertTrue(masked.endswith("qr901"))
        self.assertIn("...", masked)
        self.assertNotEqual(masked, key)

    def test_mask_short_key(self):
        masked = mask_api_key("sk-short")
        self.assertEqual(masked, "sk-***")


if __name__ == "__main__":
    unittest.main()
