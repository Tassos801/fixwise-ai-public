from __future__ import annotations

from dataclasses import dataclass, field
from typing import Annotated, Literal

from pydantic import BaseModel, Field, TypeAdapter


class APIKeyRequest(BaseModel):
    apiKey: str


class FrameMetadata(BaseModel):
    width: int = Field(gt=0)
    height: int = Field(gt=0)
    sceneDelta: float = Field(ge=0.0)


class FrameMessage(BaseModel):
    type: Literal["frame"]
    sessionId: str = Field(min_length=1)
    timestamp: float
    frame: str = Field(min_length=1)
    frameMetadata: FrameMetadata | None = None


class PromptMessage(BaseModel):
    type: Literal["prompt"]
    sessionId: str = Field(min_length=1)
    timestamp: float
    text: str = Field(min_length=1)


class EndSessionMessage(BaseModel):
    type: Literal["end_session"]
    sessionId: str = Field(min_length=1)


ClientMessage = Annotated[
    FrameMessage | PromptMessage | EndSessionMessage,
    Field(discriminator="type"),
]
CLIENT_MESSAGE_ADAPTER = TypeAdapter(ClientMessage)


def parse_client_message(payload: dict) -> FrameMessage | PromptMessage | EndSessionMessage:
    return CLIENT_MESSAGE_ADAPTER.validate_python(payload)


@dataclass(frozen=True)
class Point:
    x: float
    y: float

    def to_dict(self) -> dict[str, float]:
        return {"x": self.x, "y": self.y}


@dataclass(frozen=True)
class Annotation:
    type: str
    label: str
    x: float | None = None
    y: float | None = None
    radius: float | None = None
    color: str | None = None
    from_point: Point | None = None
    to_point: Point | None = None

    def to_dict(self) -> dict[str, object]:
        payload: dict[str, object] = {
            "type": self.type,
            "label": self.label,
            "color": self.color,
        }
        if self.x is not None:
            payload["x"] = self.x
        if self.y is not None:
            payload["y"] = self.y
        if self.radius is not None:
            payload["radius"] = self.radius
        if self.from_point is not None:
            payload["from"] = self.from_point.to_dict()
        if self.to_point is not None:
            payload["to"] = self.to_point.to_dict()
        return payload


@dataclass(frozen=True)
class GuidanceResult:
    text: str
    annotations: list[Annotation] = field(default_factory=list)
    safety_warning: str | None = None
