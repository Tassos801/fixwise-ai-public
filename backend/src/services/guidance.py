from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Protocol

from src.models import Annotation, GuidanceResult, Point
from src.utils.config import Settings


SYSTEM_PROMPT = """You are FixWise AI, a hands-on task guidance assistant.

CRITICAL SAFETY RULES:
1. Refuse to guide tasks involving high-voltage electricity (>50V), gas lines, structural load-bearing elements, or hazardous materials such as asbestos or lead paint.
2. When refusing, explain why it is dangerous and recommend a licensed professional.
3. Return concise, actionable guidance for safe tasks.

RESPONSE FORMAT:
Return a JSON object with this shape:
{
  "text": "short spoken guidance",
  "annotations": [
    {
      "type": "circle|arrow|label|bounding_box",
      "label": "description",
      "x": 0.0,
      "y": 0.0,
      "radius": 0.0,
      "color": "#hex",
      "from": {"x": 0.0, "y": 0.0},
      "to": {"x": 0.0, "y": 0.0}
    }
  ],
  "safetyWarning": null
}
Use normalized 0.0-1.0 coordinates relative to the image.
"""


class GuidanceProvider(Protocol):
    async def generate(self, prompt: str, frame_b64: str | None) -> GuidanceResult:
        """Produce guidance for the user's prompt and current frame."""


@dataclass(frozen=True)
class GuidanceService:
    provider: GuidanceProvider
    active_mode: str

    async def generate(self, prompt: str, frame_b64: str | None) -> GuidanceResult:
        return await self.provider.generate(prompt=prompt, frame_b64=frame_b64)


class MockGuidanceProvider:
    async def generate(self, prompt: str, frame_b64: str | None) -> GuidanceResult:
        normalized = prompt.lower()
        if not frame_b64:
            return GuidanceResult(
                text="Point the camera at the task area, then ask your question again.",
                annotations=[
                    Annotation(
                        type="label",
                        label="Frame needed",
                        x=0.5,
                        y=0.5,
                        color="#FF6B35",
                    )
                ],
            )

        if "valve" in normalized:
            return GuidanceResult(
                text="Center the valve in frame and turn it counterclockwise in short quarter turns.",
                annotations=[
                    Annotation(
                        type="circle",
                        label="Valve",
                        x=0.48,
                        y=0.58,
                        radius=0.09,
                        color="#FF6B35",
                    )
                ],
            )

        if "wire" in normalized or "cable" in normalized:
            return GuidanceResult(
                text="Check that the cable is fully seated before applying force anywhere else.",
                annotations=[
                    Annotation(
                        type="arrow",
                        label="Check connection",
                        color="#00D4AA",
                        from_point=Point(x=0.32, y=0.46),
                        to_point=Point(x=0.55, y=0.62),
                    )
                ],
            )

        return GuidanceResult(
            text="I can see the workspace. Hold the phone steady and focus on the exact part you want help with.",
            annotations=[
                Annotation(
                    type="label",
                    label="Focus here",
                    x=0.5,
                    y=0.55,
                    color="#00A3FF",
                )
            ],
        )


class OpenAIGuidanceProvider:
    def __init__(self, api_key: str, model: str) -> None:
        self._model = model
        from openai import AsyncOpenAI

        self._client: Any = AsyncOpenAI(api_key=api_key)

    async def generate(self, prompt: str, frame_b64: str | None) -> GuidanceResult:
        user_content: list[dict[str, object]] = [{"type": "text", "text": prompt}]
        if frame_b64:
            user_content.append(
                {
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:image/jpeg;base64,{frame_b64}",
                        "detail": "low",
                    },
                }
            )

        response = await self._client.chat.completions.create(
            model=self._model,
            response_format={"type": "json_object"},
            max_tokens=500,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_content},
            ],
        )

        content = response.choices[0].message.content or "{}"
        return _parse_guidance_payload(content)


def build_guidance_service(settings: Settings) -> GuidanceService:
    if settings.effective_ai_mode == "live" and settings.openai_api_key:
        provider: GuidanceProvider = OpenAIGuidanceProvider(
            api_key=settings.openai_api_key,
            model=settings.openai_model,
        )
    else:
        provider = MockGuidanceProvider()

    return GuidanceService(provider=provider, active_mode=settings.effective_ai_mode)


def _parse_guidance_payload(payload: str) -> GuidanceResult:
    try:
        raw = json.loads(payload)
    except json.JSONDecodeError:
        return GuidanceResult(text=payload.strip() or "I could not understand that response.")

    annotations: list[Annotation] = []
    for raw_annotation in raw.get("annotations", []):
        annotations.append(
            Annotation(
                type=raw_annotation.get("type", "label"),
                label=raw_annotation.get("label", "Focus here"),
                x=raw_annotation.get("x"),
                y=raw_annotation.get("y"),
                radius=raw_annotation.get("radius"),
                color=raw_annotation.get("color"),
                from_point=_parse_point(raw_annotation.get("from")),
                to_point=_parse_point(raw_annotation.get("to")),
            )
        )

    return GuidanceResult(
        text=raw.get("text", "I could not produce guidance for that image."),
        annotations=annotations,
        safety_warning=raw.get("safetyWarning"),
    )


def _parse_point(value: object) -> Point | None:
    if not isinstance(value, dict):
        return None

    x = value.get("x")
    y = value.get("y")
    if isinstance(x, (int, float)) and isinstance(y, (int, float)):
        return Point(x=float(x), y=float(y))
    return None
