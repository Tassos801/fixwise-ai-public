from __future__ import annotations

import base64
import io
import logging
import wave
from typing import Any

import httpx

from .config import Settings


logger = logging.getLogger("fixwise.tts")

DEFAULT_TTS_SAMPLE_RATE = 24000
DEFAULT_TTS_CHANNELS = 1
DEFAULT_TTS_SAMPLE_WIDTH = 2


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


async def generate_tts_audio_base64(
    *,
    settings: Settings,
    text: str,
) -> str | None:
    if not settings.tts_enabled:
        return None
    api_key = settings.tts_api_key
    if not api_key:
        return None
    if not text.strip():
        return None

    url = f"{settings.tts_base_url}/models/{settings.gemini_tts_model}:generateContent"
    payload = {
        "contents": [
            {
                "parts": [
                    {
                        "text": text,
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
            return base64.b64encode(_normalize_audio_bytes(audio_bytes)).decode("ascii")
    except Exception as exc:
        logger.warning("Gemini TTS failed: %s", exc)
        return None
