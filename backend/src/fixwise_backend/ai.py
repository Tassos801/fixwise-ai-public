from __future__ import annotations

import json
import logging
from typing import Protocol

from .config import Settings
from .models import AIResponse, AnnotationData


logger = logging.getLogger("fixwise.ai")

SYSTEM_PROMPT = """You are FixWise AI, a hands-on task guidance assistant.

You help users with safe DIY home repairs, car maintenance, PC building, and similar physical tasks.

Critical safety rules:
1. Refuse tasks involving high-voltage electricity (>50V), gas lines, structural load-bearing elements, or hazardous materials.
2. When refusing, explain why it is dangerous and recommend a licensed professional.
3. Proactively mention essential PPE when relevant.

Return valid JSON with this shape:
{
  "text": "concise spoken guidance",
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
        elif "what" in lower or "next" in lower:
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
                "I can see your workspace. Move the camera slightly closer to the component you want to work on, "
                "then ask for the next step."
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
                f"I have your latest frame for session {session_id[:8]}. "
                f"For '{prompt}', start by steadying the camera and focusing on the part you want to inspect."
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


class OpenAIVisionProvider:
    def __init__(self, *, api_key: str, model: str) -> None:
        from openai import AsyncOpenAI

        self._client = AsyncOpenAI(api_key=api_key)
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
        content: list[dict] = [{"type": "text", "text": prompt}]
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
        try:
            parsed = json.loads(raw_content)
        except json.JSONDecodeError as exc:
            raise RuntimeError("OpenAI response was not valid JSON") from exc

        return AIResponse.model_validate(parsed)


def build_ai_provider(settings: Settings) -> AIProvider:
    if settings.ai_mode == "mock":
        return MockAIProvider()

    if settings.openai_api_key:
        return OpenAIVisionProvider(
            api_key=settings.openai_api_key,
            model=settings.openai_model,
        )

    if settings.ai_mode == "live":
        return UnavailableAIProvider("FIXWISE_AI_MODE=live requires OPENAI_API_KEY.")

    logger.warning("OPENAI_API_KEY not set; falling back to mock AI provider.")
    return MockAIProvider()
