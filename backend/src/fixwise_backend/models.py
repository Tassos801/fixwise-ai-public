from __future__ import annotations

from typing import Annotated, Literal, get_args

from pydantic import BaseModel, Field, TypeAdapter, field_validator

from .guidance_modes import DEFAULT_GUIDANCE_MODE, normalize_guidance_mode


SetupType = Literal[
    "general_task",
    "home_repair",
    "plumbing_repair",
    "electrical_repair",
    "plant_care",
    "exercise_form",
    "cooking_task",
    "car_maintenance",
    "machine_setup",
    "pc_build",
    "display_setup",
    "network_setup",
    "peripheral_setup",
    "unknown",
]

TaskPhase = Literal[
    "identify",
    "inspect",
    "prepare",
    "connect",
    "act",
    "adjust",
    "verify",
    "troubleshoot",
    "complete",
]

ComponentKind = Literal[
    "port",
    "cable",
    "component",
    "slot",
    "header",
    "device",
    "part",
    "tool",
    "fixture",
    "fastener",
    "plant",
    "soil",
    "body_position",
    "food",
    "equipment",
    "vehicle_part",
    "unknown",
]

TroubleshootingFocus = Literal[
    "safety_check",
    "no_display",
    "no_power",
    "not_detected",
    "network_issue",
    "plant_health",
    "form_risk",
    "doneness",
    "diagnosis",
    "repair_issue",
]

_SETUP_TYPES: frozenset[str] = frozenset(get_args(SetupType))
_TASK_PHASES: frozenset[str] = frozenset(get_args(TaskPhase))
_COMPONENT_KINDS: frozenset[str] = frozenset(get_args(ComponentKind))
_TROUBLESHOOTING_FOCUSES: frozenset[str] = frozenset(get_args(TroubleshootingFocus))


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
    kind: ComponentKind = "unknown"
    confidence: Literal["low", "medium", "high"] = "medium"
    x: float | None = Field(default=None, ge=0.0, le=1.0)
    y: float | None = Field(default=None, ge=0.0, le=1.0)

    @field_validator("kind", mode="before")
    @classmethod
    def validate_kind(cls, value: object) -> str:
        if isinstance(value, str) and value in _COMPONENT_KINDS:
            return value
        return "unknown"


class TaskState(BaseModel):
    setupType: SetupType = "unknown"
    phase: TaskPhase = "identify"
    title: str = "Setup checklist"
    checklist: list[TaskChecklistItem] = Field(default_factory=list)
    visibleComponents: list[DetectedComponent] = Field(default_factory=list)
    troubleshootingFocus: TroubleshootingFocus | None = None

    @field_validator("setupType", mode="before")
    @classmethod
    def validate_setup_type(cls, value: object) -> str:
        if isinstance(value, str) and value in _SETUP_TYPES:
            return value
        return "unknown"

    @field_validator("phase", mode="before")
    @classmethod
    def validate_phase(cls, value: object) -> str:
        if isinstance(value, str) and value in _TASK_PHASES:
            return value
        return "identify"

    @field_validator("troubleshootingFocus", mode="before")
    @classmethod
    def validate_troubleshooting_focus(cls, value: object) -> str | None:
        if isinstance(value, str) and value in _TROUBLESHOOTING_FOCUSES:
            return value
        return None


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
