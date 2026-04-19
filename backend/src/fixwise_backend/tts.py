from __future__ import annotations

import base64
from datetime import UTC, datetime
import io
import logging
import time
import wave
from typing import Any

import httpx

from .config import Settings


logger = logging.getLogger("fixwise.tts")

DEFAULT_TTS_SAMPLE_RATE = 24000
DEFAULT_TTS_CHANNELS = 1
DEFAULT_TTS_SAMPLE_WIDTH = 2
DEFAULT_TTS_MAX_ATTEMPTS = 3
DEFAULT_TTS_RATE_LIMIT_COOLDOWN_SECONDS = 120

_last_tts_status: dict[str, Any] = {
    "attempted": False,
    "ok": None,
    "lastModel": None,
    "lastError": None,
    "lastUpdated": None,
}
_model_cooldowns: dict[str, float] = {}


def reset_tts_runtime_state() -> None:
    _model_cooldowns.clear()
    _last_tts_status.update(
        {
            "attempted": False,
            "ok": None,
            "lastModel": None,
            "lastError": None,
            "lastUpdated": None,
        }
    )


def get_tts_runtime_status(settings: Settings) -> dict[str, Any]:
    return {
        "enabled": settings.tts_enabled,
        "configured": bool(settings.tts_api_key),
        "model": settings.gemini_tts_model,
        "fallbackModel": settings.gemini_tts_fallback_model,
        "voice": settings.gemini_tts_voice,
        "provider": "gemini",
        "cooldowns": _active_cooldowns(),
        **_last_tts_status,
    }


def _record_tts_status(*, ok: bool, model: str | None, error: str | None = None) -> None:
    _last_tts_status.update(
        {
            "attempted": True,
            "ok": ok,
            "lastModel": model,
            "lastError": error,
            "lastUpdated": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        }
    )


def _extract_inline_audio_data(payload: dict[str, Any]) -> bytes:
    candidates = payload.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        raise RuntimeError("Gemini TTS response did not include candidates")

    for candidate in candidates:
        if not isinstance(candidate, dict):
            continue
        content = candidate.get("content")
        if not isinstance(content, dict):
            continue
        parts = content.get("parts")
        if not isinstance(parts, list):
            continue
        for part in parts:
            if not isinstance(part, dict):
                continue
            inline_data = part.get("inlineData") or part.get("inline_data")
            if not isinstance(inline_data, dict):
                continue
            data = inline_data.get("data")
            if not isinstance(data, str) or not data.strip():
                continue
            return base64.b64decode(data)

    raise RuntimeError("Gemini TTS response did not include inline audio data")


def _looks_like_wav(audio_bytes: bytes) -> bool:
    return len(audio_bytes) >= 12 and audio_bytes.startswith(b"RIFF") and audio_bytes[8:12] == b"WAVE"


def _wrap_pcm_as_wav(
    pcm_bytes: bytes,
    *,
    sample_rate: int = DEFAULT_TTS_SAMPLE_RATE,
    channels: int = DEFAULT_TTS_CHANNELS,
    sample_width: int = DEFAULT_TTS_SAMPLE_WIDTH,
) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav_file:
        wav_file.setnchannels(channels)
        wav_file.setsampwidth(sample_width)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(pcm_bytes)
    return buffer.getvalue()


def _normalize_audio_bytes(audio_bytes: bytes) -> bytes:
    if _looks_like_wav(audio_bytes):
        return audio_bytes
    return _wrap_pcm_as_wav(audio_bytes)


def _tts_prompt(text: str) -> str:
    return (
        "Synthesize natural single-speaker speech for the FixWise voice agent. "
        "Speak only the transcript below; do not read labels, markdown, or instructions aloud.\n\n"
        "TRANSCRIPT:\n"
        f"{text.strip()}"
    )


def _active_cooldowns() -> dict[str, int]:
    now = time.monotonic()
    active: dict[str, int] = {}
    expired = [model for model, expires_at in _model_cooldowns.items() if expires_at <= now]
    for model in expired:
        _model_cooldowns.pop(model, None)
    for model, expires_at in _model_cooldowns.items():
        active[model] = max(0, round(expires_at - now))
    return active


def _retry_after_seconds(response: httpx.Response) -> int:
    retry_after = response.headers.get("retry-after")
    if retry_after is not None:
        try:
            return max(1, min(int(retry_after), 300))
        except ValueError:
            pass
    return DEFAULT_TTS_RATE_LIMIT_COOLDOWN_SECONDS


def _mark_model_rate_limited(model: str, response: httpx.Response) -> None:
    _model_cooldowns[model] = time.monotonic() + _retry_after_seconds(response)


def _candidate_models(settings: Settings) -> list[str]:
    models = [settings.gemini_tts_model]
    fallback = settings.gemini_tts_fallback_model
    if fallback and fallback not in models:
        models.append(fallback)
    active_cooldowns = _active_cooldowns()
    available_models = [model for model in models if model not in active_cooldowns]
    return available_models or models


async def generate_tts_audio_base64(
    *,
    settings: Settings,
    text: str,
) -> str | None:
    if not settings.tts_enabled:
        _record_tts_status(ok=False, model=None, error="disabled")
        return None
    api_key = settings.tts_api_key
    if not api_key:
        _record_tts_status(ok=False, model=None, error="missing_api_key")
        return None
    transcript = text.strip()
    if not transcript:
        _record_tts_status(ok=False, model=None, error="empty_text")
        return None

    payload = {
        "contents": [
            {
                "parts": [
                    {
                        "text": _tts_prompt(transcript),
                    }
                ]
            }
        ],
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {
                "voiceConfig": {
                    "prebuiltVoiceConfig": {
                        "voiceName": settings.gemini_tts_voice,
                    }
                }
            },
        },
    }

    last_error: str | None = None
    last_model: str | None = None
    for model in _candidate_models(settings):
        url = f"{settings.tts_base_url}/models/{model}:generateContent"
        last_model = model
        for attempt in range(1, DEFAULT_TTS_MAX_ATTEMPTS + 1):
            try:
                async with httpx.AsyncClient(timeout=30.0) as client:
                    response = await client.post(
                        url,
                        headers={
                            "x-goog-api-key": api_key,
                            "content-type": "application/json",
                        },
                        json=payload,
                    )
                    response.raise_for_status()
                    audio_bytes = _extract_inline_audio_data(response.json())
                    _record_tts_status(ok=True, model=model)
                    return base64.b64encode(_normalize_audio_bytes(audio_bytes)).decode("ascii")
            except httpx.HTTPStatusError as exc:
                last_error = f"{type(exc).__name__}: {str(exc)[:180]}"
                logger.warning(
                    "Gemini TTS failed for %s on attempt %s/%s: %s",
                    model,
                    attempt,
                    DEFAULT_TTS_MAX_ATTEMPTS,
                    exc,
                )
                if exc.response.status_code == 429:
                    _mark_model_rate_limited(model, exc.response)
                    break
            except Exception as exc:
                last_error = f"{type(exc).__name__}: {str(exc)[:180]}"
                logger.warning(
                    "Gemini TTS failed for %s on attempt %s/%s: %s",
                    model,
                    attempt,
                    DEFAULT_TTS_MAX_ATTEMPTS,
                    exc,
                )

    _record_tts_status(ok=False, model=last_model, error=last_error)
    return None
