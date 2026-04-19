from __future__ import annotations

import json
import logging
from typing import Any, Literal, Protocol

import httpx

from .config import Settings
from .guidance_modes import (
    get_guidance_mode_label,
    get_system_prompt,
    normalize_guidance_mode,
)
from .models import AIResponse, AnnotationData, FrameMetadata
from .session_manager import SessionContext


logger = logging.getLogger("fixwise.ai")

LOW_QUALITY_MIN_DIMENSION = 360
LOW_QUALITY_MIN_SCENE_DELTA = 0.45


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


def _compact_text(text: str, *, limit: int = 120) -> str:
    stripped = " ".join(text.strip().split())
    if len(stripped) <= limit:
        return stripped
    return stripped[: limit - 1].rstrip() + "…"


def _mode_focus_target(mode: str) -> str:
    normalized = normalize_guidance_mode(mode)
    return {
        "general": "part",
        "home_repair": "fixture, fastener, or connection",
        "gardening": "plant, leaf, or stem",
        "gym": "movement or equipment setup",
        "cooking": "ingredient, pan, or dish",
        "car": "engine part or service point",
        "machines": "connector, panel, or component",
    }.get(normalized, "part")


def _context_lines(session_context: SessionContext | None) -> list[str]:
    if session_context is None:
        return []

    lines: list[str] = []
    if session_context.task_summary:
        lines.append(f"Session summary: {_compact_text(session_context.task_summary, limit=160)}")
    if session_context.last_next_action:
        lines.append(f"Last next action: {_compact_text(session_context.last_next_action, limit=160)}")
    if session_context.recent_turns:
        lines.append("Recent turns:")
        for turn in session_context.recent_turns[-3:]:
            prefix = "User" if turn.role == "user" else "Assistant"
            details = _compact_text(turn.text, limit=140)
            if turn.role == "assistant" and turn.next_action:
                details = f"{details} | Next: {_compact_text(turn.next_action, limit=80)}"
            lines.append(f"- {prefix}: {details}")
    return lines


def _build_context_prompt(
    *,
    prompt: str,
    session_context: SessionContext | None,
    frame_metadata: FrameMetadata | None,
) -> str:
    parts: list[str] = []
    context_lines = _context_lines(session_context)
    if context_lines:
        parts.append("SESSION MEMORY:\n" + "\n".join(context_lines))
    if frame_metadata is not None:
        quality_notes = _frame_quality_notes(frame_metadata)
        if quality_notes:
            parts.append("FRAME QUALITY:\n" + "\n".join(f"- {note}" for note in quality_notes))
    parts.append(f"USER QUESTION:\n{prompt}")
    return "\n\n".join(parts)


def _frame_quality_notes(frame_metadata: FrameMetadata) -> list[str]:
    notes: list[str] = []
    if frame_metadata.width < LOW_QUALITY_MIN_DIMENSION or frame_metadata.height < LOW_QUALITY_MIN_DIMENSION:
        notes.append("The frame is small and may need a closer view.")
    if frame_metadata.sceneDelta >= LOW_QUALITY_MIN_SCENE_DELTA:
        notes.append("The scene is changing quickly, so the camera may be moving too much.")
    return notes


def _frame_needs_closer_view(frame_metadata: FrameMetadata | None) -> bool:
    if frame_metadata is None:
        return False
    if frame_metadata.width < LOW_QUALITY_MIN_DIMENSION or frame_metadata.height < LOW_QUALITY_MIN_DIMENSION:
        return True
    if frame_metadata.sceneDelta >= LOW_QUALITY_MIN_SCENE_DELTA:
        return True
    return False


def _make_closer_frame_response(*, prompt: str, frame_metadata: FrameMetadata | None) -> AIResponse:
    notes = _frame_quality_notes(frame_metadata) if frame_metadata else []
    text = (
        "I need a closer, steadier view before I can be confident. "
        "Move the phone closer to the exact part, hold it still for a second, and keep the target centered."
    )
    if notes:
        text = f"{text} {notes[0]}"
    return AIResponse(
        text=text,
        annotations=[],
        safetyWarning=None,
        nextAction="Move closer to the exact part and hold the phone steady.",
        needsCloserFrame=True,
        followUpPrompts=[
            "Can you move closer and keep the target centered?",
            "What exact part should I focus on next?",
        ],
        confidence="low",
    )


class ProviderConfigurationError(RuntimeError):
    """Raised when live AI is requested without the required configuration."""


class AIProvider(Protocol):
    async def analyze(
        self,
        *,
        frame_b64: str | None,
        frame_metadata: FrameMetadata | None,
        prompt: str,
        mode: str,
        session_id: str,
        session_context: SessionContext | None = None,
    ) -> AIResponse: ...

    @property
    def provider_name(self) -> str: ...


class MockAIProvider:
    def _contains_any(self, text: str, phrases: tuple[str, ...]) -> bool:
        return any(phrase in text for phrase in phrases)

    def _response(
        self,
        *,
        text: str,
        annotations: list[AnnotationData] | None = None,
        safety_warning: str | None = None,
        next_action: str | None = None,
        needs_closer_frame: bool = False,
        follow_up_prompts: list[str] | None = None,
        confidence: Literal["low", "medium", "high"] = "medium",
    ) -> AIResponse:
        return AIResponse(
            text=text,
            annotations=annotations or [],
            safetyWarning=safety_warning,
            nextAction=next_action,
            needsCloserFrame=needs_closer_frame,
            followUpPrompts=follow_up_prompts or [],
            confidence=confidence,
        )

    @property
    def provider_name(self) -> str:
        return "mock"

    async def analyze(
        self,
        *,
        frame_b64: str | None,
        frame_metadata: FrameMetadata | None,
        prompt: str,
        mode: str,
        session_id: str,
        session_context: SessionContext | None = None,
    ) -> AIResponse:
        lower = prompt.lower()
        selected_mode = normalize_guidance_mode(mode)
        focus_target = _mode_focus_target(selected_mode)
        mode_label = get_guidance_mode_label(selected_mode)
        recent_summary = session_context.task_summary if session_context else None
        last_next_action = session_context.last_next_action if session_context else None
        if _frame_needs_closer_view(frame_metadata):
            return _make_closer_frame_response(prompt=prompt, frame_metadata=frame_metadata)

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
        if asks_next_step and last_next_action:
            text = (
                f"Based on where we left off, the next small step is to {last_next_action.lower()}. "
                "Keep the phone steady while you do that, and then ask me what changed."
            )
            return self._response(
                text=text,
                annotations=[
                    AnnotationData(
                        type="label",
                        label="Next step",
                        x=0.5,
                        y=0.28,
                        color="#2B6CB0",
                    )
                ],
                next_action=last_next_action,
                follow_up_prompts=[
                    "Show me the result after that step.",
                    "Do you want me to zoom in on anything specific?",
                ],
                confidence="high",
            )
        if asks_next_step and recent_summary:
            text = (
                f"You're working on {_compact_text(recent_summary, limit=80)}. "
                f"The next small step is to keep the camera steady on the exact {focus_target} and make the smallest reversible change first."
            )
            return self._response(
                text=text,
                annotations=[
                    AnnotationData(
                        type="label",
                        label="Start here",
                        x=0.5,
                        y=0.35,
                        color="#2B6CB0",
                    )
                ],
                next_action=f"Keep the camera steady on the exact {focus_target} and make the smallest reversible change first.",
                follow_up_prompts=[
                    "Do you want me to inspect a specific fastener or connector?",
                    "Should I stay focused on this same part?",
                ],
                confidence="high",
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
            return self._response(
                text=text,
                annotations=annotations,
                next_action="Turn the valve counterclockwise slowly and stop if you feel unusual resistance.",
                follow_up_prompts=[
                    "Do you want me to help verify the valve direction?",
                    "Should I look for a shutoff mark or label next?",
                ],
                confidence="high",
            )
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
            return self._response(
                text=text,
                annotations=annotations,
                next_action="Line the cable up gently before pressing it into place.",
                follow_up_prompts=[
                    "Do you want me to check the connector orientation?",
                    "Should I help you confirm the fit after you plug it in?",
                ],
                confidence="high",
            )
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
            return self._response(
                text=text,
                annotations=annotations,
                next_action="Confirm the area is powered down or otherwise safe before touching it.",
                follow_up_prompts=[
                    "Do you want me to look for a shutoff or disconnect point?",
                    "Should I check for pinch points or moving parts next?",
                ],
                confidence="high",
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
            return self._response(
                text=text,
                annotations=annotations,
                next_action="Gather a flashlight and the simplest tool that fits the fastener cleanly.",
                follow_up_prompts=[
                    "Do you want me to identify the fastener type?",
                    "Should I help you check whether the tool fit is correct?",
                ],
                confidence="high",
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
                f"I can see the {mode_label.lower()} workspace. Start with the smallest reversible action: move a little closer to the exact "
                f"{focus_target} you want to touch, hold the phone steady, and inspect it before moving it. "
                "If you want, ask whether this is the right part, whether it looks safe, or what tool to use next."
            )
            return self._response(
                text=text,
                annotations=annotations,
                next_action=f"Move a little closer to the exact {focus_target}, hold the phone steady, and inspect it before moving it.",
                follow_up_prompts=[
                    "Want me to help identify the exact part?",
                    "Should I tell you whether it looks safe before you touch it?",
                ],
                confidence="medium",
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
                f"I can see the general {mode_label.lower()} workspace, but I need a closer view of the exact {focus_target} to identify it well. "
                "Center it and keep the phone still for a second."
            )
            return self._response(
                text=text,
                annotations=annotations,
                next_action=f"Center the exact {focus_target} you care about and keep the phone still for a second.",
                needs_closer_frame=True,
                follow_up_prompts=[
                    "Can you center the exact part in view?",
                    "Should I help identify a label or connector instead?",
                ],
                confidence="medium",
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
                f"Keep the camera steady on the exact {focus_target} you want help with, and I will guide you through the next small step."
            )
            return self._response(
                text=text,
                annotations=annotations,
                next_action=f"Keep the camera steady on the exact {focus_target} you want help with.",
                follow_up_prompts=[
                    "Should I zoom in on a different angle?",
                    "Do you want me to help with the next small step?",
                ],
                confidence="medium",
            )
        else:
            annotations = []
            text = "I do not have a frame yet. Point the camera at the task area, then ask your question again."
            return self._response(
                text=text,
                annotations=annotations,
                next_action="Point the camera at the task area and ask again.",
                needs_closer_frame=True,
                follow_up_prompts=[
                    "Can you point the camera at the work area?",
                    "Should I help once you have the part centered?",
                ],
                confidence="low",
            )


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
        frame_metadata: FrameMetadata | None,
        prompt: str,
        mode: str,
        session_id: str,
        session_context: SessionContext | None = None,
    ) -> AIResponse:
        raise ProviderConfigurationError(self._message)


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
        frame_metadata: FrameMetadata | None,
        prompt: str,
        mode: str,
        session_id: str,
        session_context: SessionContext | None = None,
    ) -> AIResponse:
        system_prompt = get_system_prompt(mode)
        prompt_text = _build_context_prompt(
            prompt=prompt,
            session_context=session_context,
            frame_metadata=frame_metadata,
        )
        content: list[dict[str, Any]] = []
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
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": [{"type": "text", "text": prompt_text}, *content]},
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
        frame_metadata: FrameMetadata | None,
        prompt: str,
        mode: str,
        session_id: str,
        session_context: SessionContext | None = None,
    ) -> AIResponse:
        system_prompt = get_system_prompt(mode)
        prompt_text = _build_context_prompt(
            prompt=prompt,
            session_context=session_context,
            frame_metadata=frame_metadata,
        )
        parts: list[dict[str, Any]] = []
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
                "parts": [{"text": system_prompt}],
            },
            "contents": [
                {
                    "role": "user",
                    "parts": [{"text": prompt_text}, *parts],
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

    if settings.ai_mode == "live" or (
        settings.environment == "production" and settings.ai_mode == "auto"
    ):
        return UnavailableAIProvider(_required_key_message(settings))

    logger.warning(
        "No configured API key found for %s provider; falling back to mock AI provider in development.",
        settings.ai_provider,
    )
    return MockAIProvider()
