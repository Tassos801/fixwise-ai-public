from __future__ import annotations

import os
from dataclasses import dataclass


VALID_AI_MODES = {"auto", "mock", "live"}


def _parse_allowed_origins(raw: str | None) -> tuple[str, ...]:
    if not raw:
        return ("http://localhost:3000", "http://localhost:5173")
    origins = [origin.strip() for origin in raw.split(",") if origin.strip()]
    return tuple(origins) or ("http://localhost:3000", "http://localhost:5173")


@dataclass(frozen=True)
class Settings:
    app_name: str = "FixWise AI"
    app_version: str = "0.2.0"
    desired_ai_mode: str = "auto"
    openai_api_key: str | None = None
    openai_model: str = "gpt-4o-mini"
    allowed_origins: tuple[str, ...] = ("http://localhost:3000", "http://localhost:5173")

    @classmethod
    def from_env(cls) -> "Settings":
        desired_mode = (os.getenv("FIXWISE_AI_MODE") or "auto").strip().lower()
        if desired_mode not in VALID_AI_MODES:
            desired_mode = "auto"

        return cls(
            desired_ai_mode=desired_mode,
            openai_api_key=(os.getenv("OPENAI_API_KEY") or "").strip() or None,
            openai_model=(
                os.getenv("FIXWISE_OPENAI_MODEL")
                or os.getenv("OPENAI_MODEL")
                or "gpt-4o-mini"
            ).strip()
            or "gpt-4o-mini",
            allowed_origins=_parse_allowed_origins(os.getenv("FIXWISE_ALLOWED_ORIGINS")),
        )

    @property
    def live_configured(self) -> bool:
        return bool(self.openai_api_key)

    @property
    def effective_ai_mode(self) -> str:
        if self.desired_ai_mode == "mock":
            return "mock"
        if self.live_configured:
            return "live"
        return "mock"
