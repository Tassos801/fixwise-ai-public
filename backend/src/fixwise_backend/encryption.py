"""
AES-256-GCM encryption for BYOK API key storage.
Each user gets a derived key via HKDF from the server master key + user ID.
"""
from __future__ import annotations

import os

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes


# Master key: 32 bytes from environment or a secure default for development.
# MUST be set via env var in production.
_MASTER_KEY_HEX = os.getenv("FIXWISE_MASTER_KEY")

def _get_master_key() -> bytes:
    if _MASTER_KEY_HEX:
        return bytes.fromhex(_MASTER_KEY_HEX)
    # Dev fallback — deterministic but obviously not secure
    return b"fixwise-dev-master-key-not-for-prod!"[:32]


def _derive_user_key(user_id: str) -> bytes:
    """Derive a per-user 256-bit key using HKDF(SHA-256)."""
    hkdf = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=None,
        info=f"fixwise-byok-{user_id}".encode(),
    )
    return hkdf.derive(_get_master_key())


def encrypt_api_key(user_id: str, plaintext_key: str) -> bytes:
    """
    Encrypt an API key with AES-256-GCM using a per-user derived key.
    Returns: nonce (12 bytes) + ciphertext (variable length).
    """
    derived_key = _derive_user_key(user_id)
    aesgcm = AESGCM(derived_key)
    nonce = os.urandom(12)  # 96-bit nonce for GCM
    ciphertext = aesgcm.encrypt(nonce, plaintext_key.encode("utf-8"), None)
    return nonce + ciphertext


def decrypt_api_key(user_id: str, encrypted_blob: bytes) -> str:
    """
    Decrypt an API key from its nonce + ciphertext blob.
    Raises cryptography.exceptions.InvalidTag if tampered.
    """
    derived_key = _derive_user_key(user_id)
    aesgcm = AESGCM(derived_key)
    nonce = encrypted_blob[:12]
    ciphertext = encrypted_blob[12:]
    plaintext = aesgcm.decrypt(nonce, ciphertext, None)
    return plaintext.decode("utf-8")


def mask_api_key(key: str) -> str:
    """Create a safe display mask: 'sk-proj-...abc123'."""
    if len(key) < 12:
        return "sk-***"
    return f"{key[:7]}...{key[-6:]}"
