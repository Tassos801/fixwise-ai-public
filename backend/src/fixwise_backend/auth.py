"""
JWT-based authentication for FixWise API.
Handles registration, login, and token verification.
"""
from __future__ import annotations

import hashlib
import hmac
import logging
import os
import secrets
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import jwt
from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, EmailStr, Field

from .config import DEV_JWT_SECRET
from .database import Database


# ── Configuration ──────────────────────────────────────────

JWT_ALGORITHM = "HS256"
JWT_MIN_KEY_LENGTH = 32
ACCESS_TOKEN_EXPIRE_MINUTES = 60
REFRESH_TOKEN_EXPIRE_DAYS = 7
logger = logging.getLogger("fixwise.auth")


def _get_jwt_secret() -> str:
    """Return the JWT secret, falling back to the dev default only in non-prod."""
    secret = os.getenv("FIXWISE_JWT_SECRET") or DEV_JWT_SECRET
    if len(secret) < JWT_MIN_KEY_LENGTH:
        logger.warning(
            "JWT secret is shorter than %d characters; "
            "use a longer secret in production.",
            JWT_MIN_KEY_LENGTH,
        )
    return secret


# ── Request / Response Models ──────────────────────────────

class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    display_name: str | None = None


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class AuthResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int
    user: UserInfo


class UserInfo(BaseModel):
    id: str
    email: str
    display_name: str | None
    tier: str


class RefreshRequest(BaseModel):
    refresh_token: str


# ── Password Hashing ──────────────────────────────────────

def hash_password(password: str) -> str:
    """Hash password with PBKDF2-SHA256. Returns salt:hash."""
    salt = secrets.token_hex(16)
    key = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), iterations=100_000)
    return f"{salt}:{key.hex()}"


def verify_password(password: str, stored_hash: str) -> bool:
    """Verify password against stored salt:hash."""
    try:
        salt, key_hex = stored_hash.split(":")
        expected = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), iterations=100_000)
        return hmac.compare_digest(expected, bytes.fromhex(key_hex))
    except (ValueError, AttributeError):
        return False


# ── JWT Token Operations ──────────────────────────────────

def create_access_token(user_id: str, email: str) -> str:
    expire = datetime.now(UTC) + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    payload = {
        "sub": user_id,
        "email": email,
        "exp": expire,
        "type": "access",
    }
    return jwt.encode(payload, _get_jwt_secret(), algorithm=JWT_ALGORITHM)


def create_refresh_token(user_id: str) -> str:
    expire = datetime.now(UTC) + timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS)
    payload = {
        "sub": user_id,
        "exp": expire,
        "type": "refresh",
        "jti": secrets.token_hex(16),
    }
    return jwt.encode(payload, _get_jwt_secret(), algorithm=JWT_ALGORITHM)


def decode_token(token: str) -> dict:
    """Decode and validate a JWT token. Raises HTTPException on failure."""
    try:
        payload = jwt.decode(token, _get_jwt_secret(), algorithms=[JWT_ALGORITHM])
        return payload
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token has expired.")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid token.")


# ── FastAPI Dependencies ──────────────────────────────────

security = HTTPBearer(auto_error=False)


async def get_current_user_id(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(security),
) -> str:
    """Extract and validate user ID from Bearer token.
    Returns 'anonymous' if no token provided (for gradual auth rollout)."""
    token = credentials.credentials if credentials else request.query_params.get("token")
    if token is None:
        return "anonymous"

    payload = decode_token(token)
    if payload.get("type") != "access":
        raise HTTPException(status_code=401, detail="Invalid token type.")
    return payload["sub"]


async def require_auth(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(security),
) -> str:
    """Strict auth — requires a valid token. Returns user_id."""
    token = credentials.credentials if credentials else request.query_params.get("token")
    if token is None:
        raise HTTPException(status_code=401, detail="Authentication required.")

    payload = decode_token(token)
    if payload.get("type") != "access":
        raise HTTPException(status_code=401, detail="Invalid token type.")
    return payload["sub"]


# ── Auth Route Handlers ───────────────────────────────────

async def register_user(req: RegisterRequest, db: Database) -> AuthResponse:
    """Register a new user account."""
    existing = await db.get_user_by_email(req.email)
    if existing:
        raise HTTPException(status_code=409, detail="An account with this email already exists.")

    user_id = str(uuid4())
    password_hash = hash_password(req.password)

    user = await db.create_user(
        user_id=user_id,
        email=req.email,
        password_hash=password_hash,
        display_name=req.display_name,
    )

    access_token = create_access_token(user.id, user.email)
    refresh_token = create_refresh_token(user.id)

    return AuthResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        user=UserInfo(
            id=user.id,
            email=user.email,
            display_name=user.display_name,
            tier=user.tier,
        ),
    )


async def login_user(req: LoginRequest, db: Database) -> AuthResponse:
    """Authenticate an existing user."""
    user = await db.get_user_by_email(req.email)
    if not user or not verify_password(req.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid email or password.")

    access_token = create_access_token(user.id, user.email)
    refresh_token = create_refresh_token(user.id)

    return AuthResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        user=UserInfo(
            id=user.id,
            email=user.email,
            display_name=user.display_name,
            tier=user.tier,
        ),
    )


async def refresh_tokens(req: RefreshRequest, db: Database) -> AuthResponse:
    """Issue new tokens from a valid refresh token."""
    payload = decode_token(req.refresh_token)
    if payload.get("type") != "refresh":
        raise HTTPException(status_code=401, detail="Invalid token type for refresh.")

    user_id = payload["sub"]
    user = await db.get_user_by_id(user_id)
    if not user:
        raise HTTPException(status_code=401, detail="User not found.")

    access_token = create_access_token(user.id, user.email)
    refresh_token = create_refresh_token(user.id)

    return AuthResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        user=UserInfo(
            id=user.id,
            email=user.email,
            display_name=user.display_name,
            tier=user.tier,
        ),
    )
