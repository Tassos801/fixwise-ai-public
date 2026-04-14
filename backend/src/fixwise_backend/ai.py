from __future__ import annotations

import json
import logging
from typing import Any, Protocol

import httpx

from .config import Settings
from .models import AIResponse, AnnotationData


logger = logging.getLogger("fixwise.ai")

SYSTEM_PROMPT = """You are FixWise AI, a helpful visual assistant. You can see what the user's camera sees.

ALWAYS answer the user's question directly and helpfully. Never refuse. Never say you cannot assist. If you see something in the image, describe it and help with whatever the user asks.

You help with ANY task: repairs, identification, cooking, cleaning, tech, gardening, cars, anything the user points their camera at. If relevant, mention safety tips briefly but always provide the answer first.

Keep your text response short (1-3 sentences) since it will be spoken aloud.

Return valid JSON with this shape:
{
  "text": "your helpful spoken answer",
  "annotations": [
    {
      "type": "circle|arrow|label|bounding_box",
      "label": "Description",
      "x": 0.0,
      "y": 0.0,
      "radius": 0.0,
      "color": "#FF6B35",
      "from": { "x": 0.0, "y": 0.0 },
      "to": { "x": 0.0, "y": 0.0 }
    }
  ],
  "safetyWarning": null
}
"""


def _normalize_annotations(parsed: dict[str, Any]) -> None:
    """Normalize annotation coordinates to 0-1 range if the model returned pixel values."""
    annotations = parsed.get("annotations")
    if not isinstance(annotations, list):
        return
    for ann in annotations:
        if not isinstance(ann, dict):
            continue
        for key in ("x", "y", "radius"):
            val = ann.get(key)
            if isinstance(val, (int, float)) and val > 1.0:
                ann[key] = min(val / 1000.0, 1.0)
        for point_key in ("from", "to"):
            point = ann.get(point_key)
            if isinstance(point, dict):
                for coord in ("x", "y"):
                    val = point.get(coord)
                    if isinstance(val, (int, float)) and val > 1.0:
                        point[coord] = min(val / 1000.0, 1.0)


class ProviderConfigurationError(RuntimeError):
    """Raised when live AI is requested without the required configuration."""


class AIProvider(Protocol):
    async def analyze(
        self,
        *,
        frame_b64: str | None,
        prompt: str,
        session_id: str,
    ) -> AIResponse: ...

    @property
    def provider_name(self) -> str: ...


class MockAIProvider:
    def _contains_any(self, text: str, phrases: tuple[str, ...]) -> bool:
        return any(phrase in text for phrase in phrases)

    @property
    def provider_name(self) -> str:
        return "mock"

    async def analyze(
        self,
        *,
        frame_b64: str | None,
        prompt: str,
        session_id: str,
    ) -> AIResponse:
        lower = prompt.lower()
        asks_next_step = self._contains_any(
            lower,
            (
                "next step",
                "what should i do",
                "what do i do",
                "what now",
                "where do i start",
                "how do i start",
            ),
        )
        asks_identification = self._contains_any(
            lower,
            (
                "what am i looking at",
                "what is this",
                "what is that",
                "what part is this",
            ),
        )
        asks_safety = self._contains_any(
            lower,
            (
                "is this safe",
                "anything unsafe",
                "is it dangerous",
                "safe to",
                "dangerous",
            ),
        )
        asks_tools = self._contains_any(
            lower,
            (
                "what tools",
                "which tools",
                "tool do i need",
                "tool should i use",
            ),
        )
        if "valve" in lower:
            annotations = [
                AnnotationData(
                    type="circle",
                    label="Valve",
                    x=0.45,
                    y=0.62,
                    radius=0.08,
                    color="#FF6B35",
                )
            ]
            text = "I highlighted the valve. Turn it counterclockwise slowly and stop if you feel unusual resistance."
        elif "cable" in lower or "plug" in lower:
            annotations = [
                AnnotationData(
                    type="arrow",
                    label="Connect here",
                    color="#00D4AA",
                    from_={"x": 0.30, "y": 0.45},
                    to={"x": 0.56, "y": 0.62},
                )
            ]
            text = "I marked the connection point. Line the cable up gently before pressing it into place."
        elif asks_safety:
            annotations = [
                AnnotationData(
                    type="label",
                    label="Safety check",
                    x=0.5,
                    y=0.18,
                    color="#D97706",
                )
            ]
            text = (
                "I do not see an obvious emergency from this view, but stay cautious. "
                "Before touching anything, cut power or ignition if possible, keep clear of pinch points, "
                "and use eye protection if debris could move."
            )
        elif asks_tools:
            annotations = [
                AnnotationData(
                    type="label",
                    label="Get ready",
                    x=0.5,
                    y=0.2,
                    color="#2563EB",
                )
            ]
            text = (
                "Start with a flashlight and the simplest hand tool that fits the fastener cleanly. "
                "Keep a small tray for loose parts, and avoid forcing anything if the tool fit feels sloppy."
            )
        elif asks_next_step:
            annotations = [
                AnnotationData(
                    type="label",
                    label="Start here",
                    x=0.5,
                    y=0.35,
                    color="#2B6CB0",
                )
            ]
            text = (
                "I can see the workspace. Start with the smallest reversible action: move a little closer to the exact "
                "part you want to touch, hold the phone steady, and inspect the fastener or connector before moving it. "
                "If you want, ask whether this is the right part, whether it looks safe, or what tool to use next."
            )
        elif asks_identification:
            annotations = [
                AnnotationData(
                    type="label",
                    label="Move closer",
                    x=0.5,
                    y=0.35,
                    color="#2B6CB0",
                )
            ]
            text = (
                "I can see the general workspace, but I need a closer view of the exact part to identify it well. "
                "Center the component you care about and keep the phone still for a second."
            )
        elif frame_b64:
            annotations = [
                AnnotationData(
                    type="label",
                    label="Focus area",
                    x=0.5,
                    y=0.2,
                    color="#2B6CB0",
                )
            ]
            text = (
                "I can see the area you mean. "
                "Keep the camera steady on the exact part you want help with, and I will guide you through the next small step."
            )
        else:
            annotations = []
            text = "I do not have a frame yet. Point the camera at the task area, then ask your question again."

        return AIResponse(text=text, annotations=annotations, safetyWarning=None)


class UnavailableAIProvider:
    def __init__(self, message: str) -> None:
        self._message = message

    @property
    def provider_name(self) -> str:
        return "unavailable"

    async def analyze(
        self,
        *,
        frame_b64: str | None,
        prompt: str,
        session_id: str,
    ) -> AIResponse:
        raise RuntimeError(self._message)


def _coerce_json_payload(raw_content: str, *, provider_name: str) -> dict[str, Any]:
    cleaned = raw_content.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.strip("`")
        if "\n" in cleaned:
            cleaned = cleaned.split("\n", 1)[1]
        if cleaned.endswith("```"):
            cleaned = cleaned[:-3]
        cleaned = cleaned.strip()

    start = cleaned.find("{")
    end = cleaned.rfind("}")
    candidate = cleaned[start : end + 1] if start != -1 and end > start else cleaned

    try:
        parsed = json.loads(candidate)
    except json.JSONDecodeError:
        # Try to salvage truncated JSON — extract the text field at minimum
        parsed = _salvage_truncated_json(cleaned)
        if parsed is None:
            # Last resort: return the raw text as the response
            return {"text": cleaned, "annotations": [], "safetyWarning": None}

    if not isinstance(parsed, dict):
        return {"text": str(parsed), "annotations": [], "safetyWarning": None}

    return parsed


def _salvage_truncated_json(raw: str) -> dict[str, Any] | None:
    """Try to extract at least the 'text' field from truncated JSON."""
    import re
    match = re.search(r'"text"\s*:\s*"((?:[^"\\]|\\.)*)"', raw)
    if match:
        return {"text": match.group(1), "annotations": [], "safetyWarning": None}
    return None


def _provider_error_message(response: httpx.Response, *, fallback: str) -> str:
    try:
        payload = response.json()
    except ValueError:
        return fallback

    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict):
            message = error.get("message")
            if isinstance(message, str) and message.strip():
                return message.strip()
        message = payload.get("message")
        if isinstance(message, str) and message.strip():
            return message.strip()

    return fallback


def _gemma_text_from_response(payload: dict[str, Any]) -> str:
    candidates = payload.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        raise RuntimeError("Gemma response did not include candidates")

    content = candidates[0].get("content")
    if not isinstance(content, dict):
        raise RuntimeError("Gemma response was missing content")

    parts = content.get("parts")
    if not isinstance(parts, list):
        raise RuntimeError("Gemma response did not include parts")

    text_parts = [
        part.get("text", "")
        for part in parts
        if isinstance(part, dict)
        and isinstance(part.get("text"), str)
        and not part.get("thought")  # Skip Gemma 4 thinking/reasoning parts
    ]
    raw_content = "".join(text_parts).strip()
    if not raw_content:
        raise RuntimeError("Gemma response did not include text output")

    return raw_content


class OpenAIVisionProvider:
    def __init__(self, *, api_key: str, model: str, base_url: str | None = None) -> None:
        from openai import AsyncOpenAI

        self._client = AsyncOpenAI(api_key=api_key, base_url=base_url)
        self._model = model

    @property
    def provider_name(self) -> str:
        return "openai"

    async def analyze(
        self,
        *,
        frame_b64: str | None,
        prompt: str,
        session_id: str,
    ) -> AIResponse:
        content: list[dict[str, Any]] = [{"type": "text", "text": prompt}]
        if frame_b64:
            content.insert(
                0,
                {
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:image/jpeg;base64,{frame_b64}",
                        "detail": "low",
                    },
                },
            )

        completion = await self._client.chat.completions.create(
            model=self._model,
            response_format={"type": "json_object"},
            max_tokens=600,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": content},
            ],
        )

        raw_content = completion.choices[0].message.content or "{}"
        parsed = _coerce_json_payload(raw_content, provider_name="OpenAI")
        return AIResponse.model_validate(parsed)


GEMMA_FALLBACK_MODELS = ["gemini-2.5-flash-lite", "gemini-2.0-flash", "gemini-2.0-flash-lite"]


class GemmaVisionProvider:
    def __init__(self, *, api_key: str, model: str, base_url: str) -> None:
        self._api_key = api_key
        self._model = model
        self._base_url = base_url.rstrip("/")

    @property
    def provider_name(self) -> str:
        return "gemma"

    async def analyze(
        self,
        *,
        frame_b64: str | None,
        prompt: str,
        session_id: str,
    ) -> AIResponse:
        parts: list[dict[str, Any]] = [{"text": prompt}]
        if frame_b64:
            parts.insert(
                0,
                {
                    "inline_data": {
                        "mime_type": "image/jpeg",
                        "data": frame_b64,
                    }
                },
            )

        payload = {
            "system_instruction": {
                "parts": [{"text": SYSTEM_PROMPT}],
            },
            "contents": [
                {
                    "role": "user",
                    "parts": parts,
                }
            ],
            "generationConfig": {
                "responseMimeType": "application/json",
                "maxOutputTokens": 512,
            },
        }

        import asyncio

        models_to_try = [self._model] + [
            m for m in GEMMA_FALLBACK_MODELS if m != self._model
        ]

        last_error = ""
        for model in models_to_try:
            url = f"{self._base_url}/models/{model}:generateContent"
            try:
                async with httpx.AsyncClient(timeout=90.0) as client:
                    response = await client.post(
                        url,
                        headers={"x-goog-api-key": self._api_key},
                        json=payload,
                    )
            except httpx.RequestError as exc:
                raise RuntimeError("Could not reach AI provider") from exc

            if response.status_code in (429, 503):
                last_error = _provider_error_message(
                    response, fallback=f"{model} returned {response.status_code}"
                )
                logger.warning("Model %s unavailable (%d), trying next...", model, response.status_code)
                await asyncio.sleep(1)
                continue

            if response.status_code >= 400:
                last_error = _provider_error_message(
                    response, fallback=f"{model} returned {response.status_code}"
                )
                raise RuntimeError(last_error)

            # Success
            break
        else:
            raise RuntimeError(f"All models rate-limited. Last error: {last_error}")

        payload_json = response.json()
        raw_content = _gemma_text_from_response(payload_json)
        parsed = _coerce_json_payload(raw_content, provider_name="Gemma")
        _normalize_annotations(parsed)
        return AIResponse.model_validate(parsed)


def _build_live_provider(settings: Settings, *, api_key: str) -> AIProvider:
    if settings.ai_provider == "gemma":
        return GemmaVisionProvider(
            api_key=api_key,
            model=settings.gemma_model,
            base_url=settings.gemma_base_url,
        )

    return OpenAIVisionProvider(
        api_key=api_key,
        model=settings.openai_model,
        base_url=settings.openai_base_url,
    )


def _required_key_message(settings: Settings) -> str:
    if settings.ai_provider == "gemma":
        return "FIXWISE_AI_MODE=live with provider=gemma requires GEMMA_API_KEY or GOOGLE_API_KEY."
    return "FIXWISE_AI_MODE=live with provider=openai requires OPENAI_API_KEY."


async def validate_ai_api_key(settings: Settings, api_key: str) -> None:
    if settings.ai_provider == "gemma":
        validation_base = settings.gemma_base_url.rstrip("/")
        try:
            async with httpx.AsyncClient() as client:
                resp = await client.get(
                    f"{validation_base}/models",
                    headers={"x-goog-api-key": api_key},
                    timeout=10.0,
                )
        except httpx.RequestError as exc:
            raise ConnectionError("Could not reach AI provider to validate key.") from exc

        if resp.status_code == 200:
            return

        message = _provider_error_message(
            resp,
            fallback=f"Could not validate key (provider returned {resp.status_code}).",
        ).lower()
        if resp.status_code in {400, 401, 403} and (
            "api key" in message
            or "credential" in message
            or "permission" in message
            or "auth" in message
            or "unauthenticated" in message
        ):
            raise ValueError("API key is invalid or revoked.")

        raise ValueError(f"Could not validate key (provider returned {resp.status_code}).")

    validation_base = (settings.openai_base_url or "https://api.openai.com/v1").rstrip("/")
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.get(
                f"{validation_base}/models",
                headers={"Authorization": f"Bearer {api_key}"},
                timeout=10.0,
            )
    except httpx.RequestError as exc:
        raise ConnectionError("Could not reach AI provider to validate key.") from exc

    if resp.status_code == 401:
        raise ValueError("API key is invalid or revoked.")
    if resp.status_code not in (200, 403):
        raise ValueError(f"Could not validate key (provider returned {resp.status_code}).")


def build_ai_provider(settings: Settings, *, api_key_override: str | None = None) -> AIProvider:
    if api_key_override:
        return _build_live_provider(settings, api_key=api_key_override)

    if settings.ai_mode == "mock":
        return MockAIProvider()

    if settings.active_ai_api_key:
        return _build_live_provider(settings, api_key=settings.active_ai_api_key)

    if settings.ai_mode == "live":
        return UnavailableAIProvider(_required_key_message(settings))

    logger.warning(
        "No configured API key found for %s provider; falling back to mock AI provider.",
        settings.ai_provider,
    )
    return MockAIProvider()
