from __future__ import annotations

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
    frameMetadata: FrameMetadata


class PromptMessage(BaseModel):
    type: Literal["prompt"]
    sessionId: str = Field(min_length=1)
    timestamp: float
    text: str = Field(min_length=1)


class EndSessionMessage(BaseModel):
    type: Literal["end_session"]
    sessionId: str = Field(min_length=1)


class Point2D(BaseModel):
    x: float = Field(ge=0.0, le=1.0)
    y: float = Field(ge=0.0, le=1.0)


class AnnotationData(BaseModel):
    type: Literal["circle", "arrow", "label", "bounding_box"]
    label: str = Field(min_length=1)
    color: str | None = None
    x: float | None = Field(default=None, ge=0.0, le=1.0)
    y: float | None = Field(default=None, ge=0.0, le=1.0)
    radius: float | None = Field(default=None, ge=0.0, le=1.0)
    from_: Point2D | None = Field(default=None, alias="from")
    to: Point2D | None = None

    model_config = {"populate_by_name": True}


class AIResponse(BaseModel):
    text: str = Field(min_length=1)
    annotations: list[AnnotationData] = Field(default_factory=list)
    safetyWarning: str | None = None


class ResponseMessage(BaseModel):
    type: Literal["response"] = "response"
    sessionId: str
    text: str
    audio: str | None = None
    annotations: list[AnnotationData] = Field(default_factory=list)
    stepNumber: int
    safetyWarning: str | None = None


class SafetyBlockMessage(BaseModel):
    type: Literal["safety_block"] = "safety_block"
    sessionId: str
    reason: str
    recommendation: str


class ErrorMessage(BaseModel):
    type: Literal["error"] = "error"
    message: str
    sessionId: str | None = None


ClientMessage = Annotated[
    FrameMessage | PromptMessage | EndSessionMessage,
    Field(discriminator="type"),
]
CLIENT_MESSAGE_ADAPTER = TypeAdapter(ClientMessage)


def parse_client_message(payload: dict) -> FrameMessage | PromptMessage | EndSessionMessage:
    return CLIENT_MESSAGE_ADAPTER.validate_python(payload)
