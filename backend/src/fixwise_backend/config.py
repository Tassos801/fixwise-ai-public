from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

logger = logging.getLogger("fixwise")


DEFAULT_ALLOWED_ORIGINS = (
    "http://localhost:3000",
    "http://localhost:5173",
)
VALID_AI_MODES = {"auto", "mock", "live"}
VALID_AI_PROVIDERS = {"openai", "gemma"}
DEFAULT_DATABASE_PATH = str(Path(__file__).resolve().parents[2] / "fixwise.db")
DEFAULT_GEMMA_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
DEV_JWT_SECRET = "dev-secret-change-in-production-local"
MIN_JWT_SECRET_LENGTH = 32
MIN_MASTER_KEY_BYTES = 32


def _int_env(name: str, default: int, minimum: int = 1) -> int:
    raw_value = os.getenv(name)
    if raw_value is None:
        return default

    try:
        parsed = int(raw_value)
    except ValueError:
        return default

    return max(minimum, parsed)


@dataclass(frozen=True)
class Settings:
    app_name: str = "FixWise AI"
    app_version: str = "0.2.0"
    allowed_origins: tuple[str, ...] = DEFAULT_ALLOWED_ORIGINS
    ai_mode: str = "auto"
    ai_provider: str = "openai"
    openai_api_key: str | None = None
    openai_model: str = "gpt-4o-mini"
    openai_base_url: str | None = None
    gemma_api_key: str | None = None
    gemma_model: str = "gemma-4-31b-it"
    gemma_base_url: str = DEFAULT_GEMMA_BASE_URL
    environment: str = "development"
    database_path: str | None = None
    rate_limit_window_seconds: int = 60
    auth_rate_limit_requests: int = 10
    settings_rate_limit_requests: int = 30
    session_rate_limit_requests: int = 60
    websocket_connect_rate_limit_requests: int = 20
    websocket_prompt_rate_limit_requests: int = 12

    @property
    def active_ai_api_key(self) -> str | None:
        if self.ai_provider == "gemma":
            return self.gemma_api_key
        return self.openai_api_key

    @property
    def active_ai_model(self) -> str:
        if self.ai_provider == "gemma":
            return self.gemma_model
        return self.openai_model

    @property
    def active_ai_base_url(self) -> str | None:
        if self.ai_provider == "gemma":
            return (self.gemma_base_url or DEFAULT_GEMMA_BASE_URL).rstrip("/")
        return self.openai_base_url

    def validate(self) -> None:
        """Validate security-critical settings.

        In production, raises ValueError for missing or insecure values.
        In development, logs warnings instead.
        """
        is_prod = self.environment == "production"
        jwt_secret = os.getenv("FIXWISE_JWT_SECRET")
        master_key = os.getenv("FIXWISE_MASTER_KEY")

        issues: list[str] = []

        if not jwt_secret or jwt_secret == DEV_JWT_SECRET:
            issues.append(
                "FIXWISE_JWT_SECRET is not set or is using the dev default"
            )
        elif len(jwt_secret) < MIN_JWT_SECRET_LENGTH:
            issues.append(
                f"FIXWISE_JWT_SECRET must be at least {MIN_JWT_SECRET_LENGTH} characters"
            )

        if not master_key:
            issues.append("FIXWISE_MASTER_KEY is not set")
        else:
            try:
                master_key_bytes = bytes.fromhex(master_key)
            except ValueError:
                issues.append("FIXWISE_MASTER_KEY must be valid hexadecimal")
            else:
                if len(master_key_bytes) < MIN_MASTER_KEY_BYTES:
                    issues.append(
                        f"FIXWISE_MASTER_KEY must be at least {MIN_MASTER_KEY_BYTES} bytes"
                    )

        if not issues:
            return

        if is_prod:
            raise ValueError(
                "Production configuration errors: " + "; ".join(issues)
            )

        for issue in issues:
            logger.warning("Security config warning: %s", issue)

    @classmethod
    def from_env(cls) -> "Settings":
        raw_origins = (
            os.getenv("CORS_ORIGINS")
            or os.getenv("FIXWISE_ALLOWED_ORIGINS")
            or ",".join(DEFAULT_ALLOWED_ORIGINS)
        )
        allowed_origins = tuple(
            origin.strip()
            for origin in raw_origins.split(",")
            if origin.strip()
        ) or DEFAULT_ALLOWED_ORIGINS

        ai_mode = os.getenv("FIXWISE_AI_MODE", "auto").strip().lower()
        if ai_mode not in VALID_AI_MODES:
            ai_mode = "auto"

        ai_provider = (
            os.getenv("FIXWISE_AI_PROVIDER")
            or os.getenv("AI_PROVIDER")
            or "openai"
        ).strip().lower()
        if ai_provider not in VALID_AI_PROVIDERS:
            ai_provider = "openai"

        return cls(
            allowed_origins=allowed_origins,
            ai_mode=ai_mode,
            ai_provider=ai_provider,
            openai_api_key=(os.getenv("OPENAI_API_KEY") or "").strip() or None,
            openai_model=(
                os.getenv("OPENAI_MODEL")
                or os.getenv("FIXWISE_OPENAI_MODEL")
                or "gpt-4o-mini"
            ).strip()
            or "gpt-4o-mini",
            openai_base_url=(os.getenv("OPENAI_BASE_URL") or "").strip() or None,
            gemma_api_key=(
                os.getenv("GEMMA_API_KEY")
                or os.getenv("GOOGLE_API_KEY")
                or os.getenv("GEMINI_API_KEY")
                or ""
            ).strip()
            or None,
            gemma_model=(
                os.getenv("GEMMA_MODEL")
                or os.getenv("FIXWISE_GEMMA_MODEL")
                or "gemma-4-31b-it"
            ).strip()
            or "gemma-4-31b-it",
            gemma_base_url=(
                os.getenv("GEMMA_BASE_URL")
                or os.getenv("FIXWISE_GEMMA_BASE_URL")
                or DEFAULT_GEMMA_BASE_URL
            ).strip()
            .rstrip("/")
            or DEFAULT_GEMMA_BASE_URL,
            environment=os.getenv("FIXWISE_ENVIRONMENT", "development").strip()
            or "development",
            database_path=(
                os.getenv("FIXWISE_DATABASE_PATH", DEFAULT_DATABASE_PATH).strip()
                or DEFAULT_DATABASE_PATH
            ),
            rate_limit_window_seconds=_int_env("FIXWISE_RATE_LIMIT_WINDOW_SECONDS", 60),
            auth_rate_limit_requests=_int_env("FIXWISE_AUTH_RATE_LIMIT_REQUESTS", 10),
            settings_rate_limit_requests=_int_env("FIXWISE_SETTINGS_RATE_LIMIT_REQUESTS", 30),
            session_rate_limit_requests=_int_env("FIXWISE_SESSION_RATE_LIMIT_REQUESTS", 60),
            websocket_connect_rate_limit_requests=_int_env(
                "FIXWISE_WS_CONNECT_RATE_LIMIT_REQUESTS", 20
            ),
            websocket_prompt_rate_limit_requests=_int_env(
                "FIXWISE_WS_PROMPT_RATE_LIMIT_REQUESTS", 12
            ),
        )


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings.from_env()
