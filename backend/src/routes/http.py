from __future__ import annotations

from fastapi import APIRouter, HTTPException, Request

from src.models import APIKeyRequest


router = APIRouter()


@router.get("/health")
async def healthcheck(request: Request) -> dict:
    settings = request.app.state.settings
    guidance_service = request.app.state.guidance_service
    return {
        "status": "ok",
        "name": settings.app_name,
        "version": settings.app_version,
        "desiredMode": settings.desired_ai_mode,
        "activeMode": guidance_service.active_mode,
        "liveConfigured": settings.live_configured,
        "model": settings.openai_model,
    }


@router.put("/api/settings/api-key")
async def save_api_key(_: APIKeyRequest) -> dict:
    raise HTTPException(
        status_code=501,
        detail="BYOK storage is deferred for this vertical slice.",
    )


@router.delete("/api/settings/api-key")
async def delete_api_key() -> dict:
    raise HTTPException(
        status_code=501,
        detail="BYOK storage is deferred for this vertical slice.",
    )


@router.get("/api/sessions")
async def list_sessions() -> dict:
    raise HTTPException(
        status_code=501,
        detail="Session history is deferred for this vertical slice.",
    )


@router.get("/api/sessions/{session_id}/report")
async def get_fix_report(session_id: str) -> dict:
    raise HTTPException(
        status_code=501,
        detail=f"Fix reports for session {session_id} are deferred for this vertical slice.",
    )
