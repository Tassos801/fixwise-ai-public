from __future__ import annotations

from src.services.guidance import (
    MockGuidanceProvider,
    OpenAIGuidanceProvider,
    build_guidance_service,
)
from src.utils.config import Settings


def build_guidance_provider(settings: Settings):
    return build_guidance_service(settings).provider


__all__ = [
    "MockGuidanceProvider",
    "OpenAIGuidanceProvider",
    "build_guidance_provider",
]
