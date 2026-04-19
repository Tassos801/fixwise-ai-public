from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, Field, TypeAdapter, field_validator

from .guidance_modes import DEFAULT_GUIDANCE_MODE, normalize_guidance_mode


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
    mode: str = DEFAULT_GUIDANCE_MODE

    @field_validator("mode", mode="before")
    @classmethod
    def validate_mode(cls, value: object) -> str:
        if not isinstance(value, str):
            return DEFAULT_GUIDANCE_MODE
        return normalize_guidance_mode(value)


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


class TaskChecklistItem(BaseModel):
    id: str = Field(min_length=1)
    title: str = Field(min_length=1)
    status: Literal["pending", "active", "done", "blocked"] = "pending"
    detail: str | None = None


class DetectedComponent(BaseModel):
    label: str = Field(min_length=1)
    kind: Literal["port", "cable", "component", "slot", "header", "device", "unknown"] = "unknown"
    confidence: Literal["low", "medium", "high"] = "medium"
    x: float | None = Field(default=None, ge=0.0, le=1.0)
    y: float | None = Field(default=None, ge=0.0, le=1.0)


class TaskState(BaseModel):
    setupType: Literal[
        "pc_build",
        "display_setup",
        "network_setup",
        "peripheral_setup",
        "unknown",
    ] = "unknown"
    phase: Literal["identify", "connect", "verify", "troubleshoot", "complete"] = "identify"
    title: str = "Setup checklist"
    checklist: list[TaskChecklistItem] = Field(default_factory=list)
    visibleComponents: list[DetectedComponent] = Field(default_factory=list)
    troubleshootingFocus: Literal[
        "no_display",
        "no_power",
        "not_detected",
        "network_issue",
    ] | None = None


class AIResponse(BaseModel):
    text: str = Field(min_length=1)
    annotations: list[AnnotationData] = Field(default_factory=list)
    safetyWarning: str | None = None
    nextAction: str | None = None
    needsCloserFrame: bool = False
    followUpPrompts: list[str] = Field(default_factory=list)
    confidence: Literal["low", "medium", "high"] = "medium"
    taskState: TaskState | None = None


class ResponseMessage(BaseModel):
    type: Literal["response"] = "response"
    sessionId: str
    text: str
    audio: str | None = None
    annotations: list[AnnotationData] = Field(default_factory=list)
    stepNumber: int
    safetyWarning: str | None = None
    nextAction: str | None = None
    needsCloserFrame: bool = False
    followUpPrompts: list[str] = Field(default_factory=list)
    confidence: Literal["low", "medium", "high"] = "medium"
    mode: str = DEFAULT_GUIDANCE_MODE
    suggestedMode: str | None = None
    summary: str | None = None
    taskState: TaskState | None = None

    @field_validator("mode", mode="before")
    @classmethod
    def validate_response_mode(cls, value: object) -> str:
        if not isinstance(value, str):
            return DEFAULT_GUIDANCE_MODE
        return normalize_guidance_mode(value)

    @field_validator("suggestedMode", mode="before")
    @classmethod
    def validate_suggested_mode(cls, value: object) -> str | None:
        if not isinstance(value, str):
            return None
        normalized = normalize_guidance_mode(value)
        if normalized == DEFAULT_GUIDANCE_MODE:
            return None
        return normalized


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
